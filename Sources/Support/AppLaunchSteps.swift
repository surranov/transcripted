// AppLaunchSteps.swift
// Launch work the app delegate runs once its controllers are wired. Kept as a
// list so tests can check each step is still there and still runs.

/// The dictation side of launch. `DictationSessionController` conforms.
@MainActor
protocol AppLaunchDictationHost: AnyObject {
    /// Recovers dictation audio saved by an earlier run (a failed take, or
    /// one cut off by Quit or a crash): transcribes it and saves it to
    /// Dictations, and deletes only month-old takes it couldn't recover
    /// (fork; upstream deleted the short ones). Launch never asks about any
    /// of it.
    func recoverLeftoverStoppedAudio()
}

@MainActor
enum AppLaunchSteps {
    enum Step: String, CaseIterable {
        case leftoverStoppedAudioRecovery = "leftover_stopped_audio_recovery"
    }

    /// Steps run after the dictation overlay is set up, in order.
    static let afterOverlaySetup: [Step] = [.leftoverStoppedAudioRecovery]

    /// Runs `afterOverlaySetup` and returns the steps it ran.
    @discardableResult
    static func runAfterOverlaySetup(dictation: AppLaunchDictationHost) -> [Step] {
        for step in afterOverlaySetup {
            switch step {
            case .leftoverStoppedAudioRecovery:
                dictation.recoverLeftoverStoppedAudio()
            }
        }
        return afterOverlaySetup
    }
}
