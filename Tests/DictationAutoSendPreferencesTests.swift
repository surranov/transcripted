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

    runSuite("Anchored Enter's notices say Enter wasn't pressed and where") {
        let background = DictationAutoSendFailure.backgroundSendUnavailable(appName: "T3 Code").message
        assertTrue(background.hasPrefix("Pasted in T3 Code"), "names the app the words went into")
        assertTrue(background.contains("Enter"), "says which key wasn't pressed")
        let left = DictationAutoSendFailure.anchoredFieldLeft.message
        assertTrue(left.hasPrefix("Pasted, but"), "the text did paste, so lead with that")
        assertTrue(left.contains("Enter"), "says which key wasn't pressed")
        assertEqual(DictationAutoSendFailure.anchoredFieldLeft.blockReason, .targetChanged, "counted as a target change")
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
