import CoreGraphics
import Foundation

func testDictationAutoSendPreferences() {
    runSuite("DictationAutoSendFailure copy matches the Settings name and stands alone") {
        for failure in [DictationAutoSendFailure.accessibilityMissing, .targetChanged, .eventCreationFailed] {
            assertTrue(failure.message.hasPrefix("Pasted, but"), "the text did paste, so lead with that")
            assertTrue(failure.message.contains("send"), "Settings calls the feature \"Press send after pasting\"")
            assertFalse(failure.message.contains("Auto Enter"), "no name the user never saw in Settings")
            assertFalse(failure.message.contains("Return"), "the send key may be Command-Return")
        }
        assertEqual(
            DictationAutoSendFailure.targetChanged.message,
            "Pasted, but didn't press send because you switched apps.",
            "the switched-apps case in plain words"
        )
    }

    runSuite("Dictate & send key mode: only a take started with it presses send") {
        let perApp = DictationAutoSendRequestDecision(expected: true, key: .commandEnter, blockReason: .none)
        let anchored = DictationAutoSendRequestDecision(expected: true, key: .enter, blockReason: .none, requiresAnchoredField: true)
        func applied(_ decision: DictationAutoSendRequestDecision, _ mode: DictationAutoSendMode, key: Bool) -> DictationAutoSendRequestDecision {
            DictationAutoSendPolicy.applyingMode(decision, mode: mode, startedWithDictateAndSendKey: key, anchoredPasteEnabled: true)
        }

        for decision in [perApp, anchored] {
            assertEqual(applied(decision, .always, key: false), decision, "Always keeps today's behavior")
            assertEqual(applied(decision, .dictateAndSendKey, key: true), decision, "started with the key: send as decided")
            let plain = applied(decision, .dictateAndSendKey, key: false)
            assertFalse(plain.expected, "the plain dictation key only pastes")
            assertEqual(plain.blockReason, .sendKeyNotUsed, "and says why")
            assertEqual(plain.key, decision.key, "telemetry keeps the key it would have pressed")
            assertEqual(plain.requiresAnchoredField, decision.requiresAnchoredField)
        }

        let notAllowed = DictationAutoSendRequestDecision(expected: false, key: .enter, blockReason: .appNotAllowed)
        assertEqual(applied(notAllowed, .dictateAndSendKey, key: true), notAllowed, "the key doesn't widen where send is pressed")
        assertEqual(applied(notAllowed, .dictateAndSendKey, key: false).blockReason, .appNotAllowed, "an earlier reason wins")
        assertEqual(
            DictationAutoSendTelemetry.snapshot(
                request: applied(perApp, .dictateAndSendKey, key: false),
                pasteOutcome: .pasted,
                sendOutcome: .disabled
            ).analyticsProperties["auto_send_block_reason"],
            "send_key_not_used",
            "a coarse reason for the funnel"
        )
    }

    runSuite("Confirm mode: send waits for the user, and needs Anchored paste") {
        let perApp = DictationAutoSendRequestDecision(expected: true, key: .commandEnter, blockReason: .none)
        let waiting = DictationAutoSendPolicy.applyingMode(perApp, mode: .confirmAfterPaste, startedWithDictateAndSendKey: false, anchoredPasteEnabled: true)
        assertTrue(waiting.expected, "it still sends, once confirmed")
        assertTrue(waiting.awaitsConfirmation)
        assertEqual(waiting.key, .commandEnter, "with the app's own send key")
        assertFalse(waiting.pasteMayEndWaitOnLikelyPaste, "the paste keeps its full confirmation wait")
        assertFalse(
            DictationAutoSendPolicy.applyingMode(perApp, mode: .always, startedWithDictateAndSendKey: false, anchoredPasteEnabled: true).awaitsConfirmation,
            "Always sends right away"
        )

        let off = DictationAutoSendPolicy.applyingMode(perApp, mode: .confirmAfterPaste, startedWithDictateAndSendKey: false, anchoredPasteEnabled: false)
        assertFalse(off.expected, "without Anchored paste nothing is sent")
        assertEqual(off.blockReason, .confirmNeedsAnchoredPaste)

        let notAllowed = DictationAutoSendRequestDecision(expected: false, key: .enter, blockReason: .appNotAllowed)
        assertEqual(
            DictationAutoSendPolicy.applyingMode(notAllowed, mode: .confirmAfterPaste, startedWithDictateAndSendKey: false, anchoredPasteEnabled: true),
            notAllowed,
            "it never asks where send wouldn't be pressed"
        )
        assertEqual(
            DictationAutoSendTelemetry.snapshot(request: waiting, pasteOutcome: .pasted, sendOutcome: .awaitingConfirmation).blockReason,
            .none,
            "waiting isn't a block"
        )
        assertEqual(DictationAutoSendOutcome.awaitingConfirmation.diagnosticName, "awaiting_confirmation")
        assertNil(DictationAutoSendOutcome.awaitingConfirmation.confirmationTitle)
        assertEqual(
            DictationAutoSendPolicy.confirmationPrompt(confirmKey: .commandEnter, appName: "Telegram"),
            "Pasted. Press ⌘ Enter to send it in Telegram.",
            "names the key and the app"
        )
        assertEqual(
            DictationAutoSendPolicy.confirmationPrompt(
                confirmKey: .enter,
                appName: "Slack",
                text: "Let's meet at five tomorrow near the office",
                waitingAfter: 2
            ),
            "Pasted “Let's meet at five tomorrow…” in Slack. Press Enter to send it (2 more waiting).",
            "with more waiting, it quotes the words: two can go to the same app"
        )
    }

    runSuite("A send prompt quotes a take's first words, cut at a word") {
        assertEqual(DictationAutoSendPolicy.confirmationQuote("  Short   one "), "Short one", "whole when it fits")
        assertEqual(
            DictationAutoSendPolicy.confirmationQuote(String(repeating: "x", count: 40)),
            String(repeating: "x", count: DictationAutoSendPolicy.confirmationQuoteLength) + "…",
            "one long word is cut"
        )
        assertEqual(DictationAutoSendPolicy.confirmationQuote(""), "")
    }

    runSuite("A confirmed send goes only where the words went") {
        func path(
            frontmost: Bool = false, focused: Bool = false,
            terminal: Bool = false, windowCurrent: Bool = true
        ) -> DictationConfirmedSend {
            DictationAutoSendPolicy.confirmedSend(
                anchorAppIsFrontmost: frontmost, anchorIsFocused: focused,
                isTerminal: terminal, terminalWindowIsCurrent: windowCurrent, appName: "Ghostty"
            )
        }
        assertEqual(path(frontmost: true, focused: true), .frontmost, "still in that box: plain Return")
        assertEqual(path(frontmost: true, focused: false), .unavailable(.anchoredFieldLeft), "another box in the same app gets nothing")
        assertEqual(path(), .background(.accessibilityInsert), "elsewhere: the box's send button or its window, in the background")
        assertEqual(path(terminal: true), .background(.terminalKeystrokes), "a terminal takes Return addressed to it")
        assertEqual(
            path(terminal: true, windowCurrent: false),
            .unavailable(.backgroundSendUnavailable(appName: "Ghostty")),
            "never Return into another terminal window or tab"
        )
    }

    runSuite("Anchored Enter's notices say Enter wasn't pressed and where") {
        let background = DictationAutoSendFailure.backgroundSendUnavailable(appName: "T3 Code").message
        assertTrue(background.hasPrefix("Pasted in T3 Code"), "names the app the words went into")
        assertTrue(background.contains("Enter"), "says which key wasn't pressed")
        let left = DictationAutoSendFailure.anchoredFieldLeft.message
        assertTrue(left.hasPrefix("Pasted, but"), "the text did paste, so lead with that")
        assertTrue(left.contains("Enter"), "says which key wasn't pressed")
        assertEqual(DictationAutoSendFailure.anchoredFieldLeft.blockReason, .targetChanged, "counted as a target change")
        let changed = DictationAutoSendFailure.boxChanged(appName: "Slack")
        assertTrue(changed.message.contains("Slack"), "names the app of the box that changed")
        assertTrue(changed.message.hasPrefix("Didn't press send"), "a late confirm: nothing was pressed")
        assertEqual(changed.blockReason, .targetChanged, "counted as a target change")
    }

    runSuite("DictationAutoSendTelemetry counts Enter sent after a likely paste as sent") {
        let request = DictationAutoSendRequestDecision(expected: true, key: .enter, blockReason: .none, requiresAnchoredField: true)
        let sent = DictationAutoSendTelemetry.snapshot(request: request, pasteOutcome: .likelyPasted, sendOutcome: .sent(.enter))
        assertEqual(sent.blockReason, .none, "the anchored field showed the words, so Enter went")
        let held = DictationAutoSendTelemetry.snapshot(request: request, pasteOutcome: .likelyPasted, sendOutcome: .disabled)
        assertEqual(held.blockReason, .pasteUnverified, "without that proof Enter is held, as before")
    }

    runSuite("DictationAutoSendPreferences send key: Enter unless chosen") {
        let (defaults, suiteName) = makeAutoSendDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertEqual(DictationAutoSendPreferences.sendKey(userDefaults: defaults), .enter, "send key should default to Enter")
        DictationAutoSendPreferences.setSendKey(.commandEnter, userDefaults: defaults)
        assertEqual(DictationAutoSendPreferences.sendKey(userDefaults: defaults), .commandEnter, "send key should read explicit Cmd+Enter")
    }

    runSuite("DictationAutoSendPreferences falls back from unknown send key") {
        let (defaults, suiteName) = makeAutoSendDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("space_laser", forKey: "dictationAutoEnterKey")

        assertEqual(DictationAutoSendPreferences.sendKey(userDefaults: defaults), .enter, "unknown send key should fall back to Enter")
    }

    runSuite("DictationAutoSendPreferences confirm key and wait: Enter for 5 s unless chosen") {
        let (defaults, suiteName) = makeAutoSendDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertEqual(DictationAutoSendPreferences.confirmKey(userDefaults: defaults), .enter)
        assertEqual(DictationAutoSendPreferences.confirmSeconds(userDefaults: defaults), 5, "5 s by default")
        DictationAutoSendPreferences.setConfirmKey(.commandEnter, userDefaults: defaults)
        DictationAutoSendPreferences.setConfirmSeconds(15, userDefaults: defaults)
        assertEqual(DictationAutoSendPreferences.confirmKey(userDefaults: defaults), .commandEnter)
        assertEqual(DictationAutoSendPreferences.confirmSeconds(userDefaults: defaults), 15)
        DictationAutoSendPreferences.setConfirmSeconds(0, userDefaults: defaults)
        assertEqual(DictationAutoSendPreferences.confirmSeconds(userDefaults: defaults), 15, "a value Settings doesn't offer isn't saved")
        defaults.set(3600, forKey: "dictationAutoEnterConfirmSeconds")
        assertEqual(DictationAutoSendPreferences.confirmSeconds(userDefaults: defaults), 5, "a hand-edited wait falls back to 5 s")
        defaults.set("hyper_enter", forKey: "dictationAutoEnterConfirmKey")
        assertEqual(DictationAutoSendPreferences.confirmKey(userDefaults: defaults), .enter)
    }

    runSuite("DictationSendConfirmKey takes Return or keypad Enter with exactly its modifiers") {
        let m = PhysicalDictationTriggerModifiers.self
        let returnKey: UInt32 = 36, keypadEnter: UInt32 = 76, letterA: UInt32 = 0
        assertTrue(DictationSendConfirmKey.enter.matches(keyCode: returnKey, modifiers: 0))
        assertTrue(DictationSendConfirmKey.enter.matches(keyCode: keypadEnter, modifiers: m.function), "keypad Enter comes with Fn set by macOS")
        assertTrue(DictationSendConfirmKey.enter.matches(keyCode: returnKey, modifiers: m.capsLock), "Caps Lock doesn't count")
        assertFalse(DictationSendConfirmKey.enter.matches(keyCode: returnKey, modifiers: m.shift), "⇧ Enter is a new line, not plain Enter")
        assertFalse(DictationSendConfirmKey.enter.matches(keyCode: letterA, modifiers: 0))
        assertEqual(DictationSendConfirmKey.commandEnter.eventFlags, .maskCommand, "a press given back keeps its chord")
        assertEqual(DictationSendConfirmKey.enter.eventFlags, [])
        let pairs: [(DictationSendConfirmKey, UInt32)] = [
            (.shiftEnter, m.shift), (.controlEnter, m.control), (.optionEnter, m.option), (.commandEnter, m.command),
        ]
        for (key, modifier) in pairs {
            assertTrue(key.matches(keyCode: returnKey, modifiers: modifier), "\(key.title)")
            assertFalse(key.matches(keyCode: returnKey, modifiers: 0), "\(key.title) needs its modifier")
            assertFalse(key.matches(keyCode: returnKey, modifiers: modifier | m.shift | m.command | m.control), "and only that one")
        }
    }

    runSuite("DictationAutoSendOutcome confirmation titles distinguish sent keys") {
        assertEqual(
            DictationAutoSendOutcome.sent(.enter).confirmationTitle,
            "Pasted + Enter",
            "sent Enter should make the fired key visible in the overlay confirmation"
        )
        assertEqual(
            DictationAutoSendOutcome.sent(.commandEnter).confirmationTitle,
            "Pasted + Cmd + Enter",
            "sent Cmd+Enter should make the fired key visible in the overlay confirmation"
        )
        assertNil(
            DictationAutoSendOutcome.disabled.confirmationTitle,
            "disabled Auto Enter should keep the plain pasted confirmation"
        )
        assertNil(
            DictationAutoSendOutcome.failed(.accessibilityMissing).confirmationTitle,
            "failed Auto Enter should route to the visible error path instead"
        )
    }

    runSuite("DictationAutoSendTelemetry distinguishes success, paste blocks, and send failures") {
        let request = DictationAutoSendRequestDecision(expected: true, key: .commandEnter, blockReason: .none)

        let success = DictationAutoSendTelemetry.snapshot(
            request: request,
            pasteOutcome: .pasted,
            sendOutcome: .sent(.commandEnter)
        )
        assertEqual(success.expected, true, "successful Auto Enter should preserve the expected denominator")
        assertEqual(success.blockReason, .none, "successful Auto Enter should not report a block")
        assertEqual(success.analyticsProperties["auto_send_key"], "command_enter", "telemetry should retain only the coarse key choice")

        let unconfirmed = DictationAutoSendTelemetry.snapshot(
            request: request,
            pasteOutcome: .copied("unconfirmed", reason: .pasteNotConfirmed),
            sendOutcome: .disabled
        )
        assertEqual(unconfirmed.expected, true, "an eligible user configuration should remain expected when paste evidence blocks sending")
        assertEqual(unconfirmed.blockReason, .pasteNotConfirmed, "a paste with no evidence should be queryable")

        let likely = DictationAutoSendTelemetry.snapshot(
            request: request,
            pasteOutcome: .likelyPasted,
            sendOutcome: .disabled
        )
        assertEqual(likely.blockReason, .pasteUnverified, "a likely paste should say Return was held for lack of proof")
        assertEqual(likely.analyticsProperties["auto_send_block_reason"], "paste_unverified", "the block reason should stay a coarse enum value")

        let targetChanged = DictationAutoSendTelemetry.snapshot(
            request: request,
            pasteOutcome: .pasted,
            sendOutcome: .failed(.targetChanged)
        )
        assertEqual(targetChanged.blockReason, .targetChanged, "post-paste target changes should remain distinguishable")

        let featureOffRequest = DictationAutoSendRequestDecision(
            expected: false,
            key: .commandEnter,
            blockReason: .featureOff
        )
        let featureOff = DictationAutoSendTelemetry.snapshot(
            request: featureOffRequest,
            pasteOutcome: .pasted,
            sendOutcome: .disabled
        )
        assertEqual(featureOff.blockReason, .featureOff, "a disabled request should retain its real policy reason instead of looking cancelled")

        let cancelled = DictationAutoSendTelemetry.snapshot(
            request: request,
            pasteOutcome: .pasted,
            sendOutcome: .disabled
        )
        assertEqual(cancelled.blockReason, .cancelled, "only an expected eligible send that stops should be classified as cancelled")
    }

    runSuite("DictationAutoSendPolicy sends only after an eligible paste dispatch with text") {
        assertTrue(
            DictationAutoSendPolicy.shouldSend(
                decision: sendDecision(.send, isOverride: false, text: "Send this", duration: TranscriptedConstants.dictationAutoEnterMinimumDuration),
                pasteOutcome: .pasted
            ),
            "enabled pasted dictation with text should send"
        )

        assertFalse(
            DictationAutoSendPolicy.shouldSend(
                decision: sendDecision(.dontSend, isOverride: false, text: "Send this", duration: TranscriptedConstants.dictationAutoEnterMinimumDuration),
                pasteOutcome: .pasted
            ),
            "Default set to Don't send should not send"
        )

        assertFalse(
            DictationAutoSendPolicy.shouldSend(
                decision: sendDecision(.send, isOverride: false, text: "Send this", duration: TranscriptedConstants.dictationAutoEnterMinimumDuration),
                pasteOutcome: .likelyPasted
            ),
            "an unattributed clipboard read must not authorize Auto Enter"
        )

        assertFalse(
            DictationAutoSendPolicy.shouldSend(
                decision: sendDecision(.send, isOverride: false, text: "Send this", duration: TranscriptedConstants.dictationAutoEnterMinimumDuration),
                pasteOutcome: .copied(
                    "Paste dispatched without a target read",
                    reason: .pasteNotConfirmed
                )
            ),
            "an unconfirmed dispatch without target-read evidence should not send"
        )

        assertFalse(
            DictationAutoSendPolicy.shouldSend(
                decision: sendDecision(.send, isOverride: false, text: "Send this", duration: TranscriptedConstants.dictationAutoEnterMinimumDuration),
                pasteOutcome: .copied("Focus changed", reason: .focusChanged)
            ),
            "a true copied-only fallback should not send"
        )

        assertFalse(
            DictationAutoSendPolicy.shouldSend(
                decision: sendDecision(.send, isOverride: false, text: "   \n", duration: TranscriptedConstants.dictationAutoEnterMinimumDuration),
                pasteOutcome: .pasted
            ),
            "empty transcript should not send"
        )

        assertFalse(
            DictationAutoSendPolicy.shouldSend(
                decision: sendDecision(.send, isOverride: false, text: "Too fast", duration: TranscriptedConstants.dictationAutoEnterMinimumDuration - 0.01),
                pasteOutcome: .pasted
            ),
            "very short accidental taps should not send"
        )

        assertFalse(
            DictationAutoSendPolicy.shouldSend(
                decision: sendDecision(.dontSend, isOverride: true, text: "Send this", duration: TranscriptedConstants.dictationAutoEnterMinimumDuration),
                pasteOutcome: .pasted
            ),
            "an app set to Don't send should not send"
        )

    }
}

private func makeAutoSendDefaults() -> (UserDefaults, String) {
    let suiteName = "DictationAutoSendPreferencesTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}
