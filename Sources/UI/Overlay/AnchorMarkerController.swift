import AppKit
import Combine
import SwiftUI

/// Fork: the Anchored paste marker, drawn over the one window the dictation
/// is anchored to: a small black flag (the notch island's look: black, accent
/// glyphs) with the take's phase: while it listens, seven level dots that
/// stretch with the voice, the take's time and a stop button; then the
/// writing ripple, the come-back arrow or the check. It sits 3 pt above the
/// field's box (what the user sees as the text box, not just the text inside
/// it), so it covers none of the text; a box with no room above takes it
/// below or inside its top-right corner (`AnchorMarkerPlacement`). It marks
/// the field, not the caret: caret bounds are often wrong.
///
/// The box is read off the main thread about four times a second, and the
/// flag flies to a new spot: a composer grows when it takes focus (T3 Code
/// animates it) and as the text wraps. Between reads it follows its window.
///
/// The stop button stops the take like the island's. The panel takes the
/// mouse only while the pointer is over that button, so a click anywhere else
/// reaches the window; a non-activating panel that never becomes key, it
/// leaves the anchored app focused.
///
/// The panel sits one step above the window in the stacking order (re-pinned
/// every tick, as cua-driver keeps its agent cursor on the window it drives),
/// so a window in front covers it, and it hides while the window is off
/// screen (another desktop, minimized, closed). The notch island keeps
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

    /// The stop button was clicked.
    var onStop: (() -> Void)?

    private let model = AnchorMarkerModel()
    private var panel: NSPanel?
    private var timer: Timer?
    private var windowID: CGWindowID?
    /// The anchored field, whose box the marker sits above.
    private var field: AXUIElement?
    /// The box the last read found, read again directly while it answers.
    private var boxElement: AXUIElement?
    /// The box relative to its window's top-left corner, so the marker
    /// follows the window between reads. Nil until the first read lands.
    private var boxOffset: CGRect?
    /// The caret at capture, same coordinates: the box when the field can't
    /// be read.
    private var caretOffset: CGRect?
    private var boxReadInFlight = false
    private var ticksUntilBoxRead = 0
    /// Bumped on every show and hide, so a read from an earlier take is
    /// dropped.
    private var generation = 0
    /// The panel frame last set, and the box it was set for.
    private var placedFrame: NSRect?
    private var placedBoxOffset: CGRect?
    private var hideTask: Task<Void, Never>?
    private var levelSubscription: AnyCancellable?
    /// The level the dots show, before rounding for the view.
    private var shownLevel: CGFloat = 0
    /// When the marker began listening: the island starts its timer there
    /// too, not at the press, which comes before the microphone warm-up.
    private var listeningSince = Date()
    /// The take's time once it stops listening.
    private var frozenElapsed: TimeInterval?

    private static let tickInterval: TimeInterval = 1.0 / 15
    /// About four box reads a second: two Accessibility calls each, off the
    /// main thread.
    private static let ticksPerBoxRead = 4
    private static let flightDuration: TimeInterval = 0.25

    var isShowing: Bool { windowID != nil }

    /// Showing a take still recording or processing (not a finished or
    /// waiting paste).
    var phaseIsInFlight: Bool {
        isShowing && (model.phase == .listening || model.phase == .working)
    }

    /// `levels`: the dictation meter, for the dots while the take listens.
    func show(for anchor: DictationPasteAnchor, phase: Phase, levels: AnyPublisher<DictationAudioLevel, Never>?) {
        guard let windowID = anchor.windowID, let field = anchor.field,
              let frame = anchor.windowFrame ?? AnchoredTextDelivery.windowState(windowID)?.frame else {
            hide()
            return
        }
        hideTask?.cancel()
        generation += 1
        self.windowID = windowID
        self.field = field
        boxElement = nil
        boxOffset = nil
        boxReadInFlight = false
        ticksUntilBoxRead = 0
        placedFrame = nil
        placedBoxOffset = nil
        caretOffset = anchor.caretRect.map { $0.offsetBy(dx: -frame.minX, dy: -frame.minY) }
        listeningSince = Date()
        frozenElapsed = nil
        shownLevel = 0
        model.level = 0
        model.phase = phase
        // Readings come on the main actor, synchronously from the meter.
        levelSubscription = levels?.sink { [weak self] reading in
            MainActor.assumeIsolated { self?.receive(reading) }
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.sharingType = NotchIslandPreferences.visibleInScreenSharing() ? .readOnly : .none
        // Shown once the first box read lands, not where the last take was.
        panel.orderOut(nil)
        tick()
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func update(_ phase: Phase) {
        guard isShowing else { return }
        if phase != .listening {
            if frozenElapsed == nil { frozenElapsed = Date().timeIntervalSince(listeningSince) }
            levelSubscription = nil
            model.level = 0
        }
        model.phase = phase
        hideTask?.cancel()
        if phase == .done {
            hideTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 900_000_000)
                guard !Task.isCancelled else { return }
                self?.hide()
            }
        }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        timer?.invalidate()
        timer = nil
        windowID = nil
        generation += 1
        field = nil
        boxElement = nil
        boxOffset = nil
        boxReadInFlight = false
        placedFrame = nil
        placedBoxOffset = nil
        levelSubscription = nil
        setIfChanged(\.animates, false)
        setIfChanged(\.stopHovered, false)
        panel?.ignoresMouseEvents = true
        panel?.orderOut(nil)
    }

    /// Fast up, slower down, like a meter needle, so a syllable shows and
    /// the dots settle back between words.
    private func receive(_ reading: DictationAudioLevel) {
        guard model.phase == .listening else { return }
        let target = NotchIslandBarsView.shaped(reading.peak)
        shownLevel = target > shownLevel ? target : shownLevel * 0.7 + target * 0.3
        // Rounded: the view re-renders only for a change it can show.
        setIfChanged(\.level, (shownLevel * 24).rounded() / 24)
    }

    private func tick() {
        guard let windowID, let panel else { return }
        guard let state = AnchoredTextDelivery.windowState(windowID), state.isOnScreen,
              let primary = NSScreen.screens.first else {
            // Nothing to draw: stop the marker's animation clock too.
            setIfChanged(\.animates, false)
            if panel.isVisible { panel.orderOut(nil) }
            return
        }
        // Window and box are in Accessibility coordinates (top-left origin
        // on the primary display); AppKit's have a bottom-left one.
        let window = state.frame
        ticksUntilBoxRead -= 1
        if ticksUntilBoxRead <= 0 {
            ticksUntilBoxRead = Self.ticksPerBoxRead
            readBox(windowID: windowID)
        }
        guard let boxOffset else { return }

        let elapsed = frozenElapsed ?? Date().timeIntervalSince(listeningSince)
        let timerText = NotchIslandPresentation.timerText(elapsed)
        if model.timerText != timerText {
            model.timerText = timerText
            setIfChanged(\.timerWidth, AnchorMarkerLayout.timerWidth(timerText))
        }
        let animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        setIfChanged(\.animates, animates)

        let layout = AnchorMarkerLayout.self
        let spot = AnchorMarkerPlacement.spot(
            box: boxOffset.offsetBy(dx: window.minX, dy: window.minY),
            window: window,
            flagSize: CGSize(width: layout.placedFlagWidth, height: layout.flagHeight)
        )
        setIfChanged(\.pinnedRight, spot.pinnedRight)
        let size = layout.panelSize
        let left = spot.pinnedRight ? spot.x + layout.inset - size.width : spot.x - layout.inset
        let top = spot.top - layout.inset
        let frame = NSRect(x: left, y: primary.frame.maxY - top - size.height, width: size.width, height: size.height)
        if frame != placedFrame {
            // A new box reading flies the flag over; a window being dragged
            // takes it along at once.
            let flies = animates && panel.isVisible && placedBoxOffset != nil && placedBoxOffset != boxOffset
            NSAnimationContext.runAnimationGroup { context in
                // Zero for a jump: unlike a plain setFrame, it also stops a
                // flight under way.
                context.duration = flies ? Self.flightDuration : 0
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: false)
            }
            placedFrame = frame
            placedBoxOffset = boxOffset
        }
        panel.order(.above, relativeTo: Int(windowID))
        updateStopHover(panelFrame: panel.frame)
    }

    /// Reads the box off the main thread: the box found last time while it
    /// answers, else the field's box found again (T3 Code rebuilds its
    /// composer). One read at a time, so a slow app only delays the marker.
    /// The window is read right after the box, so a window being dragged
    /// doesn't skew the offset.
    private func readBox(windowID: CGWindowID) {
        guard !boxReadInFlight, let field else { return }
        boxReadInFlight = true
        let generation = generation
        let known = boxElement
        Task.detached(priority: .utility) { [weak self] in
            let reading = known.flatMap { element in AnchoredTextDelivery.frame(of: element).map { (element: element, frame: $0) } }
                ?? AnchoredTextDelivery.fieldBox(of: field)
            let window = AnchoredTextDelivery.windowState(windowID)?.frame
            await self?.receiveBox(reading, window: window, generation: generation)
        }
    }

    private func receiveBox(_ reading: (element: AXUIElement, frame: CGRect)?, window: CGRect?, generation: Int) {
        guard generation == self.generation else { return }
        boxReadInFlight = false
        guard let reading, reading.frame.height > 0, let window else {
            boxElement = nil
            // Nothing to read: the caret captured at the start stands in.
            if boxOffset == nil { boxOffset = caretOffset }
            return
        }
        boxElement = reading.element
        boxOffset = reading.frame.offsetBy(dx: -window.minX, dy: -window.minY)
    }

    /// The panel takes the mouse only over the stop button. Checked each
    /// tick: with the mouse ignored, the panel gets no tracking events.
    /// `panelFrame` is where the panel is now, mid-flight included.
    private func updateStopHover(panelFrame: NSRect) {
        var hovered = false
        if model.phase == .listening {
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
        let hosting = AnchorMarkerHostingView(rootView: AnchorMarkerView(model: model) { [weak self] in
            self?.onStop?()
        })
        // The controller sizes the panel; SwiftUI must not resize it to fit.
        hosting.sizingOptions = []
        panel.contentView = hosting
        return panel
    }
}

/// The panel belongs to an app in the background: without this, the first
/// click on the stop button would only be taken as focusing the panel.
private final class AnchorMarkerHostingView: NSHostingView<AnchorMarkerView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Marker view
// Self-contained (SwiftUI and AppKit fonts only), so a design change can be
// reviewed offscreen: copy from here to the end of the file, drop `private`
// from the types, stub `AnchorMarkerController.Phase`, and render
// `AnchorMarkerView` with `ImageRenderer`.

/// Marker geometry in points. The panel is fixed; the flag changes width
/// inside it, from its pinned end. Every part of the flag has a fixed width,
/// so the controller knows where the stop button is without asking the view.
private enum AnchorMarkerLayout {
    static let flagHeight: CGFloat = 22
    /// The island's level bars: 2.5 pt wide, a round dot at rest.
    static let dotCount = 7
    static let dotSize: CGFloat = 2.5
    static let dotGap: CGFloat = 2.5
    static let levelBarMaxHeight: CGFloat = 12
    static let glyphSize: CGFloat = 10
    static let glyphSlot: CGFloat = 11
    static let timerFontSize: CGFloat = 11
    static let stopSize: CGFloat = 16
    static let itemSpacing: CGFloat = 6
    static let leadingPadding: CGFloat = 8
    /// The stop button sits this close to the flag's round end.
    static let stopTrailingPadding: CGFloat = 3
    /// Room around the flag for its shadow.
    static let inset: CGFloat = 5

    static var dotsWidth: CGFloat { CGFloat(dotCount) * dotSize + CGFloat(dotCount - 1) * dotGap }

    static var timerFont: NSFont { .monospacedDigitSystemFont(ofSize: timerFontSize, weight: .medium) }

    /// The timer's slot. Digits are monospaced, so it changes only when the
    /// text gains a digit (9:59 to 10:00, then hours).
    static func timerWidth(_ text: String) -> CGFloat {
        ceil(NSAttributedString(string: text, attributes: [.font: timerFont]).size().width) + 1
    }

    /// The dictation cap is two hours: "h:mm:ss" is the widest timer.
    static let maxFlagWidth: CGFloat = flagWidth(.listening, timerWidth: timerWidth("0:00:00"))
    /// What the placement makes room for: a timer up to 59:59. Past an hour
    /// the flag grows by two characters and may reach past the window edge
    /// rather than jump mid-take.
    static let placedFlagWidth: CGFloat = flagWidth(.listening, timerWidth: timerWidth("00:00"))

    static let panelSize = CGSize(width: maxFlagWidth + 2 * inset, height: flagHeight + 2 * inset)

    static func flagWidth(_ phase: AnchorMarkerController.Phase, timerWidth: CGFloat) -> CGFloat {
        switch phase {
        case .listening:
            return leadingPadding + dotsWidth + itemSpacing + timerWidth + itemSpacing + stopSize + stopTrailingPadding
        case .working: return leadingPadding + dotsWidth + itemSpacing + timerWidth + leadingPadding
        case .waiting: return leadingPadding + glyphSlot + itemSpacing + timerWidth + leadingPadding
        case .done: return leadingPadding + glyphSlot + leadingPadding
        }
    }

    /// The listening flag's stop button in the panel (top-left origin).
    static func stopButtonRect(pinnedRight: Bool, timerWidth: CGFloat) -> CGRect {
        let width = flagWidth(.listening, timerWidth: timerWidth)
        let flagX = pinnedRight ? panelSize.width - inset - width : inset
        return CGRect(x: flagX + width - stopTrailingPadding - stopSize, y: inset + (flagHeight - stopSize) / 2, width: stopSize, height: stopSize)
    }
}

@MainActor
private final class AnchorMarkerModel: ObservableObject {
    @Published var phase: AnchorMarkerController.Phase = .listening
    /// The flag hangs from its right end: inside the top-right corner of a
    /// box that fills the window.
    @Published var pinnedRight = false
    /// False while the panel is off screen or the user reduces motion: the
    /// marker then draws its still pose and its animation clock stops.
    @Published var animates = true
    /// The voice, 0...1, while the take listens.
    @Published var level: CGFloat = 0
    @Published var timerText = "0:00"
    @Published var timerWidth: CGFloat = AnchorMarkerLayout.timerWidth("0:00")
    @Published var stopHovered = false
}

private struct AnchorMarkerView: View {
    @ObservedObject var model: AnchorMarkerModel
    let onStop: () -> Void

    private var accent: Color { Color(nsColor: .controlAccentColor) }

    var body: some View {
        let still = !model.animates || model.phase == .done
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: still)) { context in
            flag(time: still ? nil : context.date.timeIntervalSinceReferenceDate)
        }
        .padding(AnchorMarkerLayout.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.pinnedRight ? .topTrailing : .topLeading)
        .animation(model.animates ? .smooth(duration: 0.2) : nil, value: model.phase)
        .accessibilityHidden(true)
    }

    /// Fixed-width parts, left to right, matching
    /// `AnchorMarkerLayout.flagWidth`.
    private func flag(time: Double?) -> some View {
        let shape = Capsule(style: .continuous)
        let listening = model.phase == .listening
        return HStack(spacing: AnchorMarkerLayout.itemSpacing) {
            switch model.phase {
            case .listening, .working: dots(time: time)
            case .waiting, .done: glyph.frame(width: AnchorMarkerLayout.glyphSlot)
            }
            if model.phase != .done {
                Text(model.timerText)
                    .font(Font(AnchorMarkerLayout.timerFont))
                    .foregroundStyle(Color.white.opacity(listening ? 0.62 : 0.4))
                    .lineLimit(1)
                    .frame(width: model.timerWidth, alignment: .leading)
            }
            if listening { stopButton }
        }
        .padding(.leading, AnchorMarkerLayout.leadingPadding)
        .frame(width: AnchorMarkerLayout.flagWidth(model.phase, timerWidth: model.timerWidth), height: AnchorMarkerLayout.flagHeight, alignment: .leading)
        .background(shape.fill(Color.black.opacity(0.9)))
        // Keeps the black flag apart from a dark app background.
        .overlay(shape.strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
    }

    /// The island's level bars, center-weighted like a meter: dots at rest,
    /// stretching with the voice. While the take is written, a wave of light
    /// runs across them at the island's writing pace.
    private func dots(time: Double?) -> some View {
        HStack(spacing: AnchorMarkerLayout.dotGap) {
            ForEach(0..<AnchorMarkerLayout.dotCount, id: \.self) { index in
                Capsule()
                    .frame(width: AnchorMarkerLayout.dotSize, height: dotHeight(index, time: time))
                    .opacity(model.phase == .working ? rippleOpacity(index, time: time) : 1)
            }
        }
        .frame(width: AnchorMarkerLayout.dotsWidth, height: AnchorMarkerLayout.levelBarMaxHeight)
        .foregroundStyle(accent)
    }

    private static let dotWeights: [CGFloat] = [0.45, 0.7, 0.9, 1, 0.9, 0.7, 0.45]

    private func dotHeight(_ index: Int, time: Double?) -> CGFloat {
        let size = AnchorMarkerLayout.dotSize
        guard model.phase == .listening, model.level > 0 else { return size }
        // A small per-dot sway keeps a held vowel from freezing the row.
        var sway: CGFloat = 1
        if let time {
            let angle: Double = 2 * Double.pi * (time * 2.2 + Double(index) * 0.37)
            sway = 0.78 + 0.22 * CGFloat(sin(angle))
        }
        let height: CGFloat = model.level * Self.dotWeights[index] * sway * AnchorMarkerLayout.levelBarMaxHeight
        return max(size, height)
    }

    private func rippleOpacity(_ index: Int, time: Double?) -> Double {
        let phase = Double(index) / Double(AnchorMarkerLayout.dotCount)
        guard let time else { return [0.3, 0.45, 0.7, 1, 0.7, 0.45, 0.3][index] }
        return 0.3 + 0.7 * pow(0.5 + 0.5 * cos(2 * .pi * (time - phase)), 2)
    }

    /// Waiting shows a white "come back" arrow, matching "Pastes when you're
    /// back in <app>."; an accent check once pasted.
    @ViewBuilder
    private var glyph: some View {
        let size = AnchorMarkerLayout.glyphSize
        if model.phase == .waiting {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: size - 0.5, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.92))
        } else {
            Image(systemName: "checkmark")
                .font(.system(size: size, weight: .heavy))
                .foregroundStyle(accent)
        }
    }

    private var stopButton: some View {
        Button(action: onStop) {
            ZStack {
                Circle().fill(Color.white.opacity(model.stopHovered ? 0.28 : 0.16))
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Color.white.opacity(0.92))
                    .frame(width: 6, height: 6)
            }
            .frame(width: AnchorMarkerLayout.stopSize, height: AnchorMarkerLayout.stopSize)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}
