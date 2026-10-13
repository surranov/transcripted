// NotchIslandPanel.swift
// The borderless, non-activating panel the notch island draws in. It sits
// above the menu bar (so the island can grow out of the notch) and never
// takes keyboard focus from the app being dictated into. It stays one size
// while the island is up; NotchIslandController lets clicks through it
// everywhere except over the island itself.

import AppKit

final class NotchIslandPanel: NSPanel {
    /// On every desktop, over full-screen apps too, never in window cycling.
    static let allSpacesBehavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

    private var isRejoiningSpaces = false

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: true
        )
        // Set before the level: turning floating on resets the level to
        // .floating, which sits under the menu bar.
        self.isFloatingPanel = true
        // Above the menu bar (and the status items beside the notch), below
        // open menus.
        self.level = .statusBar
        self.becomesKeyOnlyIfNeeded = true
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden
        self.isMovableByWindowBackground = false
        self.collectionBehavior = Self.allSpacesBehavior
        self.acceptsMouseMovedEvents = true
        self.animationBehavior = .none
        // Exclude the island from screen capture / screen sharing, like the
        // other overlays: a shared screen must not broadcast live dictation.
        self.sharingType = .none
    }

    /// On only while the island asks who was on a call and someone clicks a
    /// name box to type. The island otherwise never takes keyboard focus
    /// from the app being dictated into.
    var acceptsKeyForTyping = false

    override var canBecomeKey: Bool { acceptsKeyForTyping }
    override var canBecomeMain: Bool { false }

    /// Hidden from screen sharing and screenshots unless the person turned on
    /// Show island in screen sharing. The controller calls this before each
    /// show, so the switch applies at once.
    func applyScreenSharingPreference(userDefaults: UserDefaults = .standard) {
        let wanted: NSWindow.SharingType = NotchIslandPreferences.visibleInScreenSharing(userDefaults: userDefaults) ? .readOnly : .none
        // Called on every render; skip the window-server round trip when
        // nothing changed.
        if sharingType != wanted { sharingType = wanted }
    }

    /// macOS can leave this panel on one desktop with `canJoinAllSpaces`
    /// still set: after a display was plugged back in while the island was
    /// hidden, it stayed on that display's first desktop and never showed on
    /// the others. Ordering it out and in again keeps it there; clearing the
    /// behavior and setting it back on the next main-queue turn puts it on
    /// every desktop again, hidden or shown (a same-turn clear and set
    /// reaches the window server as no change). Returns whether it had to.
    @discardableResult
    func rejoinAllSpacesIfLeftBehind() -> Bool {
        // A deferred panel that was never shown has no window yet.
        guard windowNumber > 0, !isOnActiveSpace, !isRejoiningSpaces else { return false }
        isRejoiningSpaces = true
        collectionBehavior = []
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.collectionBehavior = Self.allSpacesBehavior
                self.isRejoiningSpaces = false
            }
        }
        return true
    }

    /// AppKit keeps windows out of the menu bar; the island belongs there.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
