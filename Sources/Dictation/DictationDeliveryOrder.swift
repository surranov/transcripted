import Foundation

/// Fork: the paste order of the dictation queue. A take gets its number when
/// its stop is admitted; it pastes once every earlier take has pasted and
/// pressed send (Auto Enter), or ended without pasting (no speech,
/// cancelled, saved only), so words land in the order they were spoken even
/// when a later, shorter take is refined first, and each send carries only
/// its own take.
struct DictationDeliveryOrder: Equatable {
    private(set) var nextSequence = 0
    /// Every take up to this number is done with its paste.
    private(set) var deliveredThrough = -1
    /// Done out of turn: a take that ended while an earlier one still runs.
    private var deliveredAhead: Set<Int> = []

    mutating func assign() -> Int {
        defer { nextSequence += 1 }
        return nextSequence
    }

    /// Idempotent: a take may report its paste and then its end.
    mutating func markDelivered(_ sequence: Int) {
        guard sequence > deliveredThrough else { return }
        deliveredAhead.insert(sequence)
        while deliveredAhead.remove(deliveredThrough + 1) != nil {
            deliveredThrough += 1
        }
    }

    func isTurn(of sequence: Int) -> Bool {
        deliveredThrough >= sequence - 1
    }
}
