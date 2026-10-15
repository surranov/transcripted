import AppKit

/// Fork: a new chat a take's own send started, and the thread the app moved
/// it to (T3 Code: `#/draft/<id>` becomes `#/<environment>/<thread>`). A take
/// queued behind it on the new chat still belongs there.
struct ChatThreadMove {
    let pid: pid_t
    let from: String
    /// A take started after this send isn't queued behind it: a new chat's
    /// page (claude.ai/new, Codex's start page) looks the same every time.
    let sentAt: Date
    /// The first other identity the app showed right after the send; nil
    /// when it didn't move.
    let to: Task<String?, Never>
}

/// Fork: the chat thread guard (`ChatThreadPolicy`). A take dictated into an
/// AI chat (T3 Code, Codex, Claude, or a chat site in a browser) is pasted,
/// send pressed, only while that app still shows the thread the take was
/// dictated into. After a switch to another thread or tab the island says
/// "Not pasted" with the words and its Paste button, and they're on the
/// clipboard; a send after a paste that landed says why it wasn't pressed.
///
/// It runs with Anchored paste on or off. Anchored paste's own background
/// routes keep to the anchored thread through `AnchoredPasteContext`.
extension DictationSessionController {
    /// How long the app gets to move a new chat to its thread after a send.
    static let chatThreadMoveWait: TimeInterval = 2

    /// Reads the chat the take starts in, off the main actor; the paste
    /// awaits it.
    func beginChatThreadCapture(sourceApp: NSRunningApplication?) {
        guard let app = sourceApp ?? NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else {
            chatThreadCapture = nil
            return
        }
        chatThreadCapture = Task { @MainActor in
            let thread = await ChatThreadReader.chatThread(in: app)
            // Fork: a thread its app's server can take (`+ChatThreadSend.swift`)
            // gets that server's session ready while the user speaks, if this
            // app's takes send at all.
            if let target = thread?.sendTarget, DictationSendSettings.behavior(
                for: thread?.bundleID,
                defaultBehavior: DictationSendSettings.defaultBehavior(),
                overrides: DictationSendSettings.overrides()
            ).behavior != .dontSend {
                Task.detached(priority: .utility) { _ = await ChatThreadSender.prepare(target) }
            }
            return thread
        }
    }

    /// The chat the take was dictated into, once read; nil when it isn't one.
    func chatThreadAtStart() async -> ChatThread? {
        await chatThreadCapture?.value ?? nil
    }

    /// What the regular paste does instead when the app in front is the one
    /// the take was dictated into and it shows another chat thread now: the
    /// words go on the clipboard. Nil when the paste may go ahead (no chat,
    /// another app in front, the same thread).
    func pasteOutcomeIfChatChanged(_ text: String) async -> DictationPasteOutcome? {
        guard let thread = await chatThreadAtStart(),
              await chatChanged(thread, in: NSWorkspace.shared.frontmostApplication?.processIdentifier) else { return nil }
        // Decided as for a paste, so telemetry counts the send it held back.
        autoSendRequestDecision = autoSendDecision(for: text, bundleID: thread.bundleID)
        return copyForChangedChat(text, thread: thread)
    }

    /// The words on the clipboard instead of in another thread of `thread`'s app.
    func copyForChangedChat(_ text: String, thread: ChatThread) -> DictationPasteOutcome {
        appState?.logger.log("DICTATION | \(thread.appName) shows another chat now; not pasting")
        return textPaster.copyForChangedChat(
            text,
            message: "You switched to another chat in \(thread.appName), so it wasn't pasted. It's on your clipboard — press ⌘V to paste it."
        )
    }

    /// Whether the app `pid` is the one `thread` was dictated into and shows
    /// another thread now (in `window`, an anchored take's, or its focused
    /// one). A new chat that this app's own send moved to its thread is the
    /// same chat.
    func chatChanged(_ thread: ChatThread?, in pid: pid_t?, window: AXUIElement? = nil) async -> Bool {
        guard let thread, thread.pid == pid else { return false }
        // A move under way is waited for first: the words go into the
        // thread the new chat became, not the draft it is leaving (a queued
        // take pastes about 50 ms after the earlier one's send).
        var sameChat: Set<String> = [thread.identity]
        for move in chatThreadMoves
        where move.pid == thread.pid && move.from == thread.identity && move.sentAt >= thread.capturedAt {
            if let moved = await move.to.value { sameChat.insert(moved) }
        }
        guard let current = await ChatThreadReader.currentIdentity(of: thread, window: window) else { return true }
        return !sameChat.contains(current)
    }

    /// Why send can't be pressed in the app `pid`: it shows another thread
    /// of the chat the take was dictated into. Nil when it can.
    func chatChangedBlocker(sendIn pid: pid_t?, window: AXUIElement? = nil) async -> DictationAutoSendFailure? {
        await chatChanged(await chatThreadAtStart(), in: pid, window: window) ? .chatChanged : nil
    }

    /// After send went out with a new chat's first message in `pid`, remembers the
    /// thread the app moves it to, so a take queued on that new chat still
    /// pastes there. Only the first move within `chatThreadMoveWait` counts.
    func followNewChat(_ thread: ChatThread?, afterSendIn pid: pid_t?) {
        guard let thread, thread.isNewChat, thread.pid == pid else { return }
        let deadline = Date().addingTimeInterval(Self.chatThreadMoveWait)
        let moved = Task { @MainActor () -> String? in
            while Date() < deadline {
                if let now = await ChatThreadReader.identity(of: thread), now != thread.identity { return now }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            return nil
        }
        chatThreadMoves.append(ChatThreadMove(pid: thread.pid, from: thread.identity, sentAt: Date(), to: moved))
        if chatThreadMoves.count > 4 { chatThreadMoves.removeFirst(chatThreadMoves.count - 4) }
    }
}
