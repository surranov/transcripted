// Moving "Who was on this call?" between displays swaps its live view and a
// picture of it inside the built drop-downs: each takes the other's place,
// and nothing changes when the view to replace isn't in that drop-down.

import AppKit
import Foundation

@MainActor
func testNotchIslandDropSwap() async {
    func dropDown(_ views: [NSView]) -> (container: NSView, stack: NSStackView) {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 300))
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        container.addSubview(stack)
        return (container, stack)
    }

    runSuite("A swapped-in view takes the old one's place in the drop-down") {
        let title = NSView(), review = NSView(), buttons = NSView(), picture = NSView()
        let drop = dropDown([title, review, buttons])
        assertTrue(NotchIslandDropSwap.swap(review, for: picture, within: drop.container))
        assertTrue(drop.stack.arrangedSubviews == [title, picture, buttons], "same place, between the same neighbours")
        assertNil(review.superview, "the old view is out of the drop-down")
    }

    runSuite("The live view leaves the display it was on when another display takes it") {
        let live = NSView(), pictureA = NSView(), pictureB = NSView()
        let onA = dropDown([live])
        let onB = dropDown([pictureB])
        assertTrue(NotchIslandDropSwap.swap(live, for: pictureA, within: onA.container), "A gives the live view up first")
        assertTrue(NotchIslandDropSwap.swap(pictureB, for: live, within: onB.container), "then B takes it")
        assertTrue(onA.stack.arrangedSubviews == [pictureA], "A shows the picture")
        assertTrue(onB.stack.arrangedSubviews == [live], "B shows the live view")
    }

    runSuite("Nothing changes when the view to replace isn't in that drop-down") {
        let live = NSView(), picture = NSView(), other = NSView()
        let onA = dropDown([live])
        let onB = dropDown([other])
        assertFalse(
            NotchIslandDropSwap.swap(live, for: picture, within: onB.container),
            "the live view is in another display's drop-down"
        )
        assertTrue(onA.stack.arrangedSubviews == [live], "and it stays there")
        assertFalse(NotchIslandDropSwap.swap(NSView(), for: picture, within: onA.container), "a view in no drop-down")
        assertFalse(NotchIslandDropSwap.swap(live, for: live, within: onA.container), "a view for itself")
        assertTrue(onA.stack.arrangedSubviews == [live])
        assertNil(picture.superview, "the view that was to come in stays out")
    }
}
