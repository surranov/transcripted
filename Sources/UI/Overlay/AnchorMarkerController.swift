import AppKit
import SwiftUI

/// Fork: the Anchored paste marker, drawn over the one window the dictation
/// is anchored to. An accent "ghost caret" lies over the caret the words will
/// land at, and a small black flag (the notch island's look: black, accent
/// glyph) hangs from its foot with the take's phase. The flag hangs below the
/// caret line, where a composer or the end of the text leaves empty space, so
/// it doesn't cover the text after the caret or the line above; it flips
/// above or to the left only when the window edge leaves no room.
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

    private let model = AnchorMarkerModel()
    private var panel: NSPanel?
    private var timer: Timer?
    private var windowID: CGWindowID?
    /// The caret relative to its window's top-left corner, so the marker
    /// follows the window.
    private var caretOffset = CGPoint.zero
    private var caretHeight: CGFloat = 18
    private var hideTask: Task<Void, Never>?

    private static let tickInterval: TimeInterval = 1.0 / 15

    var isShowing: Bool { windowID != nil }

    /// Showing a take still recording or processing (not a finished or
    /// waiting paste).
    var phaseIsInFlight: Bool {
        isShowing && (model.phase == .listening || model.phase == .working)
    }

    func show(for anchor: DictationPasteAnchor, phase: Phase) {
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
        model.phase = phase
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
        setIfChanged(\.animates, false)
        panel?.orderOut(nil)
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
        // Window and caret are in Accessibility coordinates (top-left origin
        // on the primary display); AppKit's have a bottom-left one.
        let layout = AnchorMarkerLayout.self
        let window = state.frame
        let caretX = window.minX + caretOffset.x
        let caretTop = window.minY + caretOffset.y
        let flagBelow = caretTop + caretHeight + layout.barOverhang + layout.flagHeight <= window.maxY - layout.edgeMargin
        let flagTrailing = caretX + layout.barWidth / 2 + layout.maxFlagWidth <= window.maxX - layout.edgeMargin
        setIfChanged(\.flagBelow, flagBelow)
        setIfChanged(\.flagTrailing, flagTrailing)
        setIfChanged(\.animates, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)

        let size = layout.panelSize(barHeight: model.barHeight)
        let x = flagTrailing
            ? caretX - layout.barWidth / 2 - layout.inset
            : caretX + layout.barWidth / 2 + layout.inset - size.width
        let barTop = caretTop - layout.barOverhang
        let top = flagBelow ? barTop - layout.inset : barTop - layout.flagHeight - layout.inset
        let frame = NSRect(x: x, y: primary.frame.maxY - top - size.height, width: size.width, height: size.height)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        panel.order(.above, relativeTo: Int(windowID))
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
        let hosting = NSHostingView(rootView: AnchorMarkerView(model: model))
        // The controller sizes the panel; SwiftUI must not resize it to fit.
        hosting.sizingOptions = []
        panel.contentView = hosting
        return panel
    }
}

// MARK: - Marker view
// Self-contained (SwiftUI only), so a design change can be reviewed
// offscreen: copy from here to the end of the file, drop `private` from the
// three types, stub `AnchorMarkerController.Phase`, and render
// `AnchorMarkerView` with `ImageRenderer`.

/// Marker geometry in points. The panel is fixed per show; the flag changes
/// width inside it.
private enum AnchorMarkerLayout {
    static let barWidth: CGFloat = 2.5
    /// The ghost caret reaches this far past the caret's top and bottom.
    static let barOverhang: CGFloat = 1
    static let flagHeight: CGFloat = 17
    static let glyphSize: CGFloat = 9
    /// Room around the drawing for the bar's glow and the flag's shadow.
    static let inset: CGFloat = 5
    /// How close to the window edge the flag may come before it flips.
    static let edgeMargin: CGFloat = 2
    static let maxFlagWidth: CGFloat = flagWidth(.listening)

    static func flagWidth(_ phase: AnchorMarkerController.Phase) -> CGFloat {
        switch phase {
        case .listening: return 31
        case .working: return 26
        case .waiting, .done: return 22
        }
    }

    static func panelSize(barHeight: CGFloat) -> CGSize {
        CGSize(width: maxFlagWidth + 2 * inset, height: barHeight + flagHeight + 2 * inset)
    }
}

@MainActor
private final class AnchorMarkerModel: ObservableObject {
    @Published var phase: AnchorMarkerController.Phase = .listening
    @Published var barHeight: CGFloat = 20
    @Published var flagBelow = true
    /// The flag reaches right of the caret; false next to the window's
    /// right edge.
    @Published var flagTrailing = true
    /// False while the panel is off screen or the user reduces motion: the
    /// marker then draws its still pose and its animation clock stops.
    @Published var animates = true
}

private struct AnchorMarkerView: View {
    @ObservedObject var model: AnchorMarkerModel

    private var accent: Color { Color(nsColor: .controlAccentColor) }

    var body: some View {
        let still = !model.animates || model.phase == .done
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: still)) { context in
            let time = still ? nil : context.date.timeIntervalSinceReferenceDate
            VStack(alignment: model.flagTrailing ? .leading : .trailing, spacing: 0) {
                if model.flagBelow {
                    ghostCaret(time: time)
                    flag(time: time)
                } else {
                    flag(time: time)
                    ghostCaret(time: time)
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

    private func flag(time: Double?) -> some View {
        let shape = UnevenRoundedRectangle(cornerRadii: flagCorners, style: .continuous)
        return ZStack {
            shape.fill(Color.black.opacity(0.9))
            // Keeps the black flag apart from a dark app background.
            shape.strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5)
            glyph(time: time)
        }
        .frame(width: AnchorMarkerLayout.flagWidth(model.phase), height: AnchorMarkerLayout.flagHeight)
        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
    }

    /// Round at the far end, nearly square where the flag meets the caret.
    private var flagCorners: RectangleCornerRadii {
        let far = AnchorMarkerLayout.flagHeight / 2
        let near = far * 0.7
        let joint: CGFloat = 1.5
        switch (model.flagBelow, model.flagTrailing) {
        case (true, true): return RectangleCornerRadii(topLeading: joint, bottomLeading: near, bottomTrailing: far, topTrailing: far)
        case (true, false): return RectangleCornerRadii(topLeading: far, bottomLeading: far, bottomTrailing: near, topTrailing: joint)
        case (false, true): return RectangleCornerRadii(topLeading: near, bottomLeading: joint, bottomTrailing: far, topTrailing: far)
        case (false, false): return RectangleCornerRadii(topLeading: far, bottomLeading: far, bottomTrailing: joint, topTrailing: near)
        }
    }

    /// The island's vocabulary: mic and bars while it listens, rippling dots
    /// while it writes, an accent check once pasted. Waiting shows a white
    /// "come back" arrow, matching "Pastes when you're back in <app>."
    @ViewBuilder
    private func glyph(time: Double?) -> some View {
        let size = AnchorMarkerLayout.glyphSize
        switch model.phase {
        case .listening:
            HStack(spacing: 3) {
                Image(systemName: "mic.fill").font(.system(size: size, weight: .bold))
                HStack(spacing: 1.5) {
                    ForEach(0..<3, id: \.self) { index in
                        Capsule().frame(width: 2, height: barLevel(index, time: time) * (size + 0.5))
                    }
                }
                .frame(height: size + 0.5)
            }
            .foregroundStyle(accent)
        case .working:
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { index in
                    Circle().frame(width: 3.8, height: 3.8).opacity(dotOpacity(index, time: time))
                }
            }
            .foregroundStyle(accent)
        case .waiting:
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: size - 0.5, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.92))
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: size, weight: .heavy))
                .foregroundStyle(accent)
        }
    }

    /// 0...1. A slow made-up wave (the marker gets no audio levels; the
    /// island shows the real ones); a fixed pose when still.
    private func barLevel(_ index: Int, time: Double?) -> CGFloat {
        guard let time else { return [0.55, 1, 0.7][index] }
        let wave = sin(2 * .pi * (time * 1.1 + Double(index) * 0.31))
        return 0.35 + 0.65 * CGFloat(0.5 + 0.5 * wave)
    }

    /// The island's writing dots, fading 1 to 0.3 and back each second, but a
    /// third of a second apart (the island's 0.15 s lets all three go dim at
    /// once, and a dim flag this small reads as empty).
    private func dotOpacity(_ index: Int, time: Double?) -> Double {
        guard let time else { return 1 }
        return 0.65 + 0.35 * cos(2 * .pi * (time - Double(index) / 3))
    }
}
