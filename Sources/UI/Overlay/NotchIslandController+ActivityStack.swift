// NotchIslandController+ActivityStack.swift
// Fork: the dictation queue's pyramid. The dictation controller reports the
// takes finishing behind the island; the island draws them as layers under
// its shape and lists them as hover cards (`NotchIslandActivityStack`).

import AppKit

extension NotchIslandController {
    /// The takes finishing behind the island, oldest first.
    func updateBackgroundTakes(_ takes: [NotchIslandBackgroundTake]) {
        guard takes != backgroundTakes else { return }
        backgroundTakes = takes
        render()
    }
}
