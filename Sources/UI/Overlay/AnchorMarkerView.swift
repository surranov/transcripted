import AppKit
import SwiftUI

// Fork: the Anchored paste marker's flag (`AnchorMarkerController`).
// Self-contained (SwiftUI and AppKit fonts only), so a design change can be
// reviewed offscreen: drop `fileprivate`/`private`, stub
// `AnchorMarkerController.Phase`, and render `AnchorMarkerView` with
// `ImageRenderer`.

/// Marker geometry in points. The panel is fixed; the flag changes width
/// inside it, from its pinned end. Every part of the flag has a fixed width,
/// so the controller knows where the stop button is, and how wide a row of
/// flags is, without asking the view.
enum AnchorMarkerLayout {
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

    /// A compact flag (a take in the background, or on its thread's sidebar
    /// row) shows only the dots or the glyph: no timer, no stop button.
    static func flagWidth(_ phase: AnchorMarkerController.Phase, timerWidth: CGFloat, compact: Bool = false) -> CGFloat {
        switch (phase, compact) {
        case (.listening, true), (.working, true): return leadingPadding + dotsWidth + leadingPadding
        case (.waiting, true): return leadingPadding + glyphSlot + leadingPadding
        case (.listening, false):
            return leadingPadding + dotsWidth + itemSpacing + timerWidth + itemSpacing + stopSize + stopTrailingPadding
        case (.working, false): return leadingPadding + dotsWidth + itemSpacing + timerWidth + leadingPadding
        case (.waiting, false): return leadingPadding + glyphSlot + itemSpacing + timerWidth + leadingPadding
        case (.done, _): return leadingPadding + glyphSlot + leadingPadding
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
final class AnchorMarkerModel: ObservableObject {
    @Published var phase: AnchorMarkerController.Phase = .listening
    /// The flag hangs from its right end: inside the top-right corner of a
    /// box that fills the window, or in a sidebar row's corner.
    @Published var pinnedRight = false
    /// Dots or glyph only (`AnchorMarkerLayout.flagWidth`).
    @Published var compact = false
    /// False while the panel is off screen or the user reduces motion: the
    /// marker then draws its still pose and its animation clock stops.
    @Published var animates = true
    /// The voice, 0...1, while the take listens.
    @Published var level: CGFloat = 0
    @Published var timerText = "0:00"
    @Published var timerWidth: CGFloat = AnchorMarkerLayout.timerWidth("0:00")
    @Published var stopHovered = false

    /// The stop button shows: a full flag listening.
    var showsStop: Bool { phase == .listening && !compact }
}

/// The panel belongs to an app in the background: without this, the first
/// click on the stop button would only be taken as focusing the panel.
final class AnchorMarkerHostingView: NSHostingView<AnchorMarkerView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct AnchorMarkerView: View {
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
        .animation(model.animates ? .smooth(duration: 0.2) : nil, value: model.compact)
        .accessibilityHidden(true)
    }

    /// Fixed-width parts, left to right, matching
    /// `AnchorMarkerLayout.flagWidth`.
    private func flag(time: Double?) -> some View {
        let shape = Capsule(style: .continuous)
        let listening = model.phase == .listening
        let width = AnchorMarkerLayout.flagWidth(model.phase, timerWidth: model.timerWidth, compact: model.compact)
        return HStack(spacing: AnchorMarkerLayout.itemSpacing) {
            switch model.phase {
            case .listening, .working: dots(time: time)
            case .waiting, .done: glyph.frame(width: AnchorMarkerLayout.glyphSlot)
            }
            if model.phase != .done, !model.compact {
                Text(model.timerText)
                    .font(Font(AnchorMarkerLayout.timerFont))
                    .foregroundStyle(Color.white.opacity(listening ? 0.62 : 0.4))
                    .lineLimit(1)
                    .frame(width: model.timerWidth, alignment: .leading)
            }
            if model.showsStop { stopButton }
        }
        .padding(.leading, AnchorMarkerLayout.leadingPadding)
        .frame(width: width, height: AnchorMarkerLayout.flagHeight, alignment: .leading)
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
