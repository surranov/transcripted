import Foundation

// Send after dictation as one choice (DictationSendSettings): Default for
// every app, an app's own behavior over it, one send key, and the old
// toggles carried over so every take decides as before, except where the
// one select means to differ.

/// A take's decision with Anchored paste off, for the paste-outcome rules.
func sendDecision(
    _ behavior: DictationSendBehavior,
    isOverride: Bool = false,
    text: String = "ship it",
    duration: TimeInterval = 2
) -> DictationAutoSendRequestDecision {
    DictationSendSettings.decision(
        behavior: behavior, isOverride: isOverride, key: .enter, text: text, duration: duration,
        hasAnchor: false, anchoredPasteEnabled: false, startedWithDictateAndSendKey: false
    )
}

func testDictationSendSettings() {
    let slack = "com.tinyspeck.slackmacgap"
    let notes = "md.obsidian"

    func freshDefaults(_ name: String) -> UserDefaults {
        let suite = "DictationSendSettingsTests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    runSuite("DictationSendBehavior: each behavior that sends has its When to send") {
        assertNil(DictationSendBehavior.dontSend.mode, "Don't send never presses anything")
        for mode in DictationAutoSendMode.allCases {
            assertEqual(DictationSendBehavior(sendingWhen: mode).mode, mode, "\(mode) round-trips")
        }
        assertEqual(DictationSendBehavior.allCases.map(\.title), ["Don't send", "Send", "With Dictate & send key", "After I confirm"])
    }

    runSuite("DictationSendSettings: an app's own behavior wins over Default; any other app gets Default") {
        let overrides: [String: DictationSendBehavior] = [slack: .dontSend]
        let own = DictationSendSettings.behavior(for: slack, defaultBehavior: .send, overrides: overrides)
        assertEqual(own.behavior, .dontSend)
        assertTrue(own.isOverride)
        let other = DictationSendSettings.behavior(for: notes, defaultBehavior: .send, overrides: overrides)
        assertEqual(other.behavior, .send)
        assertFalse(other.isOverride)
        assertEqual(DictationSendSettings.behavior(for: nil, defaultBehavior: .afterConfirm, overrides: overrides).behavior, .afterConfirm, "an unknown app gets Default")
    }

    runSuite("DictationSendSettings: the decision follows the behavior, with one key") {
        func decide(
            _ behavior: DictationSendBehavior, isOverride: Bool = false, key: DictationAutoSendKey = .commandEnter,
            text: String = "ship it", duration: TimeInterval = 2, hasAnchor: Bool = true,
            anchoredPaste: Bool = true, startedWithKey: Bool = false
        ) -> DictationAutoSendRequestDecision {
            DictationSendSettings.decision(
                behavior: behavior, isOverride: isOverride, key: key, text: text, duration: duration,
                hasAnchor: hasAnchor, anchoredPasteEnabled: anchoredPaste, startedWithDictateAndSendKey: startedWithKey
            )
        }
        assertEqual(decide(.dontSend).blockReason, .featureOff, "Default off counts as the feature off")
        assertEqual(decide(.dontSend, isOverride: true).blockReason, .appNotAllowed, "an app turned off counts as that app")
        let send = decide(.send)
        assertTrue(send.expected)
        assertEqual(send.key, .commandEnter, "the one key")
        assertTrue(send.requiresAnchoredField, "with Anchored paste, only into the box it started in")
        assertEqual(decide(.send, hasAnchor: false).blockReason, .noAnchoredBox, "no box, no send")
        let plain = decide(.send, hasAnchor: false, anchoredPaste: false)
        assertTrue(plain.expected && !plain.requiresAnchoredField, "without Anchored paste, where the paste went")
        assertEqual(decide(.send, text: " ").blockReason, .emptyText)
        assertEqual(decide(.send, duration: 0.1).blockReason, .durationTooShort)
        assertEqual(decide(.withDictateAndSendKey).blockReason, .sendKeyNotUsed)
        assertTrue(decide(.withDictateAndSendKey, startedWithKey: true).expected)
        assertTrue(decide(.afterConfirm).awaitsConfirmation)
        assertEqual(decide(.afterConfirm, hasAnchor: false, anchoredPaste: false).blockReason, .confirmNeedsAnchoredPaste)
    }

    runSuite("DictationSendSettings: the old toggles carry over") {
        typealias Legacy = DictationSendSettings.Legacy
        let nothing = DictationSendSettings.migrated(from: Legacy(
            pressSendAfterPasting: false, sendKey: .commandEnter, apps: [slack], anchoredPaste: true, pressEnterThere: false, mode: .always
        ))
        assertEqual(nothing, .init(defaultBehavior: .dontSend, overrides: [:], sendKey: .enter), "both off: nothing sends")

        let listOnly = DictationSendSettings.migrated(from: Legacy(
            pressSendAfterPasting: true, sendKey: .commandEnter, apps: [slack, notes], anchoredPaste: false, pressEnterThere: true, mode: .confirmAfterPaste
        ))
        assertEqual(listOnly.defaultBehavior, .dontSend, "Press Enter there did nothing without Anchored paste")
        assertEqual(listOnly.overrides, [slack: .afterConfirm, notes: .afterConfirm], "the listed apps keep sending, When to send included")
        assertEqual(listOnly.sendKey, .commandEnter, "with the key chosen for them")

        let everywhere = DictationSendSettings.migrated(from: Legacy(
            pressSendAfterPasting: true, sendKey: .enter, apps: [slack], anchoredPaste: true, pressEnterThere: true, mode: .always
        ))
        assertEqual(everywhere, .init(defaultBehavior: .send, overrides: [:], sendKey: .enter), "a listed app sending like Default needs no override")

        let enterOnly = DictationSendSettings.migrated(from: Legacy(
            pressSendAfterPasting: false, sendKey: .commandEnter, apps: [], anchoredPaste: true, pressEnterThere: true, mode: .dictateAndSendKey
        ))
        assertEqual(enterOnly, .init(defaultBehavior: .withDictateAndSendKey, overrides: [:], sendKey: .enter), "Press Enter there's key was Enter")
    }

    runSuite("DictationSendSettings: every old combination decides as before, except where the one select differs on purpose") {
        var checked = 0
        for pressSend in [false, true] {
            for sendKey in [DictationAutoSendKey.enter, .commandEnter] {
                for apps in [Set<String>(), [slack]] {
                    for anchoredPaste in [false, true] {
                        for pressEnter in [false, true] {
                            for mode in DictationAutoSendMode.allCases {
                                let old = LegacySendSettings(
                                    pressSendAfterPasting: pressSend, sendKey: sendKey, apps: apps,
                                    anchoredPaste: anchoredPaste, pressEnterThere: pressEnter, mode: mode
                                )
                                let migrated = DictationSendSettings.migrated(from: .init(
                                    pressSendAfterPasting: pressSend, sendKey: sendKey, apps: apps,
                                    anchoredPaste: anchoredPaste, pressEnterThere: pressEnter, mode: mode
                                ))
                                for bundleID in [slack, notes, nil] as [String?] {
                                    // A take is anchored only with Anchored paste on.
                                    for hasAnchor in anchoredPaste ? [false, true] : [false] {
                                        for startedWithKey in [false, true] {
                                            let before = legacySendDecision(
                                                old, bundleID: bundleID, hasAnchor: hasAnchor,
                                                startedWithDictateAndSendKey: startedWithKey
                                            )
                                            let resolved = DictationSendSettings.behavior(
                                                for: bundleID, defaultBehavior: migrated.defaultBehavior, overrides: migrated.overrides
                                            )
                                            let after = DictationSendSettings.decision(
                                                behavior: resolved.behavior, isOverride: resolved.isOverride, key: migrated.sendKey,
                                                text: "ship it", duration: 2, hasAnchor: hasAnchor,
                                                anchoredPasteEnabled: anchoredPaste, startedWithDictateAndSendKey: startedWithKey
                                            )
                                            let label = "\(old) app=\(bundleID ?? "nil") anchor=\(hasAnchor) key=\(startedWithKey)"
                                            checked += 1
                                            // On purpose: with Anchored paste on, send goes only into
                                            // the take's own box, so an unanchored take no longer sends.
                                            if before.expected, anchoredPaste, !hasAnchor {
                                                assertEqual(after.blockReason, .noAnchoredBox, label)
                                                continue
                                            }
                                            assertEqual(after.expected, before.expected, "sends as before: \(label)")
                                            assertEqual(after.awaitsConfirmation, before.awaitsConfirmation, "asks as before: \(label)")
                                            guard before.expected else { continue }
                                            // On purpose: one key; Press Enter there pressed Enter
                                            // even when the listed apps had Command-Enter.
                                            if before.key != after.key {
                                                assertTrue(pressSend && sendKey == .commandEnter && before.requiresAnchoredField, "only Press Enter there's Enter changes key: \(label)")
                                            }
                                            // On purpose: with Anchored paste on, a listed app too
                                            // sends only into the take's own box.
                                            assertEqual(after.requiresAnchoredField, anchoredPaste, "into the box with Anchored paste: \(label)")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        // 2 toggles × 2 keys × 2 lists × 2 × 3 modes × 3 apps × 2 starts × (1 unanchored + 2 anchored states)
        assertEqual(checked, 864, "every combination was checked")
    }

    runSuite("DictationSendSettings stores Default and the overrides, carried over once") {
        let defaults = freshDefaults("store")
        defaults.set(true, forKey: AnchoredPastePreferences.enabledKey)
        defaults.set(true, forKey: DictationSendSettings.LegacyKeys.pressEnterThere)
        assertEqual(DictationSendSettings.defaultBehavior(userDefaults: defaults), .send, "Press Enter there carried over")
        DictationSendSettings.setDefaultBehavior(.afterConfirm, userDefaults: defaults)
        defaults.set(false, forKey: DictationSendSettings.LegacyKeys.pressEnterThere)
        assertEqual(DictationSendSettings.defaultBehavior(userDefaults: defaults), .afterConfirm, "carried over only once")

        DictationSendSettings.setOverride(.dontSend, for: slack, userDefaults: defaults)
        DictationSendSettings.setOverride(.withDictateAndSendKey, for: " \(notes) ", userDefaults: defaults)
        assertEqual(DictationSendSettings.overrides(userDefaults: defaults), [slack: .dontSend, notes: .withDictateAndSendKey])
        assertTrue(DictationSendSettings.usesDictateAndSendKey(userDefaults: defaults), "an app uses the Dictate & send key")
        assertTrue(DictationSendSettings.usesConfirm(userDefaults: defaults), "Default waits for a confirm")
        DictationSendSettings.setOverride(nil, for: notes, userDefaults: defaults)
        assertEqual(DictationSendSettings.overrides(userDefaults: defaults), [slack: .dontSend], "back on Default")
        assertFalse(DictationSendSettings.usesDictateAndSendKey(userDefaults: defaults))

        defaults.set([slack: "dont_send", notes: "from_a_newer_build"], forKey: DictationSendSettings.overridesKey)
        assertEqual(DictationSendSettings.overrides(userDefaults: defaults), [slack: .dontSend], "an unknown value follows Default")
        defaults.set("from_a_newer_build", forKey: DictationSendSettings.defaultBehaviorKey)
        assertEqual(DictationSendSettings.defaultBehavior(userDefaults: defaults), .dontSend, "and an unknown Default sends nothing")
    }

    runSuite("DictationSendSettings carries the old app list and key over") {
        let defaults = freshDefaults("carry")
        defaults.set(true, forKey: DictationSendSettings.LegacyKeys.pressSendAfterPasting)
        DictationAutoSendPreferences.setSendKey(.commandEnter, userDefaults: defaults)
        defaults.set([" \(slack) ", ""], forKey: DictationSendSettings.LegacyKeys.apps)
        defaults.set("telepathy", forKey: DictationSendSettings.LegacyKeys.mode)
        assertEqual(DictationSendSettings.overrides(userDefaults: defaults), [slack: .send], "the listed app sends, an unknown When to send read as Always")
        assertEqual(DictationSendSettings.defaultBehavior(userDefaults: defaults), .dontSend, "every other app doesn't")
        assertEqual(DictationAutoSendPreferences.sendKey(userDefaults: defaults), .commandEnter, "with its key")
    }
}
