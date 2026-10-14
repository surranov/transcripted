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

/// When a take whose behavior sends (`DictationSendBehavior`) presses it:
/// the When to send part of that behavior.
enum DictationAutoSendMode: String, CaseIterable, Identifiable {
    /// Every such take presses send, as before this setting existed.
    case always
    /// Only a take started with the Dictate & send key.
    case dictateAndSendKey = "dictate_and_send_key"
    /// The take waits after pasting, and presses send once the user confirms
    /// with the confirm key from anywhere or the island's Send button.
    case confirmAfterPaste = "confirm_after_paste"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .always: return "Always"
        case .dictateAndSendKey: return "With Dictate & send key"
        case .confirmAfterPaste: return "After I confirm"
        }
    }

    /// One line under the setting's title.
    var summary: String {
        switch self {
        case .always: return "Every dictation that can send, sends."
        case .dictateAndSendKey: return "Only dictations started with the Dictate & send key."
        case .confirmAfterPaste: return "Pastes, then waits for your confirm key or Send."
        }
    }
}

/// The key that confirms a waiting send (`DictationAutoSendMode.confirmAfterPaste`):
/// Return, or keypad Enter, with exactly these modifiers. While a send waits,
/// the event tap takes that one press from whatever app is in front.
enum DictationSendConfirmKey: String, CaseIterable, Identifiable {
    case enter
    case shiftEnter = "shift_enter"
    case controlEnter = "control_enter"
    case optionEnter = "option_enter"
    case commandEnter = "command_enter"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .enter: return "Enter"
        case .shiftEnter: return "⇧ Enter"
        case .controlEnter: return "⌃ Enter"
        case .optionEnter: return "⌥ Enter"
        case .commandEnter: return "⌘ Enter"
        }
    }

    var modifiers: UInt32 {
        switch self {
        case .enter: return 0
        case .shiftEnter: return PhysicalDictationTriggerModifiers.shift
        case .controlEnter: return PhysicalDictationTriggerModifiers.control
        case .optionEnter: return PhysicalDictationTriggerModifiers.option
        case .commandEnter: return PhysicalDictationTriggerModifiers.command
        }
    }

    var eventFlags: CGEventFlags {
        switch self {
        case .enter: return []
        case .shiftEnter: return .maskShift
        case .controlEnter: return .maskControl
        case .optionEnter: return .maskAlternate
        case .commandEnter: return .maskCommand
        }
    }

    /// Whether a key-down is this key. Caps Lock is latched, not held, and
    /// macOS sets Fn on keypad Enter by itself, so neither counts.
    func matches(keyCode: UInt32, modifiers eventModifiers: UInt32) -> Bool {
        guard keyCode == UInt32(kVK_Return) || keyCode == UInt32(kVK_ANSI_KeypadEnter) else { return false }
        let ignored = PhysicalDictationTriggerModifiers.capsLock | PhysicalDictationTriggerModifiers.function
        return eventModifiers & ~ignored == modifiers
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
    /// Send waits for the Dictate & send key (`DictationAutoSendMode`), and
    /// this take started with the plain dictation key or from the app.
    case sendKeyNotUsed = "send_key_not_used"
    /// Send waits for a confirm (`DictationAutoSendMode.confirmAfterPaste`),
    /// which needs Anchored paste to know where to press it, and that's off.
    case confirmNeedsAnchoredPaste = "confirm_needs_anchored_paste"
    /// Anchored paste is on, so send goes only into the box the take started
    /// in, and this take has none (its field couldn't be read at the start).
    case noAnchoredBox = "no_anchored_box"
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
    /// Fork: Anchored paste is on, so send goes only into the box the take
    /// started in, never into wherever the regular paste followed the user
    /// (`DictationSendSettings.decision`).
    var requiresAnchoredField = false
    /// Fork (`DictationAutoSendMode.confirmAfterPaste`): send waits for the
    /// user's confirm after the words land instead of being pressed at once.
    var awaitsConfirmation = false

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
    private static let keyKey = "dictationAutoEnterKey"
    private static let confirmKeyKey = "dictationAutoEnterConfirmKey"
    private static let confirmSecondsKey = "dictationAutoEnterConfirmSeconds"

    /// How long a pasted take waits for its send to be confirmed, offered in
    /// Settings; the default is 5 s.
    static let confirmSecondsChoices = [3, 5, 10, 15, 30]
    static let defaultConfirmSeconds = 5

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

    static func confirmKey(userDefaults: UserDefaults = .standard) -> DictationSendConfirmKey {
        userDefaults.string(forKey: confirmKeyKey).flatMap(DictationSendConfirmKey.init(rawValue:)) ?? .enter
    }

    static func setConfirmKey(_ key: DictationSendConfirmKey, userDefaults: UserDefaults = .standard) {
        userDefaults.set(key.rawValue, forKey: confirmKeyKey)
    }

    /// A stored value outside `confirmSecondsChoices` (hand-edited) reads as
    /// the default, so a send can't wait forever or not at all.
    static func confirmSeconds(userDefaults: UserDefaults = .standard) -> Int {
        guard let seconds = userDefaults.object(forKey: confirmSecondsKey) as? Int,
              confirmSecondsChoices.contains(seconds) else { return defaultConfirmSeconds }
        return seconds
    }

    static func setConfirmSeconds(_ seconds: Int, userDefaults: UserDefaults = .standard) {
        guard confirmSecondsChoices.contains(seconds) else { return }
        userDefaults.set(seconds, forKey: confirmSecondsKey)
    }
}

enum DictationAutoSendPolicy {
    static func applyingMode(
        _ decision: DictationAutoSendRequestDecision,
        mode: DictationAutoSendMode,
        startedWithDictateAndSendKey: Bool,
        anchoredPasteEnabled: Bool
    ) -> DictationAutoSendRequestDecision {
        guard decision.expected else { return decision }
        func blocked(_ reason: DictationAutoSendBlockReason) -> DictationAutoSendRequestDecision {
            DictationAutoSendRequestDecision(
                expected: false,
                key: decision.key,
                blockReason: reason,
                requiresAnchoredField: decision.requiresAnchoredField
            )
        }
        switch mode {
        case .always:
            return decision
        case .dictateAndSendKey:
            return startedWithDictateAndSendKey ? decision : blocked(.sendKeyNotUsed)
        case .confirmAfterPaste:
            // Without Anchored paste nothing knows which box the take went
            // into once the user moves on, so send is never pressed.
            guard anchoredPasteEnabled else { return blocked(.confirmNeedsAnchoredPaste) }
            var waiting = decision
            waiting.awaitsConfirmation = true
            return waiting
        }
    }

    /// Where a confirmed send goes (`DictationAutoSendMode.confirmAfterPaste`),
    /// read when the user confirms, not when the words landed. Only a take
    /// with an anchor is ever asked: without one, nothing says which box the
    /// words went into once the user clicks elsewhere.
    static func confirmedSend(
        anchorAppIsFrontmost: Bool,
        anchorIsFocused: Bool,
        isTerminal: Bool,
        terminalWindowIsCurrent: Bool,
        appName: String
    ) -> DictationConfirmedSend {
        if anchorAppIsFrontmost {
            // In that box, Return goes there. In another box of the same app
            // it would land in the wrong one, and refocusing would take the
            // user's caret.
            return anchorIsFocused ? .frontmost : .unavailable(.anchoredFieldLeft)
        }
        if isTerminal {
            // Keystrokes go to the terminal's current window: another tab or
            // window there would run Return in the wrong shell.
            return terminalWindowIsCurrent
                ? .background(.terminalKeystrokes)
                : .unavailable(.backgroundSendUnavailable(appName: appName))
        }
        return .background(.accessibilityInsert)
    }

    /// The island's line while a send waits, naming the key and the app.
    /// With more sends waiting after it (the dictation queue), it also
    /// quotes the take's first words, since two can go to the same app.
    static func confirmationPrompt(
        confirmKey: DictationSendConfirmKey,
        appName: String,
        text: String = "",
        waitingAfter: Int = 0
    ) -> String {
        guard waitingAfter > 0 else {
            return "Pasted. Press \(confirmKey.title) to send it in \(appName)."
        }
        return "Pasted “\(confirmationQuote(text))” in \(appName). Press \(confirmKey.title) to send it (\(waitingAfter) more waiting)."
    }

    static let confirmationQuoteLength = 28

    /// The take's first words, cut at a word with "…" when longer.
    static func confirmationQuote(_ text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        var quote = ""
        for word in words {
            let next = quote.isEmpty ? String(word) : quote + " " + word
            guard next.count <= confirmationQuoteLength else {
                return (quote.isEmpty ? String(next.prefix(confirmationQuoteLength)) : quote) + "…"
            }
            quote = next
        }
        return quote
    }

    /// Send goes only after a confirmed paste of a take whose decision
    /// expects it (`DictationSendSettings.decision`).
    static func shouldSend(decision: DictationAutoSendRequestDecision, pasteOutcome: TextPasteOutcome) -> Bool {
        pasteOutcome.allowsAutoSend && decision.expected
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
        case .copied(_, reason: .focusChanged), .copied(_, reason: .chatChanged):
            return .targetChanged
        case .copied(_, reason: .pasteNotConfirmed):
            return .pasteNotConfirmed
        case .failed:
            return .pasteFailed
        }
    }
}

/// Where a confirmed send is pressed (`DictationAutoSendPolicy.confirmedSend`).
enum DictationConfirmedSend: Equatable {
    /// Return to the app in front, as Press send after pasting does.
    case frontmost
    /// Send pressed in the anchored box in the background
    /// (`AnchoredTextDelivery.pressSend`).
    case background(AnchoredPasteRoute)
    /// Nowhere safe; the island says why.
    case unavailable(DictationAutoSendFailure)
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
    /// Fork (Anchored paste): after the regular paste the field the take
    /// started in no longer has focus, so send would land elsewhere.
    case anchoredFieldLeft
    /// Fork (After I confirm): a send confirmed while the box is in the
    /// background, and the box no longer holds the take's words.
    case boxChanged(appName: String)
    /// Fork (chat thread guard, `ChatThreadPolicy`): the AI chat the take was
    /// dictated into now shows another thread, so send would go there.
    case chatChanged

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
        case .boxChanged(let appName):
            return "Didn't press send: the box in \(appName) no longer holds your words."
        case .chatChanged:
            return "Pasted, but didn't press send: you switched to another chat."
        }
    }

    var blockReason: DictationAutoSendBlockReason {
        switch self {
        case .accessibilityMissing:
            return .accessibilityMissing
        case .targetChanged, .anchoredFieldLeft, .boxChanged, .chatChanged:
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
    /// The words landed and send waits for the user's confirm
    /// (`DictationAutoSendMode.confirmAfterPaste`).
    case awaitingConfirmation

    var diagnosticName: String {
        switch self {
        case .disabled:
            return "disabled"
        case .awaitingConfirmation:
            return "awaiting_confirmation"
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
        case .disabled, .failed, .awaitingConfirmation:
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
            // A send into the anchored box may follow a likely paste, once
            // that box shows the words.
            blockReason = .none
        } else if let pasteBlockReason = pasteOutcome.autoSendBlockReason {
            blockReason = pasteBlockReason
        } else {
            switch sendOutcome {
            case .disabled:
                blockReason = .cancelled
            case .sent, .awaitingConfirmation:
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
