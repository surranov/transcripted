// The island panel shows on every desktop and over full-screen apps, and
// putting it back on every desktop never touches a panel that was never shown.
// Whether macOS really moves a left-behind panel back is checked live: it needs
// a window server with several desktops (see NotchIslandPanel).

import AppKit
import Foundation

@MainActor
func testNotchIslandPanel() async {
    _ = NSApplication.shared

    func makePanel() -> NotchIslandPanel {
        // Same arguments NotchIslandController uses.
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

    runSuite("Putting the island back on every desktop leaves a panel that was never shown alone") {
        let panel = makePanel()
        assertFalse(panel.rejoinAllSpacesIfLeftBehind(), "a panel with no window yet is on no desktop to leave")
        assertEqual(
            panel.collectionBehavior,
            NotchIslandPanel.allSpacesBehavior,
            "the panel keeps joining every desktop"
        )
    }
}
