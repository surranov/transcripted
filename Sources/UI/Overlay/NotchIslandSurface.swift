// NotchIslandSurface.swift
// One copy of the notch island on screen: its panel, its view, the display it
// sits on and where the shape rests. NotchIslandController keeps the island's
// state once and draws it into each surface; how a surface's shape springs
// lives here.

import AppKit

@MainActor
final class NotchIslandSurface {
    let panel: NotchIslandPanel
    let view: NotchIslandView
    /// The display it is on, kept while the island is up so it never jumps.
    var screen: NotchIslandScreenInfo?
    /// Where the finished island sits on screen (the panel can be larger
    /// while the shape springs).
    var targetFrame: NSRect?

    init() {
        let initial = NSRect(x: 0, y: 0, width: NotchIslandGeometry.minimumTabWidth, height: NotchIslandGeometry.tabRowHeight)
        panel = NotchIslandPanel(contentRect: initial, styleMask: [], backing: .buffered, defer: true)
        view = NotchIslandView(frame: initial)
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
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
        on screen: NotchIslandScreenInfo,
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
