import Foundation

extension MeetingPromptHeuristics {
    /// Seconds the prompt counts down before it records by itself, or nil
    /// when it only asks. `chosenDelay` is the Settings choice (nil = off).
    /// Each guard keeps a prompt that may be wrong, or a start that would
    /// need a click anyway, asking instead:
    /// - Only an app holding the mic or turning the camera on, or a call
    ///   joined muted in a browser tab whose title only exists once joined
    ///   (not Meet: its code title is on the pre-join screen too, and with no
    ///   mic nothing says the user went in). A native app's call audio alone
    ///   (`.audioOutput`) is also a call ringing before anyone answers;
    ///   calendar and app-running prompts can come before anyone joins.
    /// - Only a native call app or a tab title that exists only during a
    ///   call. Browser guesses from mic time (ChatGPT voice, web dictation and
    ///   Loom hold the mic too) are turned down more often than recorded.
    /// - Mic access granted, and macOS already asked about call audio: else
    ///   the start raises a macOS dialog over the call that nobody asked for.
    /// - The call was not recorded yet: after a Stop mid-call, the next prompt
    ///   for the same call asks.
    /// - Not a chat app's call in its own app (Slack, Telegram, WhatsApp,
    ///   Discord, the Telemost app): two-way audio there is also a voice chat
    ///   left open or a long voice note played while recording another, so
    ///   those only ask. A Telemost call in a tab is named by its title.
    static func autoRecordDelaySeconds(
        for reason: MeetingPromptReason,
        provider: MeetingPromptProvider,
        evidence: MeetingPromptCallEvidence,
        chosenDelay: Int?,
        microphoneGranted: Bool,
        systemAudioStatus: SystemAudioCaptureTCCStatus,
        callAlreadyRecorded: Bool
    ) -> Int? {
        guard let chosenDelay, chosenDelay > 0,
              reason == .micInput || reason == .cameraInput
                || (reason == .audioOutput && evidence == .tabTitle && provider != .googleMeet),
              evidence == .nativeApp || evidence == .tabTitle,
              !(provider.requiresTwoWayAudio && evidence == .nativeApp),
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
