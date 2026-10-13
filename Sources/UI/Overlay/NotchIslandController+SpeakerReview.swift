// NotchIslandController+SpeakerReview.swift
// "Who was on this call?" on every display, and the keyboard while a name is
// typed. The presenter's view is one live view with name boxes and playback,
// and a view sits in one window, so it lives on one surface (the display under
// the pointer when it opened) and the others show a picture of it, repainted
// while it is up. The pointer reaching the island on another display moves
// the live view there; a name box that had the keyboard gives it back first.

import AppKit

extension NotchIslandController {
    /// Shows (or with nil, takes down) "Who was on this call?". The view is
    /// owned by the review's presenter and kept alive across drop-down
    /// rebuilds so typing and playback carry on.
    func showSpeakerReview(_ content: NotchIslandSpeakerReviewContent?, view: NSView?) {
        ensureSurfaces()
        speakerReview = content
        speakerReviewView = content == nil ? nil : view
        chooseSpeakerReviewHost()
        placeSpeakerReview()
        render()
    }

    /// Keeps the live view's display, or picks one (NotchIslandDisplays.reviewHost).
    func chooseSpeakerReviewHost() {
        speakerReviewHostID = speakerReviewView == nil ? nil : NotchIslandDisplays.reviewHost(
            keeping: speakerReviewHostID,
            pointer: NSEvent.mouseLocation,
            in: surfaces.map(\.display)
        )
    }

    /// The surface holding the live view.
    var speakerReviewHost: NotchIslandSurface? {
        guard let id = speakerReviewHostID else { return nil }
        return surfaces.first { $0.display.id == id }
    }

    /// The live view on its display, a picture of it on the others. Taking
    /// the review down leaves the drop-downs as they are, so they fade with
    /// the island; the next render changes them anyway.
    func placeSpeakerReview() {
        let host = speakerReviewHost
        // The display giving the live view up goes first, so the live view
        // leaves its drop-down before another one takes it.
        let givingUp = surfaces.filter { $0 !== host && $0.view.speakerReviewView === speakerReviewView }
        for surface in givingUp + surfaces.filter({ surface in !givingUp.contains { $0 === surface } }) {
            let isHost = surface === host
            let shown: NSView? = speakerReviewView.map { isHost ? $0 : surface.speakerReviewMirror }
            if let shown, let previous = surface.view.speakerReviewView, previous !== shown {
                // The same drop-down, another view in it: swap in place, so
                // the drop-down doesn't fade out and back in.
                if !NotchIslandDropSwap.swap(previous, for: shown, within: surface.view) { rebuildDropOnNextRender(surface) }
            }
            surface.view.speakerReviewView = shown
            // Gone while the island was down: no shrink will clear it.
            if speakerReviewView == nil, !isShown { surface.speakerReviewMirror.image = nil }
            // Once naming ends (Done, Later, or a newer review), the name boxes
            // can't take the keyboard again; render() hands it back if they had it.
            surface.panel.acceptsKeyForTyping = isHost && speakerReview?.stage == .naming
        }
    }

    /// The pointer reached the island on `surface`: bring the live review
    /// there, so what it points at is what it clicks. A name being typed
    /// moves with it and keeps the keyboard.
    func moveSpeakerReview(to surface: NotchIslandSurface) {
        guard speakerReviewOnScreen,
              let host = speakerReviewHost,
              host !== surface else { return }
        let typingField = host.panel.typingField
        returnKeyboardIfHeld()
        // Ending the edit can re-render, and that may have moved it already.
        guard speakerReviewHost !== surface else { return }
        speakerReviewHostID = surface.display.id
        // While the live view is still laid out over there, picture it for
        // the display it leaves.
        refreshSpeakerReviewMirrors(rendersOnResize: false)
        placeSpeakerReview()
        render(animated: false)
        if let typingField { keepTyping(in: typingField) }
    }

    /// Gives the keyboard to the name box being typed into after its view
    /// moved windows, caret at the end (focusing a text field selects all of
    /// it, and the next key would replace the name so far).
    func keepTyping(in field: NSView) {
        guard let host = speakerReviewHost, host.panel.acceptsKeyForTyping,
              field.isDescendant(of: host.view), host.panel.isVisible else { return }
        if !host.panel.isKeyWindow { keyboardReturnApp = keyboardReturnApp ?? Self.frontmostOtherApp() }
        host.panel.makeKey()
        host.panel.makeFirstResponder(field)
        if let editor = (field as? NSControl)?.currentEditor() {
            editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
        }
    }

    /// Repaints the picture of the review on the displays the live view is
    /// not on. A picture that changes size needs the island resized, which
    /// `render()` does itself, so only the clock asks for it.
    func refreshSpeakerReviewMirrors(rendersOnResize: Bool) {
        let host = speakerReviewHost
        // Only pictures someone can see are worth painting.
        let targets = surfaces.filter { $0 !== host && !$0.isCovered }
        guard !targets.isEmpty, let live = speakerReviewView, let window = live.window else { return }
        // Just rendered: lay the drop-down out so the picture has its size now.
        window.layoutIfNeeded()
        let bounds = live.bounds
        // Sharp on the sharpest display, whichever one the live view is on.
        let scale = surfaces.map(\.panel.backingScaleFactor).max() ?? 2
        guard bounds.width > 0, bounds.height > 0,
              let rep = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: Int((bounds.width * scale).rounded(.up)),
                  pixelsHigh: Int((bounds.height * scale).rounded(.up)),
                  bitsPerSample: 8,
                  samplesPerPixel: 4,
                  hasAlpha: true,
                  isPlanar: false,
                  colorSpaceName: .deviceRGB,
                  bytesPerRow: 0,
                  bitsPerPixel: 0
              ) else { return }
        rep.size = bounds.size
        // In the live window's colors, so the accent matches on every display.
        let tagged = window.colorSpace.flatMap { rep.retagging(with: $0) } ?? rep
        live.cacheDisplay(in: bounds, to: tagged)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(tagged)
        var resized = false
        for surface in targets {
            resized = resized || surface.speakerReviewMirror.image?.size != image.size
            surface.speakerReviewMirror.image = image
        }
        if resized, rendersOnResize { render() }
    }

    /// Keeps the pictures moving (rings, the match animation, the Later
    /// countdown) while the review is on screen on more than one display.
    func updateSpeakerReviewMirrorClock() {
        guard isShown, speakerReviewOnScreen, surfaces.count > 1, speakerReviewView != nil else {
            speakerReviewMirrorTask?.cancel()
            speakerReviewMirrorTask = nil
            return
        }
        guard speakerReviewMirrorTask == nil else { return }
        speakerReviewMirrorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled else { return }
                self?.refreshSpeakerReviewMirrors(rendersOnResize: true)
            }
        }
    }

    /// The review's rows grew or shrank.
    func speakerReviewLayoutChanged() {
        guard isShown, speakerReview != nil else { return }
        render()
    }

    /// A name box was clicked: take the keyboard, only while the review asks.
    func makeKeyForTyping() {
        guard let panel = speakerReviewHost?.panel, panel.acceptsKeyForTyping else { return }
        if !panel.isKeyWindow {
            // The panel is non-activating, so the app the person was in is
            // still the frontmost app while they type a name here.
            keyboardReturnApp = Self.frontmostOtherApp()
        }
        panel.makeKey()
    }

    /// Gives the keyboard back to the app the person was in, without hiding
    /// the island and without activating Transcripted.
    ///
    /// The island is a non-activating panel: clicking a name box made it the
    /// key window but left the other app active (its menu bar stays up). So
    /// only key focus has to move back. AppKit has no public "stop being key"
    /// for a window that stays on screen (`resignKey()` is documented as
    /// never to be called directly and only updates AppKit's side), but
    /// ordering a key non-activating panel out hands key focus back to the
    /// active app, which is what `hide()` has always relied on. The panel can
    /// no longer become key at this point, so ordering it straight back in,
    /// in the same pass with its layers untouched, leaves the island where it
    /// was. Re-activating the app that was frontmost then asks it to take its
    /// key window back, in case the window server has not already; it never
    /// activates Transcripted.
    func returnKeyboardIfHeld() {
        guard let panel = surfaces.first(where: { $0.panel.isKeyWindow })?.panel else {
            keyboardReturnApp = nil
            return
        }
        let returnTo = keyboardReturnApp ?? Self.frontmostOtherApp()
        keyboardReturnApp = nil
        panel.makeFirstResponder(nil)
        let couldTakeKey = panel.acceptsKeyForTyping
        panel.acceptsKeyForTyping = false
        if panel.isVisible {
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
        panel.acceptsKeyForTyping = couldTakeKey
        if let returnTo, !returnTo.isTerminated {
            returnTo.activate(options: [])
        }
    }

    static func frontmostOtherApp() -> NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return app
    }
}
