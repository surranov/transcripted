import Foundation

// Anchored paste decisions (AnchoredPastePolicy): which route a take takes,
// where in the field the words go, whether a write landed, and how text is
// split for keystrokes. The AX and keyboard calls themselves need a real app.

private func route(
    frontmost: Bool = false,
    focusIsAnchor: Bool = false,
    hasField: Bool = true,
    alive: Bool = true,
    context: Bool = true,
    terminal: Bool = false,
    terminalWindowCurrent: Bool = true,
    lineBreaks: Bool = false
) -> AnchoredPasteRoute {
    AnchoredPastePolicy.route(
        anchorAppIsFrontmost: frontmost,
        focusIsAnchorField: focusIsAnchor,
        hasField: hasField,
        fieldAlive: alive,
        contextMatches: context,
        isTerminal: terminal,
        terminalWindowIsCurrent: terminalWindowCurrent,
        textHasLineBreaks: lineBreaks
    )
}

func testAnchoredPastePolicy() {
    runSuite("AnchoredPastePolicy routes a take by where the user is now") {
        assertEqual(route(frontmost: true, focusIsAnchor: true), .normalPaste, "still in the field: the regular paste")
        assertEqual(route(frontmost: true, context: false), .normalPaste, "another thread or tab in the same app: paste where the user is")
        assertEqual(route(frontmost: true, focusIsAnchor: false), .accessibilityInsert, "same document, focus moved (a search box): the anchored field")
        assertEqual(route(), .accessibilityInsert, "another app: inserted in the background")
        assertEqual(route(context: false), .deferred, "the field now shows another document: wait for the user")
        assertEqual(route(alive: false), .deferred, "the field is gone: wait")
        assertEqual(route(hasField: false), .deferred, "no field was exposed: wait")
        assertEqual(route(terminal: true), .terminalKeystrokes, "a terminal is typed into")
        assertEqual(route(terminal: true, terminalWindowCurrent: false), .deferred, "another terminal window is in front of it now")
        assertEqual(route(frontmost: true, terminal: true), .normalPaste, "inside the terminal: the regular paste")
        assertEqual(
            route(terminal: true, lineBreaks: true), .deferred,
            "multi-line text waits for the regular paste: a typed line break is Return and would send a Claude Code prompt early"
        )
        assertEqual(route(lineBreaks: true), .accessibilityInsert, "a text field takes line breaks as text")
        assertTrue(AnchoredPastePolicy.hasLineBreaks("one\ntwo") && AnchoredPastePolicy.hasLineBreaks("a\r\nb") && !AnchoredPastePolicy.hasLineBreaks("one line"), "any newline counts")
    }

    runSuite("AnchoredPastePolicy finds where the words go") {
        assertEqual(
            AnchoredPastePolicy.insertionRange(current: "\n", capturedSelection: NSRange(location: 0, length: 0), textBefore: "", textAfter: ""),
            NSRange(location: 0, length: 1),
            "an empty contenteditable (\"\\n\") is replaced"
        )
        assertEqual(
            AnchoredPastePolicy.insertionRange(current: "hello world", capturedSelection: NSRange(location: 6, length: 0), textBefore: "hello ", textAfter: "world"),
            NSRange(location: 6, length: 0),
            "the captured caret, when the text around it is unchanged"
        )
        assertEqual(
            AnchoredPastePolicy.insertionRange(current: "new line\nhello world", capturedSelection: NSRange(location: 6, length: 0), textBefore: "hello ", textAfter: "world"),
            NSRange(location: 15, length: 0),
            "found again by its surroundings after text was added above"
        )
        assertNil(
            AnchoredPastePolicy.insertionRange(current: "ab ab", capturedSelection: NSRange(location: 99, length: 0), textBefore: "a", textAfter: "b"),
            "two matches: ambiguous, nothing is written"
        )
        assertNil(
            AnchoredPastePolicy.insertionRange(current: "something", capturedSelection: nil, textBefore: "", textAfter: ""),
            "no caret and no surroundings in a non-empty field: nothing is written"
        )
        let composed = AnchoredPastePolicy.composedValue(
            current: "Привет мир", capturedSelection: NSRange(location: 7, length: 0),
            textBefore: "Привет ", textAfter: "мир", inserting: "большой "
        )
        assertEqual(composed?.value, "Привет большой мир", "the words go in at the caret")
        assertEqual(composed?.caret, 15, "the caret lands after them (UTF-16)")
    }

    runSuite("AnchoredPastePolicy only counts a write that put the words in") {
        assertTrue(AnchoredPastePolicy.insertionApplied(before: "", after: "тест", text: "тест"), "added")
        assertTrue(!AnchoredPastePolicy.insertionApplied(before: "тест", after: "тест", text: "тест"), "a field that already held the same words didn't change")
        assertTrue(AnchoredPastePolicy.insertionApplied(before: "тест", after: "тест тест", text: "тест"), "a repeated dictation still counts")
        assertTrue(AnchoredPastePolicy.insertionApplied(before: "\n", after: "hello", text: "hello\n"), "trailing whitespace an app trims doesn't matter")
        assertTrue(!AnchoredPastePolicy.insertionApplied(before: "x", after: "x", text: "  "), "nothing to insert is never a success")
    }

    runSuite("AnchoredPastePolicy tells an ignored write from one an off-screen window hasn't shown yet") {
        func insertion(after: String, accepted: Bool = true, onScreen: Bool) -> AnchoredInsertion {
            AnchoredPastePolicy.insertion(before: "draft", after: after, text: "тест", writeAccepted: accepted, windowIsOnScreen: onScreen)
        }
        assertEqual(insertion(after: "draft тест", onScreen: false), .landed, "read back: landed, on any desktop")
        assertEqual(insertion(after: "draft", onScreen: true), .notTaken, "a window on screen that still shows the old value ignored it (CodeMirror)")
        assertEqual(
            insertion(after: "draft", onScreen: false),
            .unconfirmed(valueBefore: "draft"),
            "a window on another desktop may show it only once it's back (T3 Code): checked on return, not pasted twice"
        )
        assertEqual(insertion(after: "draft", accepted: false, onScreen: false), .notTaken, "a refused write is not pending")
    }

    runSuite("AnchoredPastePolicy picks how send is pressed in the background") {
        func method(
            route: AnchoredPasteRoute = .accessibilityInsert, button: Bool = false,
            bundleID: String? = "com.google.Chrome", onScreen: Bool = true, focused: Bool = true
        ) -> AnchoredSendMethod {
            AnchoredPastePolicy.sendMethod(route: route, hasSubmitButton: button, bundleID: bundleID, windowIsOnScreen: onScreen, fieldIsFocused: focused)
        }
        assertEqual(method(route: .terminalKeystrokes, bundleID: "com.apple.Terminal", onScreen: false), .returnKeystroke, "a terminal takes Return on any desktop")
        assertEqual(method(button: true, bundleID: "com.t3tools.t3code"), .pressSubmitButton, "the field's send button first (T3)")
        assertEqual(method(), .returnKeystroke, "Chrome on screen, no button, field still focused: Return (a Google search)")
        assertEqual(method(onScreen: false), .unavailable, "Chrome on another desktop may hold Return until shown")
        assertEqual(method(focused: false), .unavailable, "focus moved in that window: Return would go elsewhere")
        assertEqual(method(bundleID: "md.obsidian"), .unavailable, "an Electron window drops background keystrokes")
        assertEqual(method(route: .deferred), .unavailable, "nothing delivered, nothing sent")
    }

    runSuite("AnchoredPastePolicy recognizes a send button by its label") {
        for label in ["Submit message", "Send", "send message", "Отправить"] {
            assertTrue(AnchoredPastePolicy.isSubmitButtonLabel(label), "\(label) sends")
        }
        for label in ["Send feedback", "Attach files", "Settings", ""] {
            assertTrue(!AnchoredPastePolicy.isSubmitButtonLabel(label), "\(label) is not the send button")
        }
    }

    runSuite("AnchoredPastePolicy splits text for keystrokes") {
        let chunks = AnchoredPastePolicy.keystrokeChunks("abcdefghijklmnopqrstuvwxyz\nok")
        assertEqual(chunks, [.text("abcdefghijklmnopqrst"), .text("uvwxyz"), .returnKey, .text("ok")], "20 UTF-16 units per event, a line break is Return")
        let emoji = String(repeating: "😀", count: 11)
        let emojiChunks = AnchoredPastePolicy.keystrokeChunks(emoji)
        assertEqual(emojiChunks.count, 2, "surrogate pairs stay whole across events")
        assertEqual(emojiChunks.map { if case .text(let t) = $0 { return t } else { return "" } }.joined(), emoji, "nothing lost")
    }

    runSuite("AnchoredPasteContext holds while the document is the same") {
        let captured = AnchoredPasteContext(windowTitle: "Note - Obsidian", documentURL: "t3code://app/#/a/thread-1")
        assertTrue(captured.stillMatches(AnchoredPasteContext(windowTitle: "Note - Obsidian", documentURL: "t3code://app/#/a/thread-1")), "same")
        assertTrue(!captured.stillMatches(AnchoredPasteContext(windowTitle: "Note - Obsidian", documentURL: "t3code://app/#/a/thread-2")), "another thread in the same composer")
        assertTrue(!captured.stillMatches(AnchoredPasteContext(windowTitle: "Other - Obsidian", documentURL: "t3code://app/#/a/thread-1")), "another note")
        assertTrue(AnchoredPasteContext(windowTitle: nil, documentURL: nil).stillMatches(captured), "nothing captured, nothing compared")
    }
}
