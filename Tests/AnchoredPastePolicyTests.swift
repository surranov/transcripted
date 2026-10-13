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
            frontmost: Bool = false, window: Bool = true
        ) -> AnchoredSendMethod {
            AnchoredPastePolicy.sendMethod(route: route, hasSubmitButton: button, anchorAppIsFrontmost: frontmost, hasWindow: window)
        }
        assertEqual(method(route: .terminalKeystrokes), .returnKeystroke, "a terminal takes Return on any desktop")
        assertEqual(method(button: true), .pressSubmitButton, "the field's send button first (T3)")
        assertEqual(method(button: true, frontmost: true), .pressSubmitButton, "a button press leaves the user's caret alone")
        assertEqual(method(), .keyWindowReturn, "no button, app in the background: Return once its window is key (Chrome, Electron, native)")
        assertEqual(method(frontmost: true), .unavailable, "the user is typing in that app elsewhere: Return would land in their box")
        assertEqual(method(window: false), .unavailable, "no window to make key")
        assertEqual(method(route: .deferred), .unavailable, "nothing delivered, nothing sent")
        assertEqual(method(route: .normalPaste), .unavailable, "the regular paste presses send its own way")
    }

    runSuite("AnchoredPastePolicy tells from the field whether a background Return went in") {
        func took(_ before: String, _ after: String?, multiLine: Bool = true) -> Bool {
            AnchoredPastePolicy.returnTook(valueBefore: before, valueAfter: after, isMultiLine: multiLine)
        }
        assertTrue(took("hello there", ""), "a chat sent the message and cleared the box")
        assertTrue(took("hello there", "hello there\n"), "an editor added a line")
        assertTrue(took("hello there", nil), "the box is gone: the page moved on")
        assertFalse(took("hello there", "hello there"), "a multi-line box that didn't change dropped the key")
        assertTrue(took("weather", "weather", multiLine: false), "a search box acts on Return and keeps its text")
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

    runSuite("AnchoredPastePolicy takes the text box the user sees, not just the text inside it") {
        // T3 Code's composer, measured: the text area, then its parents up to
        // the card (5 up) and the column holding the strip above the composer.
        let t3Field = CGRect(x: 1587, y: 2245, width: 1024, height: 250)
        let t3Parents: [CGRect] = [
            CGRect(x: 1592, y: 2250, width: 1015, height: 240),
            CGRect(x: 1592, y: 2250, width: 1015, height: 240),
            CGRect(x: 1573, y: 2230, width: 1053, height: 270),
            CGRect(x: 1571, y: 2229, width: 1056, height: 329),
            CGRect(x: 1571, y: 2229, width: 1056, height: 329),
            CGRect(x: 1571, y: 2188, width: 1056, height: 370),
            CGRect(x: 1514, y: 1695, width: 1170, height: 887),
        ]
        var asked = 0
        let t3Depth = AnchoredPastePolicy.fieldBoxDepth(field: t3Field) {
            defer { asked += 1 }
            return asked < t3Parents.count ? t3Parents[asked] : nil
        }
        assertEqual(t3Depth, 5, "T3 Code: the composer card, not the strip above it")
        assertEqual(asked, 6, "stops at the first parent that isn't the box")

        func depth(_ field: CGRect, _ parents: [CGRect?]) -> Int {
            var queue = parents[...]
            return AnchoredPastePolicy.fieldBoxDepth(field: field) { queue.popFirst() ?? nil }
        }
        let input = CGRect(x: 100, y: 300, width: 200, height: 24)
        assertEqual(depth(input, [CGRect(x: 100, y: 256, width: 200, height: 68)]), 0, "a label above the input is not part of its box")
        assertEqual(depth(input, [CGRect(x: 0, y: 296, width: 300, height: 32)]), 0, "a row reaching far left is not its box")
        assertEqual(depth(input, [nil, CGRect(x: 96, y: 296, width: 208, height: 32)]), 0, "a parent without a frame ends the climb")
        assertEqual(depth(input, [CGRect(x: 0, y: 0, width: 0, height: 0)]), 0, "an empty parent is not a box")
        assertEqual(depth(input, [CGRect(x: 96, y: 296, width: 208, height: 32)]), 1, "a padded wrapper is the box")

        // A long document scrolled down: the text view starts far above its
        // scroll view, which clips it; the split view beside it is no box.
        let document = CGRect(x: 0, y: -2000, width: 600, height: 5000)
        let scroll = CGRect(x: 0, y: 80, width: 600, height: 500)
        let split = CGRect(x: 0, y: 52, width: 900, height: 548)
        assertEqual(depth(document, [scroll, split]), 1, "the scroll view showing the document")

        assertEqual(depth(input, Array(repeating: input, count: 40)), AnchoredPastePolicy.maxFieldBoxDepth, "the climb is bounded")
    }

    runSuite("AnchoredPasteContext holds while the document is the same") {
        let captured = AnchoredPasteContext(windowTitle: "Note - Obsidian", documentURL: "t3code://app/#/a/thread-1")
        assertTrue(captured.stillMatches(AnchoredPasteContext(windowTitle: "Note - Obsidian", documentURL: "t3code://app/#/a/thread-1")), "same")
        assertTrue(!captured.stillMatches(AnchoredPasteContext(windowTitle: "Note - Obsidian", documentURL: "t3code://app/#/a/thread-2")), "another thread in the same composer")
        assertTrue(!captured.stillMatches(AnchoredPasteContext(windowTitle: "Other - Obsidian", documentURL: "t3code://app/#/a/thread-1")), "another note")
        assertTrue(AnchoredPasteContext(windowTitle: nil, documentURL: nil).stillMatches(captured), "nothing captured, nothing compared")
    }
}
