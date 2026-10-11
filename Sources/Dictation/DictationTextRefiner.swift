import Foundation

/// A second pass over a finished dictation's text before it's pasted. The fork
/// runs a local LLM here (`Sources/TranscriptLLM/`); the dictation pipeline
/// only knows this protocol.
///
/// A refiner never throws and never loses text: anything but `.refined` means
/// "paste the transcript you already have".
@MainActor
protocol DictationTextRefiner: AnyObject {
    func refine(_ text: String) async -> DictationTextRefinement
}

enum DictationTextRefinement: Equatable, Sendable {
    case refined(String)
    case unchanged(DictationTextRefinementSkip)

    /// The text to deliver: the refined text, or the original on any skip.
    func text(original: String) -> String {
        if case let .refined(text) = self { return text }
        return original
    }
}

/// Why the original text was kept. Values are safe to log: no text in them.
enum DictationTextRefinementSkip: String, Equatable, Sendable {
    /// The prompt is empty: the user turned the pass off.
    case noPrompt = "no-prompt"
    /// The model is downloading, verifying, or its engine isn't running.
    case notReady = "not-ready"
    /// The engine failed, answered malformed JSON, or ran out of context.
    case failed
    /// The answer looked like something other than the dictation; see
    /// `DictationTextRefinementPolicy`.
    case rejected
    /// The dictation was cancelled while the pass ran.
    case cancelled
}

/// Accepts or rejects a refiner's answer before it replaces the transcript.
///
/// A small local model sometimes answers the dictation instead of correcting
/// it ("напиши функцию…" comes back as code), drops most of it, or stops at its
/// token limit. Pasting that would silently lose what the user said, so an
/// answer far off the original's length is rejected and the original is pasted.
/// The bounds are loose on purpose: on the owner's 32 reference dictations the
/// accepted answers ran 0.89–1.10 of the original's length. A short dictation
/// that asks for a reply ("ответь одним словом: получено") gets the reply back
/// just as a long one does, so the lower bound holds for short text too, once
/// more than a few words are gone.
enum DictationTextRefinementPolicy {
    static let minimumLengthRatio = 0.4
    static let maximumLengthRatio = 2.0
    /// Short dictations swing more in relative terms ("ок" → "OK.", fillers
    /// dropped from "ну э короче давай"): losing this many characters is
    /// fine at any ratio.
    static let maximumDroppedCharacters = 24
    static let maximumAddedCharacters = 80

    static let transcriptOpenTag = "<TRANSCRIPTION-START>"
    static let transcriptCloseTag = "<TRANSCRIPTION-END>"

    /// The answer cleaned of tags the model may echo back, or nil when it
    /// can't stand in for the original.
    static func accepted(original: String, answer: String) -> String? {
        let cleaned = answer
            .replacingOccurrences(of: transcriptOpenTag, with: "")
            .replacingOccurrences(of: transcriptCloseTag, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        let originalCount = original.trimmingCharacters(in: .whitespacesAndNewlines).count
        let answerCount = cleaned.count
        if Double(answerCount) > Double(originalCount) * maximumLengthRatio + Double(maximumAddedCharacters) {
            return nil
        }
        if originalCount - answerCount > maximumDroppedCharacters,
           Double(answerCount) < Double(originalCount) * minimumLengthRatio {
            return nil
        }
        return cleaned
    }
}
