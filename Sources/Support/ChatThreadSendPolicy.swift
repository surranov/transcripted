import Foundation

/// Fork: a take dictated into an AI chat thread whose app can be sent to
/// unseen (T3 Code through its server, Codex through its CLI's queue;
/// `sendTarget`) goes to that thread when the user isn't looking at it: the
/// app is in front showing another thread (the chat thread guard would keep
/// the words out), or, with Anchored paste on, another app is in front (the
/// words would wait for the user to come back). Only a take that sends: Send and With Dictate & send key send
/// it at once, After I confirm asks first. Don't send goes the usual way.
///
/// Words that already landed in the app's box are never sent this way: the
/// box would keep them as a draft and they'd go twice.
enum ChatThreadSendPolicy {
    enum Plan: Equatable {
        case sendNow
        case askFirst
    }

    /// The plan for a take whose send decision was made with its thread
    /// standing in for the anchored box (`DictationSendSettings.decision`
    /// with a box and Anchored paste); nil when it doesn't send.
    static func plan(_ decision: DictationAutoSendRequestDecision) -> Plan? {
        guard decision.expected else { return nil }
        return decision.awaitsConfirmation ? .askFirst : .sendNow
    }

    /// Whether the user isn't looking at the thread the take was dictated
    /// into. Another app in front counts only with Anchored paste on: with
    /// it off the words follow the user, as they always did.
    static func userIsAway(threadAppIsFrontmost: Bool, showsAnotherThread: Bool, anchoredPasteEnabled: Bool) -> Bool {
        threadAppIsFrontmost ? showsAnotherThread : anchoredPasteEnabled
    }

    /// Where the pages of a take's start send to; nil for an app that can't
    /// be sent to, a new chat, or a window showing two threads. Codex names
    /// the thread only by its page title: `codexThreadIDs` gives the threads
    /// with that name (`CodexThreads.ids`), and one must have it.
    static func sendTarget(
        bundleID: String?,
        pages: [ChatThreadPolicy.Page],
        codexThreadIDs: (String) -> [String] = { _ in [] }
    ) -> ChatThreadSendTarget? {
        if bundleID == CodexThreads.bundleID {
            let names = Set(pages.compactMap(\.title).filter { !$0.isEmpty })
            guard !ChatThreadPolicy.isNewChat(bundleID: bundleID, pages: pages),
                  names.count == 1, let name = names.first else { return nil }
            let ids = codexThreadIDs(name)
            return ids.count == 1 ? .codex(threadID: ids[0]) : nil
        }
        guard bundleID == T3CodeServer.bundleID else { return nil }
        let threads = pages.compactMap { $0.url.flatMap(T3CodeServer.threadAddress(pageURL:)) }
        guard let first = threads.first,
              threads.allSatisfy({ $0.environmentID == first.environmentID && $0.threadID == first.threadID }) else { return nil }
        return .t3Code(environmentID: first.environmentID, threadID: first.threadID)
    }

    // MARK: - The island

    static let sentTitle = "Sent to its thread"

    /// The island's line while a send to the thread waits for the confirm.
    static func confirmationPrompt(
        confirmKey: DictationSendConfirmKey,
        appName: String,
        text: String,
        waitingAfter: Int = 0
    ) -> String {
        guard waitingAfter > 0 else {
            return "Send it to its thread in \(appName)? Press \(confirmKey.title)."
        }
        return "Send “\(DictationAutoSendPolicy.confirmationQuote(text))” to its thread in \(appName)? Press \(confirmKey.title) (\(waitingAfter) more waiting)."
    }

    /// Under "Not pasted" when the server didn't answer.
    static let unconfirmedHint = "Its thread may have it already. Check before you paste."

    /// Without an island, the line in its place (the island shows the
    /// words with Paste); `onClipboard` when they were copied too.
    static func unconfirmedMessage(appName: String, onClipboard: Bool = false) -> String {
        "\(appName) didn't confirm it got your words. "
            + (onClipboard ? "They're on your clipboard — check its thread before you paste." : "Check its thread before you paste them.")
    }

    /// The clipboard couldn't take the words of an unconfirmed send.
    static func unconfirmedNotCopiedMessage(appName: String) -> String {
        "\(appName) didn't confirm it got your words, and they couldn't go on your clipboard. They're saved in Dictations."
    }

    /// Under "Not pasted" when the island's ask ran out unanswered.
    static let notConfirmedHint = "You didn't confirm, so it wasn't sent. Paste it where it goes."

    static func notConfirmedMessage(appName: String) -> String {
        "Not sent to its thread in \(appName): you didn't confirm. Paste it where it goes."
    }

    /// Under "Not pasted" when a confirmed send didn't go.
    static let notSentHint = "Couldn't send it to its thread. Paste it where it goes."

    static func notSentMessage(appName: String) -> String {
        "Couldn't send it to its thread in \(appName). Paste it where it goes."
    }
}
