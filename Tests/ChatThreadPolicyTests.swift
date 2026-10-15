import Foundation

// The chat thread guard (ChatThreadPolicy): which takes are guarded, and
// whether the thread they were dictated into is still the one on screen.
// Pages are given as Accessibility reports them (measured 2026-10-14); the
// reads themselves need a real app.

private typealias Page = ChatThreadPolicy.Page

private let t3 = "com.t3tools.t3code"
private let codex = "com.openai.codex"
private let claude = "com.anthropic.claudefordesktop"
private let chrome = "com.google.Chrome"

private func identity(_ bundleID: String?, _ pages: [Page]) -> String? {
    ChatThreadPolicy.threadIdentity(bundleID: bundleID, pages: pages)
}

private func changed(_ bundleID: String?, from start: [Page], to now: [Page]) -> Bool {
    guard let startIdentity = identity(bundleID, start) else { return false }
    return ChatThreadPolicy.threadChanged(from: startIdentity, to: identity(bundleID, now))
}

func testChatThreadPolicy() {
    runSuite("A take is guarded in a desktop AI chat app, or on an AI chat site in any app") {
        assertTrue(ChatThreadPolicy.isChat(bundleID: t3, pages: []), "T3 Code is a chat app by its bundle ID")
        assertTrue(ChatThreadPolicy.isChat(bundleID: codex, pages: []), "Codex")
        assertTrue(ChatThreadPolicy.isChat(bundleID: claude, pages: []), "Claude")
        assertTrue(ChatThreadPolicy.isChat(bundleID: chrome, pages: [Page(url: "https://chatgpt.com/c/abc", title: "ChatGPT")]), "ChatGPT in a browser")
        assertTrue(ChatThreadPolicy.isChat(bundleID: chrome, pages: [Page(url: "https://grok.com/c/1", title: nil)]), "Grok in a browser")
        assertTrue(ChatThreadPolicy.isChat(bundleID: chrome, pages: [Page(url: "https://www.kimi.com/chat/1", title: nil)]), "a subdomain of a chat site")
        assertTrue(ChatThreadPolicy.isChat(bundleID: chrome, pages: [Page(url: "https://GEMINI.google.com/app/1", title: nil)]), "hosts match in any case")
        assertFalse(ChatThreadPolicy.isChat(bundleID: chrome, pages: [Page(url: "https://mail.google.com/mail/u/0", title: "Inbox")]), "an ordinary site isn't guarded")
        assertFalse(ChatThreadPolicy.isChat(bundleID: chrome, pages: [Page(url: "https://notclaude.ai/chat/1", title: nil)]), "a host that only ends in a chat site's name isn't one")
        assertFalse(ChatThreadPolicy.isChat(bundleID: "com.apple.Notes", pages: []), "a native app with no page isn't guarded")
        assertFalse(ChatThreadPolicy.isChat(bundleID: nil, pages: [Page(url: nil, title: "Untitled")]), "an unreadable page isn't a chat")
    }

    runSuite("Only chat apps and browsers are read when a take starts") {
        assertTrue(ChatThreadPolicy.readsPages(bundleID: t3), "a chat app")
        assertTrue(ChatThreadPolicy.readsPages(bundleID: chrome), "a browser, where a chat site may be open")
        assertTrue(ChatThreadPolicy.readsPages(bundleID: "com.apple.Safari"), "Safari")
        assertFalse(ChatThreadPolicy.readsPages(bundleID: "com.apple.dt.Xcode"), "any other app costs no Accessibility work")
        assertFalse(ChatThreadPolicy.readsPages(bundleID: nil), "an unknown app")
    }

    runSuite("A new chat is told apart from a thread, so the thread its first message makes isn't another chat") {
        assertTrue(ChatThreadPolicy.isNewChat(bundleID: t3, pages: [Page(url: "t3code://app/#/draft/9be71f5c", title: nil)]), "a T3 Code draft")
        assertFalse(ChatThreadPolicy.isNewChat(bundleID: t3, pages: [Page(url: "t3code://app/#/c25d1cbe/88107faf", title: nil)]), "a T3 Code thread")
        assertTrue(ChatThreadPolicy.isNewChat(bundleID: codex, pages: [Page(url: "app://-/index.html", title: "ChatGPT")]), "Codex's start page")
        assertFalse(ChatThreadPolicy.isNewChat(bundleID: codex, pages: [Page(url: "app://-/index.html", title: "Fix pagination")]), "a Codex thread")
        assertTrue(ChatThreadPolicy.isNewChat(bundleID: chrome, pages: [Page(url: "https://claude.ai/new", title: nil)]), "claude.ai/new")
        assertTrue(ChatThreadPolicy.isNewChat(bundleID: chrome, pages: [Page(url: "https://chatgpt.com/", title: nil)]), "chatgpt.com's start page")
        assertTrue(ChatThreadPolicy.isNewChat(bundleID: chrome, pages: [Page(url: "https://gemini.google.com/app", title: nil)]), "Gemini's start page")
        assertFalse(ChatThreadPolicy.isNewChat(bundleID: chrome, pages: [Page(url: "https://chatgpt.com/c/6aca07c3", title: nil)]), "a ChatGPT conversation")
        assertFalse(ChatThreadPolicy.isNewChat(bundleID: chrome, pages: [Page(url: "https://mail.google.com/", title: nil)]), "not a chat site")
    }

    runSuite("Switching T3 Code to another thread changes the thread; staying doesn't") {
        let threadA = [Page(url: "t3code://app/#/c25d1cbe/88107faf", title: "T3 Code (Nightly)")]
        let threadB = [Page(url: "t3code://app/#/c25d1cbe/f583c7a2", title: "T3 Code (Nightly)")]
        let draft = [Page(url: "t3code://app/#/draft/9be71f5c", title: "T3 Code (Nightly)")]
        assertTrue(changed(t3, from: threadA, to: threadB), "the thread lives in the address fragment")
        assertTrue(changed(t3, from: threadA, to: draft), "a new thread's draft is another thread")
        assertFalse(changed(t3, from: threadA, to: threadA), "the same thread")
        let panel = [Page(url: "t3code://app/#/c25d1cbe/88107faf?diff=1", title: "T3 Code (Nightly)")]
        assertFalse(changed(t3, from: threadA, to: panel), "a panel opened in the same thread: a query inside the hash route")
    }

    runSuite("Codex keeps its address, so its page title tells threads apart") {
        let home = [Page(url: "app://-/index.html", title: "ChatGPT")]
        let threadA = [Page(url: "app://-/index.html", title: "Fix the multipin pagination")]
        let threadB = [Page(url: "app://-/index.html", title: "Investigate bug CD-273310")]
        assertTrue(changed(codex, from: threadA, to: threadB), "another thread, same address")
        assertTrue(changed(codex, from: home, to: threadA), "from a new chat into a thread")
        assertFalse(changed(codex, from: threadA, to: threadA), "the same thread")
    }

    runSuite("A chat site's thread is its address: a retitled tab is the same chat, another tab isn't") {
        let chat = [Page(url: "https://chatgpt.com/c/6aca07c3", title: "ChatGPT")]
        let renamed = [Page(url: "https://chatgpt.com/c/6aca07c3", title: "Pagination plan")]
        let otherChat = [Page(url: "https://chatgpt.com/c/6ac5ea0a", title: "ChatGPT")]
        let mail = [Page(url: "https://mail.google.com/mail/u/0", title: "Inbox")]
        assertFalse(changed(chrome, from: chat, to: renamed), "a chat site retitles its tab after the first reply")
        assertTrue(changed(chrome, from: chat, to: otherChat), "another conversation")
        assertTrue(changed(chrome, from: chat, to: mail), "another tab that isn't a chat")
    }

    runSuite("Launch flags in the query don't make another thread") {
        let launched = [
            Page(url: "file:///Applications/Claude.app/Contents/Resources/app.asar/.vite/renderer/main_window/index.html", title: nil),
            Page(url: "https://claude.ai/epitaxy?coldLaunch=1", title: "Claude"),
        ]
        let settled = [
            Page(url: "file:///Applications/Claude.app/Contents/Resources/app.asar/.vite/renderer/main_window/index.html", title: nil),
            Page(url: "https://claude.ai/epitaxy", title: "Claude"),
        ]
        let otherChat = [
            Page(url: "file:///Applications/Claude.app/Contents/Resources/app.asar/.vite/renderer/main_window/index.html", title: nil),
            Page(url: "https://claude.ai/chat/f8c4b6bf", title: "Claude"),
        ]
        assertFalse(changed(claude, from: launched, to: settled), "Claude's ?coldLaunch=1 is a launch flag")
        assertTrue(changed(claude, from: settled, to: otherChat), "the chat page inside Claude's shell changed")
    }

    runSuite("A take's flag finds its thread's sidebar row by the row's label, only when it can't be another's") {
        assertTrue(ChatThreadPolicy.sidebarBundleIDs.contains(t3), "T3 Code's sidebar is followed")
        assertTrue(ChatThreadPolicy.sidebarBundleIDs.contains(codex), "Codex's too")
        assertTrue(ChatThreadPolicy.sidebarBundleIDs.contains("com.anthropic.claudefordesktop"), "and Claude's")
        assertFalse(ChatThreadPolicy.sidebarBundleIDs.contains("com.google.Chrome"), "not a browser's")
        let labels = ["Fix pagination, web", "Review ADR, No project", "Fix pagination, web", "GVR, search"]
        assertEqual(ChatThreadPolicy.sidebarRow(labeled: "GVR, search", in: labels), 3, "one row with that label")
        assertNil(ChatThreadPolicy.sidebarRow(labeled: "Fix pagination, web", in: labels), "two threads share it: not a guess")
        assertEqual(
            ChatThreadPolicy.sidebarRow(labeled: "Fix pagination, web", in: labels, remembered: 2), 2,
            "the very row seen while the thread was open settles it"
        )
        assertNil(
            ChatThreadPolicy.sidebarRow(labeled: "GVR, search", in: labels.filter { $0 != "GVR, search" }, remembered: 1),
            "a remembered row now labeled otherwise may be another thread's"
        )
        assertNil(ChatThreadPolicy.sidebarRow(labeled: "Gone, web", in: labels), "scrolled out of the list's rendered rows")
    }

    runSuite("In Codex a thread listed under its project and in Recent keeps to the project's row") {
        // Codex's sidebar, read 2026-10-15: "Name\nProject" under Projects,
        // the name alone under Recent; the open thread's project row is current.
        let labels = [
            "Исследовать баг CD-273310\ndailyrent-search-frontend",
            "Запиши журнал за вчера\nObsidian",
            "Запиши журнал за вчера\nObsidian-old",
            "Установить watermark remover hook",
            "Запиши журнал за вчера",
            "Исследовать баг CD-273310",
        ]
        assertEqual(
            ChatThreadPolicy.sidebarRow(labeled: "Исследовать баг CD-273310\ndailyrent-search-frontend", in: labels), 0,
            "its Recent row doesn't make the project's row ambiguous"
        )
        assertEqual(
            ChatThreadPolicy.sidebarRow(labeled: "Запиши журнал за вчера\nObsidian", in: labels), 1,
            "one name in two projects: two threads, told by their project"
        )
        assertEqual(
            ChatThreadPolicy.sidebarRow(labeled: "Установить watermark remover hook", in: labels), 3,
            "a thread with no project: its Recent row"
        )
        assertNil(
            ChatThreadPolicy.sidebarRow(labeled: "Исследовать баг CD-273310\ndailyrent-search-frontend", in: Array(labels[3...])),
            "Projects collapsed: no project row, and the bare name in Recent isn't taken for it"
        )
    }

    runSuite("Claude's open page names the session or chat whose sidebar row it is") {
        // Claude 2.42304.0, read 2026-10-15: its shell page and its claude.ai page.
        let claudeApp = "com.anthropic.claudefordesktop"
        let shell = Page(url: "file:///Applications/Claude.app/Contents/Resources/app.asar/.vite/renderer/main_window/index.html", title: "")
        func name(_ url: String, _ title: String?) -> String? {
            ChatThreadPolicy.openThreadName(bundleID: claudeApp, pages: [shell, Page(url: url, title: title)])
        }
        assertEqual(
            name("https://claude.ai/epitaxy/local_46cdd4a8-9cf0-4bb8-9a90-a122549feba9", "Отключение атрибуции в настройках - Claude Code"),
            "Отключение атрибуции в настройках",
            "a Code session"
        )
        assertEqual(name("https://claude.ai/chat/8f0c41b4-1e1e-44a1-855d-b6e288fd606b", "Greeting - Claude"), "Greeting", "a chat")
        assertEqual(
            name("https://claude.ai/chat/8f0c41b4", "Проверка - Claude Code - Claude"),
            "Проверка - Claude Code",
            "only the app's own suffix comes off"
        )
        assertNil(name("https://claude.ai/epitaxy", "Claude"), "Code's start page: no session yet")
        assertNil(name("https://claude.ai/new", "Новая задача - Claude"), "a new chat")
        assertNil(name("https://claude.ai/chat/8f0c41b4", nil), "no title read")
        assertNil(name("https://claude.ai/chat/8f0c41b4", " - Claude"), "a title with no name")
        assertNil(
            ChatThreadPolicy.openThreadName(bundleID: codex, pages: [Page(url: "app://-/index.html", title: "Подтвердить проверку Transcripted")]),
            "Codex marks its rows itself"
        )
    }

    runSuite("A chat app whose page can't be read now counts as another thread") {
        assertTrue(ChatThreadPolicy.threadChanged(from: "t3code://app/#/a/b", to: nil), "nothing shows it's still the same thread")
        assertEqual(identity(t3, []), nil, "no page read: no thread to compare, so the take isn't guarded")
    }

    runSuite("A take kept out of another chat says so") {
        assertEqual(DictationAutoSendFailure.chatChanged.message, "Pasted, but didn't press send: you switched to another chat.", "Enter after a paste that landed")
        assertEqual(DictationAutoSendFailure.chatChanged.blockReason, .targetChanged, "telemetry counts it as a target change")
        assertEqual(TextPasteCopyReason.chatChanged.notPastedHint, "You switched to another chat. Paste it where it goes.", "the line under Not pasted")
        assertEqual(TextPasteCopyReason.focusChanged.notPastedHint, nil, "other reasons keep the plain notice")
        assertEqual(
            TextPasteOutcome.copied("m", reason: .chatChanged).autoSendBlockReason, .targetChanged,
            "a take that wasn't pasted never presses Enter, counted as a target change"
        )
    }
}
