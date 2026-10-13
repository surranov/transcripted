import CoreGraphics

/// Fork: where the Anchored paste marker's flag goes for the field's box
/// (`AnchoredPastePolicy.fieldBoxDepth`) in its window. Accessibility
/// coordinates: top-left origin on the primary display.
enum AnchorMarkerPlacement {
    /// Between the flag and the field's box.
    static let fieldGap: CGFloat = 3
    /// A standard title bar: a flag over it would cover the window buttons.
    static let titleBarHeight: CGFloat = 28
    /// How close to the window's sides and bottom the flag may come.
    static let edgeMargin: CGFloat = 2

    struct Spot: Equatable {
        /// The flag's left edge, or its right edge when `pinnedRight`: the
        /// flag widens and narrows with the take's phase from that edge.
        var x: CGFloat
        var top: CGFloat
        var pinnedRight: Bool
    }

    /// `fieldGap` above the box, left edges lined up. A box right under the
    /// title bar takes the flag `fieldGap` below it instead, and a box that
    /// fills the window (a terminal, an editor) inside its top-right corner,
    /// where lines are usually empty.
    static func spot(box: CGRect, window: CGRect, flagSize: CGSize) -> Spot {
        let left = min(max(box.minX, window.minX + edgeMargin), window.maxX - edgeMargin - flagSize.width)
        let above = box.minY - fieldGap - flagSize.height
        if above >= window.minY + titleBarHeight {
            return Spot(x: left, top: above, pinnedRight: false)
        }
        let below = box.maxY + fieldGap
        if below + flagSize.height <= window.maxY - edgeMargin {
            return Spot(x: left, top: below, pinnedRight: false)
        }
        return Spot(
            x: min(box.maxX, window.maxX - edgeMargin) - fieldGap,
            top: max(box.minY, window.minY + titleBarHeight) + fieldGap,
            pinnedRight: true
        )
    }
}
