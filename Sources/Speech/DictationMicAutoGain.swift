import Foundation

/// Automatic gain for one dictation take's microphone, so a quiet mic
/// (a dynamic USB mic, or the built-in one from across the desk) reaches
/// the transcriber at a usable level without clipping or lifting hiss.
///
/// Works in ~10 ms blocks, so it behaves the same at any sample rate and any
/// buffer of 10 ms or more (both capture paths deliver 10-85 ms; a shorter
/// buffer is one shorter block):
/// - The noise floor is the quietest block heard in the last
///   `noiseFloorWindowSeconds`, skipping the `noiseFloorOutlierBlocks`
///   quietest (a block straddling a dropout or a burst's edge would otherwise
///   drag it down for a whole window). Digital silence after the mic's first signal
///   counts as a very low floor once it lasts `minimumGatedPauseSeconds`, so
///   a mic that gates its pauses to zero still has speech detected; zeros
///   before it (a device warming up) and brief dropouts don't.
/// - A block is speech when it's `speechAboveNoiseDB` over that floor and
///   over `minimumSpeechDBFS`; only speech moves the speech level estimate,
///   so pauses, hiss and the take's lead-in never set the boost. The
///   estimate climbs fast and sinks slowly, so it follows the loud part of
///   speech (about the 90th percentile of 10 ms levels), not its average.
///   Nothing is boosted until `speechToStartSeconds` of speech has been
///   heard within about a second: a lone click or breath in a silent take
///   would otherwise lift its room tone for the rest of the take, enough to
///   pass the "usable speech" check in `DictationAudioRecovery`.
/// - The boost lifts the speech estimate toward `targetSpeechDBFS`, never
///   below unity (a loud mic is left alone), never past `maxGainDB`, and
///   never so far that the noise floor would pass `boostedNoiseCeilingDBFS`.
///   It rises at most `maxGainRiseDBPerSecond` and is ramped across each
///   block so it can't click.
/// - Each block's peak is known before the boost is applied, so the boost is
///   capped to keep every sample at or under `peakCeiling`: no clipping and no
///   distortion, and nothing ever comes out quieter than it went in.
///
/// Same shape as WebRTC's AGC2 adaptive digital gain (noise estimate, speech
/// level estimate, limiter), with an energy-over-noise check standing in for
/// its neural VAD. Unlike the meeting path's `RealtimeAGC` it aims the
/// speech level rather than a windowed peak (a key click doesn't pull the
/// boost down) and never zeroes quiet buffers, so the digital-silence check on
/// a dead mic still sees what the mic sent.
///
/// One instance per take, fed from that take's capture queue (the pinned
/// recorder's queue or the engine tap's thread), never the real-time audio
/// thread. The lock is uncontended; like `DictationAudioLevelWindow`'s, it's
/// there so a feed that moves threads can't tear the state. No allocation
/// after init.
final class DictationMicAutoGain: @unchecked Sendable {
    struct Tuning: Equatable, Sendable {
        /// The speech level estimate is raised toward this.
        var targetSpeechDBFS: Float
        /// Most boost ever applied.
        var maxGainDB: Float
        /// The boost stops before the tracked noise floor would pass this.
        var boostedNoiseCeilingDBFS: Float
        /// Linear. No output sample is louder than this unless the raw
        /// sample already was.
        var peakCeiling: Float
        /// A block counts as speech when its RMS is this far over the noise
        /// floor...
        var speechAboveNoiseDB: Float
        /// ...and over this absolute level.
        var minimumSpeechDBFS: Float
        /// Fastest the boost may grow.
        var maxGainRiseDBPerSecond: Float
        /// Seconds of speech the level estimate takes to climb to a louder
        /// word. Short, so the estimate rides the loud part of speech...
        var speechLevelRiseSeconds: Float
        /// ...and long to sink back, so quiet syllables, word tails and
        /// breaths between words don't drag it down.
        var speechLevelFallSeconds: Float
        /// How far back the noise floor looks for its quietest block.
        var noiseFloorWindowSeconds: Float
        /// Speech heard within about the last second before the first boost.
        var speechToStartSeconds: Float

        static let `default` = Tuning(
            targetSpeechDBFS: -22,
            maxGainDB: 30,
            boostedNoiseCeilingDBFS: -50,
            peakCeiling: 0.89,
            speechAboveNoiseDB: 10,
            minimumSpeechDBFS: -65,
            maxGainRiseDBPerSecond: 30,
            speechLevelRiseSeconds: 0.1,
            speechLevelFallSeconds: 1.5,
            noiseFloorWindowSeconds: 1.5,
            speechToStartSeconds: 0.15
        )
    }

    /// Analysis block length. Short enough to tell a word from the gap after
    /// it, long enough for a steady level reading.
    static let blockSeconds = 0.010
    /// Blocks at or under this are digital silence, not a level reading.
    static let digitalSilenceDBFS: Float = -100
    /// Rates below this aren't a real microphone format.
    static let minimumSampleRate = 1_000.0
    /// How long heard speech keeps counting toward `speechToStartSeconds`.
    static let speechEvidenceSeconds: Float = 1
    /// Zeros shorter than this are a dropout, not a gated pause.
    static let minimumGatedPauseSeconds: Float = 0.1
    /// The quietest blocks in the window the noise floor skips.
    static let noiseFloorOutlierBlocks = 3

    let tuning: Tuning
    private let lock = NSLock()
    /// Linear boost at the end of the last block.
    private var gain: Float = 1
    private var speechLevelDBFS: Float?
    /// Seconds of speech, leaking away over `speechEvidenceSeconds`.
    private var recentSpeechSeconds: Float = 0
    private var heardEnoughSpeech = false
    private var heardSignal = false
    private var digitalSilenceRunSeconds: Float = 0
    /// Ring of recent block levels for the noise floor.
    private var recentBlockLevelsDBFS: [Float]
    private var recentBlockLevelCount = 0
    private var nextRecentBlockIndex = 0
    /// Scratch for the quietest few levels, so the floor never allocates.
    private var quietestBlockLevelsDBFS = [Float](repeating: 0, count: noiseFloorOutlierBlocks + 1)

    init(tuning: Tuning = .default) {
        self.tuning = tuning
        let windowBlocks = Int((Double(max(0, tuning.noiseFloorWindowSeconds)) / Self.blockSeconds).rounded())
        recentBlockLevelsDBFS = [Float](repeating: 0, count: max(1, windowBlocks))
    }

    /// Boost applied at the end of the last processed buffer, in dB.
    var currentGainDB: Float { lock.withLock { gainDB } }

    private var gainDB: Float { 20 * log10(gain) }

    /// Boosts one buffer of mono samples in place. A buffer with a NaN or
    /// infinite sample, or an unusable rate, is left as is and doesn't touch
    /// the state, so a driver glitch can't poison the rest of the take.
    func process(_ samples: inout [Float], sampleRate: Double) {
        guard !samples.isEmpty,
              sampleRate.isFinite,
              sampleRate >= Self.minimumSampleRate,
              samples.allSatisfy(\.isFinite) else { return }

        let blockCount = max(1, Int((Double(samples.count) / (sampleRate * Self.blockSeconds)).rounded()))
        lock.lock()
        defer { lock.unlock() }
        samples.withUnsafeMutableBufferPointer { buffer in
            for block in 0..<blockCount {
                // Even split, so no buffer ends on a sliver of a block.
                let start = buffer.count * block / blockCount
                let end = buffer.count * (block + 1) / blockCount
                guard end > start else { continue }
                processBlock(
                    UnsafeMutableBufferPointer(rebasing: buffer[start..<end]),
                    seconds: Float(Double(end - start) / sampleRate)
                )
            }
        }
    }

    private func processBlock(_ block: UnsafeMutableBufferPointer<Float>, seconds: Float) {
        var sumOfSquares: Float = 0
        var peak: Float = 0
        for sample in block {
            sumOfSquares += sample * sample
            peak = max(peak, abs(sample))
        }
        // Sums of huge but finite samples can still overflow.
        guard sumOfSquares.isFinite else { return }
        let levelDBFS = max(
            Self.digitalSilenceDBFS,
            10 * log10(max(sumOfSquares / Float(block.count), .leastNonzeroMagnitude))
        )

        // Judged against the floor before this block joins it.
        let noiseFloorDBFS = trackedNoiseFloorDBFS()
        recentSpeechSeconds *= exp(-seconds / Self.speechEvidenceSeconds)
        if let noiseFloorDBFS,
           levelDBFS > Self.digitalSilenceDBFS,
           levelDBFS >= tuning.minimumSpeechDBFS,
           levelDBFS >= noiseFloorDBFS + tuning.speechAboveNoiseDB {
            if let speechLevelDBFS {
                let timeConstant = levelDBFS > speechLevelDBFS
                    ? tuning.speechLevelRiseSeconds
                    : tuning.speechLevelFallSeconds
                let follow = 1 - exp(-seconds / max(0.001, timeConstant))
                self.speechLevelDBFS = speechLevelDBFS + follow * (levelDBFS - speechLevelDBFS)
            } else {
                speechLevelDBFS = levelDBFS
            }
            recentSpeechSeconds += seconds
            if recentSpeechSeconds >= tuning.speechToStartSeconds {
                heardEnoughSpeech = true
            }
        }
        // Zeros after the mic's first signal are a gated pause and count as
        // the floor. Zeros before it are a device warming up, and a few
        // blocks of them a dropout: counting either would make the room tone
        // that follows look like speech for a whole floor window.
        if levelDBFS > Self.digitalSilenceDBFS {
            heardSignal = true
            digitalSilenceRunSeconds = 0
            rememberBlockLevel(levelDBFS)
        } else if heardSignal {
            digitalSilenceRunSeconds += seconds
            if digitalSilenceRunSeconds >= Self.minimumGatedPauseSeconds - 1e-4 {
                rememberBlockLevel(levelDBFS)
            }
        }

        let wantedGain = wantedGainDB(noiseFloorDBFS: trackedNoiseFloorDBFS())
        let risenGain = min(wantedGain, gainDB + tuning.maxGainRiseDBPerSecond * seconds)
        // The most this block's loudest sample allows.
        let peakBound = peak > 0 ? tuning.peakCeiling / peak : .greatestFiniteMagnitude
        let newGain = max(1, min(pow(10, risenGain / 20), peakBound))
        let previousGain = gain
        gain = newGain

        if previousGain <= peakBound, previousGain != newGain {
            // Both ends are within the bound, so every ramped sample is too.
            let step = (newGain - previousGain) / Float(block.count)
            for index in block.indices {
                block[index] *= previousGain + step * Float(index + 1)
            }
        } else if newGain != 1 {
            // A loud onset after a boosted stretch: drop to the bound at once
            // rather than ramp through clipping.
            for index in block.indices {
                block[index] *= newGain
            }
        }
    }

    /// Nil until the mic's first signal. Until the window holds more than
    /// the skipped outliers, the loudest of what it holds.
    private func trackedNoiseFloorDBFS() -> Float? {
        guard recentBlockLevelCount > 0 else { return nil }
        let rank = min(quietestBlockLevelsDBFS.count, recentBlockLevelCount)
        for index in 0..<rank {
            quietestBlockLevelsDBFS[index] = .greatestFiniteMagnitude
        }
        // Keeps the `rank` quietest, sorted, by insertion.
        for index in 0..<recentBlockLevelCount {
            var level = recentBlockLevelsDBFS[index]
            guard level < quietestBlockLevelsDBFS[rank - 1] else { continue }
            for slot in 0..<rank where level < quietestBlockLevelsDBFS[slot] {
                swap(&level, &quietestBlockLevelsDBFS[slot])
            }
        }
        return quietestBlockLevelsDBFS[rank - 1]
    }

    private func rememberBlockLevel(_ levelDBFS: Float) {
        recentBlockLevelsDBFS[nextRecentBlockIndex] = levelDBFS
        nextRecentBlockIndex = (nextRecentBlockIndex + 1) % recentBlockLevelsDBFS.count
        recentBlockLevelCount = min(recentBlockLevelCount + 1, recentBlockLevelsDBFS.count)
    }

    private func wantedGainDB(noiseFloorDBFS: Float?) -> Float {
        guard heardEnoughSpeech, let speechLevelDBFS, let noiseFloorDBFS else { return 0 }
        // What was taken for speech no longer stands out from the noise (a
        // gated mic that came back as steady hiss, or a fan that started):
        // stop boosting rather than lift the noise.
        guard speechLevelDBFS >= noiseFloorDBFS + tuning.speechAboveNoiseDB else { return 0 }
        let towardTarget = tuning.targetSpeechDBFS - speechLevelDBFS
        let noiseHeadroom = tuning.boostedNoiseCeilingDBFS - noiseFloorDBFS
        return max(0, min(towardTarget, tuning.maxGainDB, noiseHeadroom))
    }
}
