import Foundation

/// "Record calls automatically": when the detected-call prompt records by
/// itself. The countdown and the Record path are `CapturePillController` and
/// `recordPrompt` in TranscriptedApp; this only decides.
extension TranscriptedAppDelegate {
    /// Seconds the prompt counts down before recording, or nil when it only
    /// asks (see `MeetingPromptHeuristics.autoRecordDelaySeconds`).
    func callPromptAutoRecordDelay(
        for candidate: MeetingPromptDetector.Candidate,
        systemAudioStatus: SystemAudioCaptureTCCStatus
    ) -> Int? {
        MeetingPromptHeuristics.autoRecordDelaySeconds(
            for: candidate.reason,
            evidence: candidate.callEvidence,
            chosenDelay: CallPromptAutoRecordPreferences.delaySeconds(),
            microphoneGranted: TranscriptedPermissionAccess.isGranted(.microphone),
            systemAudioStatus: systemAudioStatus,
            callAlreadyRecorded: meetingPromptDetector.liveCallWasRecorded
        )
    }

    /// Read again as the countdown runs out: the settings may have changed
    /// during it, a dictation may have just started, and on a locked or
    /// sleeping screen no one saw it count down. Any of those closes the
    /// prompt unanswered instead of recording.
    func callPromptAutoRecordStillAllowed() -> Bool {
        CallPromptAutoRecordPreferences.delaySeconds() != nil
            && AutoCallDetectionPreferences.isEnabled()
            && !appState.sttRouter.isRecording
            && ScreenPresence.screenIsViewable()
    }
}
