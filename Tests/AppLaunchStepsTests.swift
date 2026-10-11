import Foundation

// Launch recovers dictation audio left by an earlier run (fork) and never asks
// about it. The app delegate runs AppLaunchSteps after the overlay is set up;
// this drives the same list on a fake dictation host. What recovery does is
// tested in DictationLeftoverRecoveryTests and DictationStoppedAudioRecoveryTests.

@MainActor
private final class FakeLaunchDictationHost: AppLaunchDictationHost {
    var leftoverRecoveries = 0

    func recoverLeftoverStoppedAudio() {
        leftoverRecoveries += 1
    }
}

@MainActor
func testAppLaunchSteps() async {
    runSuite("Launch recovers leftover dictation audio once") {
        assertEqual(
            AppLaunchSteps.afterOverlaySetup,
            [.leftoverStoppedAudioRecovery],
            "launch's only dictation step is the leftover-audio recovery, with no saved-recording prompt"
        )

        let host = FakeLaunchDictationHost()
        let ran = AppLaunchSteps.runAfterOverlaySetup(dictation: host)

        assertEqual(ran, AppLaunchSteps.afterOverlaySetup, "every listed launch step should run")
        assertEqual(host.leftoverRecoveries, 1, "launch should recover leftover dictation audio exactly once")
    }
}
