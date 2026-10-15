import Foundation

private typealias Page = ChatThreadPolicy.Page

// Codex: the page title names the thread; its id comes from Codex's state
// file, and the CLI queues the words (CodexThreads). Names and ids as Codex
// 26.924 wrote them on 2026-10-15.
func testCodexThreads() {
    let codex = CodexThreads.bundleID
    let address = "app://-/index.html"
    let testThread = "01a140d0-52d6-7ba0-afa5-52b8e060787c"

    runSuite("A Codex thread is sent to when exactly one thread has its name") {
        let page = [Page(url: address, title: "Подтвердить проверку Transcripted")]
        var asked: [String] = []
        let target = ChatThreadSendPolicy.sendTarget(bundleID: codex, pages: page) { name in
            asked.append(name)
            return [testThread]
        }
        assertEqual(target, .codex(threadID: testThread), "the one thread with that name")
        assertEqual(asked, ["Подтвердить проверку Transcripted"], "looked up by the page title")
        assertNil(
            ChatThreadSendPolicy.sendTarget(bundleID: codex, pages: [Page(url: address, title: "Запиши журнал за вчера")]) { _ in
                ["01a0a913-4450-7da3-91c4-4c2cc97edc40", "01a09f02-c17f-7683-a7e8-02da5f3ca785"]
            },
            "a daily thread's name, shared: which one is unknown"
        )
        assertNil(
            ChatThreadSendPolicy.sendTarget(bundleID: codex, pages: [Page(url: address, title: "Прочитай скил про стейджи…")]) { _ in [] },
            "a thread not named yet shows its first words cut short: no thread has that name"
        )
        assertNil(
            ChatThreadSendPolicy.sendTarget(bundleID: codex, pages: [Page(url: address, title: "ChatGPT")]) { _ in [testThread] },
            "a new chat: its first message goes the usual way"
        )
        assertNil(ChatThreadSendPolicy.sendTarget(bundleID: codex, pages: [Page(url: address, title: nil)]) { _ in [testThread] }, "no title read")
        assertNil(ChatThreadSendPolicy.sendTarget(bundleID: codex, pages: page), "Codex's state couldn't be read")
    }

    runSuite("Codex's state file gives the threads with a name, archived ones left out") {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("codex-home-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        assertEqual(CodexThreads.ids(named: "x", home: home), [], "no state file: nothing")
        let database = home.appendingPathComponent("state_5.sqlite").path
        let sql = """
            CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT NOT NULL, archived INTEGER NOT NULL DEFAULT 0, name TEXT);
            INSERT INTO threads VALUES ('a', 'Посмотри, что есть в этом проекте', 0, 'Сориентироваться в проекте');
            INSERT INTO threads VALUES ('b', 'Запиши журнал', 0, 'Запиши журнал за вчера');
            INSERT INTO threads VALUES ('c', 'Запиши журнал', 1, 'Запиши журнал за вчера');
            INSERT INTO threads VALUES ('d', 'Reply with the single word ok', 0, NULL);
            INSERT INTO threads VALUES ('e', 'Запиши журнал', 0, 'Запиши журнал за вчера');
            """
        let created = Process()
        created.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        created.arguments = [database, sql]
        try? created.run()
        created.waitUntilExit()
        assertEqual(CodexThreads.ids(named: "Сориентироваться в проекте", home: home), ["a"], "by its name, not its first message")
        assertEqual(Set(CodexThreads.ids(named: "Запиши журнал за вчера", home: home)), ["b", "e"], "two live threads share it; the archived one doesn't count")
        assertEqual(CodexThreads.ids(named: "Reply with the single word ok", home: home), ["d"], "a thread with no name goes by its first message")
        assertEqual(CodexThreads.ids(named: "Посмотри, что есть в этом проекте", home: home), [], "a named thread's first message isn't its name")
        assertEqual(CodexThreads.ids(named: "x' OR '1'='1", home: home), [], "a name is a value, never SQL")
    }

    runSuite("Codex's CLI queues the words; only a run that ended badly counts as not sent") {
        assertEqual(
            CodexThreads.queueArguments(threadID: testThread, text: "-v поправь"),
            ["queue", "--thread", testThread, "--message=-v поправь"],
            "words starting with a dash stay the message"
        )
        assertEqual(CodexThreads.queueResult(status: 0), .sent, "queued: Codex starts it")
        assertEqual(CodexThreads.queueResult(status: 1), .notSent(reason: "codex_queue_failed"), "refused (no such thread): the usual way")
        assertEqual(CodexThreads.queueResult(status: nil), .unconfirmed, "timed out: it may be queued, so never again another way")
    }
}
