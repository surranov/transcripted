import Foundation

// The dictation queue pastes takes in the order they were spoken
// (DictationDeliveryOrder): a take waits for every earlier take to paste or
// end, never for a later one.

func testDictationDeliveryOrder() {
    runSuite("DictationDeliveryOrder numbers takes and lets the first paste at once") {
        var order = DictationDeliveryOrder()
        let first = order.assign()
        let second = order.assign()
        assertEqual([first, second], [0, 1], "numbered at their stops")
        assertTrue(order.isTurn(of: first), "nothing before the first take")
        assertTrue(!order.isTurn(of: second), "the second waits for the first")
        order.markDelivered(first)
        assertTrue(order.isTurn(of: second), "then it pastes")
    }

    runSuite("DictationDeliveryOrder keeps order when a later take finishes first") {
        var order = DictationDeliveryOrder()
        let a = order.assign(), b = order.assign(), c = order.assign()
        order.markDelivered(b)
        assertTrue(!order.isTurn(of: c), "b ended early, but a still runs: c waits")
        assertEqual(order.deliveredThrough, -1, "nothing is done in order yet")
        order.markDelivered(a)
        assertEqual(order.deliveredThrough, b, "a done lets b's early end count")
        assertTrue(order.isTurn(of: c), "c's turn")
    }

    runSuite("DictationDeliveryOrder takes a take reporting twice") {
        var order = DictationDeliveryOrder()
        let a = order.assign()
        order.markDelivered(a)
        order.markDelivered(a)
        let b = order.assign()
        assertTrue(order.isTurn(of: b), "a paste then an end of the same take count once")
        assertEqual(order.deliveredThrough, a)
    }
}
