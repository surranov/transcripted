import Foundation

/// Fork: Anchored paste. A dictation is pasted into the text field that had
/// focus when it started, even after the user moved to another window or
/// desktop, without bringing that window forward.
///
/// Measured on 2026-10-11 (Obsidian, T3 Code, Chrome, Terminal on macOS 26):
/// - Accessibility writes reach a field in any window on any desktop at once:
///   `AXSelectedText` in native text views, `AXValue` in Chromium/Electron
///   inputs and text areas (T3's composer included; React sees the change).
///   CodeMirror (Obsidian) ignores both while reporting success. A window on
///   another desktop takes an `AXValue` write but can go on reporting its old
///   value until it is on screen again (T3 Code), so a write there that can't
///   be read back is unconfirmed, not failed.
/// - Keystrokes addressed to a process reach terminals on any desktop, but
///   an inactive Electron window drops them, so text is typed into terminals
///   only. (Enter reaches an inactive Electron window once it is made key
///   inside its app: `AnchoredSendMethod.keyWindowReturn`.)
/// - Apps can reuse one field for several documents (T3 keeps one composer
///   for every thread), so a field is trusted only while its window title and
///   page URL still match what they were when the dictation started.
/// This file holds the decisions; `AnchoredTextDelivery` does the AX and
/// keyboard work.
enum AnchoredPasteRoute: String, Equatable {
    /// The user is back in the anchored app: the regular paste-back runs.
    case normalPaste = "normal_paste"
    /// Typed into a terminal through keystrokes addressed to its process.
    case terminalKeystrokes = "terminal_keystrokes"
    /// Inserted through Accessibility into the anchored field.
    case accessibilityInsert = "accessibility_insert"
    /// Waits until the user returns to the anchored window, then pastes.
    case deferred
}

/// How send is pressed for a take delivered in the background.
enum AnchoredSendMethod: Equatable {
    /// The field's own send button, through Accessibility.
    case pressSubmitButton
    /// Return addressed to the app's process (a terminal: its window is
    /// already the app's current one).
    case returnKeystroke
    /// The field's window made key inside its app, without activating the
    /// app or raising the window (`BackgroundKeyWindow`), the field focused
    /// in it, then Return addressed to the app's process. An inactive
    /// Chromium/Electron window drops keystrokes until it is key.
    case keyWindowReturn
    case unavailable
}

/// How a background Accessibility write ended.
enum AnchoredInsertion: Equatable {
    /// Read back in the field.
    case landed
    /// Nothing was written, or the window on screen shows the field without
    /// the words: the app ignored the write.
    case notTaken
    /// The app took the write, but its window is off screen and still
    /// reports the old value. Whether the words arrived shows once the user
    /// is back: compare with `valueBefore` then, so they aren't pasted twice.
    case unconfirmed(valueBefore: String)
}

/// What identifies the document a field belonged to when the dictation
/// started. A field alone isn't enough: an app may keep the same field for
/// another document (another thread, note or tab).
struct AnchoredPasteContext: Equatable {
    let windowTitle: String?
    let documentURL: String?

    /// Both captured values must still hold. A value that couldn't be read
    /// at capture time isn't compared.
    func stillMatches(_ current: AnchoredPasteContext) -> Bool {
        if let windowTitle, windowTitle != current.windowTitle { return false }
        if let documentURL, documentURL != current.documentURL { return false }
        return true
    }
}

enum AnchoredPastePolicy {
    /// Text around the caret kept at capture time, to find the insertion
    /// point again if the field changed while the dictation was processed.
    static let contextSnippetLength = 80
    /// UTF-16 units per synthesized key event; `CGEventKeyboardSetUnicodeString`
    /// takes up to 20.
    static let keystrokeChunkLength = 20
    /// How long a deferred paste waits for the user to come back.
    /// How long a returning user's window gets to show an unconfirmed write
    /// before the words are pasted after all.
    static let unconfirmedWriteSettleTime: TimeInterval = 1.5
    static let deferredPasteLifetime: TimeInterval = 10 * 60

    /// Terminals whose text view takes keystrokes addressed to the process
    /// while it is inactive or on another desktop. Electron terminals
    /// (Hyper) are left out: an inactive Electron window drops them.
    static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "com.cmuxterm.app",
        "com.github.wez.wezterm",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "dev.warp.Warp-Stable",
    ]

    /// How send is pressed after a background delivery.
    static func sendMethod(
        route: AnchoredPasteRoute,
        hasSubmitButton: Bool,
        anchorAppIsFrontmost: Bool,
        hasWindow: Bool
    ) -> AnchoredSendMethod {
        switch route {
        case .terminalKeystrokes:
            return .returnKeystroke
        case .accessibilityInsert:
            if hasSubmitButton { return .pressSubmitButton }
            // With the app in front the user is typing in it elsewhere (the
            // words went to a field they moved away from): its key window is
            // theirs, and refocusing the anchored field would take their caret.
            guard !anchorAppIsFrontmost, hasWindow else { return .unavailable }
            return .keyWindowReturn
        case .normalPaste, .deferred:
            return .unavailable
        }
    }

    /// Whether Return pressed in the background went into the field, read
    /// back after it (`valueAfter` nil: the field is gone, a page that moved
    /// on). A multi-line field shows Return either way: a chat clears it, an
    /// editor adds a line. A single-line field may act on Return and keep its
    /// text (a search), so it isn't held against the key.
    static func returnTook(valueBefore: String, valueAfter: String?, isMultiLine: Bool) -> Bool {
        guard let valueAfter else { return true }
        return valueAfter != valueBefore || !isMultiLine
    }

    static func hasLineBreaks(_ text: String) -> Bool {
        text.rangeOfCharacter(from: .newlines) != nil
    }

    static func route(
        anchorAppIsFrontmost: Bool,
        focusIsAnchorField: Bool,
        hasField: Bool,
        fieldAlive: Bool,
        contextMatches: Bool,
        isTerminal: Bool,
        terminalWindowIsCurrent: Bool,
        textHasLineBreaks: Bool
    ) -> AnchoredPasteRoute {
        if anchorAppIsFrontmost {
            // Still in the field, or moved to another document in the same
            // app on purpose (another thread, note or tab): the regular
            // paste goes where the user is, as before this feature. Only a
            // move within the same document (to a search box, say) keeps the
            // anchored field.
            if focusIsAnchorField || !hasField || !fieldAlive || !contextMatches || isTerminal { return .normalPaste }
            return .accessibilityInsert
        }
        // A terminal's title changes with the running command, so it is
        // trusted while its window is still the app's focused one. A line
        // break typed as a key is Return, which sends a chat prompt (Claude
        // Code) at the first line; the regular paste on return keeps it text.
        if isTerminal {
            return terminalWindowIsCurrent && !textHasLineBreaks ? .terminalKeystrokes : .deferred
        }
        guard hasField, fieldAlive, contextMatches else { return .deferred }
        return .accessibilityInsert
    }

    /// The range of `current` the dictation replaces: the selection captured
    /// when it started if the text around it is unchanged, else the spot
    /// between that text found once elsewhere in the field, or the whole
    /// value when the field is empty (Chromium contenteditable reports "\n").
    /// Nil when the spot can't be found unambiguously.
    static func insertionRange(
        current: String,
        capturedSelection: NSRange?,
        textBefore: String,
        textAfter: String
    ) -> NSRange? {
        let field = current as NSString
        if current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return NSRange(location: 0, length: field.length)
        }
        if let selection = capturedSelection,
           selection.location >= 0,
           NSMaxRange(selection) <= field.length,
           contextHolds(in: field, at: selection, before: textBefore, after: textAfter) {
            return selection
        }
        guard !textBefore.isEmpty || !textAfter.isEmpty else { return nil }
        let needle = textBefore + textAfter
        let first = field.range(of: needle)
        guard first.location != NSNotFound else { return nil }
        let rest = NSRange(location: first.location + 1, length: field.length - first.location - 1)
        guard rest.length <= 0 || field.range(of: needle, options: [], range: rest).location == NSNotFound else {
            return nil
        }
        return NSRange(location: first.location + (textBefore as NSString).length, length: 0)
    }

    /// The field's new value with `text` in `insertionRange`, and the caret
    /// after it (UTF-16 offset).
    static func composedValue(
        current: String,
        capturedSelection: NSRange?,
        textBefore: String,
        textAfter: String,
        inserting text: String
    ) -> (value: String, caret: Int)? {
        guard let range = insertionRange(
            current: current, capturedSelection: capturedSelection,
            textBefore: textBefore, textAfter: textAfter
        ) else { return nil }
        let value = (current as NSString).replacingCharacters(in: range, with: text)
        return (value, range.location + (text as NSString).length)
    }

    private static func contextHolds(in field: NSString, at selection: NSRange, before: String, after: String) -> Bool {
        let beforeLength = (before as NSString).length
        let afterLength = (after as NSString).length
        guard selection.location >= beforeLength, NSMaxRange(selection) + afterLength <= field.length else { return false }
        let actualBefore = field.substring(with: NSRange(location: selection.location - beforeLength, length: beforeLength))
        let actualAfter = field.substring(with: NSRange(location: NSMaxRange(selection), length: afterLength))
        return actualBefore == before && actualAfter == after
    }

    /// Reads a write: `insertionApplied` decides landed; otherwise an
    /// accepted write into a window off screen is unconfirmed.
    static func insertion(
        before: String,
        after: String,
        text: String,
        writeAccepted: Bool,
        windowIsOnScreen: Bool
    ) -> AnchoredInsertion {
        if insertionApplied(before: before, after: after, text: text) { return .landed }
        guard writeAccepted, !windowIsOnScreen else { return .notTaken }
        return .unconfirmed(valueBefore: before)
    }

    /// Whether a write put `text` into the field: it appears once more than
    /// before. Apps may trim or normalize the rest of the value.
    static func insertionApplied(before: String, after: String, text: String) -> Bool {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return false }
        return occurrences(of: needle, in: after) > occurrences(of: needle, in: before)
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    /// A button next to the field that sends what's in it, by its
    /// accessibility label: T3's "Submit message", a chat's "Send".
    static func isSubmitButtonLabel(_ label: String) -> Bool {
        let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let exact: Set<String> = ["send", "submit", "send message", "submit message", "отправить", "отправить сообщение"]
        return exact.contains(normalized)
    }

    /// How far a parent may reach past the visible field on the left, top or
    /// right and still be the field's box. Measured on T3 Code: its composer
    /// card reaches 21 pt past its text area, and the next parent, which adds
    /// the strip above the composer, reaches 62 pt.
    static let fieldBoxPadding: CGFloat = 32
    /// T3 Code's composer card is 5 parents up from its text area.
    static let maxFieldBoxDepth = 12

    /// How many parents up the field's box is (0: the field itself): what
    /// the user sees as the text box, for the marker to sit above. The
    /// focused element is often only the text inside it, or a document
    /// taller than its scroll view. Climbing from the field, a parent counts
    /// while it reaches at most `fieldBoxPadding` past the visible field on
    /// the left, top and right (its bottom may hold a toolbar); a parent
    /// inside the field, like a scroll view, clips it. `nextParentFrame`
    /// gives the next parent's frame up, or nil past the last one; the
    /// window must not count, since its title bar is part of no box.
    static func fieldBoxDepth(field: CGRect, nextParentFrame: () -> CGRect?) -> Int {
        var visible = field
        var depth = 0
        while depth < maxFieldBoxDepth, let parent = nextParentFrame(),
              parent.width > 0, parent.height > 0, parent.intersects(visible),
              visible.minX - parent.minX <= fieldBoxPadding,
              visible.minY - parent.minY <= fieldBoxPadding,
              parent.maxX - visible.maxX <= fieldBoxPadding {
            visible = visible.intersection(parent)
            depth += 1
        }
        return depth
    }

    /// `text` split for keystrokes: runs of at most `keystrokeChunkLength`
    /// UTF-16 units, with each line break as its own Return.
    static func keystrokeChunks(_ text: String) -> [AnchoredKeystrokeChunk] {
        var chunks: [AnchoredKeystrokeChunk] = []
        var run: [UInt16] = []
        func flush() {
            if !run.isEmpty { chunks.append(.text(String(utf16CodeUnits: run, count: run.count))); run = [] }
        }
        for character in text {
            if character == "\n" || character == "\r\n" || character == "\r" {
                flush()
                chunks.append(.returnKey)
                continue
            }
            let units = Array(String(character).utf16)
            if run.count + units.count > keystrokeChunkLength { flush() }
            run += units
        }
        flush()
        return chunks
    }
}

enum AnchoredKeystrokeChunk: Equatable {
    case text(String)
    case returnKey
}
