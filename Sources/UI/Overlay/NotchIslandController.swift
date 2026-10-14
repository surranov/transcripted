// NotchIslandController.swift
// The one notch island shared by dictation, meetings and the call-detected
// prompt. Each controller keeps
// its own state machine, timers and actions and pushes a plain snapshot here
// (NotchIsland*Content). This composes them with NotchIslandPresentation,
// draws the result on every display (NotchIslandSurface), sized with
// NotchIslandGeometry for each one, grows it out of the notch (or down from
// the top edge of a display without one), and routes taps back to whichever
// controller owns them.

import AppKit
import Combine

@MainActor
final class NotchIslandController: NotchIslandCallPromptPresenting {
    var dictationActionHandler: ((NotchIslandAction) -> Void)?
    var meetingActionHandler: ((NotchIslandAction) -> Void)?
    var callActionHandler: ((NotchIslandAction) -> Void)?
    var callHoverHandler: ((Bool) -> Void)?
    /// Right-click menu while a meeting records (Discard Recording…).
    var meetingMenuProvider: (() -> NSMenu?)?
    /// "Paste again" on the dictation that just landed.
    var onPasteLastDictation: (() -> Void)?
    /// The text of the dictation that just landed, for Copy and the preview.
    var lastDictationTextProvider: (() -> String?)?
    /// The pointer entered or left the island while "Who was on this call?"
    /// is up, so its Later ring and "Everyone's named" linger can pause.
    var speakerReviewHoverHandler: ((Bool) -> Void)?
    /// "Who was on this call?" went on or off screen (a dictation, a call
    /// prompt, or the next meeting hides it), so its Later ring only runs
    /// while someone can see it.
    var speakerReviewVisibilityHandler: ((Bool) -> Void)? {
        didSet { reportedSpeakerReviewVisible = nil }
    }
    /// The call prompt went on or off screen (it waits behind a dictation),
    /// so its timeout only runs while someone can see it.
    var callVisibilityHandler: ((Bool) -> Void)? {
        didSet { reportedCallPromptVisible = nil }
    }

    private static let hoverOpenDelay: UInt64 = 120_000_000
    private static let hoverCloseDelay: UInt64 = 380_000_000
    private static let recentInsertLinger: UInt64 = 2_600_000_000
    private static let meterInterval: CFTimeInterval = 0.05

    var dictation: NotchIslandDictationContent?
    /// Fork: takes finishing behind the island, oldest first (`+ActivityStack`).
    var backgroundTakes: [NotchIslandBackgroundTake] = []
    var meeting: NotchIslandMeetingContent?
    private var callPrompt: NotchIslandCallPromptContent?
    var speakerReview: NotchIslandSpeakerReviewContent?
    private var reportedSpeakerReviewVisible: Bool?
    private var reportedCallPromptVisible: Bool?
    /// The app that was in front when a name box took the keyboard. It gets
    /// the keyboard back once naming ends.
    var keyboardReturnApp: NSRunningApplication?
    private var recentInsert: NotchIslandRecentInsert?
    private(set) var targetApp: NSRunningApplication?
    private var listeningSince: Date?
    private var live = NotchIslandLiveValues()

    private var expanded = false
    private var collapsedStickyKey: String?
    private var isHovered = false
    private var lastLayout: NotchIslandLayout?
    private var lastWingWidths: (left: CGFloat, right: CGFloat) = (0, 0)
    private var lastMeterPush: CFTimeInterval = 0

    /// The island's copy on each display (NotchIslandSurface.swift). Its
    /// state lives here once and every surface draws it.
    private(set) var surfaces: [NotchIslandSurface] = []
    var islandViews: [NotchIslandView] { surfaces.map(\.view) }
    /// The views someone can see now (`NotchIslandSurface.isCovered`): the
    /// only ones live levels and bars are drawn into.
    var seenIslandViews: [NotchIslandView] { surfaces.filter { !$0.isCovered }.map(\.view) }
    /// The presenter's one live "Who was on this call?" view, the display it
    /// sits on, and the clock repainting its picture on the other displays.
    var speakerReviewView: NSView?
    var speakerReviewHostID: UInt32?
    var speakerReviewMirrorTask: Task<Void, Never>?
    private(set) var isShown = false
    /// Steps the dictation waveform while a dictation listens on screen
    /// (NotchIslandController+DictationBars.swift).
    let dictationBarsClock = NotchIslandFrameClock()
    /// The target app's icon, drawn once per take (+DictationDrop.swift).
    let targetAppIconCache = NotchIslandAppIconCache()
    private var hideGeneration = 0
    private var hoverTask: Task<Void, Never>?
    private var recentInsertTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?
    /// Watches desktop switches (NotchIslandController+Spaces.swift).
    var spaceObserver: NSObjectProtocol?
    /// Mouse monitors while the island is up: the window lets clicks through
    /// everywhere except over the island itself, and hover is judged from
    /// the pointer instead of tracking areas on a window that may ignore it.
    private var pointerMonitors: [Any] = []
    var liveTranscriptWatch: AnyCancellable?
    var dictationPreviewWatch: AnyCancellable?

    init() {
        watchLiveTranscript()
        watchDictationPreview()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.displaysChanged()
            }
        }
        watchSpaces()
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        }
        hoverTask?.cancel()
        recentInsertTask?.cancel()
        tickTask?.cancel()
    }

    /// True while the pointer rests on the island (holds messages and the
    /// saved meeting, like hovering the old pills did).
    var isPointerOverIsland: Bool {
        guard isShown else { return false }
        let pointer = NSEvent.mouseLocation
        return surfaces.contains { $0.targetFrame?.insetBy(dx: -4, dy: -4).contains(pointer) == true }
    }

    /// Builds the panel and draws a sample island once at launch, so the
    /// first key press shows the island on the next frame instead of paying
    /// for window creation, fonts and symbols.
    func prewarm() {
        for surface in ensureSurfaces() { prewarm(surface) }
    }

    private func prewarm(_ surface: NotchIslandSurface) {
        let panel = surface.panel, islandView = surface.view
        guard !isShown, !panel.isVisible else { return }
        let screen = surface.screen
        islandView.apply(
            NotchIslandPresentation.layout(
                dictation: NotchIslandDictationContent(phase: .listening),
                meeting: nil,
                callPrompt: nil,
                recentInsert: nil,
                expanded: false
            ),
            live: live
        )
        islandView.setGeometry(screen: screen, hasDrop: false, edgeProgress: nil)
        panel.alphaValue = 0
        panel.setFrame(
            NotchIslandGeometry.envelope(screen: screen, containing: [], margin: NotchIslandMotion.springMargin),
            display: true
        )
        panel.orderFrontRegardless()
        // Compile the show-time blur at alpha 0 too, then drop it so the
        // island rests with no filter.
        islandView.prewarmBlur()
        panel.display()
        CATransaction.flush() // commit the filter so Core Image actually builds it
        panel.orderOut(nil)
        islandView.resetBlur()
        panel.alphaValue = 1
    }

    // MARK: - Dictation

    func updateDictation(_ content: NotchIslandDictationContent?, targetApp: NSRunningApplication?) {
        let content = withLivePreview(content)
        if content?.phase == .starting || content == nil {
            listeningSince = nil
        }
        if content?.phase == .listening, listeningSince == nil {
            listeningSince = Date()
        }
        if content?.phase == .starting, recentInsert != nil {
            clearRecentInsert()
        }
        if case .loading(_, _, let progress?)? = content?.phase {
            live.loadingProgress = progress
        }
        let ended = content == nil && dictation != nil
        guard content != dictation || targetApp !== self.targetApp else { return }
        dictation = content
        self.targetApp = content == nil ? nil : targetApp
        releaseKeptDictationDropIfTakeEnded()
        if ended, recentInsert != nil {
            scheduleRecentInsertExpiry()
        }
        render()
        updateTicker()
    }

    /// The dictation landed. The island lingers on it after the "Pasted"
    /// beat so a hover can offer Copy and Paste again.
    func noteDictationInserted(title: String) {
        recentInsertTask?.cancel()
        recentInsertTask = nil
        recentInsert = NotchIslandRecentInsert(title: title, text: lastDictationTextProvider?())
        if let text = recentInsert?.text { islandViews.forEach { $0.dictationPreviewView?.showFinal(text) } }
        if dictation == nil {
            scheduleRecentInsertExpiry()
            render()
        }
    }

    // MARK: - Meetings

    func updateMeeting(_ content: NotchIslandMeetingContent?) {
        var content = content
        let showsTranscript = Self.showsLiveTranscript(content)
        content?.showsLiveTranscript = showsTranscript
        switch NotchIslandPresentation.meetingUpdate(from: meeting, to: content) {
        case .unchanged:
            return
        case .durationOnly:
            // The once-a-second clock tick: the layout never reads the
            // duration, so refresh the timer text instead of rebuilding.
            // refreshLive still renders if a wing needs room for a digit.
            meeting = content
            live.meetingElapsed = content?.duration ?? 0
            // A full render re-reads this each time; keep the Settings
            // switch applying within a tick on this path too.
            if isShown { surfaces.forEach { $0.panel.applyScreenSharingPreference() } }
            refreshLive()
            return
        case .full:
            break
        }
        // The view must exist before a drop-down asks for it, or the first
        // hover would draw the level lanes instead.
        if showsTranscript { ensureLiveTranscriptViews() }
        meeting = content
        if !showsTranscript { releaseLiveTranscriptViewIfRecordingEnded() }
        live.meetingElapsed = content?.duration ?? 0
        if case .transcribing(let progress, _)? = content?.phase {
            live.transcriptionProgress = progress ?? 0
        }
        render()
    }

    func updateMeetingLevels(mic: Float, system: Float) {
        guard isShown, meeting?.isRecording == true else { return }
        // Mic and call levels arrive as separate ticks; one push per beat
        // keeps the lanes scrolling at a steady pace.
        let now = CACurrentMediaTime()
        guard now - lastMeterPush >= Self.meterInterval else { return }
        lastMeterPush = now
        seenIslandViews.forEach { $0.pushMeetingLevels(mic: mic, system: system) }
    }

    // MARK: - Call prompt

    func updateCallPrompt(_ content: NotchIslandCallPromptContent?) {
        if let content {
            live.callSecondsLeft = content.secondsLeft
        }
        guard content != callPrompt else {
            refreshLive()
            return
        }
        callPrompt = content
        render()
    }

    func updateCallPromptSeconds(_ secondsLeft: Int) {
        guard callPrompt != nil else { return }
        live.callSecondsLeft = secondsLeft
        refreshLive()
    }

    // MARK: - Speaker review (and NotchIslandController+SpeakerReview.swift)

    /// "Who was on this call?" is in the drop-down now.
    var speakerReviewOnScreen: Bool { lastLayout?.showsSpeakerReview == true }

    /// The view a surface's drop-down holds was swapped (the review moved to
    /// or from its display): take the drop-down down so the next render
    /// builds it again around the new view.
    func rebuildDropOnNextRender(_ surface: NotchIslandSurface) {
        // Any other drop-down is rebuilt by the next render anyway.
        guard var cleared = lastLayout, case .speakerReview? = cleared.drop else { return }
        cleared.drop = nil
        surface.view.apply(cleared, live: live)
    }

    private func reportSpeakerReviewVisibility(_ visible: Bool) {
        guard reportedSpeakerReviewVisible != visible else { return }
        reportedSpeakerReviewVisible = visible
        speakerReviewVisibilityHandler?(visible)
    }

    private func reportCallPromptVisibility() {
        guard callPrompt != nil else {
            // The next prompt reports afresh.
            reportedCallPromptVisible = nil
            return
        }
        let visible = NotchIslandPresentation.callPromptIsOnScreen(dictation: dictation, callPrompt: callPrompt, backgroundTakes: backgroundTakes)
        guard reportedCallPromptVisible != visible else { return }
        reportedCallPromptVisible = visible
        callVisibilityHandler?(visible)
    }

    // MARK: - Rendering

    func render(animated: Bool = true) {
        if NotchIslandPresentation.stickyKey(dictation: dictation, meeting: meeting, callPrompt: callPrompt, speakerReview: speakerReview, backgroundTakes: backgroundTakes) == nil {
            collapsedStickyKey = nil
        }
        let layout = NotchIslandPresentation.layout(
            dictation: dictation,
            meeting: meeting,
            callPrompt: callPrompt,
            recentInsert: recentInsert,
            expanded: expanded,
            collapsedStickyKey: collapsedStickyKey,
            speakerReview: speakerReview,
            backgroundTakes: backgroundTakes
        )
        lastLayout = layout
        reportSpeakerReviewVisibility(layout.showsSpeakerReview)
        reportCallPromptVisibility()
        if !NotchIslandPresentation.speakerReviewKeepsKeyboard(speakerReview, onScreen: layout.showsSpeakerReview) {
            returnKeyboardIfHeld()
        }
        guard !layout.isEmpty else {
            hide(animated: animated)
            return
        }

        live.dictationElapsed = listeningSince.map { Date().timeIntervalSince($0) } ?? 0
        var edgeProgress: Double?
        if layout.showsEdgeProgress, case .transcribing(let progress?, _)? = meeting?.phase {
            edgeProgress = progress
        }
        let appearing = !isShown
        if appearing {
            isShown = true
            hideGeneration += 1
        }
        var reshaped = false
        // The live review first: the other displays show a picture of it,
        // taken once it is laid out.
        let all = ensureSurfaces()
        let reviewHost = layout.showsSpeakerReview ? speakerReviewHost : nil
        let ordered = reviewHost.map { host in [host] + all.filter { $0 !== host } } ?? all
        for surface in ordered {
            if surface === ordered.dropFirst().first, reviewHost != nil {
                refreshSpeakerReviewMirrors(rendersOnResize: false)
            }
            reshaped = render(surface, layout, edgeProgress: edgeProgress, animated: animated, appearing: appearing) || reshaped
        }
        updateSpeakerReviewMirrorClock()
        if let widths = surfaces.first?.view.wingContentWidths {
            lastWingWidths = widths
        }
        if appearing {
            startPointerWatch()
            updateTicker()
        } else if reshaped {
            pointerMoved()
        }
    }

    /// Draws the layout into one surface, sized for its display, and grows
    /// it out of the notch (or the top edge) when the island appears.
    /// Returns whether the shape moved.
    @discardableResult
    private func render(
        _ surface: NotchIslandSurface,
        _ layout: NotchIslandLayout,
        edgeProgress: Double?,
        animated: Bool,
        appearing: Bool
    ) -> Bool {
        let panel = surface.panel, islandView = surface.view
        // Hidden from screen sharing and screenshots unless the person
        // turned it on in Settings; read each time so the switch applies at once.
        panel.applyScreenSharingPreference()
        let screen = surface.screen
        islandView.apply(layout, live: live)
        islandView.setGeometry(screen: screen, hasDrop: layout.drop != nil, edgeProgress: edgeProgress)

        let widths = islandView.wingContentWidths
        let size = NotchIslandGeometry.islandSize(
            screen: screen,
            leftContent: widths.left,
            rightContent: widths.right,
            dropHeight: islandView.measureDropHeight()
        )
        let frame = NotchIslandGeometry.frame(screen: screen, size: size)

        let radius = islandView.currentCornerRadius
        if appearing {
            islandView.resetBlur()
            let appearingFromHidden = !panel.isVisible
            let start = appearingFromHidden ? NotchIslandGeometry.collapsedFrame(screen: screen) : surface.presentedShapeFrame
            let startRadius = appearingFromHidden ? NotchIslandGeometry.collapsedRadius(screen: screen) : islandView.shapeCornerRadius
            surface.targetFrame = frame
            islandView.setContentVisible(false, animated: false)
            surface.springShape(from: start, fromRadius: startRadius, to: frame, radius: radius, spring: animated ? growSpring(screen) : nil)
            rejoinAllSpacesIfLeftBehind(surface, "show")
            panel.orderFrontRegardless()
            islandView.setContentVisible(true, animated: animated)
            if animated {
                islandView.blurContent(in: true)
            }
            return true
        }
        guard surface.targetFrame != frame || islandView.shapeCornerRadius != radius else { return false }
        surface.targetFrame = frame
        surface.springShape(
            from: surface.presentedShapeFrame,
            fromRadius: islandView.shapeCornerRadius,
            to: frame,
            radius: radius,
            spring: animated ? growSpring(screen) : nil
        )
        return true
    }

    private func growSpring(_ screen: NotchIslandScreenInfo) -> NotchIslandMotion.Spring {
        screen.hasNotch ? NotchIslandMotion.grow : NotchIslandMotion.growFromEdge
    }

    // MARK: - Pointer

    private func startPointerWatch() {
        guard pointerMonitors.isEmpty else {
            pointerMoved()
            return
        }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            // Global monitors deliver on the main thread, like the local one.
            MainActor.assumeIsolated { self?.pointerMoved() }
        }) {
            pointerMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        }) {
            pointerMonitors.append(local)
        }
        pointerMoved()
    }

    private func stopPointerWatch() {
        pointerMonitors.forEach { NSEvent.removeMonitor($0) }
        pointerMonitors = []
        surfaces.forEach { $0.panel.ignoresMouseEvents = true }
    }

    /// Clicks go to whatever is under the envelope unless the pointer is on
    /// the island itself.
    private func pointerMoved() {
        guard isShown else { return }
        let pointer = NSEvent.mouseLocation
        var under: NotchIslandSurface?
        for surface in surfaces {
            guard let frame = surface.targetFrame else { continue }
            let inside = frame.contains(pointer)
            if surface.panel.ignoresMouseEvents == inside {
                surface.panel.ignoresMouseEvents = !inside
            }
            if inside { under = surface }
        }
        guard surfaces.contains(where: { $0.targetFrame != nil }) else { return }
        if let under { moveSpeakerReview(to: under) }
        handleHover(under != nil)
    }

    /// Timers and countdowns tick without rebuilding the island, unless a
    /// digit is added (9:59 → 10:00) and a wing needs more room.
    private func refreshLive() {
        guard isShown, let first = surfaces.first else { return }
        live.dictationElapsed = listeningSince.map { Date().timeIntervalSince($0) } ?? 0
        islandViews.forEach { $0.updateLive(live) }
        let widths = first.view.wingContentWidths
        if widths.left != lastWingWidths.left || widths.right != lastWingWidths.right {
            render()
        }
    }

    private func hide(animated: Bool) {
        hoverTask?.cancel()
        hoverTask = nil
        tickTask?.cancel()
        tickTask = nil
        dictationBarsClock.stop()
        speakerReviewMirrorTask?.cancel()
        speakerReviewMirrorTask = nil
        islandViews.forEach { $0.releaseKeptDictationDrop() }
        expanded = false
        isHovered = false
        guard isShown, !surfaces.isEmpty else { return }
        isShown = false
        surfaces.forEach { $0.targetFrame = nil }
        stopPointerWatch()
        hideGeneration += 1
        let generation = hideGeneration
        // Takes one surface down, or every surface with nil.
        let finish = { [weak self] (only: NotchIslandSurface?) in
            guard let self, self.hideGeneration == generation, !self.isShown else { return }
            for surface in only.map({ [$0] }) ?? self.surfaces {
                surface.panel.orderOut(nil)
                // Kept through the shrink; the next review paints its own.
                if self.speakerReviewView == nil { surface.speakerReviewMirror.image = nil }
            }
            self.keyboardReturnApp = nil
        }
        guard animated, !NotchIslandPalette.reduceMotion else {
            finish(nil)
            return
        }
        for surface in surfaces {
            let screen = surface.screen, islandView = surface.view
            // Content fades and softens while the shape pulls back into the
            // notch (or up into the top edge).
            islandView.setContentVisible(false, animated: true)
            islandView.blurContent(in: false)
            surface.springShape(
                from: surface.presentedShapeFrame,
                fromRadius: islandView.shapeCornerRadius,
                to: NotchIslandGeometry.collapsedFrame(screen: screen),
                radius: NotchIslandGeometry.collapsedRadius(screen: screen),
                spring: NotchIslandMotion.shrink,
                completion: { [weak surface] in finish(surface) }
            )
        }
        // Core Animation's "done" can be lost (the Mac sleeping mid-shrink);
        // take the windows down anyway once the shrink must be over.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: NotchIslandMotion.hideFallbackNanoseconds)
            finish(nil)
        }
    }

    @discardableResult
    func ensureSurfaces() -> [NotchIslandSurface] {
        if !surfaces.isEmpty { return surfaces }
        surfaces = NotchIslandDisplays.drawnOn(Self.reportedDisplays()).map { display in
            let surface = NotchIslandSurface(display: display)
            surface.view.onAction = { [weak self] action in self?.handleAction(action) }
            surface.view.onBackgroundClick = { [weak self] in self?.handleBackgroundClick() }
            surface.view.menuProvider = { [weak self] in self?.meetingMenuProvider?() }
            surface.view.targetAppIconProvider = { [weak self] in self?.targetAppIcon() }
            return surface
        }
        return surfaces
    }

    private static func reportedDisplays() -> [NotchIslandDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return NotchIslandDisplay(
                id: id.uint32Value,
                screen: NotchIslandGeometry.screenInfo(
                    frame: screen.frame,
                    safeAreaTop: screen.safeAreaInsets.top,
                    leftAuxiliaryWidth: screen.auxiliaryTopLeftArea?.width,
                    rightAuxiliaryWidth: screen.auxiliaryTopRightArea?.width
                )
            )
        }
    }

    /// macOS posts this for the Dock and menu bar too; only a change in the
    /// displays themselves builds new windows (`NotchIslandDisplays`).
    private func displaysChanged() {
        guard !surfaces.isEmpty,
              NotchIslandDisplays.rebuildsWindows(drawnOn: surfaces.map(\.display), reported: Self.reportedDisplays()) else {
            rejoinAllSpacesIfLeftBehind("display_change")
            return
        }
        rebuildSurfaces()
        // Fresh windows join every desktop, unless the window server was
        // still settling the displays' desktops when they were made.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            self?.rejoinAllSpacesIfLeftBehind("after_display_change")
        }
    }

    /// Drops every window and draws the island again, without the grow, on
    /// fresh ones for the displays there are now. The review, live transcript
    /// and live words carry over, and a name being typed keeps the keyboard.
    private func rebuildSurfaces() {
        let wasShown = isShown
        let typingField = surfaces.lazy.compactMap(\.panel.typingField).first
        stopPointerWatch()
        dictationBarsClock.stop()
        isShown = false
        // A shrink still running on an old window must not finish on the new ones.
        hideGeneration += 1
        for surface in surfaces {
            surface.view.speakerReviewView = nil
            surface.panel.orderOut(nil)
        }
        surfaces = []
        ensureSurfaces()
        chooseSpeakerReviewHost()
        placeSpeakerReview()
        if Self.showsLiveTranscript(meeting) { ensureLiveTranscriptViews() }
        if dictation?.showsLivePreview == true { ensureDictationPreviewViews() }
        if wasShown {
            render(animated: false)
        } else {
            prewarm()
        }
        // The old window gave the keyboard back to the app in front when it
        // went; without this the next keys would land in that app.
        if let typingField { keepTyping(in: typingField) }
    }

    private func updateTicker() {
        updateDictationBarsClock()
        guard isShown, dictation?.phase == .listening else {
            tickTask?.cancel()
            tickTask = nil
            return
        }
        guard tickTask == nil else { return }
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                self?.refreshLive()
            }
        }
    }

    // MARK: - The dictation that just landed

    private func scheduleRecentInsertExpiry() {
        recentInsertTask?.cancel()
        recentInsertTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.recentInsertLinger)
            // Reading it or reaching for Copy keeps it up.
            while let self, !Task.isCancelled, self.isHovered || self.expanded {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            guard !Task.isCancelled, let self else { return }
            self.recentInsertTask = nil
            self.recentInsert = nil
            self.render()
        }
    }

    private func clearRecentInsert() {
        recentInsertTask?.cancel()
        recentInsertTask = nil
        recentInsert = nil
    }

    // MARK: - Pointer and taps

    private func handleHover(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        if callPrompt != nil { callHoverHandler?(hovered) }
        if speakerReview != nil { speakerReviewHoverHandler?(hovered) }
        islandViews.forEach { $0.setCountdownPaused(hovered) }
        hoverTask?.cancel()
        hoverTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: hovered ? Self.hoverOpenDelay : Self.hoverCloseDelay)
            guard !Task.isCancelled else { return }
            if !hovered {
                // An exit can arrive while the shape resizes under a still
                // pointer; only close once the pointer has really left.
                while self?.isPointerOverIsland == true {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard !Task.isCancelled else { return }
                }
            }
            guard let self, self.isHovered == hovered, self.expanded != hovered else { return }
            self.expanded = hovered
            self.render()
        }
    }

    private func handleBackgroundClick() {
        if case .message? = dictation?.phase {
            dictationActionHandler?(.dictationDismissMessage)
            return
        }
        // Clicks between the review's rows mean nothing; Later and Done
        // are the ways out.
        if case .speakerReview? = lastLayout?.drop { return }
        let stickyKey = NotchIslandPresentation.stickyKey(dictation: dictation, meeting: meeting, callPrompt: callPrompt, speakerReview: speakerReview, backgroundTakes: backgroundTakes)
        if let stickyKey, lastLayout?.dropIsSticky == true {
            // Close the drop-down that opened by itself. It stays closed
            // until something new needs saying; a hover or click reopens it.
            collapsedStickyKey = stickyKey
            expanded = false
        } else {
            expanded.toggle()
        }
        hoverTask?.cancel()
        render()
    }

    private func handleAction(_ action: NotchIslandAction) {
        switch action.owner {
        case .dictation:
            dictationActionHandler?(action)
        case .meeting:
            meetingActionHandler?(action)
        case .callPrompt:
            callActionHandler?(action)
        case .island:
            handleOwnAction(action)
        }
    }

    private func handleOwnAction(_ action: NotchIslandAction) {
        switch action {
        case .meetingCopyTranscript:
            copyLiveTranscript()
        case .copyLastDictation:
            guard let text = recentInsert?.text, !text.isEmpty else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            recentInsert?.title = "Copied"
            expanded = false
            render()
            scheduleRecentInsertExpiry()
        case .pasteLastDictation:
            clearRecentInsert()
            expanded = false
            render()
            onPasteLastDictation?()
        default:
            break
        }
    }
}
