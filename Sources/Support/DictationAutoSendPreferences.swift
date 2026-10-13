import ApplicationServices
import Carbon
import Foundation

enum DictationAutoSendKey: String, CaseIterable, Identifiable {
    case enter
    case commandEnter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .enter:
            return "Enter"
        case .commandEnter:
            return "Cmd + Enter"
        }
    }

    var diagnosticName: String {
        switch self {
        case .enter:
            return "enter"
        case .commandEnter:
            return "command_enter"
        }
    }

    var eventFlags: CGEventFlags {
        switch self {
        case .enter:
            return []
        case .commandEnter:
            return .maskCommand
        }
    }
}

enum DictationAutoSendBlockReason: String, Equatable {
    case none
    case notEvaluated = "not_evaluated"
    case featureOff = "feature_off"
    case emptyText = "empty_text"
    case durationTooShort = "duration_too_short"
    case sourceAppUnknown = "source_app_unknown"
    case appNotAllowed = "app_not_allowed"
    case accessibilityMissing = "accessibility_missing"
    case eventCreationFailed = "event_creation_failed"
    case targetChanged = "target_changed"
    case pasteNotConfirmed = "paste_not_confirmed"
    /// The paste most likely landed (`.likelyPasted`), but only an unattributed
    /// clipboard read backs that up, which is not enough to press Return.
    case pasteUnverified = "paste_unverified"
    case pasteFailed = "paste_failed"
    case cancelled
}

struct DictationAutoSendRequestDecision: Equatable {
    let expected: Bool
    let key: DictationAutoSendKey
    let blockReason: DictationAutoSendBlockReason
    /// Fork (Anchored Enter): the take expects Enter only because it is
    /// anchored, so Enter goes only into the anchored field, never into
    /// wherever the regular paste followed the user.
    var requiresAnchoredField = false

    static let notEvaluated = DictationAutoSendRequestDecision(
        expected: false,
        key: .enter,
        blockReason: .notEvaluated
    )

    /// Auto Enter presses Return only after a confirmed paste, so a take that
    /// expects it keeps the full confirmation wait. Any other take may end the
    /// wait on a likely paste (`ClipboardRestoringTextPaster.paste`).
    var pasteMayEndWaitOnLikelyPaste: Bool {
        !expected
    }
}

enum DictationAutoSendPreferences {
    private static let enabledKey = "dictationAutoEnterEnabled"
    private static let keyKey = "dictationAutoEnterKey"
    private static let allowedBundleIDsKey = "dictationAutoEnterAllowedBundleIDs"

    static func isEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: enabledKey)
    }

    static func setEnabled(_ enabled: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(enabled, forKey: enabledKey)
    }

    static func sendKey(userDefaults: UserDefaults = .standard) -> DictationAutoSendKey {
        guard let rawValue = userDefaults.string(forKey: keyKey),
              let key = DictationAutoSendKey(rawValue: rawValue) else {
            return .enter
        }

        return key
    }

    static func setSendKey(_ key: DictationAutoSendKey, userDefaults: UserDefaults = .standard) {
        userDefaults.set(key.rawValue, forKey: keyKey)
    }

    static func allowedBundleIDs(userDefaults: UserDefaults = .standard) -> Set<String> {
        let rawValues = userDefaults.stringArray(forKey: allowedBundleIDsKey) ?? []
        return Set(rawValues.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
    }

    static func setAllowedBundleIDs(_ bundleIDs: Set<String>, userDefaults: UserDefaults = .standard) {
        let normalized = bundleIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
        userDefaults.set(normalized, forKey: allowedBundleIDsKey)
    }
}

enum DictationAutoSendPolicy {
    static func requestDecision(
        isEnabled: Bool,
        key: DictationAutoSendKey,
        text: String,
        duration: TimeInterval,
        sourceBundleID: String?,
        allowedBundleIDs: Set<String>
    ) -> DictationAutoSendRequestDecision {
        let blockReason: DictationAutoSendBlockReason
        if !isEnabled {
            blockReason = .featureOff
        } else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blockReason = .emptyText
        } else if duration < TranscriptedConstants.dictationAutoEnterMinimumDuration {
            blockReason = .durationTooShort
        } else if sourceBundleID == nil {
            blockReason = .sourceAppUnknown
        } else if let sourceBundleID, !allowedBundleIDs.contains(sourceBundleID) {
            blockReason = .appNotAllowed
        } else {
            blockReason = .none
        }

        return DictationAutoSendRequestDecision(
            expected: blockReason == .none,
            key: key,
            blockReason: blockReason
        )
    }

    /// Fork (Anchored Enter, `AnchoredPastePreferences.pressesEnter`): an
    /// anchored take expects Enter in any app. An app chosen for Press send
    /// after pasting keeps its own decision and key.
    static func anchoredEnterDecision(
        perApp: DictationAutoSendRequestDecision,
        pressesEnter: Bool,
        text: String,
        duration: TimeInterval
    ) -> DictationAutoSendRequestDecision {
        guard pressesEnter, !perApp.expected else { return perApp }
        let blockReason: DictationAutoSendBlockReason
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blockReason = .emptyText
        } else if duration < TranscriptedConstants.dictationAutoEnterMinimumDuration {
            blockReason = .durationTooShort
        } else {
            blockReason = .none
        }
        return DictationAutoSendRequestDecision(
            expected: blockReason == .none,
            key: .enter,
            blockReason: blockReason,
            requiresAnchoredField: true
        )
    }

    static func isRequested(
        isEnabled: Bool,
        text: String,
        duration: TimeInterval,
        sourceBundleID: String?,
        allowedBundleIDs: Set<String>
    ) -> Bool {
        requestDecision(
            isEnabled: isEnabled,
            key: .enter,
            text: text,
            duration: duration,
            sourceBundleID: sourceBundleID,
            allowedBundleIDs: allowedBundleIDs
        ).expected
    }

    static func shouldSend(
        isEnabled: Bool,
        pasteOutcome: TextPasteOutcome,
        text: String,
        duration: TimeInterval,
        sourceBundleID: String?,
        allowedBundleIDs: Set<String>
    ) -> Bool {
        guard pasteOutcome.allowsAutoSend else { return false }
        return isRequested(
            isEnabled: isEnabled,
            text: text,
            duration: duration,
            sourceBundleID: sourceBundleID,
            allowedBundleIDs: allowedBundleIDs
        )
    }
}

extension TextPasteOutcome {
    var allowsAutoSend: Bool {
        switch self {
        case .pasted:
            return true
        case .likelyPasted, .copied, .failed:
            return false
        }
    }

    var requiresClipboardReadinessBeforeAutoSend: Bool {
        switch self {
        case .pasted:
            return true
        case .likelyPasted, .copied, .failed:
            return false
        }
    }

    var autoSendBlockReason: DictationAutoSendBlockReason? {
        switch self {
        case .pasted:
            return nil
        case .likelyPasted:
            return .pasteUnverified
        case .copied(_, reason: .accessibilityMissing):
            return .accessibilityMissing
        case .copied(_, reason: .pasteEventCreationFailed):
            return .eventCreationFailed
        case .copied(_, reason: .focusChanged):
            return .targetChanged
        case .copied(_, reason: .pasteNotConfirmed):
            return .pasteNotConfirmed
        case .failed:
            return .pasteFailed
        }
    }
}

enum DictationAutoSendFailure: Equatable {
    case accessibilityMissing
    case targetChanged
    case eventCreationFailed
    /// Fork (Anchored paste): the words went into a window in the background,
    /// and neither its send button nor Enter could be pressed there: the
    /// window is minimized, its app wouldn't focus the field, or the field
    /// didn't take the key.
    case backgroundSendUnavailable(appName: String)
    /// Fork (Anchored Enter): after the regular paste the field the take
    /// started in no longer has focus, so Enter would land elsewhere.
    case anchoredFieldLeft

    /// Shown after the text did paste. Settings calls this feature "Press
    /// send after pasting", and the key may be Return or ⌘Return, so the copy
    /// says "send" rather than "Auto Enter" or "Return".
    var message: String {
        switch self {
        case .accessibilityMissing:
            return "Pasted, but didn't press send because Accessibility is off."
        case .targetChanged:
            return "Pasted, but didn't press send because you switched apps."
        case .eventCreationFailed:
            return "Pasted, but couldn't press send. Press it yourself."
        case .backgroundSendUnavailable(let appName):
            return "Pasted in \(appName), but couldn't press Enter there. Press it yourself."
        case .anchoredFieldLeft:
            return "Pasted, but didn't press Enter: you've left the box you started in."
        }
    }

    var blockReason: DictationAutoSendBlockReason {
        switch self {
        case .accessibilityMissing:
            return .accessibilityMissing
        case .targetChanged, .anchoredFieldLeft:
            return .targetChanged
        case .eventCreationFailed, .backgroundSendUnavailable:
            return .eventCreationFailed
        }
    }
}

enum DictationAutoSendOutcome: Equatable {
    case disabled
    case sent(DictationAutoSendKey)
    case failed(DictationAutoSendFailure)

    var diagnosticName: String {
        switch self {
        case .disabled:
            return "disabled"
        case .sent(let key):
            return "sent_\(key.diagnosticName)"
        case .failed:
            return "failed"
        }
    }

    var confirmationTitle: String? {
        switch self {
        case .sent(let key):
            return "Pasted + \(key.title)"
        case .disabled, .failed:
            return nil
        }
    }
}

struct DictationAutoSendTelemetry: Equatable {
    let expected: Bool
    let key: DictationAutoSendKey
    let blockReason: DictationAutoSendBlockReason

    static func snapshot(
        request: DictationAutoSendRequestDecision,
        pasteOutcome: TextPasteOutcome,
        sendOutcome: DictationAutoSendOutcome
    ) -> DictationAutoSendTelemetry {
        let blockReason: DictationAutoSendBlockReason
        if !request.expected {
            blockReason = request.blockReason
        } else if case .sent = sendOutcome {
            // Anchored Enter may press Enter after a likely paste, once the
            // anchored field shows the words.
            blockReason = .none
        } else if let pasteBlockReason = pasteOutcome.autoSendBlockReason {
            blockReason = pasteBlockReason
        } else {
            switch sendOutcome {
            case .disabled:
                blockReason = .cancelled
            case .sent:
                blockReason = .none
            case .failed(let failure):
                blockReason = failure.blockReason
            }
        }

        return DictationAutoSendTelemetry(
            expected: request.expected,
            key: request.key,
            blockReason: blockReason
        )
    }

    var analyticsProperties: [String: String] {
        [
            "auto_send_expected": "\(expected)",
            "auto_send_key": key.diagnosticName,
            "auto_send_block_reason": blockReason.rawValue,
        ]
    }
}

@MainActor
final class DictationAutoSender {
    func send(_ key: DictationAutoSendKey, target: DictationPasteTarget? = nil) -> DictationAutoSendOutcome {
        guard AXIsProcessTrusted() else {
            return .failed(.accessibilityMissing)
        }

        guard target?.matchesCurrentFrontmostApp() != false else {
            return .failed(.targetChanged)
        }

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Return), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Return), keyDown: false) else {
            return .failed(.eventCreationFailed)
        }

        keyDown.flags = key.eventFlags
        keyDown.post(tap: .cghidEventTap)

        keyUp.flags = key.eventFlags
        keyUp.post(tap: .cghidEventTap)

        return .sent(key)
    }
}
