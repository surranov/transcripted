import Foundation

/// The two passes of the transcript LLM (fork, `Sources/TranscriptLLM/`):
/// every dictation before it's pasted, every utterance of a saved meeting.
/// Each has its own prompt and its own model.
enum TranscriptLLMPass: String, CaseIterable, Sendable {
    case dictation
    case meeting

    var prompt: TranscriptLLMPromptPreference {
        switch self {
        case .dictation: .dictation
        case .meeting: .meeting
        }
    }

    var model: TranscriptLLMModelPreference {
        switch self {
        case .dictation: .dictation
        case .meeting: .meeting
        }
    }
}

/// The local models a pass can run. The raw value is the model's folder
/// under `models/transcript-llm/` and its `ModelDescriptor.identifier`
/// (`TranscriptLLMModel.descriptor(for:)`), so a saved choice and the file on
/// disk always name the same model.
enum TranscriptLLMModelChoice: String, CaseIterable, Identifiable, Sendable {
    /// Benchmarked on the owner's dictations (2026-10-10): about half E4B's
    /// time per dictation.
    case gemma4E2B = "gemma-4-e2b-it-q4_0"
    /// Higher scores on the same dictations and keeps colloquial wording, at
    /// about twice E2B's time (2026-10-13).
    case gemma4E4B = "gemma-4-e4b-it-qat-q4_0"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gemma4E2B: "Gemma 4 E2B"
        case .gemma4E4B: "Gemma 4 E4B"
        }
    }

    /// The download, as Settings names it before the file is on disk.
    var downloadSize: String {
        switch self {
        case .gemma4E2B: "2.8 GB"
        case .gemma4E4B: "5.2 GB"
        }
    }
}

/// What came of deleting a model the user switched away from.
enum TranscriptLLMModelDeletion: Equatable, Sendable {
    case deleted
    /// A pass picked the model again before the deletion ran: nothing was
    /// deleted.
    case inUse
    /// The files couldn't be removed; whatever is left stays where it was.
    case failed
}

/// Which model one pass runs. Picking another model for a pass doesn't
/// delete the old one: Settings asks first, and only once no pass uses it
/// (`modelsInUse`).
struct TranscriptLLMModelPreference: Sendable {
    let key: String
    let defaultChoice: TranscriptLLMModelChoice

    /// Posted on the main thread after either pass's model changes, so the
    /// runtime can move the pass to a helper running that model.
    static let didChangeNotification = Notification.Name("TranscriptedTranscriptLLMModelDidChange")

    /// The saved model, or the default when none was saved or the saved one
    /// isn't offered anymore.
    func choice(userDefaults: UserDefaults = .standard) -> TranscriptLLMModelChoice {
        userDefaults.string(forKey: key).flatMap(TranscriptLLMModelChoice.init(rawValue:)) ?? defaultChoice
    }

    /// Saves the model and returns whether the pass's model changed. Doesn't
    /// notify; the caller posts `postDidChange()` once.
    @discardableResult
    func setChoice(_ choice: TranscriptLLMModelChoice, userDefaults: UserDefaults = .standard) -> Bool {
        guard self.choice(userDefaults: userDefaults) != choice else { return false }
        userDefaults.set(choice.rawValue, forKey: key)
        return true
    }

    static func postDidChange() {
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    /// Every model some pass runs. A model outside this set is safe to delete.
    static func modelsInUse(userDefaults: UserDefaults = .standard) -> Set<TranscriptLLMModelChoice> {
        Set(TranscriptLLMPass.allCases.map { $0.model.choice(userDefaults: userDefaults) })
    }

    /// Dictation stays on the faster model; meetings are rewritten in the
    /// background, where E4B's wording is worth its time (owner's call,
    /// 2026-10-14).
    static let dictation = TranscriptLLMModelPreference(key: "dictationLLMModel", defaultChoice: .gemma4E2B)
    static let meeting = TranscriptLLMModelPreference(key: "meetingLLMModel", defaultChoice: .gemma4E4B)
}
