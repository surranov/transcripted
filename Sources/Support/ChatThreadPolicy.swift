import Foundation

/// Fork: the chat thread guard. A take dictated into an AI chat belongs to
/// the thread it was dictated into. If the user switches that app to another
/// thread or tab while the take is processed, the words aren't pasted there
/// and send isn't pressed there: the island says "Not pasted", the words go
/// on the clipboard, and its Paste button pastes them where the user clicks.
///
/// Measured on 2026-10-14 (macOS 26) through Accessibility, the page
/// (`AXWebArea`) in the app's focused window names the open thread:
/// - T3 Code: its address, `t3code://app/#/<environment>/<thread>` (a thread not
///   sent yet is `#/draft/<id>`). Its window and page titles never change, and
///   one composer can serve every thread, so a focused field proves nothing.
/// - Codex (`com.openai.codex`, the app is named ChatGPT): the address is
///   always `app://-/index.html` (its routes, `/local/:conversationId`, live in
///   memory); the page title is the open thread's name.
/// - Claude: a `file://` shell page wraps a claude.ai page whose address
///   names the chat.
/// - Chat sites in any browser name the thread in the address path:
///   claude.ai/chat/<id>, chatgpt.com/c/<id>, grok.com/c/<id>,
///   gemini.google.com/app/<id>. A switch to another tab shows another page.
///
/// `ChatThreadReader` (Sources/Accessibility) reads the pages; this file
/// holds the decisions.
enum ChatThreadPolicy {
    /// What Accessibility reads from one page in the focused window.
    struct Page: Equatable {
        let url: String?
        let title: String?
    }

    /// Desktop AI chat apps: every take dictated into them is guarded.
    static let chatAppBundleIDs: Set<String> = [
        "com.t3tools.t3code",
        "com.anthropic.claudefordesktop",
        "com.openai.codex",
    ]

    /// Chat apps whose page address never changes: the page title is what
    /// names the thread.
    static let titleNamedThreadBundleIDs: Set<String> = [
        "com.openai.codex",
    ]

    /// Browsers, where a chat site's page is looked for. Any other app (not
    /// a chat app either) is never read: no Accessibility work in Xcode,
    /// Notes or Slack for a guard that can't apply there.
    static let browserBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.canary",
        "org.chromium.Chromium",
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "company.thebrowser.Browser",
        "company.thebrowser.dia",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "org.mozilla.firefox",
        "app.zen-browser.zen",
        "ai.perplexity.comet",
        "com.openai.atlas",
    ]

    /// AI chat sites, in a browser or an app's web view; subdomains count.
    static let chatSiteHosts: Set<String> = [
        "claude.ai",
        "chatgpt.com",
        "chat.openai.com",
        "grok.com",
        "kimi.com",
        "kimi.moonshot.cn",
        "gemini.google.com",
        "aistudio.google.com",
        "chat.deepseek.com",
        "perplexity.ai",
        "chat.mistral.ai",
        "chat.qwen.ai",
        "copilot.microsoft.com",
        "poe.com",
        "t3.chat",
        "meta.ai",
    ]

    /// Apps whose sidebar lists threads in a form the marker can find:
    /// there a take's marker sits on its thread's row while another thread
    /// is open (`AnchorMarkerController`).
    static let sidebarBundleIDs: Set<String> = [
        "com.t3tools.t3code",
        "com.openai.codex",
        "com.anthropic.claudefordesktop",
    ]

    /// The open thread's name as its sidebar row shows it, for an app whose
    /// sidebar doesn't mark the open thread's row: Claude marks it among its
    /// chats, not among its Code sessions (measured 2026-10-15, 2.42304.0).
    /// Its claude.ai page is titled "<name> - Claude Code" for a session and
    /// "<name> - Claude" for a chat. Nil for another app, a new chat, or a
    /// page with no such title.
    static func openThreadName(bundleID: String?, pages: [Page]) -> String? {
        guard bundleID == "com.anthropic.claudefordesktop", !isNewChat(bundleID: bundleID, pages: pages) else { return nil }
        let titles = pages.compactMap { page -> String? in
            guard chatSiteURL(page.url) != nil, let title = page.title else { return nil }
            for suffix in [" - Claude Code", " - Claude"] where title.hasSuffix(suffix) {
                let name = String(title.dropLast(suffix.count))
                return name.isEmpty ? nil : name
            }
            return nil
        }
        return titles.count == 1 ? titles[0] : nil
    }

    /// Which of the sidebar's rows (`labels`, each row's title and project,
    /// `ChatSidebarReader`) is the thread labeled `label`. Two
    /// threads may share a title: then only the row remembered from when the
    /// thread was open (`remembered`, the same element still) counts. A row
    /// remembered under another label now may be another thread's (a list
    /// reuses its rows), so it doesn't count alone.
    static func sidebarRow(labeled label: String, in labels: [String], remembered: Int? = nil) -> Int? {
        let matches = labels.indices.filter { labels[$0] == label }
        if matches.count == 1 { return matches[0] }
        if let remembered, matches.contains(remembered) { return remembered }
        return nil
    }

    /// Whether the app's pages are read at all when a take starts.
    static func readsPages(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return chatAppBundleIDs.contains(bundleID) || browserBundleIDs.contains(bundleID)
    }

    /// Whether a take started on these pages is guarded: a chat app, or a
    /// page of a chat site.
    static func isChat(bundleID: String?, pages: [Page]) -> Bool {
        if let bundleID, chatAppBundleIDs.contains(bundleID) { return true }
        return pages.contains { chatSiteURL($0.url) != nil }
    }

    /// Whether the pages show a chat not started yet, which its first message
    /// moves to a thread of its own: T3 Code's `#/draft/<id>`, Codex's page
    /// titled after the app, a chat site's start page (claude.ai/new,
    /// chatgpt.com/, gemini.google.com/app, Claude's Code start page).
    static func isNewChat(bundleID: String?, pages: [Page]) -> Bool {
        pages.contains { page in
            if bundleID.map(titleNamedThreadBundleIDs.contains) ?? false {
                return page.title == "ChatGPT" || page.title == "Codex"
            }
            if let url = page.url, url.hasPrefix("t3code:") {
                return URLComponents(string: url)?.fragment?.hasPrefix("/draft/") ?? false
            }
            guard let components = chatSiteURL(page.url) else { return false }
            let path = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
            return ["", "/new", "/app", "/epitaxy"].contains(path)
        }
    }

    private static func chatSiteURL(_ url: String?) -> URLComponents? {
        guard let url, let components = URLComponents(string: url),
              let host = components.host?.lowercased(),
              chatSiteHosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) else { return nil }
        return components
    }

    /// The open thread, to compare at the start and before the paste or
    /// send: each page's address without its query (launch flags such as
    /// Claude's `?coldLaunch=1`, models, tracking; no chat here keeps its
    /// thread there), plus the page title in an app that keeps its address
    /// fixed. Nil when no page could be read.
    static func threadIdentity(bundleID: String?, pages: [Page]) -> String? {
        guard !pages.isEmpty else { return nil }
        let titleNamesThread = bundleID.map(titleNamedThreadBundleIDs.contains) ?? false
        return pages.map { page in
            let address = page.url.map(addressWithoutQuery) ?? ""
            return titleNamesThread ? "\(address) \(page.title ?? "")" : address
        }.joined(separator: "\n")
    }

    /// Whether the thread changed since the start. A page that can't be read
    /// now counts as changed: the app is in front but nothing shows the
    /// thread is still the same, and a wrong guess sends words to another
    /// conversation.
    static func threadChanged(from startIdentity: String, to currentIdentity: String?) -> Bool {
        currentIdentity != startIdentity
    }

    /// The address without its query, also one inside a hash route
    /// (`#/thread?panel=diff`): a panel opened in the same thread isn't
    /// another thread.
    private static func addressWithoutQuery(_ url: String) -> String {
        guard var components = URLComponents(string: url) else { return url }
        components.query = nil
        if let fragment = components.fragment, let mark = fragment.firstIndex(of: "?") {
            components.fragment = String(fragment[..<mark])
        }
        return components.string ?? url
    }
}
