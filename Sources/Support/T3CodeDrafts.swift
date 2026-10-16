import Foundation

/// Fork: a T3 Code new chat (`#/draft/<id>`) not sent yet, as its window keeps
/// it, and the thread its first send would start. A take dictated into it
/// while the user went on elsewhere starts that thread through T3 Code's
/// server, as the composer's Enter would (`ChatThreadSender`).
///
/// Read from T3 Code (Nightly) 0.1.1-nightly.20261016.3190's client and
/// server on 2026-10-16:
/// - The server knows nothing of a draft. The window keeps it in its
///   `localStorage` (`t3code:composer-drafts:v1`, version 9, written 300 ms
///   after a change), in its Chromium profile (`t3code-v2` under Application
///   Support): `draftThreadsByThreadKey[<draft>]` holds the project, the
///   environment, the thread id picked for it, the runtime and interaction
///   modes, the branch, a worktree, the env mode (local or a new worktree),
///   and `promotedTo` once it was sent; `draftsByThreadKey[<draft>]` holds
///   the composer's own picks (the model per provider and the active one,
///   runtime and interaction modes).
/// - The first send is one request, `orchestration.launchThread`: the
///   server creates the thread, adds the message, prepares the workspace
///   (a new worktree, the setup script) and starts the agent. Its
///   `commandId` is kept once: sent again, it answers as the first time.
/// - The thread gets the draft's own thread id, so the window, back on the
///   draft, finds it and opens it, and New thread then starts a fresh
///   draft (`useHandleNewThread` drops a draft whose thread exists).
/// - The title is the first 50 characters of the words, then "..."; the
///   server names the thread afterwards from them.
enum T3CodeDrafts {
    static let storageKey = "t3code:composer-drafts:v1"
    static let storageVersion = 9
    static let pageOrigin = "t3code://app"

    /// The draft a T3 Code page shows; nil for any other page.
    static func draftID(pageURL: String) -> String? {
        guard let components = URLComponents(string: pageURL), components.scheme == "t3code",
              var route = components.percentEncodedFragment else { return nil }
        if let query = route.firstIndex(of: "?") { route = String(route[..<query]) }
        let parts = route.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0].isEmpty, parts[1] == "draft",
              let draftID = parts[2].removingPercentEncoding, !draftID.isEmpty else { return nil }
        return draftID
    }

    /// Where T3 Code's window keeps its `localStorage`: its current profile
    /// first, then the one it moved from (`resolveUserDataPath`).
    static func localStorageDirectories(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        ["t3code-v2", "T3 Code (Alpha)"].map {
            home.appendingPathComponent("Library/Application Support/\($0)/Local Storage/leveldb", isDirectory: true)
        }
    }

    /// The draft as the window keeps it.
    struct Draft {
        let draftID: String
        let environmentID: String
        let projectID: String
        /// Picked when the draft was made; the thread its send starts.
        let threadID: String
        let runtimeMode: String?
        let interactionMode: String?
        let branch: String?
        let worktreePath: String?
        let envMode: String?
        let startFromOrigin: Bool
        /// The thread it became once sent.
        let promotedTo: (environmentID: String, threadID: String)?
        /// The composer's own model for its active provider; nil for the
        /// project's default.
        let modelSelection: [String: Any]?
        let composerRuntimeMode: String?
        let composerInteractionMode: String?
    }

    /// Draft `draftID` from the stored value; nil when it isn't there or
    /// isn't in the form this was read from.
    static func draft(_ draftID: String, storedValue: String) -> Draft? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(storedValue.utf8)) as? [String: Any],
              object["version"] as? Int == storageVersion,
              let state = object["state"] as? [String: Any],
              let thread = (state["draftThreadsByThreadKey"] as? [String: Any])?[draftID] as? [String: Any],
              let environmentID = nonEmpty(thread["environmentId"]),
              let projectID = nonEmpty(thread["projectId"]),
              let threadID = nonEmpty(thread["threadId"]) else { return nil }
        let composer = (state["draftsByThreadKey"] as? [String: Any])?[draftID] as? [String: Any]
        let promoted = thread["promotedTo"] as? [String: Any]
        let activeProvider = nonEmpty(composer?["activeProvider"])
        let selection = activeProvider.flatMap { (composer?["modelSelectionByProvider"] as? [String: Any])?[$0] as? [String: Any] }
        return Draft(
            draftID: draftID,
            environmentID: environmentID,
            projectID: projectID,
            threadID: threadID,
            runtimeMode: nonEmpty(thread["runtimeMode"]),
            interactionMode: nonEmpty(thread["interactionMode"]),
            branch: nonEmpty(thread["branch"]),
            worktreePath: nonEmpty(thread["worktreePath"]),
            envMode: nonEmpty(thread["envMode"]),
            startFromOrigin: thread["startFromOrigin"] as? Bool ?? false,
            promotedTo: promoted.flatMap { promoted in
                guard let environment = nonEmpty(promoted["environmentId"]), let thread = nonEmpty(promoted["threadId"]) else { return nil }
                return (environment, thread)
            },
            modelSelection: selection.flatMap { nonEmpty($0["instanceId"]) != nil && nonEmpty($0["model"]) != nil ? $0 : nil },
            composerRuntimeMode: nonEmpty(composer?["runtimeMode"]),
            composerInteractionMode: nonEmpty(composer?["interactionMode"])
        )
    }

    /// Reads draft `draftID` from T3 Code's profile on disk. Call off the
    /// main actor: a few files of a few dozen KB.
    static func read(_ draftID: String, directories: [URL] = localStorageDirectories()) -> Draft? {
        for directory in directories {
            guard let stored = ChromiumLocalStorage.value(origin: pageOrigin, key: storageKey, in: directory) else { continue }
            if let draft = draft(draftID, storedValue: stored) { return draft }
        }
        return nil
    }

    // MARK: - The launch

    /// What the composer's first send of `text` from `draft` starts, with
    /// the server's settings (`settings.json`) for what the draft leaves to
    /// its project; nil when the composer wouldn't send it (a new worktree
    /// without a base branch, no model at all).
    struct Launch {
        let projectID: String
        let threadID: String
        let title: String
        let text: String
        let modelSelection: [String: Any]
        let runtimeMode: String
        let interactionMode: String
        let workspaceStrategy: [String: Any]
    }

    static func launch(
        _ text: String,
        from draft: Draft,
        serverSettingsJSON: Data?,
        clientSettingsJSON: Data?
    ) -> Launch? {
        let settings = serverSettingsJSON.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let client = clientSettingsJSON.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let project = projectSettings(settings, projectID: draft.projectID)
        guard var selection = draft.modelSelection ?? project["defaultModelSelection"] as? [String: Any],
              nonEmpty(selection["instanceId"]) != nil, nonEmpty(selection["model"]) != nil else { return nil }
        // Ultrathink isn't an effort the agent takes: the composer writes it
        // into the words and sends the model's own default effort.
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var text = words
        if var options = selection["options"] as? [[String: Any]],
           let index = options.firstIndex(where: { $0["id"] as? String == "effort" && $0["value"] as? String == "ultrathink" }) {
            options.remove(at: index)
            selection["options"] = options.isEmpty ? nil : options
            if !text.isEmpty, !text.hasPrefix("Ultrathink:"), text.range(of: #"^/[^\s/]+(\s|$)"#, options: .regularExpression) == nil {
                text = "Ultrathink:\n\(text)"
            }
        }
        // As `startThreadTurn` picks it: a new worktree off the draft's
        // branch, the draft's worktree, or the project's folder.
        var strategy: [String: Any]
        if draft.worktreePath == nil, draft.envMode == "worktree" {
            // The composer won't send a new worktree without its base branch.
            guard let branch = draft.branch else { return nil }
            strategy = ["type": "worktree", "baseRef": branch]
            if draft.startFromOrigin { strategy["startFromOrigin"] = true }
        } else {
            strategy = draft.worktreePath.map { ["type": "existing_worktree", "worktreePath": $0] } ?? ["type": "root"]
            if let branch = draft.branch { strategy["branch"] = branch }
        }
        let interactionMode = client["planModeEnabled"] as? Bool == false
            ? "default"
            : draft.composerInteractionMode ?? draft.interactionMode ?? "default"
        return Launch(
            projectID: draft.projectID,
            threadID: draft.threadID,
            title: title(words),
            text: text,
            modelSelection: selection,
            runtimeMode: draft.composerRuntimeMode ?? project["defaultRuntimeMode"] as? String ?? "full-access",
            interactionMode: interactionMode,
            workspaceStrategy: strategy
        )
    }

    /// The server's settings for a project: its own overrides over the
    /// environment's (`resolveProjectOverrides` with the overrides folded
    /// into `settings.json`, as they are since `projectSettingsFolded`).
    static func projectSettings(_ settings: [String: Any], projectID: String) -> [String: Any] {
        let overrides = (settings["projectSettingsOverrides"] as? [String: Any])?[projectID] as? [String: Any] ?? [:]
        return settings.merging(overrides) { $1 }
    }

    /// The composer's title: the words, cut to 50 UTF-16 units and "...".
    static func title(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "New thread" }
        let units = Array(trimmed.utf16)
        guard units.count > 50 else { return trimmed }
        var cut = Array(units.prefix(50))
        // A pair cut in two drops its first half (JavaScript keeps it as a
        // lone unit; a Swift string can't).
        if let last = cut.last, UTF16.isLeadSurrogate(last) { cut.removeLast() }
        return (String(utf16CodeUnits: cut, count: cut.count)) + "..."
    }

    /// The request that starts the thread with the take's words. Nil when
    /// it can't be written (nothing is sent then).
    static func launchRequest(requestID: String, launch: Launch, commandID: UUID, messageID: UUID) -> Data? {
        let payload: [String: Any] = [
            "commandId": commandID.uuidString.lowercased(),
            "creationSource": "web",
            "threadId": launch.threadID,
            "projectId": launch.projectID,
            "title": launch.title,
            "generateTitle": true,
            "modelSelection": launch.modelSelection,
            "runtimeMode": launch.runtimeMode,
            "interactionMode": launch.interactionMode,
            "workspaceStrategy": launch.workspaceStrategy,
            "initialMessage": [
                "messageId": messageID.uuidString.lowercased(),
                "text": launch.text,
                "attachments": [Any](),
            ] as [String: Any],
        ]
        let request: [String: Any] = [
            "_tag": "Request",
            "id": requestID,
            "tag": "orchestration.launchThread",
            "payload": payload,
            "headers": [Any](),
        ]
        guard JSONSerialization.isValidJSONObject(request) else { return nil }
        return try? JSONSerialization.data(withJSONObject: request)
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }
}
