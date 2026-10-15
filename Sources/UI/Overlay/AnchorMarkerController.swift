import AppKit
import Combine
import SwiftUI

/// Fork: the Anchored paste markers, one per take, each drawn over the one
/// window its take is anchored to: a small black flag (the notch island's
/// look: black, accent glyphs) with the take's phase. While it listens:
/// seven level dots that stretch with the voice, the take's time and a stop
/// button. Then the writing ripple, the come-back arrow or the check. It sits
/// 3 pt above the field's box (what the user sees as the text box, not just
/// the text inside it), so it covers none of the text; a box with no room
/// above takes it below or inside its top-right corner
/// (`AnchorMarkerPlacement`). It marks the field, not the caret: caret
/// bounds are often wrong.
///
/// Each take keeps its flag until its words land (or wait for the user),
/// through the hand-off to the background. Flags over one box sit side by
/// side, left to right: the newest take's full flag first, then the older
/// takes' compact ones (dots or glyph only), in the order they started.
///
/// In an app whose sidebar lists threads (`ChatThreadPolicy.sidebarBundleIDs`:
/// T3 Code), a flag sits over the box only while the window shows its take's
/// thread. With another thread open it flies, compact, to the bottom-right
/// corner of its thread's row in the sidebar (`ChatSidebarReader`), and hides
/// while that row can't be seen (the sidebar hidden, the row scrolled away),
/// coming back with it. The row is the one the app marked current while the
/// take's thread was open, found again by its label.
///
/// Boxes, the open thread and the sidebar are read off the main thread
/// about four times a second, and a flag flies to a new spot: a composer
/// grows when it takes focus (T3 Code animates it) and as the text wraps.
/// Between reads flags follow their window.
///
/// The stop button stops the take like the island's. A panel takes the mouse
/// only while the pointer is over that button, so a click anywhere else
/// reaches the window; non-activating panels that never become key, they
/// leave the anchored app focused.
///
/// Each panel sits one step above its window in the stacking order
/// (re-pinned every tick, as cua-driver keeps its agent cursor on the window
/// it drives), so a window in front covers it, and it hides while the window
/// is off screen (another desktop, minimized, closed). The notch island keeps
/// showing the dictation as before; this only says where the words will go.
@MainActor
final class AnchorMarkerController {
    enum Phase: Equatable {
        case listening
        case working
        /// The paste waits for the user to come back to this window.
        case waiting
        case done
    }

    /// The stop button on take `id`'s flag was clicked.
    var onStop: ((UUID) -> Void)?

    /// In the order the takes started.
    private var markers: [AnchorMarker] = []
    /// What each watched window shows (thread, sidebar), for flags that keep
    /// to a thread.
    private var watches: [CGWindowID: AnchorThreadWatch] = [:]
    /// Threads read before their take's flag showed (the two reads race).
    private var pendingThreads: [(id: UUID, thread: ChatThread)] = []
    private var timer: Timer?

    private static let tickInterval: TimeInterval = 1.0 / 15
    /// About four reads a second, off the main thread.
    fileprivate static let ticksPerRead = 4
    fileprivate static let flightDuration: TimeInterval = 0.25
    /// Between the box and a sidebar row: a longer way.
    fileprivate static let rowFlightDuration: TimeInterval = 0.4
    private static let doneLinger: UInt64 = 900_000_000

    func isShowing(_ id: UUID) -> Bool { marker(id) != nil }

    /// Take `id`'s flag shows a take still recording or processing (not a
    /// finished or waiting paste).
    func phaseIsInFlight(_ id: UUID) -> Bool {
        guard let phase = marker(id)?.phase else { return false }
        return phase == .listening || phase == .working
    }

    /// A flag for take `id`. `levels`: the dictation meter, for the dots
    /// while the take listens.
    func show(_ id: UUID, for anchor: DictationPasteAnchor, phase: Phase, levels: AnyPublisher<DictationAudioLevel, Never>?) {
        // A thread read first (the two reads race) is kept for the new flag.
        let pending = pendingThreads.first(where: { $0.id == id })?.thread
        pendingThreads.removeAll { $0.id == id }
        removeMarker(id)
        guard let windowID = anchor.windowID, let field = anchor.field,
              let frame = anchor.windowFrame ?? AnchoredTextDelivery.windowState(windowID)?.frame else { return }
        let marker = AnchorMarker(
            id: id,
            windowID: windowID,
            window: anchor.window,
            pid: anchor.pid,
            bundleID: anchor.bundleID,
            field: field,
            caretOffset: anchor.caretRect.map { $0.offsetBy(dx: -frame.minX, dy: -frame.minY) },
            phase: phase
        ) { [weak self] in self?.onStop?(id) }
        marker.listen(to: levels)
        markers.append(marker)
        if let pending { follow(pending, for: id) }
        startTimer()
        tick()
    }

    /// The chat thread take `id` was dictated into. In an app whose sidebar
    /// the flags follow, its flag keeps to that thread from now on.
    func follow(_ thread: ChatThread, for id: UUID) {
        guard let bundleID = thread.bundleID, ChatThreadPolicy.sidebarBundleIDs.contains(bundleID) else { return }
        guard let marker = marker(id) else {
            pendingThreads.append((id, thread))
            if pendingThreads.count > 4 { pendingThreads.removeFirst(pendingThreads.count - 4) }
            return
        }
        guard thread.pid == marker.pid else { return }
        marker.thread = thread
    }

    func update(_ phase: Phase, for id: UUID) {
        guard let marker = marker(id) else { return }
        marker.update(phase)
        marker.hideTask?.cancel()
        guard phase == .done else { return }
        marker.hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.doneLinger)
            guard !Task.isCancelled else { return }
            self?.hide(id)
        }
    }

    func hide(_ id: UUID) {
        pendingThreads.removeAll { $0.id == id }
        removeMarker(id)
    }

    private func removeMarker(_ id: UUID) {
        guard let index = markers.firstIndex(where: { $0.id == id }) else { return }
        markers.remove(at: index).close()
        let watched = Set(markers.map(\.windowID))
        watches = watches.filter { watched.contains($0.key) }
        if markers.isEmpty { stopTimer() }
    }

    /// A take that ended without its words landing (cancel, no speech, an
    /// error) takes its flag along.
    func hideIfInFlight(_ id: UUID) {
        if phaseIsInFlight(id) { hide(id) }
    }

    // MARK: - Placement

    private func marker(_ id: UUID) -> AnchorMarker? { markers.first { $0.id == id } }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// Where every flag goes now: grouped by the box or sidebar row they
    /// share, laid out side by side, then moved.
    private func tick() {
        guard !markers.isEmpty, let primary = NSScreen.screens.first else {
            stopTimer()
            return
        }
        let animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var windowFrames: [CGWindowID: CGRect] = [:]
        var boxGroups: [(box: CGRect, window: CGRect, markers: [AnchorMarker])] = []
        var rowGroups: [(row: CGRect, visible: CGRect, markers: [AnchorMarker])] = []
        var readWindows: Set<CGWindowID> = []
        // A window's rows are read on every read while a flag there is away
        // from its thread or doesn't know its row yet; else now and then.
        let rowsWanted = Set(markers.filter { $0.thread != nil && (!$0.threadShown || $0.rowLabel == nil) }.map(\.windowID))
        for marker in markers {
            // Window and box are in Accessibility coordinates (top-left origin
            // on the primary display); AppKit's have a bottom-left one.
            let window: CGRect
            if let known = windowFrames[marker.windowID] {
                window = known
            } else if let state = AnchoredTextDelivery.windowState(marker.windowID), state.isOnScreen {
                window = state.frame
                windowFrames[marker.windowID] = window
            } else {
                marker.conceal()
                continue
            }
            marker.advance()
            let watch = watch(for: marker)
            if let watch, readWindows.insert(marker.windowID).inserted {
                watch.readIfDue(rowsWanted: rowsWanted.contains(marker.windowID))
            }
            switch location(of: marker, watch: watch, window: window) {
            case .box(let box):
                // One box read by two flags at different moments (a composer
                // growing in between) is still one box: same left edge and
                // bottom, give or take. The newest reading places them.
                if let index = boxGroups.firstIndex(where: { $0.window == window && Self.sameBox($0.box, box) }) {
                    boxGroups[index].markers.append(marker)
                    boxGroups[index].box = box
                } else {
                    boxGroups.append((box, window, [marker]))
                }
            case let .row(row, visible):
                if let index = rowGroups.firstIndex(where: { $0.row == row }) {
                    rowGroups[index].markers.append(marker)
                } else {
                    rowGroups.append((row, visible, [marker]))
                }
            case .nowhere:
                marker.conceal()
            }
        }
        for group in boxGroups {
            // `markers` is in the order the takes started.
            let ordered = AnchorMarkerPlacement.boxOrder(group.markers)
            let widths = ordered.map { $0.flag.flagWidth(compact: $0.compact) }
            // Room kept for the full flag's widest time below an hour, so
            // the row doesn't jump as the take's phase changes.
            let slots = [AnchorMarkerLayout.placedFlagWidth] + widths.dropFirst()
            let total = slots.reduce(0, +) + AnchorMarkerPlacement.flagGap * CGFloat(slots.count - 1)
            let start = AnchorMarkerPlacement.spot(
                box: group.box,
                window: group.window,
                flagSize: CGSize(width: total, height: AnchorMarkerLayout.flagHeight)
            )
            for (entry, spot) in zip(ordered, AnchorMarkerPlacement.row(from: start, widths: widths)) {
                entry.flag.place(at: spot, compact: entry.compact, onRow: false, window: group.window, primary: primary, animates: animates)
            }
        }
        for group in rowGroups {
            let widths = group.markers.map { $0.flagWidth(compact: true) }
            guard let spots = AnchorMarkerPlacement.rowCorner(
                row: group.row, visible: group.visible, widths: widths, flagHeight: AnchorMarkerLayout.flagHeight
            ) else {
                group.markers.forEach { $0.conceal() }
                continue
            }
            for (marker, spot) in zip(group.markers, spots) {
                let window = windowFrames[marker.windowID] ?? group.visible
                marker.place(at: spot, compact: true, onRow: true, window: window, primary: primary, animates: animates)
            }
        }
    }

    private static func sameBox(_ one: CGRect, _ other: CGRect) -> Bool {
        abs(one.minX - other.minX) <= 24 && abs(one.maxY - other.maxY) <= 24
    }

    private enum Location {
        case box(CGRect)
        case row(CGRect, visible: CGRect)
        case nowhere
    }

    /// Over the box while the window shows the take's thread (always, for a
    /// flag that keeps to none); else on that thread's sidebar row, when it
    /// can be seen.
    private func location(of marker: AnchorMarker, watch: AnchorThreadWatch?, window: CGRect) -> Location {
        if let thread = marker.thread, let watch {
            // An unreadable page keeps the last answer: a flag mustn't jump
            // to the sidebar for one missed read.
            if let identity = watch.identity { marker.threadShown = identity == thread.identity }
            // The row marked current is this thread's only when the open
            // thread read the same before and after the rows: a switch in
            // between would teach the flag the next thread's row.
            if watch.rowsReadInThread == thread.identity, let current = watch.sidebar?.currentRow {
                marker.rowLabel = current.label
                marker.rowElement = current.element
            }
        }
        if marker.threadShown {
            guard let box = marker.box(in: window) else { return .nowhere }
            return .box(box)
        }
        guard let watch, let sidebar = watch.sidebar, let label = marker.rowLabel else { return .nowhere }
        let labels = sidebar.rows.map(\.label)
        let remembered = marker.rowElement.flatMap { element in sidebar.rows.firstIndex { CFEqual($0.element, element) } }
        guard let index = ChatThreadPolicy.sidebarRow(labeled: label, in: labels, remembered: remembered) else { return .nowhere }
        // Rows were read where the window was then; it may have moved since.
        let moved = watch.windowFrameAtRead.map { CGPoint(x: window.minX - $0.minX, y: window.minY - $0.minY) } ?? .zero
        let row = sidebar.rows[index].frame.offsetBy(dx: moved.x, dy: moved.y)
        let visible = sidebar.visible.offsetBy(dx: moved.x, dy: moved.y).intersection(window)
        return visible.isNull ? .nowhere : .row(row, visible: visible)
    }

    private func watch(for marker: AnchorMarker) -> AnchorThreadWatch? {
        guard marker.thread != nil, let window = marker.window else { return nil }
        if let watch = watches[marker.windowID] { return watch }
        let watch = AnchorThreadWatch(windowID: marker.windowID, window: window, pid: marker.pid, bundleID: marker.bundleID)
        watches[marker.windowID] = watch
        return watch
    }
}

// MARK: - One window's thread and sidebar

/// What a window shows, for the flags that keep to a thread in it: the open
/// thread and the sidebar's rows, read together off the main thread.
@MainActor
private final class AnchorThreadWatch {
    let windowID: CGWindowID
    let window: AXUIElement
    let pid: pid_t
    let bundleID: String?
    /// The open thread at the last read; nil when unread or unreadable.
    private(set) var identity: String?
    /// The rows at the last read that found them.
    private(set) var sidebar: ChatSidebar?
    /// The thread open while `sidebar` was read: the same just before and
    /// just after the rows. Nil when it changed in between.
    private(set) var rowsReadInThread: String?
    /// The window when the rows were read.
    private(set) var windowFrameAtRead: CGRect?
    /// The sidebar's landmark, searched for again only when it stops
    /// answering.
    private var landmark: UncheckedElement?
    /// Reads in a row that found no rows: a busy app can miss one, so the
    /// last rows stand for a couple of reads before a flag hides.
    private var rowMisses = 0
    private var readsSinceRows = 0
    private var readInFlight = false
    private var ticksUntilRead = 0

    private static let rowMissesKept = 2
    /// While every flag here shows its thread and knows its row, the rows
    /// are read on every fourth read, to keep the row's label fresh.
    private static let idleRowReadEvery = 4

    init(windowID: CGWindowID, window: AXUIElement, pid: pid_t, bundleID: String?) {
        self.windowID = windowID
        self.window = window
        self.pid = pid
        self.bundleID = bundleID
    }

    private struct Reading: @unchecked Sendable {
        let identity: String?
        let readsRows: Bool
        let sidebar: ChatSidebar?
        let landmark: UncheckedElement?
        let identityAfterRows: String?
        let windowFrame: CGRect?
    }

    func readIfDue(rowsWanted: Bool) {
        ticksUntilRead -= 1
        guard ticksUntilRead <= 0, !readInFlight else { return }
        ticksUntilRead = AnchorMarkerController.ticksPerRead
        readInFlight = true
        readsSinceRows += 1
        let readsRows = rowsWanted || sidebar == nil || readsSinceRows >= Self.idleRowReadEvery
        if readsRows { readsSinceRows = 0 }
        let (window, pid, bundleID, windowID, known) = (UncheckedElement(element: window), pid, bundleID, windowID, landmark)
        Task.detached(priority: .utility) { [weak self] in
            let identity = ChatThreadReader.identityNow(pid: pid, bundleID: bundleID, window: window.element)
            var reading = Reading(identity: identity, readsRows: false, sidebar: nil, landmark: nil, identityAfterRows: nil, windowFrame: nil)
            if readsRows {
                let found = ChatSidebarReader.read(window: window.element, landmark: known?.element)
                reading = Reading(
                    identity: identity,
                    readsRows: true,
                    sidebar: found.sidebar,
                    landmark: found.landmark.map(UncheckedElement.init),
                    identityAfterRows: ChatThreadReader.identityNow(pid: pid, bundleID: bundleID, window: window.element),
                    windowFrame: AnchoredTextDelivery.windowState(windowID)?.frame
                )
            }
            await self?.receive(reading)
        }
    }

    private func receive(_ reading: Reading) {
        readInFlight = false
        identity = reading.identity
        guard reading.readsRows else { return }
        landmark = reading.landmark
        if let found = reading.sidebar {
            sidebar = found
            rowsReadInThread = reading.identity == reading.identityAfterRows ? reading.identity : nil
            windowFrameAtRead = reading.windowFrame
            rowMisses = 0
        } else {
            rowMisses += 1
            if rowMisses > Self.rowMissesKept {
                sidebar = nil
                rowsReadInThread = nil
            }
        }
    }
}

/// An AX element handed to a detached read. AX calls are thread-safe.
private struct UncheckedElement: @unchecked Sendable {
    let element: AXUIElement
}

// MARK: - One take's flag

@MainActor
private final class AnchorMarker {
    let id: UUID
    let windowID: CGWindowID
    let window: AXUIElement?
    let pid: pid_t
    let bundleID: String?
    /// The anchored field, whose box the flag sits above.
    let field: AXUIElement
    /// The chat thread the flag keeps to (`AnchorMarkerController.follow`).
    var thread: ChatThread?
    /// Whether the window showed `thread` at the last read; until a read
    /// says otherwise, it does (the take started there).
    var threadShown = true
    /// The thread's sidebar row, as last seen while the thread was open.
    var rowLabel: String?
    var rowElement: AXUIElement?
    private(set) var phase: AnchorMarkerController.Phase
    var hideTask: Task<Void, Never>?

    private let model = AnchorMarkerModel()
    private var panel: NSPanel?
    /// The box found last time, read again directly while it answers.
    private var boxElement: AXUIElement?
    /// The box relative to its window's top-left corner, so the flag
    /// follows the window between reads. Nil until the first read lands.
    private var boxOffset: CGRect?
    /// The caret at capture, same coordinates: the box when the field
    /// can't be read.
    private let caretOffset: CGRect?
    private var boxReadInFlight = false
    private var ticksUntilBoxRead = 0
    private var closed = false
    /// The panel frame last set, and where the flag was relative to its
    /// window then: a new spot flies the flag over, a window being dragged
    /// takes it along at once.
    private var placedFrame: NSRect?
    private var placedRelative: CGPoint?
    private var placedOnRow = false
    private var levelSubscription: AnyCancellable?
    /// The level the dots show, before rounding for the view.
    private var shownLevel: CGFloat = 0
    /// When the flag began listening: the island starts its timer there
    /// too, not at the press, which comes before the microphone warm-up.
    private let listeningSince = Date()
    /// The take's time once it stops listening.
    private var frozenElapsed: TimeInterval?
    private let onStop: () -> Void

    init(
        id: UUID,
        windowID: CGWindowID,
        window: AXUIElement?,
        pid: pid_t,
        bundleID: String?,
        field: AXUIElement,
        caretOffset: CGRect?,
        phase: AnchorMarkerController.Phase,
        onStop: @escaping () -> Void
    ) {
        self.id = id
        self.windowID = windowID
        self.window = window
        self.pid = pid
        self.bundleID = bundleID
        self.field = field
        self.caretOffset = caretOffset
        self.phase = phase
        self.onStop = onStop
        model.phase = phase
    }

    func listen(to levels: AnyPublisher<DictationAudioLevel, Never>?) {
        // Readings come on the main actor, synchronously from the meter.
        levelSubscription = levels?.sink { [weak self] reading in
            MainActor.assumeIsolated { self?.receive(reading) }
        }
    }

    func update(_ phase: AnchorMarkerController.Phase) {
        if phase != .listening {
            if frozenElapsed == nil { frozenElapsed = Date().timeIntervalSince(listeningSince) }
            levelSubscription = nil
            setIfChanged(\.level, 0)
        }
        self.phase = phase
        model.phase = phase
    }

    func flagWidth(compact: Bool) -> CGFloat {
        AnchorMarkerLayout.flagWidth(phase, timerWidth: model.timerWidth, compact: compact)
    }

    /// The box on screen, in the window at `window`; nil until it was read.
    func box(in window: CGRect) -> CGRect? {
        boxOffset?.offsetBy(dx: window.minX, dy: window.minY)
    }

    /// One tick: the timer text, and the box read about four times a second.
    func advance() {
        let elapsed = frozenElapsed ?? Date().timeIntervalSince(listeningSince)
        let timerText = NotchIslandPresentation.timerText(elapsed)
        if model.timerText != timerText {
            model.timerText = timerText
            setIfChanged(\.timerWidth, AnchorMarkerLayout.timerWidth(timerText))
        }
        ticksUntilBoxRead -= 1
        if ticksUntilBoxRead <= 0 {
            ticksUntilBoxRead = AnchorMarkerController.ticksPerRead
            readBox()
        }
    }

    /// The flag's pinned edge at `spot` (Accessibility coordinates).
    func place(at spot: AnchorMarkerPlacement.Spot, compact: Bool, onRow: Bool, window: CGRect, primary: NSScreen, animates: Bool) {
        guard !closed else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        setIfChanged(\.animates, animates)
        setIfChanged(\.compact, compact)
        setIfChanged(\.pinnedRight, spot.pinnedRight)
        let size = AnchorMarkerLayout.panelSize
        let inset = AnchorMarkerLayout.inset
        let left = spot.pinnedRight ? spot.x + inset - size.width : spot.x - inset
        let top = spot.top - inset
        let frame = NSRect(x: left, y: primary.frame.maxY - top - size.height, width: size.width, height: size.height)
        let relative = CGPoint(x: spot.x - window.minX, y: spot.top - window.minY)
        if frame != placedFrame {
            // A new spot flies the flag over; a window being dragged takes
            // it along at once.
            let flies = animates && panel.isVisible && placedRelative != nil && placedRelative != relative
            NSAnimationContext.runAnimationGroup { context in
                // Zero for a jump: unlike a plain setFrame, it also stops a
                // flight under way.
                context.duration = flies
                    ? (onRow != placedOnRow ? AnchorMarkerController.rowFlightDuration : AnchorMarkerController.flightDuration)
                    : 0
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: false)
            }
            placedFrame = frame
            placedRelative = relative
            placedOnRow = onRow
        }
        panel.order(.above, relativeTo: Int(windowID))
        updateStopHover(panelFrame: panel.frame)
    }

    /// Off screen until a spot is found again; it then appears there, not
    /// flying from where it was.
    func conceal() {
        setIfChanged(\.animates, false)
        setIfChanged(\.stopHovered, false)
        guard let panel else { return }
        panel.ignoresMouseEvents = true
        if panel.isVisible { panel.orderOut(nil) }
        placedFrame = nil
        placedRelative = nil
    }

    func close() {
        closed = true
        hideTask?.cancel()
        hideTask = nil
        levelSubscription = nil
        panel?.orderOut(nil)
        panel = nil
    }

    /// Fast up, slower down, like a meter needle, so a syllable shows and
    /// the dots settle back between words.
    private func receive(_ reading: DictationAudioLevel) {
        guard phase == .listening else { return }
        let target = NotchIslandBarsView.shaped(reading.peak)
        shownLevel = target > shownLevel ? target : shownLevel * 0.7 + target * 0.3
        // Rounded: the view re-renders only for a change it can show.
        setIfChanged(\.level, (shownLevel * 24).rounded() / 24)
    }

    /// Reads the box off the main thread: the box found last time while it
    /// answers, else the field's box found again (T3 Code rebuilds its
    /// composer). One read at a time, so a slow app only delays the flag.
    /// The window is read right after the box, so a window being dragged
    /// doesn't skew the offset.
    private func readBox() {
        guard !boxReadInFlight, !closed else { return }
        boxReadInFlight = true
        let (field, known, windowID) = (UncheckedElement(element: field), boxElement.map(UncheckedElement.init), windowID)
        Task.detached(priority: .utility) { [weak self] in
            let reading = known.flatMap { known in AnchoredTextDelivery.frame(of: known.element).map { (element: known.element, frame: $0) } }
                ?? AnchoredTextDelivery.fieldBox(of: field.element)
            let window = AnchoredTextDelivery.windowState(windowID)?.frame
            let box = reading.map { BoxReading(element: UncheckedElement(element: $0.element), frame: $0.frame) }
            await self?.receiveBox(box, window: window)
        }
    }

    private struct BoxReading: Sendable {
        let element: UncheckedElement
        let frame: CGRect
    }

    private func receiveBox(_ reading: BoxReading?, window: CGRect?) {
        boxReadInFlight = false
        guard !closed else { return }
        guard let reading, reading.frame.height > 0, let window else {
            boxElement = nil
            // Nothing to read: the caret captured at the start stands in.
            if boxOffset == nil { boxOffset = caretOffset }
            return
        }
        boxElement = reading.element.element
        boxOffset = reading.frame.offsetBy(dx: -window.minX, dy: -window.minY)
    }

    /// The panel takes the mouse only over the stop button. Checked each
    /// tick: with the mouse ignored, the panel gets no tracking events.
    /// `panelFrame` is where the panel is now, mid-flight included.
    private func updateStopHover(panelFrame: NSRect) {
        var hovered = false
        if model.showsStop {
            let button = AnchorMarkerLayout.stopButtonRect(pinnedRight: model.pinnedRight, timerWidth: model.timerWidth)
            let onScreen = NSRect(x: panelFrame.minX + button.minX, y: panelFrame.maxY - button.maxY, width: button.width, height: button.height)
            hovered = onScreen.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
        }
        if panel?.ignoresMouseEvents == hovered { panel?.ignoresMouseEvents = !hovered }
        setIfChanged(\.stopHovered, hovered)
    }

    /// Publishes only real changes, so the 15 Hz tick doesn't re-render the
    /// SwiftUI view.
    private func setIfChanged<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<AnchorMarkerModel, Value>, _ value: Value) {
        if model[keyPath: keyPath] != value { model[keyPath: keyPath] = value }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: AnchorMarkerLayout.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.sharingType = NotchIslandPreferences.visibleInScreenSharing() ? .readOnly : .none
        let hosting = AnchorMarkerHostingView(rootView: AnchorMarkerView(model: model, onStop: onStop))
        // The controller sizes the panel; SwiftUI must not resize it to fit.
        hosting.sizingOptions = []
        panel.contentView = hosting
        return panel
    }
}
