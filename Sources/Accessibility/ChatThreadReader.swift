import AppKit
import ApplicationServices

/// Fork: the AI chat a take was dictated into (`ChatThreadPolicy`).
struct ChatThread: Equatable {
    let pid: pid_t
    let bundleID: String?
    let appName: String
    /// `ChatThreadPolicy.threadIdentity` at the start. Holds page addresses
    /// and titles: never logged or sent anywhere.
    let identity: String
    /// A chat not started yet (`ChatThreadPolicy.isNewChat`).
    let isNewChat: Bool
    /// When the take started: only a send after it may move its new chat
    /// (`ChatThreadMove.sentAt`).
    let capturedAt: Date
    /// The thread as its app's server names it, where the take is sent when
    /// the user isn't looking at it (`ChatThreadSendPolicy`); nil when the
    /// app has no server to send through or the chat isn't started.
    var sendTarget: ChatThreadSendTarget? = nil
}

/// Fork: reads which chat thread an app shows, from the pages (`AXWebArea`)
/// in one of its windows. Reads run off the main actor: a busy app costs the
/// take a moment, never a frame.
@MainActor
enum ChatThreadReader {
    nonisolated private static let messagingTimeout: Float = 0.5
    /// The pages sit under a few wrapper groups (7 or 8 deep in T3 Code,
    /// Codex, Claude and Chrome; Chrome's tab strip and toolbar take about
    /// 100 elements with a few tabs open); nothing inside a page is searched.
    nonisolated private static let maxDepth = 12
    nonisolated private static let maxElements = 1_000
    /// A hung app answers each call only at its timeout; the whole read
    /// stops here with what it found (nothing found reads as another thread).
    nonisolated private static let readDeadline: TimeInterval = 1.5
    /// A busy Electron app can miss one Accessibility read; a change is read
    /// twice, this far apart, before it counts.
    private static let rereadDelay: UInt64 = 150_000_000

    /// An AX element handed to a detached read. AX calls are thread-safe.
    private struct Window: @unchecked Sendable {
        let element: AXUIElement
    }

    /// The chat `app` shows in its focused window when a take starts; nil
    /// when it isn't an AI chat or its pages can't be read (the take then
    /// isn't guarded, as before). Only chat apps and browsers are read.
    static func chatThread(in app: NSRunningApplication) async -> ChatThread? {
        let pid = app.processIdentifier
        let bundleID = app.bundleIdentifier
        guard ChatThreadPolicy.readsPages(bundleID: bundleID), AXIsProcessTrusted(),
              pid > 0, pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        var pages = await pages(pid: pid, window: nil)
        if pages.isEmpty {
            // Electron apps build their web accessibility tree only when asked.
            await Task.detached(priority: .userInitiated) {
                let appElement = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
                AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            }.value
            try? await Task.sleep(nanoseconds: 120_000_000)
            pages = await self.pages(pid: pid, window: nil)
        }
        guard ChatThreadPolicy.isChat(bundleID: bundleID, pages: pages),
              let identity = ChatThreadPolicy.threadIdentity(bundleID: bundleID, pages: pages) else { return nil }
        return ChatThread(
            pid: pid,
            bundleID: bundleID,
            appName: app.localizedName ?? "the app",
            identity: identity,
            isNewChat: ChatThreadPolicy.isNewChat(bundleID: bundleID, pages: pages),
            capturedAt: Date(),
            sendTarget: ChatThreadSendPolicy.sendTarget(bundleID: bundleID, pages: pages)
        )
    }

    /// The thread's app's identity now: in `window` (an anchored take's), or
    /// in its focused window. A change is read twice before it counts.
    static func currentIdentity(of thread: ChatThread, window: AXUIElement? = nil) async -> String? {
        let first = await identity(of: thread, window: window)
        guard ChatThreadPolicy.threadChanged(from: thread.identity, to: first) else { return first }
        try? await Task.sleep(nanoseconds: rereadDelay)
        return await identity(of: thread, window: window)
    }

    /// The identity once, unconfirmed.
    static func identity(of thread: ChatThread, window: AXUIElement? = nil) async -> String? {
        ChatThreadPolicy.threadIdentity(bundleID: thread.bundleID, pages: await pages(pid: thread.pid, window: window))
    }

    /// The thread `window` of app `pid` shows, read on the caller's thread:
    /// for a read already off the main actor (the Anchored paste markers).
    nonisolated static func identityNow(pid: pid_t, bundleID: String?, window: AXUIElement) -> String? {
        ChatThreadPolicy.threadIdentity(bundleID: bundleID, pages: readPages(pid: pid, window: window))
    }

    private static func pages(pid: pid_t, window: AXUIElement?) async -> [ChatThreadPolicy.Page] {
        let window = window.map(Window.init)
        return await Task.detached(priority: .userInitiated) { readPages(pid: pid, window: window?.element) }.value
    }

    /// Every page in the window, breadth first, without looking inside
    /// them. Claude shows two: its `file://` shell and the claude.ai page in
    /// it.
    nonisolated private static func readPages(pid: pid_t, window: AXUIElement?) -> [ChatThreadPolicy.Page] {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
        // An anchored take's window is shared with Anchored paste: its
        // timeout is left as Anchored paste set it.
        let root: AXUIElement
        if let window {
            root = window
        } else {
            guard let focused = element(of: appElement, kAXFocusedWindowAttribute) else { return [] }
            AXUIElementSetMessagingTimeout(focused, messagingTimeout)
            root = focused
        }
        var pages: [ChatThreadPolicy.Page] = []
        var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        var index = 0
        let deadline = Date().addingTimeInterval(readDeadline)
        while index < queue.count, index < maxElements, Date() < deadline {
            let (node, depth) = queue[index]
            if index > 0 { AXUIElementSetMessagingTimeout(node, messagingTimeout) }
            index += 1
            if string(of: node, kAXRoleAttribute) == "AXWebArea" {
                pages.append(ChatThreadPolicy.Page(url: url(of: node), title: string(of: node, kAXTitleAttribute)))
                continue
            }
            guard depth < maxDepth else { continue }
            var children: AnyObject?
            guard AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &children) == .success,
                  let children = children as? [AXUIElement] else { continue }
            queue += children.map { ($0, depth + 1) }
        }
        return pages
    }

    nonisolated private static func url(of element: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value) == .success, let value else { return nil }
        if let url = value as? URL { return url.absoluteString }
        return value as? String
    }

    nonisolated private static func element(of element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    nonisolated private static func string(of element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
