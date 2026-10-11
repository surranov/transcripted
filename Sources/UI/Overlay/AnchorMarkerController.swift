import AppKit
import SwiftUI

/// Fork: the Anchored paste marker. A small pill next to the caret the
/// dictation is anchored to, drawn over that one window: it sits one step
/// above the window in the stacking order (re-pinned every tick, as
/// cua-driver keeps its agent cursor on the window it drives), so a window
/// in front covers it, and it hides while the window is off screen (another
/// desktop, minimized, closed). It follows the window when it moves. The
/// notch island keeps showing the dictation as before; this only says where
/// the words will go.
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
    private static let markerSize = CGSize(width: 34, height: 22)

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
        caretOffset = CGPoint(x: caret.maxX - frame.minX, y: caret.minY - frame.minY)
        caretHeight = max(12, min(caret.height, 40))
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
        panel?.orderOut(nil)
    }

    private func tick() {
        guard let windowID, let panel else { return }
        guard let state = AnchoredTextDelivery.windowState(windowID), state.isOnScreen,
              let primary = NSScreen.screens.first else {
            if panel.isVisible { panel.orderOut(nil) }
            return
        }
        // Accessibility coordinates have a top-left origin on the primary
        // display; AppKit's have a bottom-left one.
        let size = Self.markerSize
        let caretTop = state.frame.minY + caretOffset.y
        let x = state.frame.minX + caretOffset.x + 6
        let y = primary.frame.maxY - (caretTop + caretHeight / 2) - size.height / 2
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: false)
        panel.order(.above, relativeTo: Int(windowID))
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.markerSize),
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
        panel.contentView = NSHostingView(rootView: AnchorMarkerView(model: model))
        return panel
    }
}

@MainActor
private final class AnchorMarkerModel: ObservableObject {
    @Published var phase: AnchorMarkerController.Phase = .listening
}

private struct AnchorMarkerView: View {
    @ObservedObject var model: AnchorMarkerModel
    @State private var pulse = false

    var body: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.82))
                .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
            content
        }
        .frame(width: 34, height: 22)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .listening:
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .scaleEffect(pulse ? 1.25 : 0.8)
                .opacity(pulse ? 1 : 0.65)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true }
                }
        case .working:
            ProgressView()
                .controlSize(.mini)
                .tint(.white)
        case .waiting:
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.9))
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.green)
        }
    }
}
