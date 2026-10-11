import AppKit
import Combine
import SwiftUI

/// Fork: the Anchored paste marker, drawn over the one window the dictation
/// is anchored to. An accent "ghost caret" lies over the caret the words will
/// land at, and a small black flag (the notch island's look: black, accent
/// glyphs) hangs from its foot with the take's phase: while it listens, seven
/// level dots that stretch with the voice, the take's time and a stop button;
/// then the writing ripple, the come-back arrow or the check. The flag hangs
/// below the caret line, where a composer or the end of the text leaves empty
/// space, so it doesn't cover the text after the caret or the line above; at
/// the window's bottom edge it sits beside the caret instead, and it flips
/// above or to the left only in the window's corners
/// (`AnchorMarkerLayout.flagSpot`).
///
/// The stop button stops the take like the island's. The panel takes the
/// mouse only while the pointer is over that button, so a click anywhere else
/// (the caret under the ghost caret included) reaches the window; a
/// non-activating panel that never becomes key, it leaves the anchored app
/// focused.
///
/// The panel sits one step above the window in the stacking order (re-pinned
/// every tick, as cua-driver keeps its agent cursor on the window it drives),
/// so a window in front covers it, and it hides while the window is off
/// screen (another desktop, minimized, closed). It follows the window when it
/// moves. The notch island keeps showing the dictation as before; this only
/// says where the words will go.
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
    /// The caret relative to its window's top-left corner, so the marker
    /// follows the window.
    private var caretOffset = CGPoint.zero
    private var caretHeight: CGFloat = 18
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

    var isShowing: Bool { windowID != nil }

    /// Showing a take still recording or processing (not a finished or
    /// waiting paste).
    var phaseIsInFlight: Bool {
        isShowing && (model.phase == .listening || model.phase == .working)
    }

    /// `levels`: the dictation meter, for the dots while the take listens.
    func show(for anchor: DictationPasteAnchor, phase: Phase, levels: AnyPublisher<DictationAudioLevel, Never>?) {
        guard let windowID = anchor.windowID, let caret = anchor.caretRect,
              let frame = anchor.windowFrame ?? AnchoredTextDelivery.windowState(windowID)?.frame else {
            hide()
            return
        }
        hideTask?.cancel()
        self.windowID = windowID
        // The insertion point is the caret rect's leading edge (a zero-width
        // rect, or the 1 pt rect built after the previous character).
        caretOffset = CGPoint(x: caret.minX - frame.minX, y: caret.minY - frame.minY)
        caretHeight = max(12, min(caret.height, 40))
        model.barHeight = caretHeight + 2 * AnchorMarkerLayout.barOverhang
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
        let elapsed = frozenElapsed ?? Date().timeIntervalSince(listeningSince)
        let timerText = NotchIslandPresentation.timerText(elapsed)
        if model.timerText != timerText {
            model.timerText = timerText
            setIfChanged(\.timerWidth, AnchorMarkerLayout.timerWidth(timerText))
        }

        // Window and caret are in Accessibility coordinates (top-left origin
        // on the primary display); AppKit's have a bottom-left one.
        let layout = AnchorMarkerLayout.self
        let window = state.frame
        let caretX = window.minX + caretOffset.x
        let caretTop = window.minY + caretOffset.y
        let spot = layout.flagSpot(caretX: caretX, caretTop: caretTop, caretHeight: caretHeight, window: window)
        setIfChanged(\.flagPlacement, spot.placement)
        setIfChanged(\.flagTrailing, spot.trailing)
        setIfChanged(\.animates, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)

        let size = layout.panelSize(barHeight: model.barHeight)
        let origin = layout.panelOrigin(caretX: caretX, caretTop: caretTop, barHeight: model.barHeight, spot: spot)
        let frame = NSRect(x: origin.x, y: primary.frame.maxY - origin.y - size.height, width: size.width, height: size.height)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        panel.order(.above, relativeTo: Int(windowID))
        updateStopHover(panelFrame: frame, spot: spot)
    }

    /// The panel takes the mouse only over the stop button. Checked each
    /// tick: with the mouse ignored, the panel gets no tracking events.
    private func updateStopHover(panelFrame: NSRect, spot: (placement: AnchorFlagPlacement, trailing: Bool)) {
        var hovered = false
        if model.phase == .listening {
            let button = AnchorMarkerLayout.stopButtonRect(spot: spot, barHeight: model.barHeight, timerWidth: model.timerWidth)
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
        let size = AnchorMarkerLayout.panelSize(barHeight: model.barHeight)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
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

/// Where the flag hangs from the ghost caret.
private enum AnchorFlagPlacement: Equatable {
    /// Under the caret line, where a composer or the end of the text leaves
    /// empty space.
    case below
    /// Right of the caret, on its line: the window's bottom edge leaves no
    /// room below. A terminal's prompt sits on its last line with the output
    /// right above, and nothing follows its caret.
    case beside
    /// Over the line above: only in the window's bottom-right corner.
    case above
}

/// Marker geometry in points. The panel is fixed per show; the flag changes
/// width inside it. Every part of the flag has a fixed width, so the
/// controller knows where the stop button is without asking the view.
private enum AnchorMarkerLayout {
    static let barWidth: CGFloat = 2.5
    /// The ghost caret reaches this far past the caret's top and bottom.
    static let barOverhang: CGFloat = 1
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
    /// Room around the drawing for the bar's glow and the flag's shadow.
    static let inset: CGFloat = 5
    /// How close to the window edge the flag may come before it flips.
    static let edgeMargin: CGFloat = 2
    /// Between the ghost caret and a flag beside it.
    static let besideGap: CGFloat = 2

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
    /// rather than jump to another side mid-take; sized for hours from the
    /// start, it would cover the line above more often.
    static let placedFlagWidth: CGFloat = flagWidth(.listening, timerWidth: timerWidth("00:00"))

    static func flagWidth(_ phase: AnchorMarkerController.Phase, timerWidth: CGFloat) -> CGFloat {
        switch phase {
        case .listening:
            return leadingPadding + dotsWidth + itemSpacing + timerWidth + itemSpacing + stopSize + stopTrailingPadding
        case .working: return leadingPadding + dotsWidth + itemSpacing + timerWidth + leadingPadding
        case .waiting: return leadingPadding + glyphSlot + itemSpacing + timerWidth + leadingPadding
        case .done: return leadingPadding + glyphSlot + leadingPadding
        }
    }

    /// Fits every placement: the flag under or over the bar, or beside it.
    static func panelSize(barHeight: CGFloat) -> CGSize {
        CGSize(width: barWidth + besideGap + maxFlagWidth + 2 * inset, height: barHeight + flagHeight + 2 * inset)
    }

    /// The flag's spot for a caret in its window (Accessibility coordinates,
    /// top-left origin), and whether it reaches right of the caret.
    static func flagSpot(caretX: CGFloat, caretTop: CGFloat, caretHeight: CGFloat, window: CGRect) -> (placement: AnchorFlagPlacement, trailing: Bool) {
        let roomBelow = caretTop + caretHeight + barOverhang + flagHeight <= window.maxY - edgeMargin
        let roomRight = caretX + barWidth / 2 + placedFlagWidth <= window.maxX - edgeMargin
        if roomBelow { return (.below, roomRight) }
        let roomBeside = caretX + barWidth / 2 + besideGap + placedFlagWidth <= window.maxX - edgeMargin
        return roomBeside ? (.beside, true) : (.above, roomRight)
    }

    /// The panel's top-left corner, same coordinates. The view pins its
    /// drawing to the panel's top-leading corner, or top-trailing for a flag
    /// reaching left.
    static func panelOrigin(caretX: CGFloat, caretTop: CGFloat, barHeight: CGFloat, spot: (placement: AnchorFlagPlacement, trailing: Bool)) -> CGPoint {
        let width = panelSize(barHeight: barHeight).width
        let x = spot.trailing ? caretX - barWidth / 2 - inset : caretX + barWidth / 2 + inset - width
        let barTop = caretTop - barOverhang
        switch spot.placement {
        case .below: return CGPoint(x: x, y: barTop - inset)
        case .above: return CGPoint(x: x, y: barTop - flagHeight - inset)
        // Centered on the bar: a flag taller than a small caret overhangs it
        // evenly.
        case .beside: return CGPoint(x: x, y: barTop - max(0, flagHeight - barHeight) / 2 - inset)
        }
    }

    /// The listening flag's stop button in the panel (top-left origin).
    static func stopButtonRect(spot: (placement: AnchorFlagPlacement, trailing: Bool), barHeight: CGFloat, timerWidth: CGFloat) -> CGRect {
        let width = flagWidth(.listening, timerWidth: timerWidth)
        let flagX: CGFloat
        switch (spot.placement, spot.trailing) {
        case (.beside, _): flagX = inset + barWidth + besideGap
        case (_, true): flagX = inset
        case (_, false): flagX = panelSize(barHeight: barHeight).width - inset - width
        }
        let flagY: CGFloat
        switch spot.placement {
        case .below: flagY = inset + barHeight
        case .above: flagY = inset
        case .beside: flagY = inset + max(0, barHeight - flagHeight) / 2
        }
        return CGRect(x: flagX + width - stopTrailingPadding - stopSize, y: flagY + (flagHeight - stopSize) / 2, width: stopSize, height: stopSize)
    }
}

@MainActor
private final class AnchorMarkerModel: ObservableObject {
    @Published var phase: AnchorMarkerController.Phase = .listening
    @Published var barHeight: CGFloat = 20
    @Published var flagPlacement = AnchorFlagPlacement.below
    /// The flag reaches right of the caret; false next to the window's
    /// right edge.
    @Published var flagTrailing = true
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
            let time = still ? nil : context.date.timeIntervalSinceReferenceDate
            switch model.flagPlacement {
            case .below:
                VStack(alignment: model.flagTrailing ? .leading : .trailing, spacing: 0) {
                    ghostCaret(time: time)
                    flag(time: time)
                }
            case .above:
                VStack(alignment: model.flagTrailing ? .leading : .trailing, spacing: 0) {
                    flag(time: time)
                    ghostCaret(time: time)
                }
            case .beside:
                HStack(spacing: AnchorMarkerLayout.besideGap) {
                    ghostCaret(time: time)
                    flag(time: time)
                }
            }
        }
        .padding(AnchorMarkerLayout.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.flagTrailing ? .topLeading : .topTrailing)
        .animation(model.animates ? .smooth(duration: 0.2) : nil, value: model.phase)
        .accessibilityHidden(true)
    }

    /// An accent bar over the real caret, with a soft glow. While the paste
    /// waits it blinks slowly, like a caret asking for the user to come back.
    private func ghostCaret(time: Double?) -> some View {
        let opacity: Double
        if model.phase == .waiting {
            opacity = time.map { 0.5 + 0.5 * (0.5 + 0.5 * cos(2 * .pi * $0 / 1.2)) } ?? 0.6
        } else {
            opacity = 1
        }
        return RoundedRectangle(cornerRadius: AnchorMarkerLayout.barWidth / 2, style: .continuous)
            .fill(accent)
            .frame(width: AnchorMarkerLayout.barWidth, height: model.barHeight)
            .shadow(color: accent.opacity(0.45), radius: 3)
            .opacity(opacity)
    }

    /// Fixed-width parts, left to right, matching
    /// `AnchorMarkerLayout.flagWidth`.
    private func flag(time: Double?) -> some View {
        let shape = UnevenRoundedRectangle(cornerRadii: flagCorners, style: .continuous)
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

    /// Round at the far end, nearly square where the flag meets the caret.
    private var flagCorners: RectangleCornerRadii {
        let far = AnchorMarkerLayout.flagHeight / 2
        let near = far * 0.75
        let joint: CGFloat = 3
        switch (model.flagPlacement, model.flagTrailing) {
        case (.below, true): return RectangleCornerRadii(topLeading: joint, bottomLeading: far, bottomTrailing: far, topTrailing: far)
        case (.below, false): return RectangleCornerRadii(topLeading: far, bottomLeading: far, bottomTrailing: far, topTrailing: joint)
        case (.above, true): return RectangleCornerRadii(topLeading: far, bottomLeading: joint, bottomTrailing: far, topTrailing: far)
        case (.above, false): return RectangleCornerRadii(topLeading: far, bottomLeading: far, bottomTrailing: joint, topTrailing: far)
        // Always trailing: a caret with no room right goes `.above`.
        case (.beside, _): return RectangleCornerRadii(topLeading: near, bottomLeading: near, bottomTrailing: far, topTrailing: far)
        }
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
