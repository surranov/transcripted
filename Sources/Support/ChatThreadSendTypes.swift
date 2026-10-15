import Foundation

/// Fork: the thread a take was dictated into, as its app's own server names
/// it: where `ChatThreadSender` sends the take when the user isn't looking
/// at that thread.
enum ChatThreadSendTarget: Equatable {
    /// T3 Code's server environment and the thread's id (`T3CodeServer`).
    case t3Code(environmentID: String, threadID: String)
    /// A Codex thread's id (`CodexThreads`).
    case codex(threadID: String)
}

/// Fork: what sending a take to its thread through the app's server came to.
enum ChatThreadSendResult: Equatable {
    case sent
    /// Not sent, for certain: the server couldn't be reached, or it refused
    /// the session or the message. The take goes the usual way instead.
    case notSent(reason: String)
    /// The message went out and no answer came back: it may have arrived,
    /// so it is never sent again another way.
    case unconfirmed

    var diagnosticName: String {
        switch self {
        case .sent: return "sent"
        case .notSent: return "not_sent"
        case .unconfirmed: return "unconfirmed"
        }
    }
}
