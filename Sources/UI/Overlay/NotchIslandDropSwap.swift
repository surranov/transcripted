// NotchIslandDropSwap.swift
// Swaps one view for another in a built drop-down, in place. "Who was on this
// call?" moves its live view between displays this way (and a picture of it
// takes the live view's place), so the drop-downs don't fade out and back in.

import AppKit

enum NotchIslandDropSwap {
    /// Puts `new` where `old` sits in its stack inside `container`, taking
    /// `new` out of wherever it was. False, changing nothing, when `old`
    /// isn't an arranged view of a stack inside `container` (that drop-down
    /// isn't built, or `old` already moved).
    @MainActor
    static func swap(_ old: NSView, for new: NSView, within container: NSView) -> Bool {
        guard old !== new,
              old.isDescendant(of: container),
              let stack = old.superview as? NSStackView,
              let index = stack.arrangedSubviews.firstIndex(of: old) else { return false }
        stack.removeArrangedSubview(old)
        old.removeFromSuperview()
        new.removeFromSuperview()
        stack.insertArrangedSubview(new, at: index)
        return true
    }
}
