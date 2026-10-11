import AppKit
import ApplicationServices

/// Fork: the text field a dictation is anchored to (Anchored paste,
/// `AnchoredPastePolicy`), captured when the dictation starts.
struct DictationPasteAnchor {
    let pid: pid_t
    let bundleID: String?
    let appName: String
    /// The focused text field, when the app exposes one.
    let field: AXUIElement?
    let window: AXUIElement?
    let windowID: CGWindowID?
    let context: AnchoredPasteContext
    let selection: NSRange?
    let textBefore: String
    let textAfter: String
    /// Screen rectangles in Accessibility coordinates (top-left origin):
    /// the caret (or the field when the caret has no bounds) and its window.
    let caretRect: CGRect?
    let windowFrame: CGRect?
    let isTerminal: Bool
    let capturedAt: Date
}

/// Fork: the Accessibility and keyboard side of Anchored paste. Every AX call
/// is bounded (`messagingTimeout`), so a hung target app costs at most a
/// fraction of a second and then falls back.
@MainActor
enum AnchoredTextDelivery {
    private static let messagingTimeout: Float = 0.5

    // MARK: - Capture

    /// The anchor for the field focused in `app` right now. Electron apps
    /// build their web accessibility tree only when asked
    /// (`AXManualAccessibility`), so a first miss asks and looks once more.
    static func captureAnchor(for app: NSRunningApplication) async -> DictationPasteAnchor? {
        let pid = app.processIdentifier
        guard AXIsProcessTrusted(), pid > 0, pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
        let isTerminal = app.bundleIdentifier.map(AnchoredPastePolicy.terminalBundleIDs.contains) ?? false
        var field = focusedTextField(in: appElement)
        if field == nil, !isTerminal {
            AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            try? await Task.sleep(nanoseconds: 120_000_000)
            field = focusedTextField(in: appElement)
        }
        let window = field.flatMap { element(of: $0, kAXWindowAttribute) } ?? element(of: appElement, kAXFocusedWindowAttribute)
        let windowID = window.flatMap(windowID(of:))
        let value = field.flatMap(stringValue(of:))
        let selection = field.flatMap(selectedRange(of:))
        var textBefore = ""
        var textAfter = ""
        if let value, let selection {
            let nsValue = value as NSString
            if NSMaxRange(selection) <= nsValue.length {
                let length = AnchoredPastePolicy.contextSnippetLength
                let beforeStart = max(0, selection.location - length)
                textBefore = nsValue.substring(with: NSRange(location: beforeStart, length: selection.location - beforeStart))
                let afterLength = min(length, nsValue.length - NSMaxRange(selection))
                textAfter = nsValue.substring(with: NSRange(location: NSMaxRange(selection), length: afterLength))
            }
        }
        return DictationPasteAnchor(
            pid: pid,
            bundleID: app.bundleIdentifier,
            appName: app.localizedName ?? "the app",
            field: field,
            window: window,
            windowID: windowID,
            context: context(field: field, window: window, isTerminal: isTerminal),
            selection: selection,
            textBefore: textBefore,
            textAfter: textAfter,
            caretRect: field.flatMap {
                caretRect(of: $0, selection: selection, characterBefore: textBefore.last, textIsKnown: value != nil)
            },
            windowFrame: windowID.flatMap { windowState($0)?.frame },
            isTerminal: isTerminal,
            capturedAt: Date()
        )
    }

    // MARK: - Decide

    static func route(for anchor: DictationPasteAnchor, text: String) -> AnchoredPasteRoute {
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == anchor.pid
        let appElement = AXUIElementCreateApplication(anchor.pid)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
        let focused = element(of: appElement, kAXFocusedUIElementAttribute)
        let focusIsAnchor = anchor.field.map { field in focused.map { CFEqual(field, $0) } ?? false } ?? false
        let fieldAlive = anchor.field.map { element in
            AXUIElementSetMessagingTimeout(element, messagingTimeout)
            return (string(of: element, kAXRoleAttribute)) != nil
        } ?? false
        let focusedWindow = element(of: appElement, kAXFocusedWindowAttribute)
        let terminalWindowIsCurrent = anchor.window.map { window in focusedWindow.map { CFEqual(window, $0) } ?? false } ?? false
        return AnchoredPastePolicy.route(
            anchorAppIsFrontmost: frontmost,
            focusIsAnchorField: focusIsAnchor,
            hasField: anchor.field != nil,
            fieldAlive: fieldAlive,
            contextMatches: anchor.context.stillMatches(currentContext(of: anchor)),
            isTerminal: anchor.isTerminal,
            terminalWindowIsCurrent: terminalWindowIsCurrent,
            textHasLineBreaks: AnchoredPastePolicy.hasLineBreaks(text)
        )
    }

    /// Whether the user is back where a deferred paste goes: the anchored app
    /// is in front, showing the same document.
    static func userIsBack(at anchor: DictationPasteAnchor) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == anchor.pid else { return false }
        return anchor.context.stillMatches(currentContext(of: anchor))
    }

    static func currentContext(of anchor: DictationPasteAnchor) -> AnchoredPasteContext {
        context(field: anchor.field, window: anchor.window, isTerminal: anchor.isTerminal)
    }

    // MARK: - Deliver

    /// Inserts `text` at the anchored caret through Accessibility and checks
    /// it landed. Native text views take `AXSelectedText` (formatting kept);
    /// Chromium/Electron inputs take a rewritten `AXValue`. See
    /// `AnchoredInsertion` for a write that can't be read back yet.
    static func insertViaAccessibility(_ text: String, anchor: DictationPasteAnchor) async -> AnchoredInsertion {
        guard let field = anchor.field else { return .notTaken }
        AXUIElementSetMessagingTimeout(field, 1)
        let before = stringValue(of: field) ?? ""
        // Put the caret back where the dictation started (the user may have
        // clicked elsewhere in the field since); without that spot, only an
        // empty field is safe to fill.
        guard let range = AnchoredPastePolicy.insertionRange(
            current: before, capturedSelection: anchor.selection,
            textBefore: anchor.textBefore, textAfter: anchor.textAfter
        ) else { return .notTaken }
        setSelectedRange(range, of: field)
        if AXUIElementSetAttributeValue(field, kAXSelectedTextAttribute as CFString, text as CFString) == .success {
            // Give the app a moment to apply it before reading back.
            try? await Task.sleep(nanoseconds: 120_000_000)
            let after = stringValue(of: field) ?? ""
            if AnchoredPastePolicy.insertionApplied(before: before, after: after, text: text) { return .landed }
        }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(field, kAXValueAttribute as CFString, &settable) == .success,
              settable.boolValue,
              let composed = AnchoredPastePolicy.composedValue(
                  current: before,
                  capturedSelection: anchor.selection,
                  textBefore: anchor.textBefore,
                  textAfter: anchor.textAfter,
                  inserting: text
              ),
              AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, composed.value as CFString) == .success else {
            return .notTaken
        }
        try? await Task.sleep(nanoseconds: 60_000_000)
        let insertion = AnchoredPastePolicy.insertion(
            before: before,
            after: stringValue(of: field) ?? "",
            text: text,
            writeAccepted: true,
            windowIsOnScreen: anchor.windowID.flatMap(windowState)?.isOnScreen ?? true
        )
        if insertion == .landed {
            setSelectedRange(NSRange(location: composed.caret, length: 0), of: field)
        }
        return insertion
    }

    /// Whether `text` arrived in the anchored field since it held
    /// `valueBefore` (an unconfirmed write, read again).
    static func insertionLanded(_ text: String, since valueBefore: String, anchor: DictationPasteAnchor) -> Bool {
        guard let field = anchor.field else { return false }
        AXUIElementSetMessagingTimeout(field, messagingTimeout)
        guard let value = stringValue(of: field) else { return false }
        return AnchoredPastePolicy.insertionApplied(before: valueBefore, after: value, text: text)
    }

    /// Whether the anchored field has keyboard focus in its app.
    static func anchoredFieldIsFocused(_ anchor: DictationPasteAnchor) -> Bool {
        guard let field = anchor.field else { return false }
        let appElement = AXUIElementCreateApplication(anchor.pid)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
        return element(of: appElement, kAXFocusedUIElementAttribute).map { CFEqual(field, $0) } ?? false
    }

    /// Whether the anchored field now holds `text` (a paste into an app that
    /// reports no confirmation of its own).
    static func fieldContains(_ text: String, anchor: DictationPasteAnchor) -> Bool {
        guard let field = anchor.field else { return false }
        AXUIElementSetMessagingTimeout(field, messagingTimeout)
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, let value = stringValue(of: field) else { return false }
        return value.contains(needle)
    }

    /// Types `text` into the anchored terminal through keystrokes addressed
    /// to its process (`BackgroundKeystrokes`).
    static func typeIntoTerminal(_ text: String, anchor: DictationPasteAnchor) async -> Bool {
        // `route` keeps multi-line text off this path; a line break here
        // would be typed as Return.
        guard !AnchoredPastePolicy.hasLineBreaks(text) else { return false }
        let pid = anchor.pid
        return await Task.detached(priority: .userInitiated) {
            BackgroundKeystrokes.type(text, pid: pid)
        }.value
    }

    /// Presses send after a background insertion (`AnchoredPastePolicy.sendMethod`):
    /// Return (or ⌘Return) in a terminal; the field's own send button,
    /// pressed through Accessibility, elsewhere; Return in a Chrome window on
    /// screen when there is no such button. A background Electron window
    /// ignores keystrokes, so without a button nothing is pressed there.
    static func pressSend(
        _ key: DictationAutoSendKey,
        route: AnchoredPasteRoute,
        anchor: DictationPasteAnchor
    ) async -> DictationAutoSendOutcome {
        let button = route == .accessibilityInsert ? anchor.field.flatMap(submitButton(near:)) : nil
        let method = AnchoredPastePolicy.sendMethod(
            route: route,
            hasSubmitButton: button != nil,
            bundleID: anchor.bundleID,
            windowIsOnScreen: anchor.windowID.flatMap(windowState)?.isOnScreen ?? false,
            fieldIsFocused: anchoredFieldIsFocused(anchor)
        )
        switch method {
        case .returnKeystroke:
            let pid = anchor.pid
            let sent = await Task.detached(priority: .userInitiated) {
                BackgroundKeystrokes.press(keyCode: 36, flags: key.eventFlags, pid: pid)
            }.value
            return sent ? .sent(key) : .failed(.eventCreationFailed)
        case .pressSubmitButton:
            guard let button else { return .failed(.backgroundSendUnavailable) }
            // A React form enables its button a beat after the value changes.
            for _ in 0..<10 where (bool(of: button, kAXEnabledAttribute) == false) {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
                ? .sent(key)
                : .failed(.backgroundSendUnavailable)
        case .unavailable:
            return route == .accessibilityInsert ? .failed(.backgroundSendUnavailable) : .disabled
        }
    }

    // MARK: - Window

    /// The window's frame (Accessibility coordinates) and whether it is on
    /// screen now: not minimized, not hidden, on the current desktop.
    static func windowState(_ windowID: CGWindowID) -> (frame: CGRect, isOnScreen: Bool)? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let info = list.first,
              let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: boundsDictionary) else { return nil }
        return (frame, (info[kCGWindowIsOnscreen as String] as? Bool) ?? false)
    }

    // MARK: - AX helpers

    private static func focusedTextField(in appElement: AXUIElement) -> AXUIElement? {
        guard let focused = element(of: appElement, kAXFocusedUIElementAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(focused, messagingTimeout)
        let role = string(of: focused, kAXRoleAttribute) ?? ""
        let subrole = string(of: focused, kAXSubroleAttribute)
        // The shared policy also takes a focused web area or static text (for
        // placing the overlay); an insertion needs an editable field.
        guard AccessibilityBridge.acceptsFocusedTextRole(role, subrole: subrole),
              role != "AXWebArea", role != "AXStaticText" else { return nil }
        return focused
    }

    private static func context(field: AXUIElement?, window: AXUIElement?, isTerminal: Bool) -> AnchoredPasteContext {
        AnchoredPasteContext(
            // A terminal's title follows the running command.
            windowTitle: isTerminal ? nil : window.flatMap { string(of: $0, kAXTitleAttribute) },
            documentURL: field.flatMap(enclosingDocumentURL(of:)) ?? window.flatMap { string(of: $0, kAXDocumentAttribute) }
        )
    }

    /// The URL of the web page holding `element` (Chromium/Electron expose it
    /// on the enclosing `AXWebArea`): a T3 thread, a Chrome tab.
    private static func enclosingDocumentURL(of element: AXUIElement) -> String? {
        var current: AXUIElement? = element
        for _ in 0..<40 {
            guard let node = current else { return nil }
            if string(of: node, kAXRoleAttribute) == "AXWebArea" {
                var url: AnyObject?
                guard AXUIElementCopyAttributeValue(node, kAXURLAttribute as CFString, &url) == .success, let url else { return nil }
                if let url = url as? URL { return url.absoluteString }
                return url as? String
            }
            current = self.element(of: node, kAXParentAttribute)
        }
        return nil
    }

    /// A send button close to `field`: the nearest ancestor whose subtree has
    /// one (`AnchoredPastePolicy.isSubmitButtonLabel`).
    private static func submitButton(near field: AXUIElement) -> AXUIElement? {
        var ancestor = element(of: field, kAXParentAttribute)
        for _ in 0..<8 {
            guard let node = ancestor else { return nil }
            var visited = 0
            if let button = findSubmitButton(in: node, depth: 0, visited: &visited) { return button }
            ancestor = element(of: node, kAXParentAttribute)
        }
        return nil
    }

    private static func findSubmitButton(in node: AXUIElement, depth: Int, visited: inout Int) -> AXUIElement? {
        visited += 1
        guard depth <= 6, visited <= 600 else { return nil }
        if string(of: node, kAXRoleAttribute) == "AXButton" {
            let label = string(of: node, kAXDescriptionAttribute) ?? string(of: node, kAXTitleAttribute) ?? ""
            if AnchoredPastePolicy.isSubmitButtonLabel(label) { return node }
        }
        var children: AnyObject?
        guard AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &children) == .success,
              let children = children as? [AXUIElement] else { return nil }
        for child in children {
            if let found = findSubmitButton(in: child, depth: depth + 1, visited: &visited) { return found }
        }
        return nil
    }

    /// The caret, in Accessibility coordinates. Cocoa text views (TextEdit)
    /// report a zero-length range one line too high (the rect is shifted up
    /// by its own height), so with the text known the caret is the previous
    /// character's right edge, or after a line break the next character's
    /// left edge, where the caret starts that line. A zero-length range is
    /// the last resort (an empty field, the end after a line break), and the
    /// first try only when the field's text can't be read.
    private static func caretRect(of field: AXUIElement, selection: NSRange?, characterBefore: Character?, textIsKnown: Bool) -> CGRect? {
        if let selection {
            let location = selection.location
            let previous = location > 0 ? bounds(of: field, NSRange(location: location - 1, length: 1)) : nil
            let atCaret = bounds(of: field, NSRange(location: location, length: 0))
            if textIsKnown {
                if let before = characterBefore, !before.isNewline, let previous {
                    // A soft wrap: the caret is drawn where the next line starts.
                    if before.isWhitespace, let next = bounds(of: field, NSRange(location: location, length: 1)),
                       next.minY >= previous.maxY - 1 {
                        return CGRect(x: next.minX, y: next.minY, width: 1, height: next.height)
                    }
                    return CGRect(x: previous.maxX, y: previous.minY, width: 1, height: previous.height)
                }
                if let next = bounds(of: field, NSRange(location: location, length: 1)) {
                    return CGRect(x: next.minX, y: next.minY, width: 1, height: next.height)
                }
                if var atCaret {
                    // After a line break the caret starts the line below it.
                    // Chromium puts the zero-length range after the text
                    // above; the first character marks where lines start.
                    if characterBefore?.isNewline == true, let lineBreak = previous, atCaret.minY < lineBreak.maxY - 1 {
                        atCaret.origin.y = lineBreak.maxY
                        if let first = bounds(of: field, NSRange(location: 0, length: 1)) { atCaret.origin.x = first.minX }
                    }
                    return atCaret
                }
            } else {
                if let atCaret { return atCaret }
                if let previous { return CGRect(x: previous.maxX, y: previous.minY, width: 1, height: previous.height) }
            }
        }
        var position: AnyObject?
        var size: AnyObject?
        guard AXUIElementCopyAttributeValue(field, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(field, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        // A tall editor without caret bounds: mark its first line.
        return CGRect(x: origin.x + 8, y: origin.y + 6, width: 1, height: min(extent.height, 22))
    }

    /// A range's bounds; nil when the field has none for it (an error, or the
    /// empty rect some fields return instead).
    private static func bounds(of field: AXUIElement, _ range: NSRange) -> CGRect? {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var boundsValue: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(field, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &boundsValue) == .success,
              let boundsValue, CFGetTypeID(boundsValue) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect)
        return rect.height > 0 && rect.origin != .zero ? rect : nil
    }

    private static func windowID(of window: AXUIElement) -> CGWindowID? {
        typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
        var id: CGWindowID = 0
        return unsafeBitCast(symbol, to: GetWindow.self)(window, &id) == .success && id != 0 ? id : nil
    }

    private static func stringValue(of element: AXUIElement) -> String? {
        guard let value = string(of: element, kAXValueAttribute), (value as NSString).length <= 500_000 else { return nil }
        return value
    }

    private static func selectedRange(of element: AXUIElement) -> NSRange? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private static func setSelectedRange(_ range: NSRange, of element: AXUIElement) {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else { return }
        AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
    }

    private static func element(of element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func string(of element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func bool(of element: AXUIElement, _ attribute: String) -> Bool? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? Bool
    }
}
