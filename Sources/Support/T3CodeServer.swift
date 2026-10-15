import Foundation

/// Fork: T3 Code's own local server, the one its window talks to. A take
/// dictated into a T3 Code thread is sent there through it when the user
/// isn't looking at that thread (`ChatThreadSender`), as the composer's
/// Enter would send it.
///
/// Read from T3 Code (Nightly)'s bundled server and client, 2026-10-15:
/// - its home is `$T3CODE_HOME`, else ~/.t3 (what its `t3` CLI uses); the
///   running server writes `userdata/server-runtime.json` (host, port) and
///   its id is in `userdata/environment-id`;
/// - a page's address names its thread, `t3code://app/#/<environment>/<thread>`
///   (`#/draft/<id>` is a chat not sent yet, with no thread on the server);
/// - it takes Effect RPC requests as JSON text over `ws://<host>:<port>/ws`,
///   with a bearer from `t3 auth session issue` holding `orchestration:operate`;
///   `/.well-known/t3/environment` names it without one;
/// - the composer sends `orchestration.dispatchCommand` with a
///   `message.dispatch`; while the agent works, Enter steers it or queues
///   behind it, as Settings → Follow-up behavior says (`client-settings.json`);
/// - a command is kept once per `commandId`: sent again, it answers as the
///   first time and does nothing more.
enum T3CodeServer {
    static let bundleID = "com.t3tools.t3code"
    /// The narrowest scope that can send a message. It also covers the other
    /// thread commands (archive, interrupt, answering the agent's requests),
    /// which Transcripted never sends.
    static let sessionScope = "orchestration:operate"
    static let sessionLabel = "Transcripted"
    static let sessionTTL = "7d"
    static let orchestrationProtocol = 2

    /// Where T3 Code keeps its state: `$T3CODE_HOME` when it's a full path,
    /// as T3 Code's CLI reads it, else ~/.t3.
    static func homeDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let home = environment["T3CODE_HOME"].map({ ($0 as NSString).expandingTildeInPath }), home.hasPrefix("/") {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".t3", isDirectory: true)
    }

    /// The running server, as it describes itself.
    struct Runtime: Equatable {
        let host: String
        let port: Int
        let environmentID: String
        /// The server's process; the file outlives a crash.
        let pid: Int32?
    }

    /// The server from `server-runtime.json` and `environment-id`; nil when
    /// either is missing or it listens elsewhere than on this Mac: the bearer
    /// never goes anywhere else. A server listening everywhere (no host, or
    /// `0.0.0.0`) is reached on loopback.
    static func runtime(serverRuntimeJSON: Data, environmentID: String) -> Runtime? {
        guard let object = try? JSONSerialization.jsonObject(with: serverRuntimeJSON) as? [String: Any],
              let port = object["port"] as? Int, (1...65_535).contains(port) else { return nil }
        var host = (object["host"] as? String) ?? "127.0.0.1"
        if host == "0.0.0.0" { host = "127.0.0.1" }
        if host == "::" { host = "::1" }
        guard ["127.0.0.1", "localhost", "::1"].contains(host) else { return nil }
        let environmentID = environmentID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !environmentID.isEmpty else { return nil }
        return Runtime(host: host, port: port, environmentID: environmentID, pid: (object["pid"] as? Int).flatMap { Int32(exactly: $0) })
    }

    static func runtime(home: URL) -> Runtime? {
        let userdata = home.appendingPathComponent("userdata", isDirectory: true)
        guard let json = try? Data(contentsOf: userdata.appendingPathComponent("server-runtime.json")),
              let environmentID = try? String(contentsOf: userdata.appendingPathComponent("environment-id"), encoding: .utf8) else {
            return nil
        }
        return runtime(serverRuntimeJSON: json, environmentID: environmentID)
    }

    /// Whether `/.well-known/t3/environment` describes the server the take's
    /// thread lives on: checked before the bearer goes out, since after a
    /// crash another process may hold the port the files still name.
    static func describes(environmentID: String, descriptorJSON: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: descriptorJSON) as? [String: Any] else { return false }
        return object["environmentId"] as? String == environmentID
            && object["orchestrationProtocolVersion"] as? Int == orchestrationProtocol
    }

    /// The thread a T3 Code page shows; nil for a new chat's draft or any
    /// other page (a preview of a site the agent runs, say).
    static func threadAddress(pageURL: String) -> (environmentID: String, threadID: String)? {
        guard let components = URLComponents(string: pageURL), components.scheme == "t3code",
              var route = components.percentEncodedFragment else { return nil }
        if let query = route.firstIndex(of: "?") { route = String(route[..<query]) }
        let parts = route.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0].isEmpty, parts[1] != "draft",
              let environmentID = parts[1].removingPercentEncoding, !environmentID.isEmpty,
              let threadID = parts[2].removingPercentEncoding, !threadID.isEmpty else { return nil }
        return (environmentID, threadID)
    }

    /// What Enter does while the agent works (Settings → Follow-up behavior).
    enum FollowUp: String {
        /// The words join the turn under way; T3 Code's default. Sent as
        /// "auto" (`dispatchRequest`): where the agent can't take words into
        /// a turn, the server queues them, where the composer would restart
        /// the turn.
        case steer
        /// The words wait for the turn to end.
        case queue

        /// From `userdata/client-settings.json`; steer when it can't be read.
        init(clientSettingsJSON: Data?) {
            let object = clientSettingsJSON.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            self = (object?["followUpBehavior"] as? String) == FollowUp.queue.rawValue ? .queue : .steer
        }
    }

    /// The request the composer's Enter sends: idle, the agent starts on it;
    /// working, it steers or queues as `followUp` says. Nil when it can't be
    /// written (nothing is sent then).
    static func dispatchRequest(
        requestID: String,
        threadID: String,
        text: String,
        commandID: UUID,
        messageID: UUID,
        followUp: FollowUp
    ) -> Data? {
        var command: [String: Any] = [
            "type": "message.dispatch",
            "commandId": commandID.uuidString.lowercased(),
            "createdBy": "user",
            "creationSource": "web",
            "threadId": threadID,
            "messageId": messageID.uuidString.lowercased(),
            "text": text,
            "attachments": [Any](),
        ]
        switch followUp {
        case .steer:
            // "auto", as the composer sends while no turn runs: the server
            // starts it, queues it behind a turn still starting, and steers
            // a running one where the agent supports it. "steer" itself is
            // refused while a turn starts (no provider turn to steer yet).
            command["deliveryIntent"] = "auto"
            command["dispatchMode"] = ["type": "start_immediately"]
        case .queue:
            command["dispatchMode"] = ["type": "queue_after_active"]
        }
        let request: [String: Any] = [
            "_tag": "Request",
            "id": requestID,
            "tag": "orchestration.dispatchCommand",
            "payload": command,
            "headers": [Any](),
        ]
        return try? JSONSerialization.data(withJSONObject: request)
    }

    /// The server refused the command itself (no such thread, a turn it
    /// can't take words into now); nothing ran.
    static let dispatchRefused = "OrchestrationV2DispatchCommandError"

    /// What a frame from the server says about request `requestID`; nil
    /// when it says nothing about it (another message, a keep-alive).
    static func reply(to requestID: String, frame: Data) -> ChatThreadSendResult? {
        guard let json = try? JSONSerialization.jsonObject(with: frame) else { return nil }
        let messages = (json as? [[String: Any]]) ?? [(json as? [String: Any])].compactMap { $0 }
        for message in messages {
            switch message["_tag"] as? String {
            case "Exit" where (message["requestId"] as? String) == requestID:
                let exit = message["exit"] as? [String: Any]
                if exit?["_tag"] as? String == "Success" { return .sent }
                // The cause is a list of failures. Only a typed error
                // (`{_tag: Fail, error: {_tag, message}}`) means the command
                // was refused before anything was kept; a crash or an
                // interrupt (`Die`, `Interrupt`) may come after it was.
                let causes = (exit?["cause"] as? [[String: Any]]) ?? [(exit?["cause"] as? [String: Any])].compactMap { $0 }
                guard let error = causes.lazy.filter({ $0["_tag"] as? String == "Fail" })
                    .compactMap({ $0["error"] as? [String: Any] }).first else { return .unconfirmed }
                return .notSent(reason: (error["_tag"] as? String) ?? "failure")
            case "ClientProtocolError":
                // The request wasn't understood, so nothing ran.
                return .notSent(reason: "client_protocol_error")
            case "Defect":
                // The server failed somewhere; whether the message got in
                // can't be told.
                return .unconfirmed
            default:
                continue
            }
        }
        return nil
    }

    /// A session `t3 auth session issue --json` printed.
    struct IssuedSession: Codable, Equatable {
        let token: String
        /// To revoke it once a new one replaces it.
        let sessionID: String?
        let expiresAt: Date?
    }

    static func issuedSession(cliOutput: Data) -> IssuedSession? {
        guard let object = try? JSONSerialization.jsonObject(with: cliOutput) as? [String: Any],
              let token = object["token"] as? String, !token.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expiresAt = (object["expiresAt"] as? String).flatMap {
            formatter.date(from: $0) ?? ISO8601DateFormatter().date(from: $0)
        }
        return IssuedSession(token: token, sessionID: object["sessionId"] as? String, expiresAt: expiresAt)
    }
}
