import Foundation

func testCallPromptTimeoutClock() {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let limit = CallPromptTimeoutClock.offScreenHoldLimit

    runSuite("A call prompt's timeout runs its full length once shown") {
        var clock = CallPromptTimeoutClock()
        assertEqual(clock.start(timeout: 30, now: t0), .run(seconds: 30))
        assertEqual(clock.deadline, t0.addingTimeInterval(30))
        assertFalse(clock.isHeld)
    }

    runSuite("A call prompt waiting behind a dictation doesn't use up its time") {
        var clock = CallPromptTimeoutClock()
        _ = clock.start(timeout: 30, now: t0)
        assertEqual(
            clock.setOnScreen(false, now: t0.addingTimeInterval(5)),
            .hold(expiresIn: limit),
            "a dictation covering the prompt stops its timeout"
        )
        assertEqual(clock.heldRemaining, 25)
        // A long dictation: far longer than the whole timeout.
        assertEqual(
            clock.setOnScreen(true, now: t0.addingTimeInterval(95)),
            .run(seconds: 25),
            "back on screen it picks up with the time it had left"
        )
        assertEqual(clock.deadline, t0.addingTimeInterval(120))
    }

    runSuite("A call prompt that arrives during a dictation keeps its whole timeout") {
        var clock = CallPromptTimeoutClock()
        _ = clock.start(timeout: 30, now: t0)
        // The island reports the new prompt as off screen right away.
        assertEqual(clock.setOnScreen(false, now: t0), .hold(expiresIn: limit))
        assertEqual(clock.setOnScreen(true, now: t0.addingTimeInterval(90)), .run(seconds: 30))
    }

    runSuite("A call prompt can't wait behind dictations forever") {
        var clock = CallPromptTimeoutClock()
        _ = clock.start(timeout: 30, now: t0)
        assertEqual(clock.setOnScreen(false, now: t0.addingTimeInterval(10)), .hold(expiresIn: limit))
        // Back for a moment, then covered again: the allowance is per prompt,
        // not per stretch.
        _ = clock.setOnScreen(true, now: t0.addingTimeInterval(10 + 50))
        assertEqual(
            clock.setOnScreen(false, now: t0.addingTimeInterval(65)),
            .hold(expiresIn: limit - 50),
            "the second stretch only gets what the first one left"
        )
        // Hovering the island while it is covered doesn't lift the cap.
        assertEqual(
            clock.setHovered(true, now: t0.addingTimeInterval(75)),
            .hold(expiresIn: limit - 60)
        )
        assertEqual(
            clock.setHovered(false, now: t0.addingTimeInterval(80)),
            .hold(expiresIn: limit - 65),
            "still covered, still counting down the allowance"
        )
    }

    runSuite("A newer call prompt behind the same dictation stays held with a fresh allowance") {
        var clock = CallPromptTimeoutClock()
        _ = clock.start(timeout: 30, now: t0)
        _ = clock.setOnScreen(false, now: t0.addingTimeInterval(2))
        assertEqual(
            clock.start(timeout: 30, now: t0.addingTimeInterval(100)),
            .hold(expiresIn: limit),
            "the island only reports changes, so a replacement must not start running while still covered"
        )
        assertEqual(clock.setOnScreen(true, now: t0.addingTimeInterval(140)), .run(seconds: 30))
    }

    runSuite("Hovering the island holds the call prompt's timeout for as long as it's read") {
        var clock = CallPromptTimeoutClock()
        _ = clock.start(timeout: 30, now: t0)
        assertEqual(clock.setHovered(true, now: t0.addingTimeInterval(10)), .hold(expiresIn: nil))
        assertEqual(clock.setHovered(false, now: t0.addingTimeInterval(600)), .run(seconds: 20))
    }

    runSuite("The call prompt's timeout runs only when it is both on screen and not hovered") {
        var clock = CallPromptTimeoutClock()
        _ = clock.start(timeout: 30, now: t0)
        assertEqual(clock.setHovered(true, now: t0.addingTimeInterval(4)), .hold(expiresIn: nil))
        assertEqual(clock.setOnScreen(false, now: t0.addingTimeInterval(6)), .hold(expiresIn: limit))
        assertEqual(clock.setOnScreen(true, now: t0.addingTimeInterval(8)), .hold(expiresIn: nil), "still hovered")
        assertTrue(clock.isHeld)
        assertEqual(clock.setHovered(false, now: t0.addingTimeInterval(50)), .run(seconds: 26))
    }

    runSuite("Repeated reports of the same call prompt state change nothing") {
        var clock = CallPromptTimeoutClock()
        _ = clock.start(timeout: 30, now: t0)
        _ = clock.setOnScreen(false, now: t0.addingTimeInterval(1))
        assertEqual(clock.setOnScreen(false, now: t0.addingTimeInterval(30)), .keepGoing)
        assertEqual(clock.setHovered(false, now: t0.addingTimeInterval(31)), .keepGoing)
        assertEqual(
            clock.setOnScreen(true, now: t0.addingTimeInterval(40)),
            .run(seconds: 29),
            "a repeated off-screen report doesn't restart the stretch or lose the remaining time"
        )
    }

    runSuite("A new call prompt doesn't inherit an old hover") {
        var clock = CallPromptTimeoutClock()
        _ = clock.start(timeout: 30, now: t0)
        _ = clock.setHovered(true, now: t0.addingTimeInterval(1))
        assertEqual(clock.start(timeout: 20, now: t0.addingTimeInterval(3)), .run(seconds: 20))
    }

    runSuite("A held call prompt always has at least a second left") {
        var clock = CallPromptTimeoutClock()
        _ = clock.start(timeout: 30, now: t0)
        _ = clock.setHovered(true, now: t0.addingTimeInterval(45))
        assertEqual(clock.heldRemaining, 1)
    }

    runSuite("With no call prompt up, hover and visibility changes do nothing") {
        var clock = CallPromptTimeoutClock()
        assertEqual(clock.setOnScreen(false, now: t0), .keepGoing)
        assertEqual(clock.setHovered(true, now: t0), .keepGoing)
        _ = clock.start(timeout: 30, now: t0)
        _ = clock.setOnScreen(false, now: t0.addingTimeInterval(1))
        clock.stop()
        assertNil(clock.deadline)
        assertEqual(clock.setOnScreen(true, now: t0.addingTimeInterval(2)), .keepGoing)
        assertEqual(
            clock.start(timeout: 30, now: t0.addingTimeInterval(3)),
            .run(seconds: 30),
            "after the prompt closes, the next one starts on screen until the island says otherwise"
        )
    }

    runSuite("An auto-record call prompt that runs out on screen records") {
        var clock = CallPromptTimeoutClock()
        assertEqual(clock.start(timeout: 15, autoRecords: true, now: t0), .run(seconds: 15))
        assertEqual(clock.timeoutOutcome, .record, "running out while shown and unhovered starts the recording")
    }

    runSuite("Hovering an auto-record call prompt holds the countdown, and it still records after") {
        var clock = CallPromptTimeoutClock()
        _ = clock.start(timeout: 15, autoRecords: true, now: t0)
        assertEqual(
            clock.setHovered(true, now: t0.addingTimeInterval(5)),
            .hold(expiresIn: nil),
            "reading the prompt never lets it record out from under the pointer"
        )
        assertEqual(clock.setHovered(false, now: t0.addingTimeInterval(300)), .run(seconds: 10))
        assertEqual(clock.timeoutOutcome, .record, "once the pointer leaves, running out records again")
    }

    runSuite("An auto-record call prompt nobody could see never records") {
        var clock = CallPromptTimeoutClock()
        _ = clock.start(timeout: 15, autoRecords: true, now: t0)
        assertEqual(clock.setOnScreen(false, now: t0.addingTimeInterval(3)), .hold(expiresIn: limit))
        assertEqual(
            clock.timeoutOutcome,
            .expire,
            "the off-screen allowance running out closes the prompt unanswered instead of recording"
        )
        _ = clock.setHovered(true, now: t0.addingTimeInterval(10))
        _ = clock.setHovered(false, now: t0.addingTimeInterval(11))
        assertEqual(clock.timeoutOutcome, .expire, "hover changes while covered don't turn recording back on")
    }

    runSuite("An auto-record call prompt back on screen records when its time runs out") {
        var clock = CallPromptTimeoutClock()
        _ = clock.start(timeout: 15, autoRecords: true, now: t0)
        _ = clock.setOnScreen(false, now: t0.addingTimeInterval(3))
        assertEqual(clock.setOnScreen(true, now: t0.addingTimeInterval(60)), .run(seconds: 12))
        assertEqual(clock.timeoutOutcome, .record)
    }

    runSuite("A call prompt without auto-record only ever expires") {
        var clock = CallPromptTimeoutClock()
        _ = clock.start(timeout: 30, now: t0)
        assertEqual(clock.timeoutOutcome, .expire, "on screen")
        _ = clock.setOnScreen(false, now: t0.addingTimeInterval(1))
        assertEqual(clock.timeoutOutcome, .expire, "off screen")
        _ = clock.setOnScreen(true, now: t0.addingTimeInterval(2))
        assertEqual(clock.timeoutOutcome, .expire, "back on screen")
    }

    runSuite("Auto-record doesn't carry over to the next call prompt") {
        var clock = CallPromptTimeoutClock()
        _ = clock.start(timeout: 15, autoRecords: true, now: t0)
        _ = clock.start(timeout: 30, now: t0.addingTimeInterval(2))
        assertEqual(clock.timeoutOutcome, .expire, "a replacement prompt that doesn't auto-record only expires")

        _ = clock.start(timeout: 15, autoRecords: true, now: t0.addingTimeInterval(4))
        clock.stop()
        assertEqual(clock.timeoutOutcome, .expire, "a closed prompt has nothing to record")
        _ = clock.start(timeout: 30, now: t0.addingTimeInterval(6))
        assertEqual(clock.timeoutOutcome, .expire, "and the next plain prompt after it only expires")
    }
}
