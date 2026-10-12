import Foundation

/// Fork: finds the pauses in a dictation's 16 kHz audio as it arrives, so
/// Breeze can transcribe the take in pieces while the person is still talking
/// and only the last piece is left at Stop.
///
/// Cuts only ever land in silence, never inside a word: a piece ends after a
/// pause of `commitPause` (0.5 s), and the cut is at the end of that pause.
/// Speech is any 20 ms frame louder than three times the take's quiet level
/// (the 20th percentile of frame loudness over the last 30 s), but never
/// above half its loud level (the 90th percentile) and never below 0.004 RMS. A quiet word ending shorter than the pause still
/// falls inside the piece before the cut.
///
/// At a shorter pause (`speculativePause`, 0.3 s) it asks for a speculative
/// transcription of the piece so far: if the person stops right there, that
/// text is already done when they press Stop; if they keep talking it is
/// thrown away. These are the settings the 2026-10-12 simulation measured
/// (132 dictations: about 0.5 s left after Stop at any length).
struct DictationPauseChunker {
    enum EventKind: Equatable { case speculate, commit }

    /// A piece of the take, in samples from the take's start.
    struct Event: Equatable {
        let kind: EventKind
        let start: Int
        let end: Int
    }

    let sampleRate: Int
    let speculativePauseFrames: Int
    let commitPauseFrames: Int
    let minimumCommitSpeechFrames: Int
    /// A piece this long commits at the next short pause instead of waiting
    /// for a long one, so it stays inside one 30 s Whisper window.
    let longPieceFrames: Int

    static let frameSeconds = 0.02
    static let minimumSpeechRMS: Float = 0.004
    static let quietLevelWindowFrames = 1_500
    static let quietLevelRefreshFrames = 25

    private let frameLength: Int
    private var pendingFrame: [Float] = []
    private var frameIndex = 0
    private var recentLevels: [Float] = []
    private var speechThreshold = DictationPauseChunker.minimumSpeechRMS
    private var framesSinceThreshold = 0

    private var silentFrames = 0
    private var spokeSinceSpeculation = false
    /// Speech frames in the piece not yet committed.
    private(set) var pieceSpeechFrames = 0
    /// Start of the piece not yet committed, in samples.
    private(set) var pieceStart = 0
    /// End of the last speech frame, in samples; nil before any speech.
    private(set) var lastSpeechEnd: Int?

    var receivedSamples: Int { frameIndex * frameLength + pendingFrame.count }

    init(
        sampleRate: Int = 16_000,
        speculativePause: Double = 0.3,
        commitPause: Double = 0.5,
        minimumCommitSpeech: Double = 3.0,
        longPiece: Double = 25.0
    ) {
        self.sampleRate = sampleRate
        frameLength = Int(Double(sampleRate) * Self.frameSeconds)
        speculativePauseFrames = Int((speculativePause / Self.frameSeconds).rounded())
        commitPauseFrames = Int((commitPause / Self.frameSeconds).rounded())
        minimumCommitSpeechFrames = Int((minimumCommitSpeech / Self.frameSeconds).rounded())
        longPieceFrames = Int((longPiece / Self.frameSeconds).rounded())
    }

    /// Feeds the next audio and returns the pieces it closes, in order.
    mutating func append(_ samples: [Float]) -> [Event] {
        var events: [Event] = []
        for sample in samples {
            pendingFrame.append(sample)
            guard pendingFrame.count == frameLength else { continue }
            if let event = consumeFrame() { events.append(event) }
        }
        return events
    }

    private mutating func consumeFrame() -> Event? {
        var energy: Float = 0
        for sample in pendingFrame { energy += sample * sample }
        let level = (energy / Float(frameLength)).squareRoot()
        pendingFrame.removeAll(keepingCapacity: true)
        frameIndex += 1
        updateThreshold(with: level)

        let frameEnd = frameIndex * frameLength
        if level > speechThreshold {
            silentFrames = 0
            spokeSinceSpeculation = true
            pieceSpeechFrames += 1
            lastSpeechEnd = frameEnd
            return nil
        }

        silentFrames += 1
        let pieceFrames = (frameEnd - pieceStart) / frameLength
        let longPiece = pieceFrames >= longPieceFrames
        if silentFrames == speculativePauseFrames, spokeSinceSpeculation, pieceSpeechFrames >= speculativePauseFrames {
            spokeSinceSpeculation = false
            if longPiece, pieceSpeechFrames >= minimumCommitSpeechFrames {
                return commit(at: frameEnd)
            }
            return Event(kind: .speculate, start: pieceStart, end: frameEnd)
        }
        if silentFrames == commitPauseFrames, pieceSpeechFrames >= minimumCommitSpeechFrames {
            return commit(at: frameEnd)
        }
        return nil
    }

    private mutating func commit(at end: Int) -> Event {
        let event = Event(kind: .commit, start: pieceStart, end: end)
        pieceStart = end
        pieceSpeechFrames = 0
        return event
    }

    private mutating func updateThreshold(with level: Float) {
        recentLevels.append(level)
        if recentLevels.count > Self.quietLevelWindowFrames {
            recentLevels.removeFirst(recentLevels.count - Self.quietLevelWindowFrames)
        }
        framesSinceThreshold += 1
        guard framesSinceThreshold >= Self.quietLevelRefreshFrames || recentLevels.count < Self.quietLevelRefreshFrames else { return }
        framesSinceThreshold = 0
        let sorted = recentLevels.sorted()
        let quiet = sorted[Int(Double(sorted.count - 1) * 0.2)]
        let loud = sorted[Int(Double(sorted.count - 1) * 0.9)]
        // Capped at half the loud level: when quiet frames are scarce (a take
        // that starts straight into speech, or someone talking with hardly a
        // pause) the 20th percentile is the voice itself, and three times it
        // would call speech silence and let a cut land inside a word.
        speechThreshold = max(min(quiet * 3, loud * 0.5), Self.minimumSpeechRMS)
    }
}
