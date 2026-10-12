import Foundation

extension MeetingPromptHeuristics {
    /// Seconds the prompt counts down before it records by itself, or nil
    /// when it only asks. `chosenDelay` is the Settings choice (nil = off).
    /// Each guard keeps a prompt that may be wrong, or a start that would
    /// need a click anyway, asking instead:
    /// - Only an app holding the mic or turning the camera on. Call audio
    ///   alone (`.audioOutput`) is also a call ringing before anyone answers;
    ///   calendar and app-running prompts can come before anyone joins.
    /// - Only a native call app or a tab title that exists only during a
    ///   call. Browser guesses from mic time (ChatGPT voice, web dictation and
    ///   Loom hold the mic too) are turned down more often than recorded.
    /// - Mic access granted, and macOS already asked about call audio: else
    ///   the start raises a macOS dialog over the call that nobody asked for.
    /// - The call was not recorded yet: after a Stop mid-call, the next prompt
    ///   for the same call asks.
    static func autoRecordDelaySeconds(
        for reason: MeetingPromptReason,
        evidence: MeetingPromptCallEvidence,
        chosenDelay: Int?,
        microphoneGranted: Bool,
        systemAudioStatus: SystemAudioCaptureTCCStatus,
        callAlreadyRecorded: Bool
    ) -> Int? {
        guard let chosenDelay, chosenDelay > 0,
              reason == .micInput || reason == .cameraInput,
              evidence == .nativeApp || evidence == .tabTitle,
              microphoneGranted,
              systemAudioStatus != .notDetermined,
              !callAlreadyRecorded
        else { return nil }
        return chosenDelay
    }
}

extension MeetingPromptDetector {
    /// Whether a meeting recorded during the call that is going on now; a
    /// prompt after that recording stopped is for a call already recorded.
    var liveCallWasRecorded: Bool {
        detectedCallSession?.sawMeetingRecording ?? false
    }
}
