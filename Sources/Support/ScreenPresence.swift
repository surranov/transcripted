// Support/ScreenPresence.swift
// Whether someone at this Mac could be looking at the screen right now.

import CoreGraphics

enum ScreenPresence {
    /// False while the screen is locked or the main display is asleep. A
    /// fresh read each call, so a lock that came before anyone asked can't be
    /// missed. The lock flag is the private but long-stable CGSession key
    /// Writing's `ScreenLockObserver` also reads (that module is off limits
    /// here). No session dictionary is not the normal signed-in case, so it
    /// reads as not viewable.
    static func screenIsViewable() -> Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if (info["CGSSessionScreenIsLocked"] as? Bool) == true { return false }
        return CGDisplayIsAsleep(CGMainDisplayID()) == 0
    }
}
