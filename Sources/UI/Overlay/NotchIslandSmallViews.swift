// NotchIslandSmallViews.swift
// The island's small drawings: the progress ring, the dots, the writing
// ripple and the shimmer. Split out of NotchIslandView.swift.

import AppKit

// MARK: - Small drawings

/// A round progress ring, or a spinning arc when there is no number yet.
final class NotchIslandRingView: NSView {
    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    private let indeterminate: Bool

    init(indeterminate: Bool) {
        self.indeterminate = indeterminate
        super.init(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
        wantsLayer = true
        for shape in [track, arc] {
            shape.fillColor = nil
            shape.lineWidth = 2.5
            shape.lineCap = .round
            layer?.addSublayer(shape)
        }
        track.strokeColor = NSColor(white: 1, alpha: 0.25).cgColor
        arc.strokeColor = NotchIslandPalette.accent.cgColor
        arc.strokeEnd = indeterminate ? 0.28 : 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: 14, height: 14) }

    override func layout() {
        super.layout()
        let path = CGPath(ellipseIn: bounds.insetBy(dx: 1.5, dy: 1.5), transform: nil)
        track.frame = bounds
        arc.frame = bounds
        track.path = path
        arc.path = path
        if indeterminate, arc.animation(forKey: "spin") == nil, !NotchIslandPalette.reduceMotion {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi
            spin.duration = 0.9
            spin.repeatCount = .infinity
            arc.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            arc.position = CGPoint(x: bounds.midX, y: bounds.midY)
            arc.add(spin, forKey: "spin")
        }
    }

    func setProgress(_ progress: Double) {
        guard !indeterminate else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arc.strokeEnd = CGFloat(min(1, max(0, progress)))
        CATransaction.commit()
    }
}

/// A plain dot; `pulsing` breathes gently.
final class NotchIslandDotView: NSView {
    private let size: CGFloat
    private let glow: Bool

    init(size: CGFloat, color: NSColor, glow: Bool) {
        self.size = size
        self.glow = glow
        super.init(frame: NSRect(x: 0, y: 0, width: glow ? size * 2 : size, height: glow ? size * 2 : size))
        wantsLayer = true
        let dot = CALayer()
        dot.backgroundColor = color.cgColor
        dot.cornerRadius = size / 2
        let outer = glow ? size * 2 : size
        dot.frame = CGRect(x: (outer - size) / 2, y: (outer - size) / 2, width: size, height: size)
        if glow {
            let ring = CALayer()
            ring.backgroundColor = color.withAlphaComponent(0.3).cgColor
            ring.cornerRadius = outer / 2
            ring.frame = CGRect(x: 0, y: 0, width: outer, height: outer)
            layer?.addSublayer(ring)
        }
        layer?.addSublayer(dot)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize {
        glow ? NSSize(width: size * 2, height: size * 2) : NSSize(width: size, height: size)
    }
}

/// Three dots that ripple while the words are written.
final class NotchIslandDotsView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 21, height: 5))
        wantsLayer = true
        for index in 0..<3 {
            let dot = CALayer()
            dot.backgroundColor = NotchIslandPalette.accent.cgColor
            dot.cornerRadius = 2.5
            dot.frame = CGRect(x: CGFloat(index) * 8, y: 0, width: 5, height: 5)
            if !NotchIslandPalette.reduceMotion {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 1
                fade.toValue = 0.3
                fade.duration = 0.5
                fade.autoreverses = true
                fade.repeatCount = .infinity
                fade.beginTime = CACurrentMediaTime() + Double(index) * 0.15
                dot.add(fade, forKey: "ripple")
            }
            layer?.addSublayer(dot)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: 21, height: 5) }
}

/// A short light sweep where the text is being written.
final class NotchIslandShimmerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 46, height: 5))
        wantsLayer = true
        let gradient = CAGradientLayer()
        gradient.frame = CGRect(x: 0, y: 0, width: 46, height: 5)
        gradient.cornerRadius = 2.5
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        let dim = NSColor(white: 1, alpha: 0.18).cgColor
        let bright = NSColor(white: 1, alpha: 0.55).cgColor
        gradient.colors = [dim, bright, dim]
        gradient.locations = [0, 0.5, 1]
        if !NotchIslandPalette.reduceMotion {
            let sweep = CABasicAnimation(keyPath: "locations")
            sweep.fromValue = [-1, -0.5, 0]
            sweep.toValue = [1, 1.5, 2]
            sweep.duration = 1
            sweep.repeatCount = .infinity
            gradient.add(sweep, forKey: "sweep")
        }
        layer?.addSublayer(gradient)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: 46, height: 5) }
}
