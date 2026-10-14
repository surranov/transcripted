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

    runSuite("Anchored Enter expects Enter for an anchored take in any app") {
        func decision(
            perApp: DictationAutoSendRequestDecision = DictationAutoSendRequestDecision(expected: false, key: .enter, blockReason: .appNotAllowed),
            on: Bool = true, text: String = "ship it", duration: TimeInterval = 2
        ) -> DictationAutoSendRequestDecision {
            DictationAutoSendPolicy.anchoredEnterDecision(perApp: perApp, pressesEnter: on, text: text, duration: duration)
        }
        let anchored = decision()
        assertTrue(anchored.expected, "an app never chosen for Press send after pasting still gets Enter")
        assertEqual(anchored.key, .enter, "Anchored Enter presses Enter")
        assertTrue(anchored.requiresAnchoredField, "and only into the anchored field")
        assertTrue(decision(perApp: .init(expected: false, key: .enter, blockReason: .featureOff)).expected, "Press send after pasting may be off entirely")

        let chosen = DictationAutoSendRequestDecision(expected: true, key: .commandEnter, blockReason: .none)
        assertEqual(decision(perApp: chosen), chosen, "a chosen app keeps its own key and rules")

        let off = decision(on: false)
        assertFalse(off.expected, "off: only the per-app choice counts")
        assertEqual(off.blockReason, .appNotAllowed, "and its reason is kept")
        assertFalse(off.requiresAnchoredField)

        assertEqual(decision(text: "  \n").blockReason, .emptyText, "no words, no Enter")
        assertFalse(decision(text: "  \n").expected)
        assertEqual(decision(duration: 0.1).blockReason, .durationTooShort, "an accidental tap sends nothing")
        assertFalse(decision(duration: 0.1).expected)
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

    runSuite("AnchoredPastePreferences: Press Enter there needs Anchored paste") {
        let suiteName = "AnchoredEnterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        assertFalse(AnchoredPastePreferences.pressesEnter(userDefaults: defaults), "off by default")
        AnchoredPastePreferences.setPressesEnter(true, userDefaults: defaults)
        assertFalse(AnchoredPastePreferences.pressesEnter(userDefaults: defaults), "nothing to press Enter in without Anchored paste")
        AnchoredPastePreferences.setEnabled(true, userDefaults: defaults)
        assertTrue(AnchoredPastePreferences.pressesEnter(userDefaults: defaults), "both on")
        AnchoredPastePreferences.setPressesEnter(false, userDefaults: defaults)
        assertFalse(AnchoredPastePreferences.pressesEnter(userDefaults: defaults), "Anchored paste alone only pastes")
    }

    runSuite("DictationAutoSendPreferences defaults to disabled Enter") {
        let (defaults, suiteName) = makeAutoSendDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertFalse(DictationAutoSendPreferences.isEnabled(userDefaults: defaults), "auto enter should default off")
        assertEqual(DictationAutoSendPreferences.sendKey(userDefaults: defaults), .enter, "send key should default to Enter")
        assertEqual(DictationAutoSendPreferences.allowedBundleIDs(userDefaults: defaults), [], "allowed app list should default empty")
    }

    runSuite("DictationAutoSendPreferences persists enabled state and send key") {
        let (defaults, suiteName) = makeAutoSendDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        DictationAutoSendPreferences.setEnabled(true, userDefaults: defaults)
        DictationAutoSendPreferences.setSendKey(.commandEnter, userDefaults: defaults)
        DictationAutoSendPreferences.setAllowedBundleIDs(["com.example.Chat", "com.example.Notes"], userDefaults: defaults)

        assertTrue(DictationAutoSendPreferences.isEnabled(userDefaults: defaults), "auto enter should read explicit enabled state")
        assertEqual(DictationAutoSendPreferences.sendKey(userDefaults: defaults), .commandEnter, "send key should read explicit Cmd+Enter")
        assertEqual(
            DictationAutoSendPreferences.allowedBundleIDs(userDefaults: defaults),
            ["com.example.Chat", "com.example.Notes"],
            "allowed app list should persist bundle IDs"
        )
    }

    runSuite("DictationAutoSendPreferences falls back from unknown send key") {
        let (defaults, suiteName) = makeAutoSendDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("space_laser", forKey: "dictationAutoEnterKey")

        assertEqual(DictationAutoSendPreferences.sendKey(userDefaults: defaults), .enter, "unknown send key should fall back to Enter")
    }

    runSuite("DictationAutoSendPreferences mode: always unless chosen") {
        let (defaults, suiteName) = makeAutoSendDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertEqual(DictationAutoSendPreferences.mode(userDefaults: defaults), .always, "nothing stored keeps sending on every take")
        for mode in DictationAutoSendMode.allCases {
            DictationAutoSendPreferences.setMode(mode, userDefaults: defaults)
            assertEqual(DictationAutoSendPreferences.mode(userDefaults: defaults), mode, "\(mode) reads back")
        }
        defaults.set("telepathy", forKey: "dictationAutoEnterMode")
        assertEqual(DictationAutoSendPreferences.mode(userDefaults: defaults), .always, "a mode this build doesn't know falls back to always")
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

    runSuite("DictationAutoSendPolicy explains why Auto Enter was or was not expected") {
        let expected = DictationAutoSendPolicy.requestDecision(
            isEnabled: true,
            key: .commandEnter,
            text: "Send this",
            duration: TranscriptedConstants.dictationAutoEnterMinimumDuration,
            sourceBundleID: "com.example.Chat",
            allowedBundleIDs: ["com.example.Chat"]
        )
        assertEqual(
            expected,
            DictationAutoSendRequestDecision(expected: true, key: .commandEnter, blockReason: .none),
            "selected apps should expose an expected Command+Enter decision without app identity telemetry"
        )

        let featureOff = DictationAutoSendPolicy.requestDecision(
            isEnabled: false,
            key: .commandEnter,
            text: "Send this",
            duration: TranscriptedConstants.dictationAutoEnterMinimumDuration,
            sourceBundleID: "com.example.Chat",
            allowedBundleIDs: ["com.example.Chat"]
        )
        assertEqual(featureOff.blockReason, .featureOff, "disabled Auto Enter should have a coarse block reason")

        let appNotAllowed = DictationAutoSendPolicy.requestDecision(
            isEnabled: true,
            key: .enter,
            text: "Send this",
            duration: TranscriptedConstants.dictationAutoEnterMinimumDuration,
            sourceBundleID: "com.example.Notes",
            allowedBundleIDs: ["com.example.Chat"]
        )
        assertEqual(appNotAllowed.blockReason, .appNotAllowed, "unselected apps should have a coarse block reason")
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
                isEnabled: true,
                pasteOutcome: .pasted,
                text: "Send this",
                duration: TranscriptedConstants.dictationAutoEnterMinimumDuration,
                sourceBundleID: "com.example.Chat",
                allowedBundleIDs: ["com.example.Chat"]
            ),
            "enabled pasted dictation with text should send"
        )

        assertFalse(
            DictationAutoSendPolicy.shouldSend(
                isEnabled: false,
                pasteOutcome: .pasted,
                text: "Send this",
                duration: TranscriptedConstants.dictationAutoEnterMinimumDuration,
                sourceBundleID: "com.example.Chat",
                allowedBundleIDs: ["com.example.Chat"]
            ),
            "disabled preference should not send"
        )

        assertFalse(
            DictationAutoSendPolicy.shouldSend(
                isEnabled: true,
                pasteOutcome: .likelyPasted,
                text: "Send this",
                duration: TranscriptedConstants.dictationAutoEnterMinimumDuration,
                sourceBundleID: "com.example.Chat",
                allowedBundleIDs: ["com.example.Chat"]
            ),
            "an unattributed clipboard read must not authorize Auto Enter"
        )

        assertFalse(
            DictationAutoSendPolicy.shouldSend(
                isEnabled: true,
                pasteOutcome: .copied(
                    "Paste dispatched without a target read",
                    reason: .pasteNotConfirmed
                ),
                text: "Send this",
                duration: TranscriptedConstants.dictationAutoEnterMinimumDuration,
                sourceBundleID: "com.example.Chat",
                allowedBundleIDs: ["com.example.Chat"]
            ),
            "an unconfirmed dispatch without target-read evidence should not send"
        )

        assertFalse(
            DictationAutoSendPolicy.shouldSend(
                isEnabled: true,
                pasteOutcome: .copied("Focus changed", reason: .focusChanged),
                text: "Send this",
                duration: TranscriptedConstants.dictationAutoEnterMinimumDuration,
                sourceBundleID: "com.example.Chat",
                allowedBundleIDs: ["com.example.Chat"]
            ),
            "a true copied-only fallback should not send"
        )

        assertFalse(
            DictationAutoSendPolicy.shouldSend(
                isEnabled: true,
                pasteOutcome: .pasted,
                text: "   \n",
                duration: TranscriptedConstants.dictationAutoEnterMinimumDuration,
                sourceBundleID: "com.example.Chat",
                allowedBundleIDs: ["com.example.Chat"]
            ),
            "empty transcript should not send"
        )

        assertFalse(
            DictationAutoSendPolicy.shouldSend(
                isEnabled: true,
                pasteOutcome: .pasted,
                text: "Too fast",
                duration: TranscriptedConstants.dictationAutoEnterMinimumDuration - 0.01,
                sourceBundleID: "com.example.Chat",
                allowedBundleIDs: ["com.example.Chat"]
            ),
            "very short accidental taps should not send"
        )

        assertFalse(
            DictationAutoSendPolicy.shouldSend(
                isEnabled: true,
                pasteOutcome: .pasted,
                text: "Send this",
                duration: TranscriptedConstants.dictationAutoEnterMinimumDuration,
                sourceBundleID: "com.example.Notes",
                allowedBundleIDs: ["com.example.Chat"]
            ),
            "unselected apps should not send"
        )

        assertFalse(
            DictationAutoSendPolicy.shouldSend(
                isEnabled: true,
                pasteOutcome: .pasted,
                text: "Send this",
                duration: TranscriptedConstants.dictationAutoEnterMinimumDuration,
                sourceBundleID: nil,
                allowedBundleIDs: ["com.example.Chat"]
            ),
            "unknown source apps should not send"
        )
    }
}

private func makeAutoSendDefaults() -> (UserDefaults, String) {
    let suiteName = "DictationAutoSendPreferencesTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}
