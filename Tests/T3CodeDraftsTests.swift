import Foundation

// A take dictated into a T3 Code new chat starts its thread while the user is
// away (T3CodeDrafts, ChromiumLocalStorage). The stored shapes and the launch
// are as T3 Code (Nightly) 0.1.1-nightly.20261016.3190 keeps and sends them;
// the files here are built byte by byte in Chromium's LevelDB format.

private let draftKey = "t3code:composer-drafts:v1"
private let origin = "t3code://app"
private let draftID = "9be71f5c-0d5e-4bc1-a3a3-1f4a1d1b6a01"
private let environment = "c25d1cbe-e9bc-406f-aed2-9d76f720525a"
private let project = "722a0064-5563-4ca9-855d-95c7eb1646a4"
private let threadOfDraft = "dc86dc8e-e1a5-45d0-bbd0-fece11e49e8e"

// MARK: - LevelDB bytes

private func varint(_ value: Int) -> [UInt8] {
    var value = UInt64(value)
    var bytes: [UInt8] = []
    while value >= 0x80 {
        bytes.append(UInt8(value & 0x7f) | 0x80)
        value >>= 7
    }
    return bytes + [UInt8(value)]
}

private func le(_ value: UInt64, _ count: Int) -> [UInt8] {
    (0..<count).map { UInt8((value >> (8 * UInt64($0))) & 0xff) }
}

private func mapKey(_ key: String = draftKey) -> [UInt8] {
    Array("_\(origin)".utf8) + [0] + [UInt8](ChromiumLocalStorage.encodedKey(key))
}

/// A stored value as Chromium writes it: Latin-1 when it fits, else UTF-16LE.
private func stored(_ value: String) -> [UInt8] {
    if let latin1 = value.data(using: .isoLatin1) { return [1] + [UInt8](latin1) }
    return [0] + [UInt8](value.data(using: .utf16LittleEndian)!)
}

/// A write batch: puts (a value) and deletes (nil), numbered from `sequence`.
private func batch(sequence: UInt64, _ writes: [([UInt8], [UInt8]?)]) -> [UInt8] {
    var bytes = le(sequence, 8) + le(UInt64(writes.count), 4)
    for (key, value) in writes {
        bytes += [value == nil ? 0 : 1] + varint(key.count) + key
        if let value { bytes += varint(value.count) + value }
    }
    return bytes
}

/// A log file holding `batches`, each cut into pieces at the 32 KiB block
/// edges as LevelDB writes them.
private func logFile(_ batches: [[UInt8]]) -> [UInt8] {
    let block = 32_768
    var file: [UInt8] = []
    for batch in batches {
        var rest = batch[...]
        var first = true
        repeat {
            var left = block - file.count % block
            if left < 7 {
                file += [UInt8](repeating: 0, count: left)
                left = block
            }
            let piece = rest.prefix(left - 7)
            rest = rest.dropFirst(piece.count)
            let type: UInt8 = first ? (rest.isEmpty ? 1 : 2) : (rest.isEmpty ? 4 : 3)
            file += [0, 0, 0, 0] + le(UInt64(piece.count), 2) + [type] + piece
            first = false
        } while !rest.isEmpty
    }
    return file
}

/// One block: every key whole (no shared prefix), one restart.
private func block(_ entries: [([UInt8], [UInt8])]) -> [UInt8] {
    var bytes: [UInt8] = []
    for (key, value) in entries {
        bytes += varint(0) + varint(key.count) + varint(value.count) + key + value
    }
    return bytes + le(0, 4) + le(1, 4)
}

/// Snappy with literals only: as valid as the compressor's own output.
private func snappyLiterals(_ bytes: [UInt8]) -> [UInt8] {
    var out = varint(bytes.count)
    var rest = bytes[...]
    while !rest.isEmpty {
        let piece = rest.prefix(60)
        rest = rest.dropFirst(piece.count)
        out += [UInt8((piece.count - 1) << 2)] + piece
    }
    return out
}

/// A table of one data block (Snappy or not) and its index; `entries` are
/// user keys with their sequence and kind (1 put, 0 delete).
private func tableFile(_ entries: [([UInt8], UInt64, UInt8, [UInt8])], snappy: Bool) -> [UInt8] {
    let data = block(entries.map { key, sequence, kind, value in (key + le(sequence << 8 | UInt64(kind), 8), value) })
    let dataContents = snappy ? snappyLiterals(data) : data
    var file = dataContents + [snappy ? 1 : 0, 0, 0, 0, 0]
    let indexOffset = file.count
    let index = block([(Array("z".utf8), varint(0) + varint(dataContents.count))])
    file += index + [0, 0, 0, 0, 0]
    var footer = varint(0) + varint(0) + varint(indexOffset) + varint(index.count)
    footer += [UInt8](repeating: 0, count: 40 - footer.count)
    return file + footer + le(0xdb4775248b80fb57, 8)
}

private func directory(_ files: [String: [UInt8]]) -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("t3drafts-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    for (name, bytes) in files { FileManager.default.createFile(atPath: url.appendingPathComponent(name).path, contents: Data(bytes)) }
    return url
}

// MARK: - Stored drafts

private func draftsJSON(
    version: Int = 9,
    thread: [String: Any] = [:],
    composer: [String: Any]? = nil
) -> String {
    var draftThread: [String: Any] = [
        "threadId": threadOfDraft, "environmentId": environment, "projectId": project,
        "logicalProjectKey": "\(environment):\(project)", "createdAt": "2026-10-16T16:00:00.000Z",
        "runtimeMode": "full-access", "interactionMode": "default", "branch": NSNull(), "worktreePath": NSNull(),
        "envMode": "local", "startFromOrigin": false, "promotedTo": NSNull(),
    ]
    draftThread.merge(thread) { $1 }
    var drafts: [String: Any] = [:]
    if let composer { drafts[draftID] = composer }
    let object: [String: Any] = [
        "state": [
            "draftsByThreadKey": drafts,
            "draftThreadsByThreadKey": [draftID: draftThread],
            "logicalProjectDraftThreadKeyByLogicalProjectKey": [String: Any](),
        ] as [String: Any],
        "version": version,
    ]
    return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

private let opus: [String: Any] = [
    "instanceId": "claudeAgent", "model": "claude-opus-5-5",
    "options": [["id": "effort", "value": "xhigh"], ["id": "contextWindow", "value": "1m"]],
]

private func settingsJSON(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

private let serverSettings = settingsJSON([
    "defaultModelSelection": opus,
    "projectSettingsFolded": true,
    "projectSettingsOverrides": [
        project: ["defaultModelSelection": ["instanceId": "claudeAgent_2", "model": "claude-opus-5-5"]],
    ],
])

private func draft(thread: [String: Any] = [:], composer: [String: Any]? = nil) -> T3CodeDrafts.Draft {
    T3CodeDrafts.draft(draftID, storedValue: draftsJSON(thread: thread, composer: composer))!
}

private func launch(
    _ text: String = "Fix the pagination",
    thread: [String: Any] = [:],
    composer: [String: Any]? = nil,
    settings: Data? = serverSettings,
    client: Data? = nil
) -> T3CodeDrafts.Launch? {
    T3CodeDrafts.launch(text, from: draft(thread: thread, composer: composer), serverSettingsJSON: settings, clientSettingsJSON: client)
}

private func string(_ value: Any?) -> String? { value as? String }

func testT3CodeDrafts() {
    runSuite("A T3 Code page names its new chat; a thread or another page doesn't") {
        assertEqual(T3CodeDrafts.draftID(pageURL: "t3code://app/#/draft/\(draftID)"), draftID, "New thread's page")
        assertEqual(T3CodeDrafts.draftID(pageURL: "t3code://app/#/draft/\(draftID)?panel=diff"), draftID, "a panel open on it")
        assertNil(T3CodeDrafts.draftID(pageURL: "t3code://app/#/\(environment)/\(threadOfDraft)"), "a thread")
        assertNil(T3CodeDrafts.draftID(pageURL: "http://localhost:5173/#/draft/\(draftID)"), "only T3 Code's own page")
        assertNil(T3CodeDrafts.draftID(pageURL: "t3code://app/#/draft/"), "no id")
    }

    runSuite("A new chat sends to its own thread; two things in one window don't") {
        let draftPage = ChatThreadPolicy.Page(url: "t3code://app/#/draft/\(draftID)", title: "T3 Code (Nightly)")
        let preview = ChatThreadPolicy.Page(url: "http://localhost:3000/", title: "My site")
        assertEqual(
            ChatThreadSendPolicy.sendTarget(bundleID: "com.t3tools.t3code", pages: [draftPage, preview]),
            .t3CodeDraft(draftID: draftID),
            "the draft, a preview beside it doesn't count"
        )
        assertNil(
            ChatThreadSendPolicy.sendTarget(
                bundleID: "com.t3tools.t3code",
                pages: [draftPage, ChatThreadPolicy.Page(url: "t3code://app/#/\(environment)/\(threadOfDraft)", title: nil)]
            ),
            "a draft beside a thread: which one is unknown"
        )
        assertNil(
            ChatThreadSendPolicy.sendTarget(bundleID: "com.anthropic.claudefordesktop", pages: [draftPage]),
            "only T3 Code's own drafts"
        )
    }

    runSuite("localStorage reads from the log, a write cut across blocks, and the newest write wins") {
        let first = stored(draftsJSON(thread: ["branch": "first"]))
        let newer = stored(draftsJSON(thread: ["branch": "newer"]))
        let other = (Array("_\(origin)".utf8) + [0, 1] + Array("t3code:theme".utf8), stored("dark"))
        let log = logFile([
            batch(sequence: 10, [(mapKey(), first), other]),
            // Long enough to span a block edge (first, middle, last pieces).
            batch(sequence: 20, [(Array("_\(origin)".utf8) + [0, 1] + Array("filler".utf8), [UInt8](repeating: 1, count: 70_000))]),
            batch(sequence: 30, [(mapKey(), newer)]),
        ])
        let value = ChromiumLocalStorage.value(origin: origin, key: draftKey, in: directory(["000003.log": log]))
        assertEqual(value.flatMap { T3CodeDrafts.draft(draftID, storedValue: $0)?.branch }, "newer", "the later batch")

        let deleted = logFile([batch(sequence: 10, [(mapKey(), first)]), batch(sequence: 11, [(mapKey(), nil)])])
        assertNil(ChromiumLocalStorage.value(origin: origin, key: draftKey, in: directory(["000003.log": deleted])), "a delete after it: none")

        var cut = logFile([batch(sequence: 10, [(mapKey(), first)]), batch(sequence: 11, [(mapKey(), newer)])])
        cut.removeLast(40)
        assertEqual(
            ChromiumLocalStorage.value(origin: origin, key: draftKey, in: directory(["000003.log": cut]))
                .flatMap { T3CodeDrafts.draft(draftID, storedValue: $0)?.branch },
            "first",
            "a write still under way is left out"
        )
        assertNil(ChromiumLocalStorage.value(origin: origin, key: draftKey, in: directory([:])), "no files")
        assertNil(
            ChromiumLocalStorage.value(origin: origin, key: draftKey, in: URL(fileURLWithPath: "/nonexistent/leveldb")),
            "no profile"
        )
    }

    runSuite("localStorage reads compacted tables, Snappy or not, against the log by sequence") {
        let old = stored(draftsJSON(thread: ["branch": "old"]))
        let newer = stored(draftsJSON(thread: ["branch": "newer"]))
        func branch(_ files: [String: [UInt8]]) -> String? {
            ChromiumLocalStorage.value(origin: origin, key: draftKey, in: directory(files))
                .flatMap { T3CodeDrafts.draft(draftID, storedValue: $0)?.branch }
        }
        assertEqual(branch(["000005.ldb": tableFile([(mapKey(), 5, 1, old)], snappy: true)]), "old", "a Snappy table")
        assertEqual(branch(["000005.ldb": tableFile([(mapKey(), 5, 1, old)], snappy: false)]), "old", "a plain table")
        assertEqual(
            branch(["000005.ldb": tableFile([(mapKey(), 5, 1, old)], snappy: true), "000007.log": logFile([batch(sequence: 9, [(mapKey(), newer)])])]),
            "newer",
            "the log's newer write"
        )
        assertEqual(
            branch(["000005.ldb": tableFile([(mapKey(), 12, 1, old)], snappy: true), "000007.log": logFile([batch(sequence: 9, [(mapKey(), newer)])])]),
            "old",
            "a table written later than the log's record"
        )
        assertNil(branch(["000005.ldb": tableFile([(mapKey(), 5, 0, [])], snappy: true)]), "a delete compacted into a table")
        assertNil(branch(["000005.ldb": [UInt8](repeating: 7, count: 100)]), "a broken table")
    }

    runSuite("Snappy copies, overlapping ones too, come back whole") {
        // "abc", then a copy 3 back of 9 bytes, which reads what it writes.
        assertEqual(
            ChromiumLocalStorage.Snappy.decompress([12, 0x08] + Array("abc".utf8) + [0x15, 0x03]).map { String(decoding: $0, as: UTF8.self) },
            "abcabcabcabc",
            "a 1-byte-offset copy"
        )
        assertEqual(
            ChromiumLocalStorage.Snappy.decompress([6, 0x04] + Array("xy".utf8) + [0x0e, 0x02, 0x00]).map { String(decoding: $0, as: UTF8.self) },
            "xyxyxy",
            "a 2-byte-offset copy"
        )
        assertNil(ChromiumLocalStorage.Snappy.decompress([5, 0x15, 0x03]), "a copy from before the start")
        assertNil(ChromiumLocalStorage.Snappy.decompress([9, 0x08] + Array("abc".utf8)), "shorter than it says")
    }

    runSuite("Values in UTF-16, as Chromium stores text that isn't Latin-1") {
        let russian = draftsJSON(thread: ["branch": "ветка"])
        let log = logFile([batch(sequence: 1, [(mapKey(), stored(russian))])])
        assertEqual(
            ChromiumLocalStorage.value(origin: origin, key: draftKey, in: directory(["000003.log": log])),
            russian,
            "read back as written"
        )
    }

    runSuite("The draft as the window keeps it") {
        let plain = draft()
        assertEqual(plain.threadID, threadOfDraft, "the thread id picked for it")
        assertEqual(plain.projectID, project, "its project")
        assertEqual(plain.environmentID, environment, "its environment")
        assertNil(plain.branch, "no branch")
        assertNil(plain.promotedTo?.threadID, "not sent")
        assertNil(plain.modelSelection, "no model picked: the project's")
        let sent = draft(thread: ["promotedTo": ["environmentId": environment, "threadId": "sent-thread"]])
        assertEqual(sent.promotedTo?.threadID, "sent-thread", "sent from the window")
        assertNil(T3CodeDrafts.draft(draftID, storedValue: draftsJSON(version: 10)), "another version: its shape may differ")
        assertNil(T3CodeDrafts.draft("another", storedValue: draftsJSON()), "another draft")
        assertNil(T3CodeDrafts.draft(draftID, storedValue: draftsJSON(thread: ["projectId": ""])), "no project")
        assertNil(T3CodeDrafts.draft(draftID, storedValue: "not json"), "a broken value")
    }

    runSuite("The thread starts as the composer would: its model, modes and workspace") {
        let picked: [String: Any] = ["instanceId": "codex", "model": "gpt-6-astra"]
        assertEqual(
            string(launch(composer: ["activeProvider": "codex", "modelSelectionByProvider": ["codex": picked, "claudeAgent": opus]])?.modelSelection["model"]),
            "gpt-6-astra",
            "the model picked in the composer, for its active provider"
        )
        assertEqual(string(launch()?.modelSelection["instanceId"]), "claudeAgent_2", "else the project's default")
        assertEqual(
            string(launch(settings: settingsJSON(["defaultModelSelection": opus]))?.modelSelection["instanceId"]),
            "claudeAgent",
            "else the environment's"
        )
        assertNil(launch(settings: nil), "no model anywhere: not sent")

        assertEqual(launch()?.runtimeMode, "full-access", "T3 Code's default runtime")
        assertEqual(launch(composer: ["runtimeMode": "approval-required"])?.runtimeMode, "approval-required", "the composer's")
        assertEqual(
            launch(settings: settingsJSON(["defaultModelSelection": opus, "defaultRuntimeMode": "auto-accept-edits"]))?.runtimeMode,
            "auto-accept-edits",
            "the environment's default"
        )
        assertEqual(launch(thread: ["interactionMode": "plan"])?.interactionMode, "plan", "the draft's plan mode")
        assertEqual(launch(composer: ["interactionMode": "plan"])?.interactionMode, "plan", "the composer's")
        assertEqual(
            launch(composer: ["interactionMode": "plan"], client: settingsJSON(["planModeEnabled": false]))?.interactionMode,
            "default",
            "plan mode turned off in T3 Code"
        )

        let root = launch(thread: ["branch": "main"])?.workspaceStrategy
        assertEqual(string(root?["type"]), "root", "local: the project's folder")
        assertEqual(string(root?["branch"]), "main", "with its branch")
        assertNil(launch()?.workspaceStrategy["branch"], "no branch picked")
        let existing = launch(thread: ["worktreePath": "/tmp/wt", "branch": "feature"])?.workspaceStrategy
        assertEqual(string(existing?["type"]), "existing_worktree", "the draft's worktree")
        assertEqual(string(existing?["worktreePath"]), "/tmp/wt", "its path")
        let fresh = launch(thread: ["envMode": "worktree", "branch": "main", "startFromOrigin": true])?.workspaceStrategy
        assertEqual(string(fresh?["type"]), "worktree", "New worktree")
        assertEqual(string(fresh?["baseRef"]), "main", "off the draft's branch")
        assertEqual(fresh?["startFromOrigin"] as? Bool, true, "from origin when asked")
        assertNil(fresh?["branch"], "its branch is the server's to name")
        assertNil(launch(thread: ["envMode": "worktree"]), "New worktree without a base branch: the composer won't send")
    }

    runSuite("Ultrathink goes into the words, as the composer writes it") {
        let ultrathink: [String: Any] = [
            "activeProvider": "claudeAgent",
            "modelSelectionByProvider": ["claudeAgent": [
                "instanceId": "claudeAgent", "model": "claude-opus-5-5",
                "options": [["id": "effort", "value": "ultrathink"], ["id": "contextWindow", "value": "1m"]],
            ]],
        ]
        let launched = launch("  Fix it  ", composer: ultrathink)
        assertEqual(launched?.text, "Ultrathink:\nFix it", "a line before the words")
        assertEqual((launched?.modelSelection["options"] as? [[String: Any]])?.count, 1, "the effort itself left to the model's default")
        assertEqual(launch("/compact", composer: ultrathink)?.text, "/compact", "a command stays as it is")
        assertEqual(launch("Fix it")?.text, "Fix it", "other efforts: the words alone")
    }

    runSuite("The title is the words' first 50 characters") {
        assertEqual(T3CodeDrafts.title("  Fix the pagination  "), "Fix the pagination", "short words whole")
        let long = String(repeating: "a", count: 60)
        assertEqual(T3CodeDrafts.title(long), String(repeating: "a", count: 50) + "...", "long ones cut")
        let emoji = String(repeating: "a", count: 49) + "😀 tail"
        assertEqual(T3CodeDrafts.title(emoji), String(repeating: "a", count: 49) + "...", "a pair cut in two drops its half")
        assertEqual(T3CodeDrafts.title(" "), "New thread", "no words")
    }

    runSuite("The launch request, as the composer's first send") {
        guard let plan = launch(thread: ["branch": "main"]) else { return assertTrue(false, "a launch") }
        let commandID = UUID()
        let messageID = UUID()
        let data = T3CodeDrafts.launchRequest(requestID: "1", launch: plan, commandID: commandID, messageID: messageID)
        let request = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        assertEqual(string(request["tag"]), "orchestration.launchThread", "one request starts the thread and the agent")
        let payload = request["payload"] as? [String: Any] ?? [:]
        assertEqual(string(payload["commandId"]), commandID.uuidString.lowercased(), "a command kept once")
        assertEqual(string(payload["threadId"]), threadOfDraft, "the draft's own thread, which its window then opens")
        assertEqual(string(payload["projectId"]), project, "its project")
        assertEqual(string(payload["title"]), "Fix the pagination", "titled by its words")
        assertEqual(payload["generateTitle"] as? Bool, true, "and named by the server afterwards")
        let message = payload["initialMessage"] as? [String: Any] ?? [:]
        assertEqual(string(message["text"]), "Fix the pagination", "the take's words")
        assertEqual(string(message["messageId"]), messageID.uuidString.lowercased(), "its message id")
        assertEqual((message["attachments"] as? [Any])?.count, 0, "no attachments")
        assertEqual(string((payload["workspaceStrategy"] as? [String: Any])?["type"]), "root", "the workspace")
    }
}
