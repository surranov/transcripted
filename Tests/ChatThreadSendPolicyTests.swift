import Foundation

// Sending a take to the chat thread it was dictated into through the app's
// own server (ChatThreadSendPolicy, T3CodeServer). Pages, files and frames
// are as T3 Code (Nightly) wrote and answered them on 2026-10-15; the send
// itself needs a running T3 Code.

private typealias Page = ChatThreadPolicy.Page

private let t3 = "com.t3tools.t3code"
private let environment = "c25d1cbe-e9bc-406f-aed2-9d76f720525a"
private let thread = "0942014c-f176-4a8d-a071-e642a5330787"

private func json(_ data: Data?) -> [String: Any] {
    data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
}

private func frame(_ string: String) -> Data { Data(string.utf8) }

private func decision(
    _ behavior: DictationSendBehavior,
    text: String = "Fix the pagination",
    duration: TimeInterval = 5,
    sendKey: Bool = false
) -> DictationAutoSendRequestDecision {
    // As the session asks: the thread stands in for the anchored box.
    DictationSendSettings.decision(
        behavior: behavior, isOverride: false, key: .enter, text: text, duration: duration,
        hasAnchor: true, anchoredPasteEnabled: true, startedWithDictateAndSendKey: sendKey
    )
}

func testChatThreadSendPolicy() {
    runSuite("A T3 Code page names the thread to send to; a draft or another page doesn't") {
        let address = T3CodeServer.threadAddress(pageURL: "t3code://app/#/\(environment)/\(thread)")
        assertEqual(address?.environmentID, environment, "the environment comes first")
        assertEqual(address?.threadID, thread, "then the thread")
        assertNil(T3CodeServer.threadAddress(pageURL: "t3code://app/#/draft/9be71f5c"), "a new chat has no thread on the server yet")
        assertEqual(
            T3CodeServer.threadAddress(pageURL: "t3code://app/#/\(environment)/mcp%3A1a9ad813-6936")?.threadID,
            "mcp:1a9ad813-6936",
            "a thread made by an agent has a colon in its id, escaped in the address"
        )
        assertEqual(
            T3CodeServer.threadAddress(pageURL: "t3code://app/#/\(environment)/\(thread)?diff=1")?.threadID, thread,
            "a panel open in the thread"
        )
        assertNil(T3CodeServer.threadAddress(pageURL: "http://localhost:5173/#/\(environment)/\(thread)"), "only T3 Code's own page")
        assertNil(T3CodeServer.threadAddress(pageURL: "t3code://app/#/settings"), "a page that isn't a thread")
        assertNil(T3CodeServer.threadAddress(pageURL: "t3code://app/#/\(environment)/\(thread)/extra"), "a deeper route isn't a thread")
    }

    runSuite("Only a T3 Code window showing one thread has somewhere to send") {
        let threadPage = Page(url: "t3code://app/#/\(environment)/\(thread)", title: "T3 Code (Nightly)")
        let preview = Page(url: "http://localhost:3000/", title: "My site")
        assertEqual(
            ChatThreadSendPolicy.sendTarget(bundleID: t3, pages: [threadPage, preview]),
            .t3Code(environmentID: environment, threadID: thread),
            "a site previewed beside the thread doesn't count"
        )
        assertEqual(
            ChatThreadSendPolicy.sendTarget(bundleID: t3, pages: [Page(url: "t3code://app/#/draft/9be71f5c", title: nil)]),
            .t3CodeDraft(draftID: "9be71f5c"),
            "a new chat: its first message starts its thread (T3CodeDraftsTests)"
        )
        assertNil(
            ChatThreadSendPolicy.sendTarget(bundleID: t3, pages: [threadPage, Page(url: "t3code://app/#/\(environment)/other", title: nil)]),
            "two threads in one window: which one is unknown"
        )
        assertNil(
            ChatThreadSendPolicy.sendTarget(bundleID: "com.anthropic.claudefordesktop", pages: [threadPage]),
            "Claude has no way to send through"
        )
        assertNil(ChatThreadSendPolicy.sendTarget(bundleID: t3, pages: []), "no page read")
    }

    runSuite("Only a take that sends goes to its thread; After I confirm asks first") {
        assertEqual(ChatThreadSendPolicy.plan(decision(.send)), .sendNow, "Send")
        assertEqual(ChatThreadSendPolicy.plan(decision(.afterConfirm)), .askFirst, "After I confirm, with or without Anchored paste")
        assertNil(ChatThreadSendPolicy.plan(decision(.dontSend)), "Don't send goes the usual way")
        assertNil(ChatThreadSendPolicy.plan(decision(.withDictateAndSendKey)), "the plain dictation key doesn't send")
        assertEqual(ChatThreadSendPolicy.plan(decision(.withDictateAndSendKey, sendKey: true)), .sendNow, "the Dictate & send key does")
        assertNil(ChatThreadSendPolicy.plan(decision(.send, text: "  ")), "nothing to send")
        assertNil(ChatThreadSendPolicy.plan(decision(.send, duration: 0.1)), "a take too short to send")
    }

    runSuite("The user is away from the thread: another thread in front, or another app with Anchored paste on") {
        assertTrue(ChatThreadSendPolicy.userIsAway(threadAppIsFrontmost: true, showsAnotherThread: true, anchoredPasteEnabled: false), "another thread in T3 Code")
        assertFalse(ChatThreadSendPolicy.userIsAway(threadAppIsFrontmost: true, showsAnotherThread: false, anchoredPasteEnabled: true), "still in that thread: pasted there")
        assertTrue(ChatThreadSendPolicy.userIsAway(threadAppIsFrontmost: false, showsAnotherThread: false, anchoredPasteEnabled: true), "another app, the words would wait")
        assertFalse(ChatThreadSendPolicy.userIsAway(threadAppIsFrontmost: false, showsAnotherThread: false, anchoredPasteEnabled: false), "another app without Anchored paste: the words follow the user")
    }

    runSuite("The server is found from its own files, and only on this Mac") {
        let runtime = frame(#"{"version":1,"pid":90099,"host":"127.0.0.1","port":3773,"origin":"http://127.0.0.1:3773","startedAt":"x"}"#)
        assertEqual(
            T3CodeServer.runtime(serverRuntimeJSON: runtime, environmentID: environment + "\n"),
            T3CodeServer.Runtime(host: "127.0.0.1", port: 3773, environmentID: environment, pid: 90099),
            "host, port, the environment id (trimmed) and the process, whose file outlives a crash"
        )
        assertNil(T3CodeServer.runtime(serverRuntimeJSON: frame(#"{"host":"192.168.1.5","port":3773}"#), environmentID: environment), "the bearer never leaves this Mac")
        assertEqual(
            T3CodeServer.runtime(serverRuntimeJSON: frame(#"{"port":3773}"#), environmentID: environment)?.host, "127.0.0.1",
            "a server started without a host listens everywhere: reached on loopback"
        )
        assertNil(T3CodeServer.runtime(serverRuntimeJSON: frame(#"{"host":"127.0.0.1"}"#), environmentID: environment), "no port")
        assertNil(T3CodeServer.runtime(serverRuntimeJSON: runtime, environmentID: " "), "no environment id")
        assertNil(T3CodeServer.runtime(serverRuntimeJSON: frame("not json"), environmentID: environment), "a broken file")
        assertEqual(
            T3CodeServer.homeDirectory(environment: ["T3CODE_HOME": "/tmp/t3home"]).path, "/tmp/t3home",
            "T3CODE_HOME, as T3 Code's CLI reads it"
        )
        assertTrue(T3CodeServer.homeDirectory(environment: [:]).path.hasSuffix("/.t3"), "else ~/.t3")
        assertTrue(
            T3CodeServer.homeDirectory(environment: ["T3CODE_HOME": "relative/dir"]).path.hasSuffix("/.t3"),
            "a relative T3CODE_HOME would depend on where Transcripted runs: ~/.t3"
        )
        assertEqual(
            T3CodeServer.runtime(serverRuntimeJSON: frame(#"{"host":"0.0.0.0","port":3773}"#), environmentID: environment)?.host, "127.0.0.1",
            "a server listening everywhere is reached on loopback"
        )
        let descriptor = frame(#"{"environmentId":"\#(environment)","label":"Mac","serverVersion":"0.0.46","orchestrationProtocolVersion":2,"capabilities":{}}"#)
        assertTrue(T3CodeServer.describes(environmentID: environment, descriptorJSON: descriptor), "the port is T3 Code's server for the thread's environment")
        assertFalse(T3CodeServer.describes(environmentID: "another", descriptorJSON: descriptor), "another environment: the bearer isn't sent")
        assertFalse(
            T3CodeServer.describes(environmentID: environment, descriptorJSON: frame(#"{"environmentId":"\#(environment)"}"#)),
            "a server without this protocol"
        )
        assertFalse(T3CodeServer.describes(environmentID: environment, descriptorJSON: frame("<html>")), "something else on the port")
    }

    runSuite("The message goes as the composer's Enter: steering or queued as T3 Code's Follow-up behavior says") {
        assertEqual(T3CodeServer.FollowUp(clientSettingsJSON: frame(#"{"followUpBehavior":"queue"}"#)), .queue, "Queue")
        assertEqual(T3CodeServer.FollowUp(clientSettingsJSON: frame(#"{"followUpBehavior":"steer"}"#)), .steer, "Steer")
        assertEqual(T3CodeServer.FollowUp(clientSettingsJSON: nil), .steer, "no settings file: T3 Code's default")

        let steering = json(T3CodeServer.dispatchRequest(
            requestID: "1", threadID: thread, text: "Fix it", commandID: UUID(), messageID: UUID(), followUp: .steer
        ))
        assertEqual(steering["_tag"] as? String, "Request", "an Effect RPC request")
        assertEqual(steering["tag"] as? String, "orchestration.dispatchCommand", "the composer's command")
        let command = steering["payload"] as? [String: Any] ?? [:]
        assertEqual(command["type"] as? String, "message.dispatch", "a message")
        assertEqual(command["threadId"] as? String, thread, "into the take's thread")
        assertEqual(command["text"] as? String, "Fix it", "the take's words")
        assertEqual(command["createdBy"] as? String, "user", "the user's own message")
        assertEqual(
            command["deliveryIntent"] as? String, "auto",
            "auto, not steer: a turn still starting refuses a steer, and auto queues behind it"
        )
        assertEqual((command["dispatchMode"] as? [String: Any])?["type"] as? String, "start_immediately", "idle: the agent starts on it")

        let queued = json(T3CodeServer.dispatchRequest(
            requestID: "1", threadID: thread, text: "Fix it", commandID: UUID(), messageID: UUID(), followUp: .queue
        ))["payload"] as? [String: Any] ?? [:]
        assertNil(queued["deliveryIntent"] as? String, "queued: no intent")
        assertEqual((queued["dispatchMode"] as? [String: Any])?["type"] as? String, "queue_after_active", "behind the turn, or at once when idle")
    }

    runSuite("The server's answer: sent, refused (so the usual way may run), or unknown (never sent twice)") {
        assertEqual(
            T3CodeServer.reply(to: "1", frame: frame(#"{"_tag":"Exit","requestId":"1","exit":{"_tag":"Success","value":{"sequence":42}}}"#)),
            .sent, "accepted"
        )
        assertEqual(
            T3CodeServer.reply(to: "1", frame: frame(#"{"_tag":"Exit","requestId":"1","exit":{"_tag":"Failure","cause":[{"_tag":"Fail","error":{"_tag":"OrchestrationV2DispatchCommandError","message":"No orchestration projection exists for thread x."}}]}}"#)),
            .notSent(reason: T3CodeServer.dispatchRefused), "a thread gone, or a turn that can't take words now"
        )
        assertEqual(
            T3CodeServer.reply(to: "1", frame: frame(#"{"_tag":"Exit","requestId":"1","exit":{"_tag":"Failure","cause":{"_tag":"Fail","error":{"_tag":"EnvironmentAuthorizationError"}}}}"#)),
            .notSent(reason: "EnvironmentAuthorizationError"), "a cause given as one object"
        )
        assertEqual(
            T3CodeServer.reply(to: "1", frame: frame(#"{"_tag":"Exit","requestId":"1","exit":{"_tag":"Failure","cause":[{"_tag":"Die","defect":"boom"}]}}"#)),
            .unconfirmed, "a crash may come after the message was kept: never sent again another way"
        )
        assertEqual(
            T3CodeServer.reply(to: "1", frame: frame(#"{"_tag":"Exit","requestId":"1","exit":{"_tag":"Failure","cause":{"_tag":"Interrupt"}}}"#)),
            .unconfirmed, "an interrupt, likewise"
        )
        assertNil(T3CodeServer.reply(to: "1", frame: frame(#"{"_tag":"Exit","requestId":"2","exit":{"_tag":"Success"}}"#)), "another request's answer")
        assertNil(T3CodeServer.reply(to: "1", frame: frame(#"{"_tag":"Pong"}"#)), "a keep-alive")
        assertNil(T3CodeServer.reply(to: "1", frame: frame("garbage")), "not JSON")
        assertEqual(T3CodeServer.reply(to: "1", frame: frame(#"{"_tag":"Defect","defect":"boom"}"#)), .unconfirmed, "the server broke: it may have it")
        assertEqual(
            T3CodeServer.reply(to: "1", frame: frame(#"{"_tag":"ClientProtocolError","error":{}}"#)),
            .notSent(reason: "client_protocol_error"), "a request it couldn't read ran nothing"
        )
        assertEqual(
            T3CodeServer.reply(to: "1", frame: frame(#"[{"_tag":"Pong"},{"_tag":"Exit","requestId":"1","exit":{"_tag":"Success"}}]"#)),
            .sent, "a batch of messages"
        )
    }

    runSuite("The session comes from T3 Code's CLI") {
        let issued = T3CodeServer.issuedSession(cliOutput: frame(
            #"{"sessionId":"s1","token":"abc","scopes":["orchestration:operate"],"expiresAt":"2026-10-22T05:42:35.394Z"}"#
        ))
        assertEqual(issued?.token, "abc", "`t3 auth session issue --json`")
        assertEqual(issued?.sessionID, "s1", "kept to revoke it once replaced")
        assertTrue(abs((issued?.expiresAt?.timeIntervalSince1970 ?? 0) - 1_792_647_755.394) < 0.01, "renewed before it runs out")
        assertNil(T3CodeServer.issuedSession(cliOutput: frame(#"{"error":"no"}"#)), "no token")
        assertNil(T3CodeServer.issuedSession(cliOutput: frame("Issued session")), "not JSON")
        assertEqual(T3CodeServer.sessionScope, "orchestration:operate", "the narrowest scope that can send a message")
        assertEqual(T3CodeServer.sessionTTL, "7d", "a week, renewed when it has an hour left")
    }

    runSuite("The island and Dictations say where the words went") {
        assertEqual(
            ChatThreadSendPolicy.confirmationPrompt(confirmKey: .enter, appName: "T3 Code", text: "Fix the pagination"),
            "Send it to its thread in T3 Code? Press Enter.", "one send waiting"
        )
        assertEqual(
            ChatThreadSendPolicy.confirmationPrompt(confirmKey: .commandEnter, appName: "T3 Code", text: "Fix the pagination", waitingAfter: 1),
            "Send “Fix the pagination” to its thread in T3 Code? Press ⌘ Enter (1 more waiting).", "more waiting: its words tell them apart"
        )
        assertEqual(ChatThreadSendPolicy.sentTitle, "Sent to its thread", "the island once it went")
        assertFalse(
            ChatThreadSendPolicy.unconfirmedMessage(appName: "T3 Code").contains("clipboard"),
            "a confirmed send that got no answer copied nothing"
        )
        assertTrue(
            ChatThreadSendPolicy.unconfirmedMessage(appName: "T3 Code", onClipboard: true).contains("on your clipboard"),
            "a send at once that got no answer copied the words"
        )
        assertEqual(DictationDelivery.sentToThread.rawValue, "sent_to_thread", "Dictations' Delivery line")
        assertEqual(DictationDelivery(rawValue: "sent_to_thread"), .sentToThread, "read back")
        assertEqual(DictationDelivery.sentToThread.summaryText, "Sent to its thread", "the card's summary")
        assertNil(DictationCardFormatting.deliveryProblem(.sentToThread), "no amber note: the words landed")
        assertEqual(ChatThreadSendResult.unconfirmed.diagnosticName, "unconfirmed", "logged without the words or the thread")
    }
}
