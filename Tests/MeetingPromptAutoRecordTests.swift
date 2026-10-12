import Foundation

/// "Record calls automatically": which detected-call prompts may record by
/// themselves after their countdown, and which only ask.
func testMeetingPromptAutoRecord() {
    func delay(
        reason: MeetingPromptReason = .micInput,
        evidence: MeetingPromptCallEvidence = .nativeApp,
        chosen: Int? = 10,
        mic: Bool = true,
        systemAudio: SystemAudioCaptureTCCStatus = .authorized,
        recorded: Bool = false
    ) -> Int? {
        MeetingPromptHeuristics.autoRecordDelaySeconds(
            for: reason,
            evidence: evidence,
            chosenDelay: chosen,
            microphoneGranted: mic,
            systemAudioStatus: systemAudio,
            callAlreadyRecorded: recorded
        )
    }

    runSuite("Auto-record: a live call in a call app counts down the chosen delay") {
        assertEqual(delay(chosen: 10), 10, "Zoom holding the mic records after 10s")
        assertEqual(delay(chosen: 30), 30, "the delay is the one chosen in Settings")
        assertEqual(delay(reason: .cameraInput), 10, "a camera-on, mic-muted join is a live call too")
        assertEqual(delay(evidence: .tabTitle), 10, "a Meet tab whose title only exists during a call")
        assertEqual(delay(systemAudio: .denied), 10, "call audio already turned down: records the mic without asking macOS again")
        assertEqual(delay(systemAudio: .unavailable), 10, "no answer from macOS's permission API is not a dialog either")
    }

    runSuite("Auto-record: off in Settings, every prompt only asks") {
        assertNil(delay(chosen: nil), "Off is the default")
        assertNil(delay(chosen: 0), "a zero delay would record with no countdown")
        assertNil(delay(chosen: -5), "a negative delay is not a choice")
    }

    runSuite("Auto-record: prompts that may come before a call or aren't one only ask") {
        for reason in [MeetingPromptReason.calendarNearby, .calendarPlusRuntimeMatch, .runtimeOnly] {
            assertNil(delay(reason: reason, evidence: .none), "\(reason.rawValue) can come before anyone joined")
        }
        assertNil(delay(reason: .audioOutput), "call audio alone is also a call ringing before anyone answers")
        for evidence in [MeetingPromptCallEvidence.callSite, .camera, .micAndOutput, .micOnly, .none] {
            assertNil(
                delay(evidence: evidence),
                "\(evidence.rawValue) is a guess (ChatGPT voice, web dictation and Loom hold the mic too)"
            )
        }
    }

    runSuite("Auto-record: a start that would raise a macOS dialog only asks") {
        assertNil(delay(mic: false), "without mic access the start asks macOS for it or fails")
        assertNil(delay(systemAudio: .notDetermined), "the first start shows macOS's call audio allow box")
    }

    runSuite("Auto-record: a call already recorded once only asks again") {
        assertNil(delay(recorded: true), "after a Stop mid-call, the next prompt for that call asks")
    }
}
