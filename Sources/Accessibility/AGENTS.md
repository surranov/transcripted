# Accessibility

`AccessibilityBridge.swift`: the AX (AXUIElement) queries that find the focused text field in the target app. Fork: `AnchoredTextDelivery.swift`, `BackgroundKeystrokes.swift` and `BackgroundKeyWindow.swift` deliver Anchored paste and its send into the anchored box (below); `ChatThreadReader.swift` reads which AI chat thread an app shows (the chat thread guard, below). Part of the `Support` module in `.agents/modules.json` (with `Sources/Support/` and `Sources/Reliability/`), so it may depend only on Core's `core-vocab` tier. The module card is in `Sources/AGENTS.md`.

## What it does

- `AccessibilityBridge` is `@MainActor`. `focusedTextElement(for:)` returns the focused element only if AX is trusted and the role passes `AccessibilityFocusedTextPolicy`. `focusedTextFieldRect(for:)` returns its screen rect. `textValue(of:)` reads `kAXValueAttribute`.
- `focusedTextFieldRect(for:)` has no caller in the fork: the island draws on every display, so it no longer reads the focused field to pick one.
- Other AX code does its own queries and doesn't go through this file: `Sources/Support/FocusedTextPasteConfirmation.swift` (did the paste land), `Sources/Meeting/BrowserWindowTitleReader.swift`, and the Writing Screen Memory readers in `Sources/TranscriptedWriting/Runtime/ScreenMemory/`.

## Anchored paste (fork)

The words go to the field focused when the take started, even after the user moved to another window or desktop, without raising it. Rules are in `Sources/Support/AnchoredPastePolicy.swift`; the session side is `Sources/UI/Overlay/DictationSessionController+AnchoredPaste.swift`.

- `AnchoredTextDelivery.captureAnchor` records the focused field, its window (`_AXUIElementGetWindow`), the caret rect (from the previous character's right edge, or the next character's left edge after a line break: Cocoa text views like TextEdit report a zero-length range one line too high, so a zero-length range is the last resort), the selection with 80 characters around it, and a context signature: window title plus the enclosing `AXWebArea`'s `AXURL`. T3 Code reuses one composer element across threads, and its URL holds the thread id, so the signature is what keeps a take out of another thread. Electron apps get `AXManualAccessibility` first.
- Routes, as measured on macOS 26: Chromium and Electron web fields take an `AXValue` write on any desktop (`AXSelectedText` returns success there and changes nothing, so every write is read back); terminals take process-addressed keystrokes on any desktop (`BackgroundKeystrokes`, the SkyLight `SLEventPostToPid` recipe ported from trycua/cua, MIT), single-line text only: a typed line break is Return and would send a Claude Code prompt at the first line, so multi-line text waits for the regular paste; CodeMirror (Obsidian) ignores every AX write and inactive Electron windows drop keystrokes, so those wait for the user to come back.
- **A write into a window on another desktop can't be trusted to read back.** T3 Code takes it but reports the old value until its window is shown again. Such a write is `AnchoredInsertion.unconfirmed`: the paste is deferred with the field's value from before, and on return the session polls up to `unconfirmedWriteSettleTime` (1.5 s) before pasting, so the words never arrive twice. A window on screen that doesn't show the words ignored the write (`notTaken`) and is pasted on return without waiting.
- Background send (`AnchoredPastePolicy.sendMethod`): a terminal gets Return as a keystroke; a web field gets AXPress on a nearby button labelled Send / Submit message / Отправить (`isSubmitButtonLabel`); without one, while the anchored app is in the background, `keyWindowReturn`: `BackgroundKeyWindow.makeKey` (yabai's focus and make-key event records, as cua-driver posts them, MIT) makes the field's window key inside its app without activating the app or raising the window, the field gets `AXFocused` if the app had moved focus, and Return goes as a keystroke only once the app reports that window and that field focused; then `resignKey` (unless the user came to that app meanwhile). Measured on macOS 26: an inactive Electron window drops a process-addressed Return until made key, then takes it; the front app keeps the keyboard; a minimized window takes nothing. A multi-line field read back unchanged didn't take it (`returnTook`). With the app in front (the user typing elsewhere in it), no window, or any of that failing, it reports `backgroundSendUnavailable(appName:)` instead of guessing.
- **Send into the anchored box** (`DictationSendSettings.decision`): with Anchored paste on, a take that sends (Settings → Send after dictation) sends only into the box it started in, in any app. The decision has `requiresAnchoredField`: after the regular paste (the user stayed) or a deferred one (they came back), Enter goes only while the anchored field has focus (`anchoredFieldBlocker`), else `anchoredFieldLeft`; a likely paste counts once the field holds the words. Every route ends in "Pasted + Enter" or a notice on the island.
- The context also holds the page title (`AnchoredPasteContext.pageTitle`) in Codex only: its window title and address are the same for every thread, and its page is titled after the open one (`ChatThreadPolicy.titleNamedThreadBundleIDs`). Without it a background write or a deferred paste could go into whatever Codex thread is open now.
- `windowState` (`kCGWindowIsOnscreen`) drives the marker: off screen means another desktop, minimized or closed.
- `fieldBox` finds the field's box for the marker: the field's nearest parents that only pad it (at most 32 pt past it on the left, top and right, the window excluded), or the scroll view clipping it (`AnchoredPastePolicy.fieldBoxDepth`). It and `frame(of:)` are nonisolated: the marker calls them off the main thread, and they set timeouts only on parents they fetch, never on the anchor's shared field.

## Chat thread guard (fork)

A take dictated into an AI chat goes only into the thread it was dictated into, with Anchored paste on or off. Rules and measurements are in `Sources/Support/ChatThreadPolicy.swift`; the session side is `Sources/UI/Overlay/DictationSessionController+ChatThreadGuard.swift`.

- `ChatThreadReader.chatThread(in:)` runs at the start, only in chat apps and browsers (`ChatThreadPolicy.readsPages`): the pages (`AXWebArea`) in the app's focused window, breadth first, never inside a page (7 or 8 deep in T3 Code, Codex, Claude and Chrome). A chat app (T3 Code, Codex, Claude) or a page of a chat site (claude.ai, chatgpt.com, grok.com, kimi.com, gemini, ...) gets a `ChatThread`; anything else isn't guarded. Electron apps and browsers get `AXManualAccessibility` and a second look when no page shows.
- The thread is each page's address without the query, plus the page title in Codex. T3 Code keeps the thread in its address fragment and reuses one composer, so the focused field proves nothing there.
- `currentIdentity` reads it again (a change is read twice, 150 ms apart, before it counts) before the regular paste (only when that app is in front), before a deferred anchored paste, and before every send into that app (Settings → Send after dictation): after the regular paste, a background send (in the anchor's window), a deferred paste's send, and a send confirmed later (After I confirm, `PendingSendConfirmation.chatThread`, in the anchor's window). A page that can't be read then counts as another thread.
- A new chat (T3 Code's `#/draft/<id>`, claude.ai/new, Codex's start page: `ChatThreadPolicy.isNewChat`) moves to a thread of its own when its first message is sent. After the take's own send, `followNewChat` watches for that move for 2 s (`ChatThreadMove`), so a take queued on the new chat still pastes into its thread; a check waits for a move under way first, since a queued take pastes about 50 ms after the earlier send. Only a take started before that send follows it (`sentAt >= capturedAt`): every new chat's page looks the same. A move by hand is never followed.
- The read stops after 1.5 s with what it found (a hung app answers each call only at its timeout). In a browser with no page in its tree, `AXManualAccessibility` is set too, as Anchored paste does: without it the guard can't see the chat; Chrome then keeps its accessibility tree on until it quits.
- Reads run off the main actor (`Task.detached`), each AX call bounded by `messagingTimeout`.
- In T3 Code the start also keeps the thread as its server names it (`ChatThread.sendTarget`, from the page address `#/<environment>/<thread>`; none for a draft or a window showing two threads): a take that sends goes there through T3 Code's server when the user isn't looking at that thread (`Sources/Support/ChatThreadSendPolicy.swift`, `Sources/Support/ChatThreadSender.swift`).

## Rules

- **Secure fields are never exposed.** `AXSecureTextField` is rejected as role or subrole (some AppKit hosts report it as a subrole of `AXTextField`). Keep both checks.
- **Every AX round trip is time-bounded** (`messagingTimeout`, 2 s). Set it on the application element and again on the focused element; never on the system-wide element, where it would replace the process-wide default. A wedged target app must not stall the overlay's first pixel, because these calls run on the main actor.
- **Return nil, don't throw.** No AX permission, no focus, or an unsupported role all mean nil, and callers have placement fallbacks.
- Keep it small: read metadata here, put product logic in the caller.

## Verification

```bash
bash build.sh --no-open
bash run-tests.sh
```

Manual: focus a normal text editor, start and stop dictation, and confirm the island sits near that editor, not a stale target. Check a password field too: the island must not anchor to it.
