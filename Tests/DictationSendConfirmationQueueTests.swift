import Foundation

// With the dictation queue several takes can land, each in its own box,
// before the user answers any "send it?" prompt (DictationSendConfirmationQueue):
// each is asked in turn, in take order, one at a time.

func testDictationSendConfirmationQueue() {
    runSuite("DictationSendConfirmationQueue asks about each take once, in take order") {
        var queue = DictationSendConfirmationQueue<String>()
        queue.add("slack", order: 0)
        queue.add("telegram", order: 1)
        assertEqual(queue.count, 2)
        assertEqual(queue.showNext(), "slack", "the first to land is asked first")
        assertNil(queue.showNext(), "one prompt at a time")
        assertEqual(queue.count, 2, "the shown one still counts")
        assertEqual(queue.takeShown(), "slack", "answered")
        assertEqual(queue.showNext(), "telegram", "then the next")
        queue.takeShown()
        assertTrue(queue.isEmpty)
        assertNil(queue.takeShown(), "nothing left to answer")
    }

    runSuite("DictationSendConfirmationQueue asks again after a new take, before later sends") {
        var queue = DictationSendConfirmationQueue<String>()
        queue.add("slack", order: 0)
        queue.showNext()
        queue.add("telegram", order: 1)
        queue.putShownBack()
        assertNil(queue.shown, "nothing on the island while the new take runs")
        assertEqual(queue.waiting, ["slack", "telegram"], "the unanswered one stays first")
        queue.putShownBack()
        assertEqual(queue.waiting, ["slack", "telegram"], "nothing shown, nothing moves")
    }

    runSuite("DictationSendConfirmationQueue passes over a send that won't be asked") {
        var queue = DictationSendConfirmationQueue<String>()
        queue.add("sent-by-hand", order: 0)
        queue.add("telegram", order: 1)
        queue.dropNext()
        assertEqual(queue.next, "telegram")
        queue.dropNext()
        queue.dropNext()
        assertTrue(queue.isEmpty, "dropping past the end is harmless")
    }

    runSuite("DictationSendConfirmationQueue keeps take order when a later take gets there first") {
        var queue = DictationSendConfirmationQueue<String>()
        queue.add("third", order: 2)
        queue.add("first", order: 0)
        queue.add("second", order: 1)
        queue.add("second-too", order: 1)
        assertEqual(queue.waiting, ["first", "second", "second-too", "third"], "by take, ties by arrival")
        queue.showNext()
        queue.add("zeroth", order: -1)
        assertEqual(queue.shown, "first", "the one on the island isn't pushed off")
        assertEqual(queue.next, "zeroth", "an earlier take is asked right after it")
    }
}
