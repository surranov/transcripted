import Foundation

/// The meeting side: one utterance at a time on the meeting slot, for
/// `MeetingTranscriptLLMWorker` (`Sources/Meeting/MeetingTranscriptLLMPass.swift`).
extension TranscriptLLMController: MeetingUtteranceRefiner {
    var meetingRefinerModelID: String { TranscriptLLMModel.descriptor.identifier }

    func refineMeetingUtterance(_ text: String) async -> MeetingUtteranceRefinement {
        let prompt = Self.systemPrompt(.meeting)
        guard !prompt.isEmpty else { return .keep }
        guard isStarted, !isStopped, let host else { return .unavailable }
        // A dictation waiting on the model goes first.
        while dictationsInFlight > 0, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard await waitUntilEngineReady(host) else {
            if !Task.isCancelled { ensureRunning() }
            return .unavailable
        }
        let outcome = await Self.complete(
            host: host,
            slot: .meeting,
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
            // The helper died mid-request: restart it and retry this
            // utterance once it's back, rather than keep it unrefined.
            host.reportCompletionFailure()
            return .unavailable
        case .cancelled:
            return .unavailable
        }
    }
}
