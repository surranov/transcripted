import AppKit
import SQLite3

/// Fork: Codex desktop's threads (`com.openai.codex`, the app named ChatGPT),
/// where a take goes to the thread it was dictated into while the user looks
/// elsewhere (`ChatThreadSender`).
///
/// Measured on 2026-10-15 (Codex 26.924, its CLI 0.158.0-alpha.2.1):
/// - Codex keeps its threads in `~/.codex/state_5.sqlite` (`threads`: `id`,
///   `name`, `title`, `archived`). The page of an open thread is titled with
///   its `name`; a thread not named yet shows its first message cut short
///   with "…", which names no thread here. Names repeat (a daily "Запиши
///   журнал за вчера"), so a name is sent to only when one thread has it.
/// - The CLI inside the app, `codex queue --thread <id> --message <text>`,
///   adds the message to the thread's queue (`~/.codex/queue_1.sqlite`), as
///   Codex's own box queues one while the agent works, and prints "Queued
///   message <id> for thread <id>.". The running app started it within 7
///   seconds on an idle thread opened earlier in its run but not shown
///   then; on a working one it waits for the agent's turn to end.
enum CodexThreads {
    static let bundleID = "com.openai.codex"

    /// Codex's home: `CODEX_HOME` isn't set for the app.
    static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    /// The threads named `name` that aren't archived (up to three: one more
    /// than tells it apart). Empty when Codex's state can't be read, or reads
    /// as another version wrote it.
    static func ids(named name: String, home: URL = home) -> [String] {
        let database = home.appendingPathComponent("state_5.sqlite")
        guard FileManager.default.fileExists(atPath: database.path) else { return [] }
        var connection: OpaquePointer?
        // Read-only, beside Codex writing it (it keeps a write-ahead log).
        guard sqlite3_open_v2(
            "file:\(database.path)?mode=ro", &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil
        ) == SQLITE_OK, let connection else {
            sqlite3_close(connection)
            return []
        }
        defer { sqlite3_close(connection) }
        sqlite3_busy_timeout(connection, 300)
        let query = "SELECT id FROM threads WHERE archived = 0 AND (name = ?1 OR (name IS NULL AND title = ?1)) LIMIT 3"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, query, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, name, -1, transient)
        var ids: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let id = sqlite3_column_text(statement, 0) { ids.append(String(cString: id)) }
        }
        return ids
    }

    /// The CLI inside the running app; nil while Codex isn't running (a
    /// queued message would wait unseen until the thread is opened).
    static func runningCLI() -> URL? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { !$0.isTerminated }),
              let bundle = app.bundleURL else { return nil }
        let cli = bundle.appendingPathComponent("Contents/Resources/codex-cli/bin/codex")
        return FileManager.default.isExecutableFile(atPath: cli.path) ? cli : nil
    }

    /// The CLI's arguments for one message. `--message=`: words starting
    /// with a dash stay words.
    static func queueArguments(threadID: String, text: String) -> [String] {
        ["queue", "--thread", threadID, "--message=\(text)"]
    }

    /// What one queue run came to: `status` nil when it timed out, so the
    /// message may be queued.
    static func queueResult(status: Int32?) -> ChatThreadSendResult {
        guard let status else { return .unconfirmed }
        return status == 0 ? .sent : .notSent(reason: "codex_queue_failed")
    }

    /// Queues `text` in thread `threadID`. Off the cooperative pool: it
    /// blocks a thread until the CLI ends.
    static func queue(_ text: String, threadID: String) async -> ChatThreadSendResult {
        guard let cli = runningCLI() else { return .notSent(reason: "codex_not_running") }
        // Only what the CLI needs: none of Transcripted's own variables.
        let environment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // It only writes the queue: a tenth of a second, measured.
                let status: Int32?
                do {
                    status = try BoundedProcessRunner.run(
                        executable: cli,
                        arguments: queueArguments(threadID: threadID, text: text),
                        timeout: 15,
                        environment: environment
                    ).status
                } catch BoundedProcessRunner.RunError.timedOut {
                    status = nil
                } catch {
                    // It didn't start: nothing was queued.
                    continuation.resume(returning: .notSent(reason: "codex_cli_failed_to_start"))
                    return
                }
                continuation.resume(returning: queueResult(status: status))
            }
        }
    }
}
