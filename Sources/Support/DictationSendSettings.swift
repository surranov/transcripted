import Foundation

/// Fork: what a take does once its words land, the one choice behind
/// Settings → Send after dictation. Default applies in every app; an app may
/// override it (`DictationSendSettings`). Every behavior that sends presses
/// the one send key (`DictationAutoSendPreferences.sendKey`).
enum DictationSendBehavior: String, CaseIterable, Identifiable {
    case dontSend = "dont_send"
    case send
    case withDictateAndSendKey = "dictate_and_send_key"
    case afterConfirm = "confirm_after_paste"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dontSend: return "Don't send"
        case .send: return "Send"
        case .withDictateAndSendKey: return "With Dictate & send key"
        case .afterConfirm: return "After I confirm"
        }
    }

    var summary: String {
        switch self {
        case .dontSend:
            return "Paste only; send is never pressed."
        case .send:
            return "Every dictation presses send once its words land."
        case .withDictateAndSendKey:
            return "Only a dictation started with the Dictate & send key presses send."
        case .afterConfirm:
            return "The island asks; send goes when you press the confirm key or Send."
        }
    }

    /// When send is pressed, for a behavior that sends; nil for Don't send.
    var mode: DictationAutoSendMode? {
        switch self {
        case .dontSend: return nil
        case .send: return .always
        case .withDictateAndSendKey: return .dictateAndSendKey
        case .afterConfirm: return .confirmAfterPaste
        }
    }

    init(sendingWhen mode: DictationAutoSendMode) {
        switch mode {
        case .always: self = .send
        case .dictateAndSendKey: self = .withDictateAndSendKey
        case .confirmAfterPaste: self = .afterConfirm
        }
    }
}

/// Fork: Default and the per-app overrides. Before them, sending was two
/// toggles that could both apply (Press send after pasting with its app
/// list, and Press Enter there in the Dictation card) plus When to send; the
/// first read carries those over (`migrated(from:)`).
enum DictationSendSettings {
    static let defaultBehaviorKey = "dictationSendDefault"
    static let overridesKey = "dictationSendOverrides"

    /// The behavior for every app without an override. Nothing stored and
    /// nothing to carry over reads as Don't send, as before either toggle.
    static func defaultBehavior(userDefaults: UserDefaults = .standard) -> DictationSendBehavior {
        migrateIfNeeded(userDefaults: userDefaults)
        return userDefaults.string(forKey: defaultBehaviorKey).flatMap(DictationSendBehavior.init(rawValue:)) ?? .dontSend
    }

    static func setDefaultBehavior(_ behavior: DictationSendBehavior, userDefaults: UserDefaults = .standard) {
        migrateIfNeeded(userDefaults: userDefaults)
        userDefaults.set(behavior.rawValue, forKey: defaultBehaviorKey)
        // The event tap catches the Dictate & send key only while some
        // behavior uses it (`usesDictateAndSendKey`).
        NotificationCenter.default.post(name: .hotkeysDidChange, object: nil)
    }

    /// Apps with their own behavior, by bundle id. A value this build
    /// doesn't know is dropped, so that app follows Default.
    static func overrides(userDefaults: UserDefaults = .standard) -> [String: DictationSendBehavior] {
        migrateIfNeeded(userDefaults: userDefaults)
        let stored = userDefaults.dictionary(forKey: overridesKey) as? [String: String] ?? [:]
        return stored.compactMapValues(DictationSendBehavior.init(rawValue:))
    }

    /// Sets `bundleID`'s own behavior; nil puts it back on Default.
    static func setOverride(_ behavior: DictationSendBehavior?, for bundleID: String, userDefaults: UserDefaults = .standard) {
        let id = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        var stored = overrides(userDefaults: userDefaults).mapValues(\.rawValue)
        stored[id] = behavior?.rawValue
        userDefaults.set(stored, forKey: overridesKey)
        NotificationCenter.default.post(name: .hotkeysDidChange, object: nil)
    }

    /// The behavior a take started in `bundleID` gets, and whether it came
    /// from that app's override. An unknown app gets Default.
    static func behavior(
        for bundleID: String?,
        defaultBehavior: DictationSendBehavior,
        overrides: [String: DictationSendBehavior]
    ) -> (behavior: DictationSendBehavior, isOverride: Bool) {
        if let bundleID, let own = overrides[bundleID] { return (own, true) }
        return (defaultBehavior, false)
    }

    /// Whether Default or any app sends only with the Dictate & send key,
    /// so the event tap should catch that key.
    static func usesDictateAndSendKey(userDefaults: UserDefaults = .standard) -> Bool {
        uses(.withDictateAndSendKey, userDefaults: userDefaults)
    }

    /// Whether Default or any app waits for a confirm (the confirm key and
    /// wait rows show then).
    static func usesConfirm(userDefaults: UserDefaults = .standard) -> Bool {
        uses(.afterConfirm, userDefaults: userDefaults)
    }

    private static func uses(_ behavior: DictationSendBehavior, userDefaults: UserDefaults) -> Bool {
        defaultBehavior(userDefaults: userDefaults) == behavior
            || overrides(userDefaults: userDefaults).values.contains(behavior)
    }

    // MARK: - Decision

    /// Whether a take presses send, with which key, and how. Anchored paste
    /// on means send goes only into the box the take started in
    /// (`requiresAnchoredField`): a take with no anchored box doesn't send.
    /// When to send is the behavior's own (`DictationAutoSendPolicy.applyingMode`).
    static func decision(
        behavior: DictationSendBehavior,
        isOverride: Bool,
        key: DictationAutoSendKey,
        text: String,
        duration: TimeInterval,
        hasAnchor: Bool,
        anchoredPasteEnabled: Bool,
        startedWithDictateAndSendKey: Bool
    ) -> DictationAutoSendRequestDecision {
        let blockReason: DictationAutoSendBlockReason
        if behavior == .dontSend {
            blockReason = isOverride ? .appNotAllowed : .featureOff
        } else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blockReason = .emptyText
        } else if duration < TranscriptedConstants.dictationAutoEnterMinimumDuration {
            blockReason = .durationTooShort
        } else if anchoredPasteEnabled, !hasAnchor {
            blockReason = .noAnchoredBox
        } else {
            blockReason = .none
        }
        let decision = DictationAutoSendRequestDecision(
            expected: blockReason == .none,
            key: key,
            blockReason: blockReason,
            requiresAnchoredField: anchoredPasteEnabled
        )
        guard let mode = behavior.mode else { return decision }
        return DictationAutoSendPolicy.applyingMode(
            decision,
            mode: mode,
            startedWithDictateAndSendKey: startedWithDictateAndSendKey,
            anchoredPasteEnabled: anchoredPasteEnabled
        )
    }

    // MARK: - Carrying the old settings over

    /// The settings as stored before Default and the overrides.
    struct Legacy: Equatable {
        var pressSendAfterPasting: Bool
        var sendKey: DictationAutoSendKey
        var apps: Set<String>
        var anchoredPaste: Bool
        var pressEnterThere: Bool
        var mode: DictationAutoSendMode
    }

    struct Migrated: Equatable {
        var defaultBehavior: DictationSendBehavior
        var overrides: [String: DictationSendBehavior]
        var sendKey: DictationAutoSendKey
    }

    /// Press Enter there (it needed Anchored paste) becomes Default; the
    /// apps chosen for Press send after pasting become overrides where that
    /// differs from Default; When to send goes into both. One key now serves
    /// every app: the one chosen for Press send after pasting when that was
    /// on, else Enter (Press Enter there's key).
    static func migrated(from legacy: Legacy) -> Migrated {
        let sending = DictationSendBehavior(sendingWhen: legacy.mode)
        let defaultBehavior: DictationSendBehavior = legacy.anchoredPaste && legacy.pressEnterThere ? sending : .dontSend
        var overrides: [String: DictationSendBehavior] = [:]
        if legacy.pressSendAfterPasting, sending != defaultBehavior {
            for app in legacy.apps { overrides[app] = sending }
        }
        return Migrated(
            defaultBehavior: defaultBehavior,
            overrides: overrides,
            sendKey: legacy.pressSendAfterPasting ? legacy.sendKey : .enter
        )
    }

    /// Carries the old settings over once, the first time Default is read.
    /// The old keys stay where they were; nothing reads them after this.
    static func migrateIfNeeded(userDefaults: UserDefaults = .standard) {
        guard userDefaults.object(forKey: defaultBehaviorKey) == nil else { return }
        let migrated = migrated(from: Legacy(
            pressSendAfterPasting: DictationAutoSendPreferences.isEnabled(userDefaults: userDefaults),
            sendKey: DictationAutoSendPreferences.sendKey(userDefaults: userDefaults),
            apps: DictationAutoSendPreferences.allowedBundleIDs(userDefaults: userDefaults),
            anchoredPaste: AnchoredPastePreferences.isEnabled(userDefaults: userDefaults),
            pressEnterThere: userDefaults.bool(forKey: AnchoredPastePreferences.enterEnabledKey),
            mode: DictationAutoSendPreferences.mode(userDefaults: userDefaults)
        ))
        userDefaults.set(migrated.defaultBehavior.rawValue, forKey: defaultBehaviorKey)
        userDefaults.set(migrated.overrides.mapValues(\.rawValue), forKey: overridesKey)
        DictationAutoSendPreferences.setSendKey(migrated.sendKey, userDefaults: userDefaults)
    }
}
