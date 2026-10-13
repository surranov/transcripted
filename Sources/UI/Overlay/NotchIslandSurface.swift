// NotchIslandSurface.swift
// One display's copy of the notch island: its panel, its view, the display
// and where the shape rests. NotchIslandController keeps the island's state
// once and draws it into the surface on every display; how a surface's shape
// springs lives here.

import AppKit

@MainActor
final class NotchIslandSurface {
    let display: NotchIslandDisplay
    let panel: NotchIslandPanel
    let view: NotchIslandView
    /// Where the finished island sits on screen (the panel can be larger
    /// while the shape springs).
    var targetFrame: NSRect?

    var screen: NotchIslandScreenInfo { display.screen }

    /// A picture of "Who was on this call?" while its live view is on
    /// another display (NotchIslandController+SpeakerReview.swift).
    let speakerReviewMirror = NotchIslandSpeakerReviewMirror()

    /// Up but seen by no one: its display asleep or locked, or the window
    /// covered. Its level bars and the review's picture wait then. Only the
    /// window server's word sets it, so a surface just shown (before that
    /// word arrives, about 50 ms later) still animates from the first frame.
    private(set) var isCovered = false
    private var occlusionObserver: NSObjectProtocol?

    init(display: NotchIslandDisplay) {
        self.display = display
        let initial = NSRect(x: 0, y: 0, width: NotchIslandGeometry.minimumTabWidth, height: NotchIslandGeometry.tabRowHeight)
        panel = NotchIslandPanel(contentRect: initial, styleMask: [], backing: .buffered, defer: true)
        view = NotchIslandView(frame: initial)
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isCovered = self.panel.isVisible && !self.panel.occlusionState.contains(.visible)
            }
        }
    }

    deinit {
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
        }
    }

    /// The shape's current on-screen rect, mid-spring included.
    var presentedShapeFrame: NSRect {
        let shape = view.presentedShapeRect
        let canvas = panel.frame
        return NSRect(x: canvas.minX + shape.minX, y: canvas.maxY - shape.maxY, width: shape.width, height: shape.height)
    }

    /// Springs the shape from one on-screen rect to another. The window
    /// stays put while the island is up (a fixed envelope with room for the
    /// overshoot); only Core Animation moves the shape, so the window can
    /// never resize out of step with it.
    func springShape(
        from start: NSRect,
        fromRadius: CGFloat,
        to end: NSRect,
        radius: CGFloat,
        spring: NotchIslandMotion.Spring?,
        completion: (() -> Void)? = nil
    ) {
        let needed = NotchIslandGeometry.envelope(screen: screen, containing: [start, end], margin: NotchIslandMotion.springMargin)
        let oldCanvas = panel.frame
        let canvas: NSRect
        if !panel.isVisible {
            canvas = needed
        } else if oldCanvas.contains(needed) {
            canvas = oldCanvas
        } else {
            canvas = oldCanvas.union(needed)
        }
        func local(_ rect: NSRect) -> CGRect {
            CGRect(x: rect.minX - canvas.minX, y: canvas.maxY - rect.maxY, width: rect.width, height: rect.height)
        }
        // Where the wings' content sits now, to slide it from there. Not on
        // the first grow, where the content starts in place.
        let slidesContent = spring != nil && completion == nil && panel.isVisible
        let previousAnchors = view.contentAnchors().map { $0 + oldCanvas.minX - canvas.minX }
        if canvas != oldCanvas || !panel.isVisible {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            panel.setFrame(canvas, display: false)
            view.frame = NSRect(origin: .zero, size: canvas.size)
            CATransaction.commit()
        }
        view.setIslandRect(local(end))
        if slidesContent, let spring {
            view.slideContent(from: previousAnchors, spring: spring)
        }
        view.morph(from: local(start), fromRadius: fromRadius, to: local(end), radius: radius, spring: spring) {
            completion?()
        }
    }
}

/// The picture of "Who was on this call?" shown where its live view is not.
/// Clicks fall through to the drop-down (a click between the review's rows
/// does nothing); the pointer arriving brings the live view here first.
final class NotchIslandSpeakerReviewMirror: NSImageView {
    init() {
        super.init(frame: .zero)
        imageScaling = .scaleNone
        imageFrameStyle = .none
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension NotchIslandPanel {
    /// The name box being typed into, while this panel has the keyboard.
    var typingField: NSView? {
        guard isKeyWindow, let editor = firstResponder as? NSTextView, editor.isFieldEditor else { return nil }
        return editor.delegate as? NSView
    }
}
