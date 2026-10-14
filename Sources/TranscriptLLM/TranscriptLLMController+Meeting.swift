import Foundation

/// The meeting side: one utterance at a time on the meeting pass's slot, for
/// `MeetingTranscriptLLMWorker` (`Sources/Meeting/MeetingTranscriptLLMPass.swift`).
extension TranscriptLLMController: MeetingUtteranceRefiner {
    var meetingRefinerModelID: String {
        (layout?.engine(for: .meeting)?.model ?? TranscriptLLMModelPreference.meeting.choice()).rawValue
    }

    func refineMeetingUtterance(_ text: String) async -> MeetingUtteranceRefinement {
        let prompt = Self.systemPrompt(.meeting)
        guard !prompt.isEmpty else { return .keep }
        guard isStarted, !isStopped, let runtime = runtime(for: .meeting) else {
            return .unavailable
        }
        // A dictation waiting on the model goes first.
        while dictationsInFlight > 0, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard await waitUntilEngineReady(runtime) else {
            if !Task.isCancelled { ensureRunning(runtime) }
            return .unavailable
        }
        let outcome = await Self.complete(
            host: runtime.host,
            slot: runtime.engine.slot(of: .meeting),
            systemPrompt: prompt,
            transcript: text,
            maxTokens: TranscriptLLMChat.maxTokens(transcript: text)
        )
        switch outcome {
        case let .answer(.text(answer)):
            return DictationTextRefinementPolicy.accepted(original: text, answer: answer).map { .refined($0) } ?? .keep
        case .answer(.truncated), .answer(.malformed), .rejectedRequest:
            return .keep
        case .transportFailure:
            // The helper died mid-request, or a model switch retired it:
            // restart it and retry this utterance once a helper is back,
            // rather than keep it unrefined.
            runtime.host.reportCompletionFailure()
            return .unavailable
        case .cancelled:
            return .unavailable
        }
    }
}
