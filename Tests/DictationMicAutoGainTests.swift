// DictationMicAutoGainTests.swift
//
// Promise tests for DictationMicAutoGain, the per-take automatic gain applied to
// dictation microphone samples. Written from the promises, not from the
// implementation: synthetic speech bursts (220 Hz sine, 300 ms on / 200 ms off)
// and seeded white noise are fed in capture-sized buffers, and only the
// returned samples and `currentGainDB` are checked.
//
// Synthetic is not real: these prove the arithmetic on generated signals. Real
// quiet mics, AirPods and noisy rooms still need `bash check.sh hardware` or a
// manual dictation pass.

import Foundation

// MARK: - Signals

/// Deterministic white noise source (64-bit LCG), so every run sees the same samples.
private struct AutoGainNoise {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 1
    }

    /// Uniform value in [-1, 1).
    mutating func nextUnit() -> Float {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let top24 = Float(state >> 40) / Float(1 << 24)
        return top24 * 2 - 1
    }

    mutating func nextInt(_ upperBound: Int) -> Int {
        Int((nextUnit() + 1) / 2 * Float(upperBound)) % upperBound
    }
}

/// One generated take: samples plus which samples are inside a speech burst.
private struct AutoGainSignal {
    var name: String
    var sampleRate: Double
    var samples: [Float]
    var isBurst: [Bool]
}

private func linear(dBFS: Float) -> Float {
    powf(10, dBFS / 20)
}

private func dBFS(rms: Double) -> Float {
    rms > 0 ? Float(20 * log10(rms)) : -Float.infinity
}

/// Speech-like bursts: a 220 Hz sine at `speechDBFS` RMS for 300 ms, then 200 ms
/// pause, repeating from `onsetSeconds`. Before the onset and in pauses there is
/// digital zero, or white noise at `noiseDBFS` RMS (also mixed under the speech).
private func speechBursts(
    name: String,
    sampleRate: Double,
    seconds: Double,
    speechDBFS: Float,
    noiseDBFS: Float?,
    onsetSeconds: Double = 0,
    seed: UInt64 = 1
) -> AutoGainSignal {
    let count = Int((sampleRate * seconds).rounded())
    let sineAmplitude = linear(dBFS: speechDBFS) * Float(2).squareRoot()
    // Uniform noise in [-a, a) has RMS a / sqrt(3).
    let noiseAmplitude = noiseDBFS.map { linear(dBFS: $0) * Float(3).squareRoot() } ?? 0
    var noise = AutoGainNoise(seed: seed)
    var samples = [Float](repeating: 0, count: count)
    var isBurst = [Bool](repeating: false, count: count)
    for index in 0..<count {
        let time = Double(index) / sampleRate
        var value: Float = 0
        if time >= onsetSeconds {
            let phase = (time - onsetSeconds).truncatingRemainder(dividingBy: 0.5)
            if phase < 0.3 {
                isBurst[index] = true
                value = sineAmplitude * Float(sin(2 * Double.pi * 220 * phase))
            }
        }
        if noiseDBFS != nil {
            value += noiseAmplitude * noise.nextUnit()
        }
        samples[index] = value
    }
    return AutoGainSignal(name: name, sampleRate: sampleRate, samples: samples, isBurst: isBurst)
}

private func whiteNoise(name: String, sampleRate: Double, seconds: Double, noiseDBFS: Float, seed: UInt64) -> AutoGainSignal {
    let count = Int((sampleRate * seconds).rounded())
    let amplitude = linear(dBFS: noiseDBFS) * Float(3).squareRoot()
    var noise = AutoGainNoise(seed: seed)
    let samples = (0..<count).map { _ in amplitude * noise.nextUnit() }
    return AutoGainSignal(name: name, sampleRate: sampleRate, samples: samples, isBurst: [Bool](repeating: false, count: count))
}

/// `seconds` of a cosine burst (starts at full amplitude: a sudden step) with
/// the given peak amplitude, followed by `pauseSeconds` of zero.
private func appendLoudBurst(to signal: inout AutoGainSignal, amplitude: Float, seconds: Double, pauseSeconds: Double) {
    let burstCount = Int((signal.sampleRate * seconds).rounded())
    for index in 0..<burstCount {
        let time = Double(index) / signal.sampleRate
        signal.samples.append(amplitude * Float(cos(2 * Double.pi * 220 * time)))
        signal.isBurst.append(true)
    }
    let pauseCount = Int((signal.sampleRate * pauseSeconds).rounded())
    signal.samples.append(contentsOf: [Float](repeating: 0, count: pauseCount))
    signal.isBurst.append(contentsOf: [Bool](repeating: false, count: pauseCount))
}

private func append(_ tail: AutoGainSignal, to signal: inout AutoGainSignal) {
    signal.samples.append(contentsOf: tail.samples)
    signal.isBurst.append(contentsOf: tail.isBurst)
}

/// A pile of mixed, deterministic signals: silence, quiet and loud bursts,
/// noise, sudden steps, over-full-scale input, at several sample rates.
private func mixedSignalCorpus() -> [(signal: AutoGainSignal, bufferFrames: [Int])] {
    var rng = AutoGainNoise(seed: 0xA11CE)
    var corpus: [(signal: AutoGainSignal, bufferFrames: [Int])] = []
    let rates: [Double] = [8_000, 16_000, 44_100, 48_000]
    for signalIndex in 0..<24 {
        let sampleRate = rates[signalIndex % rates.count]
        var signal = AutoGainSignal(name: "mixed #\(signalIndex) @ \(Int(sampleRate)) Hz", sampleRate: sampleRate, samples: [], isBurst: [])
        for _ in 0..<(4 + rng.nextInt(5)) {
            let seconds = 0.05 + Double(rng.nextInt(60)) / 100
            let kind = rng.nextInt(5)
            switch kind {
            case 0:
                let count = Int(sampleRate * seconds)
                signal.samples.append(contentsOf: [Float](repeating: 0, count: count))
                signal.isBurst.append(contentsOf: [Bool](repeating: false, count: count))
            case 1:
                let level = -75 + Float(rng.nextInt(70))
                let noiseLevel: Float? = rng.nextInt(2) == 0 ? nil : level - 10 - Float(rng.nextInt(30))
                append(speechBursts(name: "", sampleRate: sampleRate, seconds: seconds, speechDBFS: level, noiseDBFS: noiseLevel, seed: UInt64(signalIndex + 7)), to: &signal)
            case 2:
                let level = -80 + Float(rng.nextInt(50))
                append(whiteNoise(name: "", sampleRate: sampleRate, seconds: seconds, noiseDBFS: level, seed: UInt64(signalIndex + 99)), to: &signal)
            case 3:
                let amplitude = 0.3 + Float(rng.nextInt(100)) / 100
                appendLoudBurst(to: &signal, amplitude: amplitude, seconds: seconds, pauseSeconds: 0.02)
            default:
                // A sudden DC-ish step close to (or above) full scale.
                let count = Int(sampleRate * min(seconds, 0.1))
                let value = (rng.nextInt(2) == 0 ? -1 : 1) * (0.5 + Float(rng.nextInt(80)) / 100)
                signal.samples.append(contentsOf: [Float](repeating: value, count: count))
                signal.isBurst.append(contentsOf: [Bool](repeating: true, count: count))
            }
        }
        let tenMs = Int((sampleRate * 0.01).rounded())
        let frameChoices: [[Int]] = [[tenMs], [1024], [4096], [37, 512, 3001, 1, 900]]
        corpus.append((signal, frameChoices[signalIndex % frameChoices.count]))
    }
    return corpus
}

// MARK: - Running a take

private struct AutoGainRun {
    var output: [Float]
    /// `currentGainDB` after each buffer, with the buffer's frame count.
    var gainAfterBuffer: [(frames: Int, endSample: Int, gainDB: Float)]
    /// Input and output of each buffer, as handed to and returned by `process`.
    var buffers: [(input: [Float], output: [Float])]
}

private func tenMsFrames(_ sampleRate: Double) -> [Int] {
    [Int((sampleRate * 0.01).rounded())]
}

/// Feeds the signal through one auto-gain instance in buffers, cycling through
/// `bufferFrames`, the way a capture queue hands over audio.
private func runTake(
    _ signal: AutoGainSignal,
    bufferFrames: [Int],
    autoGain: DictationMicAutoGain = DictationMicAutoGain()
) -> AutoGainRun {
    var run = AutoGainRun(output: [], gainAfterBuffer: [], buffers: [])
    run.output.reserveCapacity(signal.samples.count)
    var start = 0
    var bufferIndex = 0
    while start < signal.samples.count {
        let frames = min(bufferFrames[bufferIndex % bufferFrames.count], signal.samples.count - start)
        let input = Array(signal.samples[start..<(start + frames)])
        var buffer = input
        autoGain.process(&buffer, sampleRate: signal.sampleRate)
        run.output.append(contentsOf: buffer)
        run.buffers.append((input, buffer))
        start += frames
        run.gainAfterBuffer.append((frames, start, autoGain.currentGainDB))
        bufferIndex += 1
    }
    return run
}

private func rmsDBFS(_ samples: [Float], where include: (Int) -> Bool) -> Float {
    var sum = 0.0
    var count = 0
    for index in samples.indices where include(index) {
        sum += Double(samples[index]) * Double(samples[index])
        count += 1
    }
    return count > 0 ? dBFS(rms: (sum / Double(count)).squareRoot()) : -Float.infinity
}

/// Contiguous index ranges where `isBurst` is true.
private func burstRanges(_ signal: AutoGainSignal) -> [Range<Int>] {
    var ranges: [Range<Int>] = []
    var start: Int?
    for index in signal.isBurst.indices {
        if signal.isBurst[index], start == nil { start = index }
        if !signal.isBurst[index], let begin = start {
            ranges.append(begin..<index)
            start = nil
        }
    }
    if let begin = start { ranges.append(begin..<signal.isBurst.count) }
    return ranges
}

/// Same bits per index, with any NaN matching any NaN.
private func sameSamples(_ lhs: [Float], _ rhs: [Float]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    for index in lhs.indices {
        if lhs[index].isNaN && rhs[index].isNaN { continue }
        if lhs[index].bitPattern != rhs[index].bitPattern { return false }
    }
    return true
}

private func firstDifference(_ lhs: [Float], _ rhs: [Float]) -> String {
    for index in lhs.indices where index < rhs.count {
        if lhs[index].isNaN && rhs[index].isNaN { continue }
        if lhs[index].bitPattern != rhs[index].bitPattern {
            return "sample \(index): in \(lhs[index]) out \(rhs[index])"
        }
    }
    return "count in \(lhs.count) out \(rhs.count)"
}

/// The signals used across these promises, for the "every signal" checks.
private func everyNamedSignal() -> [(signal: AutoGainSignal, bufferFrames: [Int])] {
    var named: [(signal: AutoGainSignal, bufferFrames: [Int])] = []
    for sampleRate in [16_000.0, 44_100, 48_000] {
        named.append((speechBursts(name: "loud -15 @ \(Int(sampleRate))", sampleRate: sampleRate, seconds: 3, speechDBFS: -15, noiseDBFS: -80), tenMsFrames(sampleRate)))
        named.append((speechBursts(name: "quiet -40 noise -90 @ \(Int(sampleRate))", sampleRate: sampleRate, seconds: 4, speechDBFS: -40, noiseDBFS: -90), [1024]))
        named.append((speechBursts(name: "quiet -40 zero pauses @ \(Int(sampleRate))", sampleRate: sampleRate, seconds: 4, speechDBFS: -40, noiseDBFS: nil), tenMsFrames(sampleRate)))
        named.append((speechBursts(name: "very quiet -62 @ \(Int(sampleRate))", sampleRate: sampleRate, seconds: 4, speechDBFS: -62, noiseDBFS: nil), [4096]))
        named.append((speechBursts(name: "hiss -45/-62 @ \(Int(sampleRate))", sampleRate: sampleRate, seconds: 4, speechDBFS: -45, noiseDBFS: -62), tenMsFrames(sampleRate)))
        named.append((speechBursts(name: "late onset -40 @ \(Int(sampleRate))", sampleRate: sampleRate, seconds: 3, speechDBFS: -40, noiseDBFS: nil, onsetSeconds: 0.2), tenMsFrames(sampleRate)))
        named.append((whiteNoise(name: "noise -60 @ \(Int(sampleRate))", sampleRate: sampleRate, seconds: 3, noiseDBFS: -60, seed: 5), tenMsFrames(sampleRate)))
        var overload = speechBursts(name: "quiet then overload @ \(Int(sampleRate))", sampleRate: sampleRate, seconds: 3, speechDBFS: -50, noiseDBFS: nil)
        for amplitude: Float in [0.8, 1.0, 1.2] {
            appendLoudBurst(to: &overload, amplitude: amplitude, seconds: 0.3, pauseSeconds: 0.2)
        }
        named.append((overload, [4096]))
    }
    return named + mixedSignalCorpus()
}

// MARK: - Promises

func testDictationMicAutoGain() {
    let tuning = DictationMicAutoGain.Tuning.default

    runSuite("Mic auto-gain: a loud mic is left alone") {
        for (sampleRate, frames) in [(48_000.0, tenMsFrames(48_000)), (44_100.0, [1024])] {
            let signal = speechBursts(name: "loud", sampleRate: sampleRate, seconds: 3, speechDBFS: -15, noiseDBFS: -80)
            let run = runTake(signal, bufferFrames: frames)
            assertTrue(
                sameSamples(signal.samples, run.output),
                "speech at -15 dBFS must pass through unchanged @ \(Int(sampleRate)) Hz; first difference: \(firstDifference(signal.samples, run.output))"
            )
            let nonZeroGains = run.gainAfterBuffer.filter { $0.gainDB != 0 }
            assertTrue(nonZeroGains.isEmpty, "currentGainDB must stay 0 for a loud mic; first non-zero: \(String(describing: nonZeroGains.first))")
        }
    }

    runSuite("Mic auto-gain: quiet speech is raised to the target level") {
        for (label, noise) in [("noise -90 dBFS", Optional<Float>(-90)), ("zero pauses", nil)] {
            let sampleRate = 48_000.0
            let signal = speechBursts(name: label, sampleRate: sampleRate, seconds: 4, speechDBFS: -40, noiseDBFS: noise)
            let run = runTake(signal, bufferFrames: tenMsFrames(sampleRate))
            let settledStart = Int(sampleRate * 2)
            let outputBurstDB = rmsDBFS(run.output) { $0 >= settledStart && signal.isBurst[$0] }
            assertTrue(
                abs(outputBurstDB - tuning.targetSpeechDBFS) <= 3,
                "\(label): output burst RMS after 2 s is \(outputBurstDB) dBFS, target \(tuning.targetSpeechDBFS) ± 3"
            )
        }
    }

    runSuite("Mic auto-gain: the boost never exceeds the cap") {
        var smallCap = tuning
        smallCap.maxGainDB = 10
        for capTuning in [tuning, smallCap] {
            let sampleRate = 48_000.0
            let seconds = max(4.0, Double(capTuning.maxGainDB / max(capTuning.maxGainRiseDBPerSecond, 0.1)) + 3)
            let signal = speechBursts(name: "very quiet", sampleRate: sampleRate, seconds: min(seconds, 20), speechDBFS: -62, noiseDBFS: nil)
            let run = runTake(signal, bufferFrames: tenMsFrames(sampleRate), autoGain: DictationMicAutoGain(tuning: capTuning))
            let highestGain = run.gainAfterBuffer.map(\.gainDB).max() ?? 0
            assertTrue(
                highestGain <= capTuning.maxGainDB + 0.01,
                "currentGainDB peaked at \(highestGain) dB, cap \(capTuning.maxGainDB) dB"
            )
            // Without reaching the cap the check above proves nothing.
            assertTrue(
                highestGain >= capTuning.maxGainDB - 1,
                "-62 dBFS speech needs more than the cap, so the boost should reach it; peaked at \(highestGain) dB, cap \(capTuning.maxGainDB) dB"
            )
            for range in burstRanges(signal) {
                let inputDB = rmsDBFS(signal.samples) { range.contains($0) }
                let outputDB = rmsDBFS(run.output) { range.contains($0) }
                if outputDB > inputDB + capTuning.maxGainDB + 0.1 {
                    recordFailure("burst \(range) out \(outputDB) dBFS > in \(inputDB) + cap \(capTuning.maxGainDB) dB")
                    break
                }
            }
        }
    }

    runSuite("Mic auto-gain: the output never overloads") {
        for (sampleRate, frames) in [(48_000.0, tenMsFrames(48_000)), (48_000.0, [4096]), (16_000.0, [1024])] {
            var signal = speechBursts(name: "quiet then loud", sampleRate: sampleRate, seconds: 3, speechDBFS: -50, noiseDBFS: nil)
            let quietEnd = signal.samples.count
            for amplitude: Float in [0.8, 1.0, 1.2] {
                appendLoudBurst(to: &signal, amplitude: amplitude, seconds: 0.3, pauseSeconds: 0.2)
            }
            let run = runTake(signal, bufferFrames: frames)
            let gainBeforeLoud = run.gainAfterBuffer.last { $0.endSample <= quietEnd }?.gainDB ?? 0
            assertTrue(gainBeforeLoud > 6, "setup: 3 s of -50 dBFS speech should leave a high boost before the loud burst, got \(gainBeforeLoud) dB")
            for index in signal.samples.indices {
                let bound = max(tuning.peakCeiling, abs(signal.samples[index])) + 1e-6
                if !(abs(run.output[index]) <= bound) {
                    recordFailure("@ \(Int(sampleRate)) Hz frames \(frames): sample \(index) in \(signal.samples[index]) out \(run.output[index]) > \(bound)")
                    break
                }
            }
        }

        var violations: [String] = []
        for (signal, frames) in mixedSignalCorpus() {
            let run = runTake(signal, bufferFrames: frames)
            for index in signal.samples.indices {
                let bound = max(tuning.peakCeiling, abs(signal.samples[index])) + 1e-6
                if !(abs(run.output[index]) <= bound) {
                    violations.append("\(signal.name) frames \(frames): sample \(index) in \(signal.samples[index]) out \(run.output[index])")
                    break
                }
            }
        }
        assertTrue(violations.isEmpty, "output louder than max(peakCeiling, |in|): \(violations.prefix(3))")
    }

    runSuite("Mic auto-gain: the output is never quieter than the mic") {
        var violations: [String] = []
        for (signal, frames) in everyNamedSignal() {
            let run = runTake(signal, bufferFrames: frames)
            for index in signal.samples.indices where !(abs(run.output[index]) >= abs(signal.samples[index]) - 1e-6) {
                violations.append("\(signal.name) frames \(frames): sample \(index) in \(signal.samples[index]) out \(run.output[index])")
                break
            }
        }
        assertTrue(violations.isEmpty, "output quieter than input: \(violations.prefix(3))")
    }

    runSuite("Mic auto-gain: noise alone is not lifted") {
        for (sampleRate, frames) in [(48_000.0, tenMsFrames(48_000)), (44_100.0, [1024])] {
            let signal = whiteNoise(name: "noise", sampleRate: sampleRate, seconds: 5, noiseDBFS: -60, seed: 42)
            let run = runTake(signal, bufferFrames: frames)
            let inputDB = rmsDBFS(signal.samples) { _ in true }
            let outputDB = rmsDBFS(run.output) { _ in true }
            assertTrue(outputDB <= inputDB + 1, "@ \(Int(sampleRate)) Hz: noise in \(inputDB) dBFS came out \(outputDB) dBFS")
            let lastSecond = signal.samples.count - Int(sampleRate)
            let inputTailDB = rmsDBFS(signal.samples) { $0 >= lastSecond }
            let outputTailDB = rmsDBFS(run.output) { $0 >= lastSecond }
            assertTrue(outputTailDB <= inputTailDB + 1, "@ \(Int(sampleRate)) Hz: last second of noise in \(inputTailDB) dBFS came out \(outputTailDB) dBFS")
        }
    }

    runSuite("Mic auto-gain: a mic that starts with digital silence and then only hiss is not lifted") {
        for (sampleRate, frames) in [(48_000.0, tenMsFrames(48_000)), (16_000.0, [4096])] {
            var signal = AutoGainSignal(
                name: "zeros then hiss",
                sampleRate: sampleRate,
                samples: [Float](repeating: 0, count: Int(sampleRate * 0.5)),
                isBurst: [Bool](repeating: false, count: Int(sampleRate * 0.5))
            )
            append(whiteNoise(name: "", sampleRate: sampleRate, seconds: 5, noiseDBFS: -58, seed: 77), to: &signal)
            let run = runTake(signal, bufferFrames: frames)
            // Every quarter second of the hiss, from its first sample on: the
            // zeros before it must not make its start look like speech.
            let window = Int(sampleRate * 0.25)
            for start in stride(from: Int(sampleRate * 0.5), to: signal.samples.count - window + 1, by: window) {
                let span = start..<(start + window)
                let inputDB = rmsDBFS(signal.samples) { span.contains($0) }
                let outputDB = rmsDBFS(run.output) { span.contains($0) }
                if outputDB > inputDB + 1 {
                    recordFailure("@ \(Int(sampleRate)) Hz frames \(frames): hiss at \(Double(start) / sampleRate) s in \(inputDB) dBFS came out \(outputDB) dBFS")
                    break
                }
            }
        }
    }

    runSuite("Mic auto-gain: hiss in pauses stays below the noise ceiling") {
        for (sampleRate, frames) in [(48_000.0, tenMsFrames(48_000)), (44_100.0, [1024])] {
            let signal = speechBursts(name: "hiss", sampleRate: sampleRate, seconds: 5, speechDBFS: -45, noiseDBFS: -62, seed: 9)
            let run = runTake(signal, bufferFrames: frames)
            let settledStart = Int(sampleRate * 2)
            let pauseDB = rmsDBFS(run.output) { $0 >= settledStart && !signal.isBurst[$0] }
            assertTrue(
                pauseDB <= tuning.boostedNoiseCeilingDBFS + 3,
                "@ \(Int(sampleRate)) Hz: pause hiss after 2 s is \(pauseDB) dBFS, ceiling \(tuning.boostedNoiseCeilingDBFS) + 3"
            )
        }
    }

    runSuite("Mic auto-gain: digital silence stays silent and real signal never becomes silence") {
        var silenceViolations: [String] = []
        for (signal, frames) in everyNamedSignal() {
            let run = runTake(signal, bufferFrames: frames)
            for (bufferIndex, buffer) in run.buffers.enumerated()
            where buffer.input.allSatisfy({ $0 == 0 }) && !buffer.output.allSatisfy({ $0 == 0 }) {
                silenceViolations.append("\(signal.name) buffer \(bufferIndex)")
                break
            }
        }
        assertTrue(silenceViolations.isEmpty, "all-zero buffers must come out all zero: \(silenceViolations.prefix(3))")

        let warmedUp = DictationMicAutoGain()
        _ = runTake(speechBursts(name: "warm-up", sampleRate: 48_000, seconds: 3, speechDBFS: -40, noiseDBFS: nil), bufferFrames: [480], autoGain: warmedUp)
        assertTrue(warmedUp.currentGainDB > 0, "setup: quiet speech should leave a boost, got \(warmedUp.currentGainDB) dB")

        var spike = [Float](repeating: 0, count: 480)
        spike[200] = 1e-6
        let tinyBuffers: [(String, [Float])] = [
            ("single 1e-6 spike", spike),
            ("all least-nonzero", [Float](repeating: .leastNonzeroMagnitude, count: 480)),
            ("alternating +-1e-38", (0..<480).map { $0 % 2 == 0 ? 1e-38 : -1e-38 }),
            ("one sample -1e-9", [-1e-9]),
        ]
        for (label, input) in tinyBuffers {
            for (state, autoGain) in [("fresh", DictationMicAutoGain()), ("boosted", warmedUp)] {
                var buffer = input
                autoGain.process(&buffer, sampleRate: 48_000)
                assertTrue(
                    buffer.contains { $0 != 0 && $0.isFinite },
                    "\(label) (\(state)): a buffer with real signal must keep a non-zero finite sample"
                )
            }
        }
    }

    runSuite("Mic auto-gain: the boost changes smoothly within steady quiet speech") {
        for (sampleRate, frames) in [(48_000.0, tenMsFrames(48_000)), (44_100.0, [1024]), (16_000.0, [4096])] {
            let signal = speechBursts(name: "quiet", sampleRate: sampleRate, seconds: 4, speechDBFS: -40, noiseDBFS: nil)
            let run = runTake(signal, bufferFrames: frames)
            var worst: (jump: Float, index: Int) = (0, -1)
            for index in 0..<(signal.samples.count - 1) where signal.isBurst[index] && signal.isBurst[index + 1] {
                let a = signal.samples[index], b = signal.samples[index + 1]
                guard abs(a) > 1e-4, abs(b) > 1e-4 else { continue }
                let gainA = 20 * log10(abs(run.output[index]) / abs(a))
                let gainB = 20 * log10(abs(run.output[index + 1]) / abs(b))
                let jump = abs(gainB - gainA)
                if !(jump <= worst.jump) { worst = (jump, index) }
            }
            assertTrue(
                worst.jump <= 0.5,
                "@ \(Int(sampleRate)) Hz frames \(frames): effective gain jumped \(worst.jump) dB between samples \(worst.index) and \(worst.index + 1)"
            )
        }
    }

    runSuite("Mic auto-gain: the boost rises no faster than allowed") {
        var violations: [String] = []
        var sawRise = false
        for (signal, frames) in everyNamedSignal() {
            let run = runTake(signal, bufferFrames: frames)
            var previous: Float = 0
            for step in run.gainAfterBuffer {
                let allowed = tuning.maxGainRiseDBPerSecond * Float(Double(step.frames) / signal.sampleRate) + 0.01
                if step.gainDB > previous { sawRise = true }
                if !(step.gainDB - previous <= allowed) {
                    violations.append("\(signal.name) frames \(frames): +\(step.gainDB - previous) dB in \(step.frames) frames (allowed \(allowed)) at sample \(step.endSample)")
                    break
                }
                previous = step.gainDB
            }
        }
        assertTrue(sawRise, "setup: some signal should have raised the boost")
        assertTrue(violations.isEmpty, "boost rose too fast: \(violations.prefix(3))")
    }

    runSuite("Mic auto-gain: short takes still get boosted") {
        let sampleRate = 48_000.0
        let onset = 0.2
        // Most mics hiss a little before the first word, so the first word
        // already stands out: settled within a second of speech.
        // A mic that gates to digital zero gives nothing to measure the first
        // word against (it starts the floor), so its boost starts on the
        // second word, half a second later: settled within 1.5 s.
        for (label, noise, settleSeconds) in [("room tone before speech", Optional<Float>(-80), 1.0), ("gated mic, zeros before and between words", nil, 1.5)] {
            let signal = speechBursts(name: label, sampleRate: sampleRate, seconds: onset + 4, speechDBFS: -40, noiseDBFS: noise, onsetSeconds: onset)
            let run = runTake(signal, bufferFrames: tenMsFrames(sampleRate))
            let settledBy = Int(sampleRate * (onset + settleSeconds))
            let gainThen = run.gainAfterBuffer.last { $0.endSample <= settledBy }?.gainDB ?? .nan
            let gainAtEnd = run.gainAfterBuffer.last?.gainDB ?? .nan
            assertTrue(gainAtEnd >= 10, "\(label): -40 dBFS speech should end up boosted, got \(gainAtEnd) dB")
            assertTrue(
                abs(gainAtEnd - gainThen) <= 3,
                "\(label): \(settleSeconds) s after speech starts the boost is \(gainThen) dB; after 4 s it is \(gainAtEnd) dB (must be within 3 dB)"
            )
        }
    }

    runSuite("Mic auto-gain: a lone click in a silent take doesn't lift its room tone") {
        for (sampleRate, frames) in [(48_000.0, tenMsFrames(48_000)), (16_000.0, [1024])] {
            var signal = whiteNoise(name: "room", sampleRate: sampleRate, seconds: 0.5, noiseDBFS: -65, seed: 21)
            // 10 ms click 20 dB over the room, then nothing but room tone.
            appendLoudBurst(to: &signal, amplitude: linear(dBFS: -45) * Float(2).squareRoot(), seconds: 0.01, pauseSeconds: 0)
            append(whiteNoise(name: "room", sampleRate: sampleRate, seconds: 3, noiseDBFS: -65, seed: 22), to: &signal)
            let run = runTake(signal, bufferFrames: frames)
            let highestGain = run.gainAfterBuffer.map(\.gainDB).max() ?? 0
            assertTrue(highestGain <= 0.01, "@ \(Int(sampleRate)) Hz: one click is not speech, yet the boost reached \(highestGain) dB")
        }
    }

    runSuite("Mic auto-gain: a brief dropout to zeros doesn't make room tone look like speech") {
        for (sampleRate, frames) in [(48_000.0, tenMsFrames(48_000)), (44_100.0, [1024])] {
            var signal = speechBursts(name: "quiet speech", sampleRate: sampleRate, seconds: 2, speechDBFS: -40, noiseDBFS: -62, seed: 31)
            let dropout = Int(sampleRate * 0.05)
            signal.samples.append(contentsOf: [Float](repeating: 0, count: dropout))
            signal.isBurst.append(contentsOf: [Bool](repeating: false, count: dropout))
            append(whiteNoise(name: "room", sampleRate: sampleRate, seconds: 3, noiseDBFS: -62, seed: 32), to: &signal)
            let run = runTake(signal, bufferFrames: frames)
            let gainBefore = run.gainAfterBuffer.last { $0.endSample <= Int(sampleRate * 2) }?.gainDB ?? 0
            let highestAfter = run.gainAfterBuffer.filter { $0.endSample > Int(sampleRate * 2) }.map(\.gainDB).max() ?? 0
            assertTrue(gainBefore >= 5, "@ \(Int(sampleRate)) Hz: quiet speech should be boosted before the dropout, got \(gainBefore) dB")
            assertTrue(
                highestAfter <= gainBefore + 1,
                "@ \(Int(sampleRate)) Hz frames \(frames): a 50 ms dropout let room tone push the boost from \(gainBefore) to \(highestAfter) dB"
            )
        }
    }

    runSuite("Mic auto-gain: same boost regardless of sample rate and buffer size") {
        for (label, speech, noise) in [("quiet -40, noise -85", Float(-40), Float(-85)), ("hiss -45/-62", -45, -62)] {
            var finals: [String] = []
            var values: [Float] = []
            for sampleRate in [16_000.0, 44_100, 48_000] {
                for frames in [tenMsFrames(sampleRate), [1024], [4096]] {
                    let signal = speechBursts(name: label, sampleRate: sampleRate, seconds: 4, speechDBFS: speech, noiseDBFS: noise, seed: 3)
                    let gain = runTake(signal, bufferFrames: frames).gainAfterBuffer.last?.gainDB ?? .nan
                    values.append(gain)
                    finals.append("\(Int(sampleRate))/\(frames[0]): \(gain)")
                }
            }
            let spread = (values.max() ?? .nan) - (values.min() ?? .nan)
            assertTrue(spread <= 1.5, "\(label): final boosts spread \(spread) dB: \(finals.joined(separator: ", "))")
        }
    }

    runSuite("Mic auto-gain: broken input passes through untouched and does not poison later audio") {
        let sampleRate = 48_000.0
        let quiet = speechBursts(name: "quiet", sampleRate: sampleRate, seconds: 3, speechDBFS: -40, noiseDBFS: nil)
        var nanBuffer = Array(quiet.samples[0..<480])
        nanBuffer[100] = .nan
        var infBuffer = Array(quiet.samples[480..<960])
        infBuffer[7] = .infinity
        // Longer than one ~10 ms analysis block, with the bad sample late:
        // the whole buffer still comes back untouched, not just its tail.
        var longNaNBuffer = Array(quiet.samples[960..<1984])
        longNaNBuffer[900] = .nan
        let brokenBuffers: [(String, [Float])] = [
            ("NaN", nanBuffer),
            ("NaN late in a 1024-frame buffer", longNaNBuffer),
            ("+Inf", infBuffer),
            ("all NaN", [Float](repeating: .nan, count: 480)),
        ]
        for (state, warmUpSeconds) in [("fresh", 0.0), ("boosted", 3.0)] {
            for (label, broken) in brokenBuffers {
                let autoGain = DictationMicAutoGain()
                if warmUpSeconds > 0 {
                    _ = runTake(quiet, bufferFrames: tenMsFrames(sampleRate), autoGain: autoGain)
                }
                var buffer = broken
                autoGain.process(&buffer, sampleRate: sampleRate)
                assertTrue(sameSamples(broken, buffer), "\(label) (\(state)): buffer must come back unchanged; \(firstDifference(broken, buffer))")

                let later = runTake(quiet, bufferFrames: tenMsFrames(sampleRate), autoGain: autoGain)
                assertTrue(later.output.allSatisfy(\.isFinite), "\(label) (\(state)): later valid audio must stay finite")
                assertTrue(
                    autoGain.currentGainDB.isFinite && autoGain.currentGainDB > 0,
                    "\(label) (\(state)): later quiet speech must still get a finite positive boost, got \(autoGain.currentGainDB) dB"
                )
            }
        }

        let autoGain = DictationMicAutoGain()
        _ = runTake(quiet, bufferFrames: tenMsFrames(sampleRate), autoGain: autoGain)
        for badRate in [0.0, -48_000, .nan] {
            let gainBefore = autoGain.currentGainDB
            let input = Array(quiet.samples[0..<480])
            var buffer = input
            autoGain.process(&buffer, sampleRate: badRate)
            assertTrue(sameSamples(input, buffer), "sampleRate \(badRate): buffer must come back unchanged; \(firstDifference(input, buffer))")
            assertEqual(autoGain.currentGainDB.bitPattern, gainBefore.bitPattern, "sampleRate \(badRate): currentGainDB must not change (\(gainBefore) -> \(autoGain.currentGainDB))")
        }
    }

    runSuite("Mic auto-gain: the boost eases down without steps when the voice gets louder") {
        for (sampleRate, frames) in [(48_000.0, tenMsFrames(48_000)), (44_100.0, [1024])] {
            var signal = speechBursts(name: "quiet", sampleRate: sampleRate, seconds: 2, speechDBFS: -40, noiseDBFS: nil)
            append(speechBursts(name: "louder", sampleRate: sampleRate, seconds: 2, speechDBFS: -28, noiseDBFS: nil), to: &signal)
            let run = runTake(signal, bufferFrames: frames)
            let gainBeforeLouder = run.gainAfterBuffer.last { $0.endSample <= Int(sampleRate * 2) }?.gainDB ?? 0
            let finalGain = run.gainAfterBuffer.last?.gainDB ?? 0
            // Without a real drop the step check below proves nothing.
            assertTrue(
                finalGain <= gainBeforeLouder - 6,
                "@ \(Int(sampleRate)) Hz: a 12 dB louder voice should pull the boost down; \(gainBeforeLouder) -> \(finalGain) dB"
            )
            var worst: (jump: Float, index: Int) = (0, -1)
            for index in 0..<(signal.samples.count - 1) where signal.isBurst[index] && signal.isBurst[index + 1] {
                let a = signal.samples[index], b = signal.samples[index + 1]
                guard abs(a) > 1e-4, abs(b) > 1e-4 else { continue }
                let jump = abs(20 * log10(abs(run.output[index + 1]) / abs(b)) - 20 * log10(abs(run.output[index]) / abs(a)))
                if !(jump <= worst.jump) { worst = (jump, index) }
            }
            assertTrue(
                worst.jump <= 0.5,
                "@ \(Int(sampleRate)) Hz frames \(frames): effective gain jumped \(worst.jump) dB between samples \(worst.index) and \(worst.index + 1)"
            )
        }
    }

    runSuite("Mic auto-gain: the boost holds through a pause in speech") {
        for (sampleRate, frames) in [(48_000.0, tenMsFrames(48_000)), (16_000.0, [1024])] {
            // Room tone loud enough to pass the absolute speech floor, so
            // only its closeness to the noise floor marks it as not speech.
            var signal = speechBursts(name: "quiet speech", sampleRate: sampleRate, seconds: 2, speechDBFS: -40, noiseDBFS: -62, seed: 3)
            append(whiteNoise(name: "pause", sampleRate: sampleRate, seconds: 3, noiseDBFS: -62, seed: 4), to: &signal)
            let run = runTake(signal, bufferFrames: frames)
            let gainBeforePause = run.gainAfterBuffer.last { $0.endSample <= Int(sampleRate * 2) }?.gainDB ?? 0
            let gainAfterPause = run.gainAfterBuffer.last?.gainDB ?? 0
            assertTrue(gainBeforePause >= 10, "@ \(Int(sampleRate)) Hz: quiet speech should be boosted before the pause, got \(gainBeforePause) dB")
            assertTrue(
                abs(gainAfterPause - gainBeforePause) <= 1,
                "@ \(Int(sampleRate)) Hz frames \(frames): 3 s of room tone moved the boost \(gainBeforePause) -> \(gainAfterPause) dB"
            )
        }
    }

    runSuite("Mic auto-gain: noise that drowns the voice is not lifted") {
        for (sampleRate, frames) in [(48_000.0, tenMsFrames(48_000)), (16_000.0, [1024])] {
            var signal = speechBursts(name: "quiet speech", sampleRate: sampleRate, seconds: 2, speechDBFS: -45, noiseDBFS: -85, seed: 5)
            append(whiteNoise(name: "fan", sampleRate: sampleRate, seconds: 3, noiseDBFS: -52, seed: 6), to: &signal)
            let run = runTake(signal, bufferFrames: frames)
            // Once the noise floor has caught up with the new noise (its
            // window is about 1.5 s of ~10 ms blocks), so the last second.
            let lastSecond = signal.samples.count - Int(sampleRate)
            let inputDB = rmsDBFS(signal.samples) { $0 >= lastSecond }
            let outputDB = rmsDBFS(run.output) { $0 >= lastSecond }
            assertTrue(
                outputDB <= inputDB + 1,
                "@ \(Int(sampleRate)) Hz frames \(frames): noise louder than the voice was lifted from \(inputDB) to \(outputDB) dBFS"
            )
        }
    }

    runSuite("Mic auto-gain: an empty buffer is a no-op") {
        for (state, warmUp) in [("fresh", false), ("boosted", true)] {
            let autoGain = DictationMicAutoGain()
            if warmUp {
                _ = runTake(speechBursts(name: "quiet", sampleRate: 48_000, seconds: 3, speechDBFS: -40, noiseDBFS: nil), bufferFrames: [480], autoGain: autoGain)
            }
            let gainBefore = autoGain.currentGainDB
            var empty: [Float] = []
            autoGain.process(&empty, sampleRate: 48_000)
            assertTrue(empty.isEmpty, "\(state): an empty buffer must stay empty")
            assertEqual(autoGain.currentGainDB.bitPattern, gainBefore.bitPattern, "\(state): currentGainDB must not change on an empty buffer")
        }
    }

    runSuite("Mic auto-gain: starts at unity before any speech is heard") {
        for (sampleRate, frames) in [(48_000.0, tenMsFrames(48_000)), (48_000.0, [4096]), (16_000.0, [160])] {
            let autoGain = DictationMicAutoGain()
            assertEqual(autoGain.currentGainDB, 0, "a new instance starts at 0 dB")
            let noise = whiteNoise(name: "low noise", sampleRate: sampleRate, seconds: 0.3, noiseDBFS: -80, seed: 11)
            let run = runTake(noise, bufferFrames: frames, autoGain: autoGain)
            assertTrue(sameSamples(noise.samples, run.output), "@ \(Int(sampleRate)) Hz frames \(frames): low noise before speech must pass unchanged; \(firstDifference(noise.samples, run.output))")
            assertTrue(run.gainAfterBuffer.allSatisfy { $0.gainDB == 0 }, "currentGainDB must stay 0 before speech")
        }
    }
}
