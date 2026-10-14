import Foundation

// Pins how the send settings before "Send after dictation" was one select
// decide whether a take presses send, the way the session composes them
// (`DictationSessionController.autoSendDecision` with `withAnchoredEnter`):
// Press send after pasting with its app list and key, then Press Enter there
// (Anchored Enter) for an anchored take, then When to send. The settings
// moving into one select keep these decisions; see the migration tests.

/// The send settings as they were stored before the one select.
struct LegacySendSettings {
    var pressSendAfterPasting = false
    var sendKey: DictationAutoSendKey = .enter
    var apps: Set<String> = []
    var anchoredPaste = false
    var pressEnterThere = false
    var mode: DictationAutoSendMode = .always
}

/// The decision those settings made for one take, composed as the session
/// composed it.
func legacySendDecision(
    _ settings: LegacySendSettings,
    bundleID: String?,
    hasAnchor: Bool,
    startedWithDictateAndSendKey: Bool = false,
    text: String = "ship it",
    duration: TimeInterval = 2
) -> DictationAutoSendRequestDecision {
    var decision = DictationAutoSendPolicy.requestDecision(
        isEnabled: settings.pressSendAfterPasting,
        key: settings.sendKey,
        text: text,
        duration: duration,
        sourceBundleID: bundleID,
        allowedBundleIDs: settings.apps
    )
    if hasAnchor {
        decision = DictationAutoSendPolicy.anchoredEnterDecision(
            perApp: decision,
            pressesEnter: settings.anchoredPaste && settings.pressEnterThere,
            text: text,
            duration: duration
        )
    }
    return DictationAutoSendPolicy.applyingMode(
        decision,
        mode: settings.mode,
        startedWithDictateAndSendKey: startedWithDictateAndSendKey,
        anchoredPasteEnabled: settings.anchoredPaste
    )
}

func testDictationSendSettingsLegacy() {
    let slack = "com.tinyspeck.slackmacgap"
    let notes = "md.obsidian"

    runSuite("Old send settings: Press send after pasting sends only in its apps, with its key") {
        let settings = LegacySendSettings(pressSendAfterPasting: true, sendKey: .commandEnter, apps: [slack])
        let listed = legacySendDecision(settings, bundleID: slack, hasAnchor: false)
        assertTrue(listed.expected, "a listed app sends")
        assertEqual(listed.key, .commandEnter, "with the chosen key")
        assertFalse(listed.requiresAnchoredField, "wherever the paste went")
        assertEqual(legacySendDecision(settings, bundleID: notes, hasAnchor: false).blockReason, .appNotAllowed, "an app not listed doesn't")
        assertEqual(legacySendDecision(settings, bundleID: nil, hasAnchor: false).blockReason, .sourceAppUnknown, "nor an unknown app")
        assertEqual(
            legacySendDecision(LegacySendSettings(apps: [slack]), bundleID: slack, hasAnchor: false).blockReason,
            .featureOff,
            "the list does nothing with the toggle off"
        )
        let anchoredListed = legacySendDecision(
            LegacySendSettings(pressSendAfterPasting: true, sendKey: .commandEnter, apps: [slack], anchoredPaste: true),
            bundleID: slack, hasAnchor: true
        )
        assertTrue(anchoredListed.expected && !anchoredListed.requiresAnchoredField, "anchored or not, a listed app sends where the paste went")
    }

    runSuite("Old send settings: Press Enter there sends Enter in any app, only into the anchored box") {
        let settings = LegacySendSettings(anchoredPaste: true, pressEnterThere: true)
        for bundleID in [slack, notes, nil] as [String?] {
            let decision = legacySendDecision(settings, bundleID: bundleID, hasAnchor: true)
            assertTrue(decision.expected, "every anchored take sends")
            assertEqual(decision.key, .enter, "with Enter")
            assertTrue(decision.requiresAnchoredField, "only into the box it started in")
        }
        assertEqual(legacySendDecision(settings, bundleID: slack, hasAnchor: false).blockReason, .featureOff, "a take with no anchor doesn't")
        let off = legacySendDecision(LegacySendSettings(anchoredPaste: false, pressEnterThere: true), bundleID: slack, hasAnchor: true)
        assertFalse(off.expected, "nor without Anchored paste")
    }

    runSuite("Old send settings: a listed app keeps its key when Press Enter there is on too") {
        let settings = LegacySendSettings(
            pressSendAfterPasting: true, sendKey: .commandEnter, apps: [slack], anchoredPaste: true, pressEnterThere: true
        )
        let listed = legacySendDecision(settings, bundleID: slack, hasAnchor: true)
        assertEqual(listed.key, .commandEnter, "the listed app's own key")
        assertFalse(listed.requiresAnchoredField, "and its own rule")
        let other = legacySendDecision(settings, bundleID: notes, hasAnchor: true)
        assertEqual(other.key, .enter, "every other app gets Enter")
        assertTrue(other.requiresAnchoredField)
    }

    runSuite("Old send settings: an empty or too short take never sends") {
        let settings = LegacySendSettings(pressSendAfterPasting: true, apps: [slack], anchoredPaste: true, pressEnterThere: true)
        assertEqual(legacySendDecision(settings, bundleID: slack, hasAnchor: true, text: "  ").blockReason, .emptyText)
        assertEqual(legacySendDecision(settings, bundleID: notes, hasAnchor: true, text: "").blockReason, .emptyText)
        assertEqual(legacySendDecision(settings, bundleID: notes, hasAnchor: true, duration: 0.1).blockReason, .durationTooShort)
    }

    runSuite("Old send settings: When to send decides last, for both") {
        var settings = LegacySendSettings(pressSendAfterPasting: true, apps: [slack], anchoredPaste: true, pressEnterThere: true)
        settings.mode = .dictateAndSendKey
        assertEqual(legacySendDecision(settings, bundleID: slack, hasAnchor: true).blockReason, .sendKeyNotUsed)
        assertEqual(legacySendDecision(settings, bundleID: notes, hasAnchor: true).blockReason, .sendKeyNotUsed)
        assertTrue(legacySendDecision(settings, bundleID: notes, hasAnchor: true, startedWithDictateAndSendKey: true).expected)
        settings.mode = .confirmAfterPaste
        assertTrue(legacySendDecision(settings, bundleID: slack, hasAnchor: true).awaitsConfirmation)
        assertTrue(legacySendDecision(settings, bundleID: notes, hasAnchor: true).awaitsConfirmation)
        settings.anchoredPaste = false
        assertEqual(
            legacySendDecision(settings, bundleID: slack, hasAnchor: false).blockReason,
            .confirmNeedsAnchoredPaste,
            "confirming needs Anchored paste"
        )
    }
}
