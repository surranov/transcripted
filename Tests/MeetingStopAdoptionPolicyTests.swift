import Foundation

func testMeetingStopAdoptionPolicy() {
    // A capture that stopped itself (disk guard, device give-up) is
    // `isRecording == false` from the first moment of its stop, but its files
    // are still being finalized. A manual Stop in that window must wait for it.
    runSuite("MeetingStopAdoptionPolicy waits for a stop the capture started on its own") {
        assertEqual(
            MeetingStopAdoptionPolicy.stopGenerationToAdopt(
                audioIsRecording: false,
                currentGeneration: 14,
                recordingGeneration: 12,
                settledStopGeneration: nil
            ),
            14,
            "the in-flight internal stop's completion is the one to wait for"
        )
        assertEqual(
            MeetingStopAdoptionPolicy.stopGenerationToAdopt(
                audioIsRecording: false,
                currentGeneration: 14,
                recordingGeneration: 12,
                settledStopGeneration: 10
            ),
            14,
            "an older stop's completion does not finish this one"
        )
    }

    runSuite("MeetingStopAdoptionPolicy leaves a live recording to the normal stop path") {
        assertEqual(
            MeetingStopAdoptionPolicy.stopGenerationToAdopt(
                audioIsRecording: true,
                currentGeneration: 14,
                recordingGeneration: 12,
                settledStopGeneration: nil
            ),
            nil,
            "a recording that is still running gets its own stop, not an adopted one"
        )
    }

    runSuite("MeetingStopAdoptionPolicy returns the finished files once the stop was handled") {
        assertEqual(
            MeetingStopAdoptionPolicy.stopGenerationToAdopt(
                audioIsRecording: false,
                currentGeneration: 14,
                recordingGeneration: 12,
                settledStopGeneration: 14
            ),
            nil,
            "a completed stop has nothing left to wait for"
        )
        assertEqual(
            MeetingStopAdoptionPolicy.stopGenerationToAdopt(
                audioIsRecording: false,
                currentGeneration: 14,
                recordingGeneration: 12,
                settledStopGeneration: 20
            ),
            nil,
            "a later completion also covers it"
        )
    }

    runSuite("MeetingStopAdoptionPolicy never waits when no stop was ever started") {
        assertEqual(
            MeetingStopAdoptionPolicy.stopGenerationToAdopt(
                audioIsRecording: false,
                currentGeneration: 3,
                recordingGeneration: nil,
                settledStopGeneration: nil
            ),
            nil,
            "no recording started on this bridge, so no completion will ever arrive"
        )
        assertEqual(
            MeetingStopAdoptionPolicy.stopGenerationToAdopt(
                audioIsRecording: false,
                currentGeneration: 12,
                recordingGeneration: 12,
                settledStopGeneration: nil
            ),
            nil,
            "the generation never moved, so no stop began"
        )
    }
}
