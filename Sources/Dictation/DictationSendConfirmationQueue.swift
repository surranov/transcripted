import Foundation

/// Fork: the sends waiting for the user's confirm
/// (`DictationAutoSendMode.confirmAfterPaste`), one per pasted take. With the
/// dictation queue several takes can land, each in its own box, before the
/// user answers any of them, so they wait in take order and the island asks
/// about one at a time: the confirm key and Send act on the one it shows
/// (`DictationSessionController+SendConfirmation.swift`).
struct DictationSendConfirmationQueue<Request> {
    private typealias Entry = (order: Int, request: Request)

    private var entries: [Entry] = []
    private var shownEntry: Entry?

    var waiting: [Request] { entries.map(\.request) }
    /// The one the island asks about now.
    var shown: Request? { shownEntry?.request }
    var isEmpty: Bool { entries.isEmpty && shownEntry == nil }
    /// Everything still to be answered, the shown one included.
    var count: Int { entries.count + (shownEntry == nil ? 0 : 1) }
    /// The one the island asks about next.
    var next: Request? { entries.first?.request }

    /// `order` is the take's place in the dictation queue
    /// (`DictationDeliveryOrder`): a take that gets here late (a slow save)
    /// still waits behind earlier takes. Equal orders keep arrival order.
    mutating func add(_ request: Request, order: Int) {
        let index = entries.firstIndex { $0.order > order } ?? entries.endIndex
        entries.insert((order, request), at: index)
    }

    /// The next one is on the island now. Nil while one is up already.
    @discardableResult
    mutating func showNext() -> Request? {
        guard shownEntry == nil, !entries.isEmpty else { return nil }
        shownEntry = entries.removeFirst()
        return shownEntry?.request
    }

    /// The next one won't be asked (its box was emptied meanwhile).
    mutating func dropNext() {
        guard !entries.isEmpty else { return }
        entries.removeFirst()
    }

    /// The shown one was answered (sent, dismissed, the wait ran out).
    @discardableResult
    mutating func takeShown() -> Request? {
        defer { shownEntry = nil }
        return shownEntry?.request
    }

    /// Something else took the island before the user answered (a new take,
    /// another message): the shown one goes back to the front and is asked
    /// again once the island is free.
    mutating func putShownBack() {
        guard let shownEntry else { return }
        entries.insert(shownEntry, at: 0)
        self.shownEntry = nil
    }
}
