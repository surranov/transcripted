// The island panel shows on every desktop and over full-screen apps, and a
// panel macOS left on one desktop is put back in two turns. Whether the window
// server really moves it back is checked live: that needs several desktops
// (see NotchIslandPanel.rejoinAllSpacesIfLeftBehind()).

import AppKit
import Foundation

@MainActor
func testNotchIslandPanel() async {
    _ = NSApplication.shared

    func makePanel() -> NotchIslandPanel {
        // Same arguments NotchIslandSurface uses.
        NotchIslandPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 32),
            styleMask: [],
            backing: .buffered,
            defer: true
        )
    }

    runSuite("The notch island panel is on every desktop and over full-screen apps") {
        let panel = makePanel()
        assertTrue(
            panel.collectionBehavior.contains(.canJoinAllSpaces),
            "the island must show on whichever desktop is in front"
        )
        assertTrue(
            panel.collectionBehavior.contains(.fullScreenAuxiliary),
            "the island must show over an app in full screen"
        )
        assertFalse(
            panel.collectionBehavior.contains(.moveToActiveSpace),
            "moving to the active desktop would drop it from the others"
        )
    }

    runSuite("Only a panel off the desktop in front is put back on every desktop") {
        assertTrue(
            NotchIslandPanel.isLeftBehind(hasWindow: true, isOnActiveSpace: false, isRejoining: false),
            "a window the desktop in front doesn't have was left behind"
        )
        assertFalse(
            NotchIslandPanel.isLeftBehind(hasWindow: true, isOnActiveSpace: true, isRejoining: false),
            "a panel on the desktop in front, hidden or shown, is left alone"
        )
        assertFalse(
            NotchIslandPanel.isLeftBehind(hasWindow: false, isOnActiveSpace: false, isRejoining: false),
            "a panel that was never shown has no window to move"
        )
        assertFalse(
            NotchIslandPanel.isLeftBehind(hasWindow: true, isOnActiveSpace: false, isRejoining: true),
            "a rejoin already halfway waits for its second turn"
        )

        let neverShown = makePanel()
        assertFalse(neverShown.rejoinAllSpacesIfLeftBehind(), "a panel with no window yet is on no desktop to leave")
        assertEqual(neverShown.collectionBehavior, NotchIslandPanel.allSpacesBehavior, "and keeps joining every desktop")
    }

    runSuite("Rejoining drops every-desktop for one turn, stays over full-screen apps, then sets it back") {
        let panel = makePanel()
        var heldTurns: [@MainActor () -> Void] = []
        panel.onNextTurn = { heldTurns.append($0) }

        panel.rejoinAllSpaces()
        assertFalse(
            panel.collectionBehavior.contains(.canJoinAllSpaces),
            "dropped first: setting it back in the same turn reaches the window server as no change"
        )
        assertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary), "still over a full-screen app in between")
        assertTrue(panel.isRejoiningSpaces, "halfway")
        assertEqual(heldTurns.count, 1, "the second half waits for the next turn")

        heldTurns.forEach { $0() }
        assertEqual(panel.collectionBehavior, NotchIslandPanel.allSpacesBehavior, "every desktop again on the next turn")
        assertFalse(panel.isRejoiningSpaces, "done")
    }
}
