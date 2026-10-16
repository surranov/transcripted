import Foundation

/// Fork: sends a take to the chat thread it was dictated into, unseen
/// (`ChatThreadSendPolicy`): through T3 Code's own server (`T3CodeServer`;
/// a new chat's first send starts its thread there, `T3CodeDrafts`), or
/// into a Codex thread's queue with Codex's CLI (`CodexThreads`).
enum ChatThreadSender {
    /// Whether a send can go now: the server runs, is the one the thread
    /// lives on, and a session is ready (issued here when there's none).
    /// Called when a take starts and before the island asks to confirm, so
    /// the send itself rarely waits for T3 Code's CLI.
    static func prepare(_ target: ChatThreadSendTarget) async -> Bool {
        switch target {
        case let .t3Code(environmentID, _):
            return await T3CodeConnection.ready(environmentID: environmentID)
        case let .t3CodeDraft(draftID):
            guard let draft = T3CodeDrafts.read(draftID) else { return false }
            return await T3CodeConnection.ready(environmentID: draft.promotedTo?.environmentID ?? draft.environmentID)
        case .codex:
            return CodexThreads.runningCLI() != nil
        }
    }

    static func send(_ text: String, to target: ChatThreadSendTarget) async -> ChatThreadSendResult {
        switch target {
        case let .t3Code(environmentID, threadID):
            return await SendOrder.shared.enqueue {
                await T3CodeConnection.send(text, environmentID: environmentID, threadID: threadID)
            }.value
        case let .t3CodeDraft(draftID):
            return await SendOrder.shared.enqueue {
                await T3CodeConnection.send(text, draftID: draftID)
            }.value
        case let .codex(threadID):
            return await SendOrder.shared.enqueue {
                await CodexThreads.queue(text, threadID: threadID)
            }.value
        }
    }

    /// Sends go one at a time, in the order asked: two takes to one thread
    /// (a confirm while another send is under way) arrive as dictated. Each
    /// runs apart from the take's task: cancelling the take (Esc, a new take)
    /// mustn't cut the exchange short and call a message that may have
    /// arrived unanswered.
    private actor SendOrder {
        static let shared = SendOrder()
        private var last: Task<ChatThreadSendResult, Never>?

        func enqueue(_ send: @escaping @Sendable () async -> ChatThreadSendResult) -> Task<ChatThreadSendResult, Never> {
            let previous = last
            let next = Task.detached(priority: .userInitiated) { () -> ChatThreadSendResult in
                _ = await previous?.value
                return await send()
            }
            last = next
            return next
        }
    }
}

/// Fork: one send to T3 Code's server: which server, the session, and the
/// retries that can't deliver twice.
private enum T3CodeConnection {
    /// Whether a send to `environmentID` can go now: its server runs, is
    /// that environment's, and a session is ready (issued here when there's
    /// none).
    static func ready(environmentID: String) async -> Bool {
        let home = T3CodeServer.homeDirectory()
        guard let runtime = runningServer(home: home, environmentID: environmentID),
              await serves(runtime) else { return false }
        return await T3CodeSession.shared.token(home: home) != nil
    }

    /// The threads drafts started here, by draft: a second take into the
    /// same new chat goes to the thread the first one started (the window
    /// marks the draft sent only while it shows it).
    private actor StartedThreads {
        struct Thread: Sendable {
            let environmentID: String
            let threadID: String
        }

        static let shared = StartedThreads()
        private var byDraft: [String: Thread] = [:]

        func thread(of draftID: String) -> Thread? { byDraft[draftID] }

        func started(_ thread: Thread, by draftID: String) { byDraft[draftID] = thread }
    }

    /// A take into new chat `draftID`: starts its thread with the take's
    /// words, as the composer's first send would. A draft already sent (here
    /// or by the window) gets them in its thread instead.
    static func send(_ text: String, draftID: String) async -> ChatThreadSendResult {
        if let started = await StartedThreads.shared.thread(of: draftID) {
            return await send(text, environmentID: started.environmentID, threadID: started.threadID)
        }
        guard let draft = T3CodeDrafts.read(draftID) else { return .notSent(reason: "draft_not_found") }
        if let promoted = draft.promotedTo {
            return await send(text, environmentID: promoted.environmentID, threadID: promoted.threadID)
        }
        let home = T3CodeServer.homeDirectory()
        guard let runtime = runningServer(home: home, environmentID: draft.environmentID) else {
            return .notSent(reason: "server_not_running")
        }
        guard await serves(runtime) else { return .notSent(reason: "not_t3_code") }
        let userdata = home.appendingPathComponent("userdata", isDirectory: true)
        guard let launch = T3CodeDrafts.launch(
            text,
            from: draft,
            serverSettingsJSON: try? Data(contentsOf: userdata.appendingPathComponent("settings.json")),
            clientSettingsJSON: try? Data(contentsOf: userdata.appendingPathComponent("client-settings.json"))
        ) else { return .notSent(reason: "draft_not_sendable") }
        guard let token = await T3CodeSession.shared.token(home: home) else { return .notSent(reason: "no_session") }
        var result = await launchThread(launch, runtime: runtime, token: token)
        if result == .notSent(reason: T3CodeSocket.unauthorized) {
            await T3CodeSession.shared.refused(token)
            guard let fresh = await T3CodeSession.shared.token(home: home) else { return .notSent(reason: "no_session") }
            result = await launchThread(launch, runtime: runtime, token: fresh)
        }
        if case .notSent(let reason) = result, !T3CodeSocket.undeliveredReasons.contains(reason) {
            // The server refused it, so nothing ran: the draft's thread may
            // exist already (sent from the window a moment ago); then the
            // words go there, and a server without it refuses them too.
            return await send(text, environmentID: draft.environmentID, threadID: draft.threadID)
        }
        if result != .notSent(reason: T3CodeSocket.unauthorized) {
            // Unanswered counts too: it may have started, and a second launch
            // of the same thread would only be refused.
            await StartedThreads.shared.started(.init(environmentID: draft.environmentID, threadID: draft.threadID), by: draftID)
        }
        return result
    }

    /// The launch, once more when unanswered: its `commandId` is kept once,
    /// so a repeat answers as the first did without starting a second thread.
    private static func launchThread(
        _ launch: T3CodeDrafts.Launch,
        runtime: T3CodeServer.Runtime,
        token: String
    ) async -> ChatThreadSendResult {
        guard let frame = T3CodeDrafts.launchRequest(
            requestID: T3CodeSocket.requestID, launch: launch, commandID: UUID(), messageID: UUID()
        ) else { return .notSent(reason: "bad_request") }
        switch await T3CodeSocket.exchange(frame, runtime: runtime, token: token) {
        case .notDelivered(let reason):
            return .notSent(reason: reason)
        case .reply(let result) where result != .unconfirmed:
            return result
        case .reply, .noAnswer:
            guard case .reply(.sent) = await T3CodeSocket.exchange(frame, runtime: runtime, token: token) else {
                return .unconfirmed
            }
            return .sent
        }
    }

    static func send(_ text: String, environmentID: String, threadID: String) async -> ChatThreadSendResult {
        let home = T3CodeServer.homeDirectory()
        guard let runtime = runningServer(home: home, environmentID: environmentID) else {
            return .notSent(reason: "server_not_running")
        }
        guard await serves(runtime) else { return .notSent(reason: "not_t3_code") }
        let followUp = T3CodeServer.FollowUp(clientSettingsJSON: try? Data(
            contentsOf: home.appendingPathComponent("userdata/client-settings.json")
        ))
        guard let token = await T3CodeSession.shared.token(home: home) else { return .notSent(reason: "no_session") }
        let result = await dispatch(text, threadID: threadID, runtime: runtime, token: token, followUp: followUp)
        guard result == .notSent(reason: T3CodeSocket.unauthorized) else { return result }
        // Revoked or expired: a new session, once.
        await T3CodeSession.shared.refused(token)
        guard let fresh = await T3CodeSession.shared.token(home: home) else { return .notSent(reason: "no_session") }
        return await dispatch(text, threadID: threadID, runtime: runtime, token: fresh, followUp: followUp)
    }

    /// The server its files describe, for `environmentID`, while its process
    /// runs: the files outlive a crash.
    static func runningServer(home: URL, environmentID: String) -> T3CodeServer.Runtime? {
        guard let runtime = T3CodeServer.runtime(home: home), runtime.environmentID == environmentID else { return nil }
        if let pid = runtime.pid, pid > 0, kill(pid, 0) != 0, errno != EPERM { return nil }
        return runtime
    }

    /// Whether the port the files name is T3 Code's server for that
    /// environment, asked without the bearer: another process may hold it.
    static func serves(_ runtime: T3CodeServer.Runtime) async -> Bool {
        guard let url = URL(string: "http://\(T3CodeSocket.urlHost(runtime)):\(runtime.port)/.well-known/t3/environment") else { return false }
        let session = T3CodeSocket.loopbackSession()
        defer { session.invalidateAndCancel() }
        guard let (data, response) = try? await session.data(for: URLRequest(url: url, timeoutInterval: 2)),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return T3CodeServer.describes(environmentID: runtime.environmentID, descriptorJSON: data)
    }

    /// A refused steer goes once more queued behind the agent's turn: a turn
    /// caught starting can't take words into it yet. A refused command ran
    /// nothing, so the words can't arrive twice.
    private static func dispatch(
        _ text: String,
        threadID: String,
        runtime: T3CodeServer.Runtime,
        token: String,
        followUp: T3CodeServer.FollowUp
    ) async -> ChatThreadSendResult {
        let result = await command(text, threadID: threadID, runtime: runtime, token: token, followUp: followUp)
        guard result == .notSent(reason: T3CodeServer.dispatchRefused), followUp == .steer else { return result }
        return await command(text, threadID: threadID, runtime: runtime, token: token, followUp: .queue)
    }

    /// One command. Unanswered, the same command goes once more: the server
    /// keeps a command once per `commandId` and answers a repeat as it did
    /// the first, so the answer is known without sending the words twice.
    private static func command(
        _ text: String,
        threadID: String,
        runtime: T3CodeServer.Runtime,
        token: String,
        followUp: T3CodeServer.FollowUp
    ) async -> ChatThreadSendResult {
        guard let frame = T3CodeServer.dispatchRequest(
            requestID: T3CodeSocket.requestID,
            threadID: threadID,
            text: text,
            commandID: UUID(),
            messageID: UUID(),
            followUp: followUp
        ) else { return .notSent(reason: "bad_request") }
        switch await T3CodeSocket.exchange(frame, runtime: runtime, token: token) {
        case .notDelivered(let reason):
            return .notSent(reason: reason)
        case .reply(let result) where result != .unconfirmed:
            return result
        case .reply, .noAnswer:
            // Only an answer that it went counts now: the first may have
            // arrived, and a refusal of the repeat can't tell (the server
            // reports some of its own failures as refusals too).
            guard case .reply(.sent) = await T3CodeSocket.exchange(frame, runtime: runtime, token: token) else {
                return .unconfirmed
            }
            return .sent
        }
    }
}

/// Fork: Transcripted's session on T3 Code's server: a bearer issued by T3
/// Code's own CLI (`t3 auth session issue`, `orchestration:operate`, labeled
/// Transcripted, so it shows in `t3 auth session list` and can be revoked
/// there; a replaced one is revoked here), kept in Transcripted's state
/// folder (owner-only). Not in the Keychain: a rebuilt app may be asked to
/// confirm Keychain access with a modal in the middle of a take, and the
/// file guards nothing more than it costs, since anyone who can read it can
/// run that CLI themselves.
actor T3CodeSession {
    static let shared = T3CodeSession()

    private struct Stored: Codable {
        let session: T3CodeServer.IssuedSession
        let issuedAt: Date
    }

    private var cached: Stored?
    /// An issue under way: takes that need a session meanwhile wait for it
    /// rather than issue one each.
    private var issuing: Task<T3CodeServer.IssuedSession?, Never>?
    /// No issuing until then: the CLI failed (each take would wait for it
    /// again, up to its timeout), or a session just issued was refused too
    /// (issuing more won't help: the files may name another T3 Code).
    private var issueBlockedUntil: Date?

    private var fileURL: URL {
        FileManager.default.transcriptedStateDir.appendingPathComponent("t3-code-session.json")
    }

    /// The session: kept while it has an hour left, else issued now. Nil
    /// when T3 Code's CLI isn't there or didn't issue one.
    func token(home: URL) async -> String? {
        if cached == nil, let data = try? Data(contentsOf: fileURL) {
            cached = try? Self.decoder.decode(Stored.self, from: data)
        }
        if let cached, (cached.session.expiresAt ?? .distantFuture) > Date().addingTimeInterval(3_600) {
            return cached.session.token
        }
        // Renewing a session that still has a little while left: it serves
        // when no new one comes.
        let stillValid = cached.flatMap { ($0.session.expiresAt ?? .distantFuture) > Date() ? $0.session.token : nil }
        if let issuing { return await issuing.value?.token ?? stillValid }
        if let issueBlockedUntil, issueBlockedUntil > Date() { return stillValid }
        let issue = Task.detached(priority: .userInitiated) { await Self.issue(home: home) }
        issuing = issue
        let issued = await issue.value
        issuing = nil
        guard let issued else {
            issueBlockedUntil = Date().addingTimeInterval(60)
            return stillValid
        }
        if let replaced = cached?.session.sessionID, replaced != issued.sessionID {
            Self.revoke(replaced, home: home)
        }
        let stored = Stored(session: issued, issuedAt: Date())
        cached = stored
        save(stored)
        return issued.token
    }

    /// The server refused `token`: forget it, so the next send issues anew.
    func refused(_ token: String) {
        guard let refused = cached, refused.session.token == token else { return }
        if Date().timeIntervalSince(refused.issuedAt) < 600 {
            issueBlockedUntil = Date().addingTimeInterval(600)
        }
        cached = nil
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Written owner-only from the start, then moved into place.
    private func save(_ stored: Stored) {
        guard let data = try? Self.encoder.encode(stored) else { return }
        let temporary = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".t3-code-session.\(UUID().uuidString).json")
        guard FileManager.default.createFile(
            atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]
        ) else { return }
        if rename(temporary.path, fileURL.path) != 0 {
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    private static func issue(home: URL) async -> T3CodeServer.IssuedSession? {
        let output = await runCLI(home: home, arguments: [
            "auth", "session", "issue",
            "--scope", T3CodeServer.sessionScope,
            "--label", T3CodeServer.sessionLabel,
            "--ttl", T3CodeServer.sessionTTL,
            "--json",
        ])
        return output.flatMap(T3CodeServer.issuedSession(cliOutput:))
    }

    private static func revoke(_ sessionID: String, home: URL) {
        Task.detached(priority: .utility) {
            _ = await runCLI(home: home, arguments: ["auth", "session", "revoke", sessionID])
        }
    }

    /// T3 Code's CLI (the wrapper it writes, `<home>/bin/t3`), with only the
    /// variables it needs: none of Transcripted's own reach it. Off the
    /// cooperative pool: it blocks a thread until the CLI ends.
    private static func runCLI(home: URL, arguments: [String]) async -> Data? {
        let cli = home.appendingPathComponent("bin/t3")
        guard FileManager.default.isExecutableFile(atPath: cli.path) else { return nil }
        let environment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "T3CODE_HOME": home.path,
        ]
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // The CLI starts T3 Code's own runtime: a few seconds at most.
                let output = try? BoundedProcessRunner.run(
                    executable: cli, arguments: arguments, timeout: 20, environment: environment
                )
                continuation.resume(returning: output?.status == 0 ? output?.stdoutData : nil)
            }
        }
    }
}

/// Fork: one request over T3 Code's WebSocket, on loopback only.
private enum T3CodeSocket {
    static let unauthorized = "unauthorized"
    static let cannotConnect = "cannot_connect"
    /// Reasons the request never reached the server, or never left.
    static let undeliveredReasons: Set<String> = [unauthorized, cannotConnect, "bad_address", "bad_request"]
    static let requestID = "1"
    /// For the server to answer once the request went out.
    static let replyTimeout: UInt64 = 8_000_000_000

    enum Exchange {
        /// The request never went out.
        case notDelivered(reason: String)
        case reply(ChatThreadSendResult)
        /// It went out and no answer came.
        case noAnswer
    }

    static func urlHost(_ runtime: T3CodeServer.Runtime) -> String {
        runtime.host.contains(":") ? "[\(runtime.host)]" : runtime.host
    }

    /// No proxy, no redirects: the bearer and the words stay on this Mac.
    static func loopbackSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    static func exchange(_ frame: Data, runtime: T3CodeServer.Runtime, token: String) async -> Exchange {
        guard let url = URL(string: "ws://\(urlHost(runtime)):\(runtime.port)/ws?orchestrationProtocol=\(T3CodeServer.orchestrationProtocol)") else {
            return .notDelivered(reason: "bad_address")
        }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let session = loopbackSession()
        defer { session.invalidateAndCancel() }
        let socket = session.webSocketTask(with: request)
        socket.resume()
        do {
            // Throws when the connection fails, so the request never left.
            try await socket.send(.string(String(decoding: frame, as: UTF8.self)))
        } catch {
            let status = (socket.response as? HTTPURLResponse)?.statusCode
            return .notDelivered(reason: status == 401 ? unauthorized : cannotConnect)
        }
        let reply = await withTaskGroup(of: ChatThreadSendResult?.self) { group in
            group.addTask { await receiveReply(socket) }
            group.addTask {
                try? await Task.sleep(nanoseconds: replyTimeout)
                return nil
            }
            let first = await group.next() ?? nil
            socket.cancel(with: .normalClosure, reason: nil)
            group.cancelAll()
            return first
        }
        return reply.map(Exchange.reply) ?? .noAnswer
    }

    private static func receiveReply(_ socket: URLSessionWebSocketTask) async -> ChatThreadSendResult? {
        while !Task.isCancelled {
            guard let message = try? await socket.receive() else { return nil }
            let data: Data
            switch message {
            case .string(let string): data = Data(string.utf8)
            case .data(let bytes): data = bytes
            @unknown default: continue
            }
            if let reply = T3CodeServer.reply(to: requestID, frame: data) { return reply }
        }
        return nil
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}
