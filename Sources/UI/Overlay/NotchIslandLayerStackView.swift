// NotchIslandLayerStackView.swift
// Fork: the dictation queue's pyramid, drawn. The layers behind the island
// (`NotchIslandActivityStack`) sit in this view, under the island's masked
// content: each a card hanging from the top edge, a step narrower and a
// shade lighter than the one above it, peeking out below, with a small
// animation in its peek and a shadow by its height above the bottom layer.
// Core Animation only: the cards ride the island's own spring when its
// shape morphs, and spring on their own when a layer joins or leaves.
//
// The island is always centered horizontally and its row height doesn't
// change while layers show (they tuck in under a drop-down), so a card only
// changes width, and its bottom (with its glyph) only when its depth does.

import AppKit
import QuartzCore

@MainActor
final class NotchIslandLayerStackView: NSView {
    private final class Card {
        let fill = CALayer()
        let glyph = CALayer()
        var kind: NotchIslandBackLayer.Glyph
        var depth = 0

        init(kind: NotchIslandBackLayer.Glyph) {
            self.kind = kind
        }
    }

    /// A shape-only layer under the island casting the island's own shadow
    /// onto the layers below it (the island's content is masked, so it can't).
    private let islandShadow = CALayer()
    private var cards: [String: Card] = [:]
    private var order: [NotchIslandBackLayer] = []
    /// Where the island's shape is heading, in this view's flipped coordinates.
    private var shape: CGRect = .zero
    /// A 1-point view at the top-left: where AppKit puts its layer tells
    /// which way this view's layer y axis runs (as in NotchIslandView).
    private let orientationProbe = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    private var cachedLayerIsYDown: Bool?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        orientationProbe.wantsLayer = true
        orientationProbe.alphaValue = 0
        addSubview(orientationProbe)
        islandShadow.backgroundColor = NSColor.black.cgColor
        islandShadow.cornerCurve = .continuous
        islandShadow.shadowColor = NSColor.black.cgColor
        islandShadow.shadowOpacity = 0
        islandShadow.zPosition = 1
        layer?.addSublayer(islandShadow)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        cachedLayerIsYDown = nil
    }

    // MARK: - Updates

    /// The layers behind the island changed (from the layout). New ones slide
    /// out from under the layer above; gone ones tuck back up and fade.
    func setLayers(_ layers: [NotchIslandBackLayer]) {
        guard layers != order else { return }
        let wanted = Set(layers.map(\.key))
        for (key, card) in cards where !wanted.contains(key) {
            cards[key] = nil
            tuckAway(card)
        }
        for (index, layer) in layers.enumerated() {
            if let card = cards[layer.key] {
                if card.kind != layer.glyph {
                    card.kind = layer.glyph
                    drawGlyph(card)
                }
            } else {
                let card = Card(kind: layer.glyph)
                cards[layer.key] = card
                add(card, startingUnder: index)
            }
        }
        order = layers
        place(spring: NotchIslandMotion.grow)
    }

    /// The island's shape moved: the layers follow with the same spring.
    func follow(to end: CGRect, radius: CGFloat, spring: NotchIslandMotion.Spring?) {
        shape = end
        place(spring: spring, islandRadius: radius)
    }

    /// The island is going away: every layer tucks in.
    func tuckAll() {
        setLayers([])
    }

    // MARK: - Placing

    private var layerIsYDown: Bool {
        if let cachedLayerIsYDown { return cachedLayerIsYDown }
        layoutSubtreeIfNeeded()
        let yDown = (orientationProbe.layer?.frame.minY ?? 0) < 0.5
        if window != nil { cachedLayerIsYDown = yDown }
        return yDown
    }

    /// A flipped rect in this view's layer coordinates.
    private func layerRect(_ rect: CGRect) -> CGRect {
        if layerIsYDown { return rect }
        return CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    private var bottomCorners: CACornerMask {
        layerIsYDown
            ? [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            : [.layerMinXMinYCorner, .layerMaxXMinYCorner]
    }

    private func place(spring: NotchIslandMotion.Spring?, islandRadius: CGFloat? = nil) {
        let layerCount = order.count + 1
        let animated = spring != nil && !NotchIslandPalette.reduceMotion
        let spring = animated ? spring : nil
        apply(
            to: islandShadow,
            frame: layerRect(shape),
            radius: islandRadius ?? NotchIslandGeometry.restingCornerRadius,
            shadow: order.isEmpty ? nil : NotchIslandActivityStack.shadow(depth: 0, layerCount: layerCount),
            spring: spring
        )
        for (index, layer) in order.enumerated() {
            guard let card = cards[layer.key] else { continue }
            let depth = index + 1
            card.depth = depth
            let frame = NotchIslandActivityStack.frame(island: shape, depth: depth)
            let fill = NotchIslandActivityStack.fill(depth: depth)
            card.fill.backgroundColor = CGColor(srgbRed: fill.red, green: fill.green, blue: fill.blue, alpha: 1)
            card.fill.zPosition = -CGFloat(depth * 2)
            card.glyph.zPosition = -CGFloat(depth * 2) + 1
            card.fill.opacity = 1
            card.glyph.opacity = 1
            apply(
                to: card.fill,
                frame: layerRect(frame),
                radius: 13,
                shadow: NotchIslandActivityStack.shadow(depth: depth, layerCount: layerCount),
                spring: spring
            )
            move(card.glyph, to: glyphCenter(in: frame), spring: spring)
        }
    }

    /// The glyph sits in the middle of the card's own peek.
    private func glyphCenter(in frame: CGRect) -> CGPoint {
        let flipped = CGPoint(x: frame.midX, y: frame.maxY - NotchIslandActivityStack.peekPerDepth / 2)
        return layerIsYDown ? flipped : CGPoint(x: flipped.x, y: bounds.height - flipped.y)
    }

    private func add(_ card: Card, startingUnder index: Int) {
        card.fill.cornerCurve = .continuous
        card.fill.maskedCorners = bottomCorners
        card.fill.shadowColor = NSColor.black.cgColor
        card.fill.shadowOpacity = 0
        card.fill.borderColor = NSColor(white: 1, alpha: 0.07).cgColor
        card.fill.borderWidth = 0.5
        layer?.addSublayer(card.fill)
        layer?.addSublayer(card.glyph)
        drawGlyph(card)
        // Starts hidden right under the layer above it, then springs out.
        let start = NotchIslandActivityStack.frame(island: shape, depth: index)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let rect = layerRect(start)
        card.fill.bounds = CGRect(origin: .zero, size: rect.size)
        card.fill.position = CGPoint(x: rect.midX, y: rect.midY)
        card.fill.cornerRadius = 13
        card.glyph.position = glyphCenter(in: start)
        card.glyph.opacity = 0
        CATransaction.commit()
    }

    private func tuckAway(_ card: Card) {
        let spring = NotchIslandPalette.reduceMotion ? nil : NotchIslandMotion.shrink
        let target = NotchIslandActivityStack.frame(island: shape, depth: max(0, card.depth - 1))
        apply(to: card.fill, frame: layerRect(target), radius: 13, shadow: nil, spring: spring)
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            card.fill.removeFromSuperlayer()
            card.glyph.removeFromSuperlayer()
        }
        card.glyph.opacity = 0
        card.fill.opacity = 0
        if spring != nil {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = 0.22
            card.fill.add(fade, forKey: "tuck")
            card.glyph.add(fade, forKey: "tuck")
        }
        CATransaction.commit()
    }

    /// Sets a layer's final geometry, then springs it there from wherever it
    /// is on screen now (mid-animation included).
    private func apply(
        to layer: CALayer,
        frame: CGRect,
        radius: CGFloat,
        shadow: NotchIslandActivityStack.Shadow?,
        spring: NotchIslandMotion.Spring?
    ) {
        let presented = layer.presentation() ?? layer
        let fromBounds = presented.bounds
        let fromPosition = presented.position
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.maskedCorners = bottomCorners
        layer.cornerCurve = .continuous
        layer.bounds = CGRect(origin: .zero, size: frame.size)
        layer.position = CGPoint(x: frame.midX, y: frame.midY)
        layer.cornerRadius = min(radius, frame.height, frame.width / 2)
        layer.shadowOpacity = shadow?.opacity ?? 0
        layer.shadowRadius = shadow?.radius ?? 0
        layer.shadowOffset = CGSize(width: 0, height: (layerIsYDown ? 1 : -1) * (shadow?.offsetY ?? 0))
        CATransaction.commit()
        guard let spring, fromBounds.size != frame.size || fromPosition != layer.position else { return }
        layer.add(Self.spring("bounds", from: NSValue(rect: fromBounds), spring), forKey: "stackBounds")
        layer.add(Self.spring("position", from: NSValue(point: fromPosition), spring), forKey: "stackPosition")
    }

    private func move(_ layer: CALayer, to point: CGPoint, spring: NotchIslandMotion.Spring?) {
        let from = (layer.presentation() ?? layer).position
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.position = point
        CATransaction.commit()
        guard let spring, from != point else { return }
        layer.add(Self.spring("position", from: NSValue(point: from), spring), forKey: "stackPosition")
    }

    private static func spring(_ keyPath: String, from value: Any, _ spring: NotchIslandMotion.Spring) -> CASpringAnimation {
        let animation = CASpringAnimation(keyPath: keyPath)
        animation.fromValue = value
        animation.mass = 1
        animation.stiffness = spring.stiffness
        animation.damping = spring.damping
        animation.duration = animation.settlingDuration
        return animation
    }

    // MARK: - Glyphs

    /// Each back layer shows only a small animation in its peek, no text:
    /// the meeting's red dot and levels, a take's rippling dots and wave,
    /// a queued take's ring.
    private func drawGlyph(_ card: Card) {
        let glyph = card.glyph
        glyph.sublayers?.forEach { $0.removeFromSuperlayer() }
        let animates = !NotchIslandPalette.reduceMotion
        switch card.kind {
        case .meeting:
            let dot = Self.dot(size: 5, color: NotchIslandPalette.recording)
            if animates { dot.add(Self.pulse(duration: 1.1), forKey: "pulse") }
            let bars = Self.bars(count: 4, color: NotchIslandPalette.accent.withAlphaComponent(0.6), animates: animates, period: 0.9)
            Self.row([dot, bars], in: glyph)
        case .processing:
            let dots = (0..<3).map { index -> CALayer in
                let dot = Self.dot(size: 3, color: NotchIslandPalette.accent)
                if animates {
                    let ripple = Self.pulse(duration: 0.5)
                    ripple.beginTime = CACurrentMediaTime() + Double(index) * 0.15
                    dot.add(ripple, forKey: "ripple")
                }
                return dot
            }
            let dotsRow = CALayer()
            Self.row(dots, in: dotsRow, gap: 2)
            let wave = Self.bars(count: 3, color: NSColor(white: 1, alpha: 0.65), animates: animates, period: 0.7)
            Self.row([dotsRow, wave], in: glyph)
        case .queued:
            let ring = CAShapeLayer()
            ring.bounds = CGRect(x: 0, y: 0, width: 6, height: 6)
            ring.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: 0.75, dy: 0.75), transform: nil)
            ring.fillColor = nil
            ring.strokeColor = NotchIslandPalette.accent.cgColor
            ring.lineWidth = 1.5
            if animates { ring.add(Self.pulse(duration: 1.2), forKey: "pulse") }
            Self.row([ring], in: glyph)
        }
    }

    /// Lays `items` out left to right, vertically centered, and sizes
    /// `container` to fit them (its position is its center).
    private static func row(_ items: [CALayer], in container: CALayer, gap: CGFloat = 5) {
        let width = items.reduce(0) { $0 + $1.bounds.width } + gap * CGFloat(max(0, items.count - 1))
        let height = items.map(\.bounds.height).max() ?? 0
        container.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        var x: CGFloat = 0
        for item in items {
            item.position = CGPoint(x: x + item.bounds.width / 2, y: height / 2)
            x += item.bounds.width + gap
            container.addSublayer(item)
        }
    }

    private static func dot(size: CGFloat, color: NSColor) -> CALayer {
        let dot = CALayer()
        dot.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        dot.cornerRadius = size / 2
        dot.backgroundColor = color.cgColor
        return dot
    }

    /// Small bars bouncing out of phase: a level meter or a working wave.
    /// Still bars at rest when motion is reduced.
    private static func bars(count: Int, color: NSColor, animates: Bool, period: Double) -> CALayer {
        let height: CGFloat = 6
        let items = (0..<count).map { index -> CALayer in
            let bar = CALayer()
            bar.bounds = CGRect(x: 0, y: 0, width: 2, height: height)
            bar.cornerRadius = 1
            bar.backgroundColor = color.cgColor
            if animates {
                let bounce = CABasicAnimation(keyPath: "transform.scale.y")
                bounce.fromValue = 0.3
                bounce.toValue = 1
                bounce.duration = period / 2
                bounce.autoreverses = true
                bounce.repeatCount = .infinity
                bounce.beginTime = CACurrentMediaTime() + Double(index) * period / Double(count + 1)
                bounce.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                bar.add(bounce, forKey: "bounce")
            } else {
                bar.transform = CATransform3DMakeScale(1, 0.4, 1)
            }
            return bar
        }
        let container = CALayer()
        row(items, in: container, gap: 1.5)
        return container
    }

    private static func pulse(duration: Double) -> CABasicAnimation {
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.35
        pulse.duration = duration
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        return pulse
    }
}
