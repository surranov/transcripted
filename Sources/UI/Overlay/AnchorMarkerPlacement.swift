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

    // MARK: - Several flags

    /// Between flags side by side.
    static let flagGap: CGFloat = 4
    /// Between a flag and the corner of a sidebar row it sits in.
    static let rowCornerInset: CGFloat = 6
    /// T3 Code draws the thread's agent badge in that corner (20 pt wide,
    /// 6 pt from the edges, measured 2026-10-15): the flags sit to its left,
    /// level with it.
    static let rowBadgeWidth: CGFloat = 26

    /// Flags sharing one box, left to right: the newest take's full flag
    /// first, then the older ones compact, in the order they started.
    /// `started`: oldest first.
    static func boxOrder<Flag>(_ started: [Flag]) -> [(flag: Flag, compact: Bool)] {
        guard let newest = started.last else { return [] }
        return [(newest, false)] + started.dropLast().map { ($0, true) }
    }

    /// Flags of `widths` side by side from `spot`: each one's pinned edge (its
    /// left edge, or its right edge when `pinnedRight`, the row then growing
    /// leftward), `flagGap` apart.
    static func row(from spot: Spot, widths: [CGFloat]) -> [Spot] {
        var edge = spot.x
        return widths.map { width in
            defer { edge += spot.pinnedRight ? -(width + flagGap) : width + flagGap }
            return Spot(x: edge, top: spot.top, pinnedRight: spot.pinnedRight)
        }
    }

    /// Flags of `widths` in the bottom-right corner of a sidebar row, beside
    /// its badge, right to left; each spot is a left edge (pinned left, as
    /// over a box, so a flag flying between the two doesn't jump inside its
    /// panel). Nil when that spot isn't in sight (`visible`: the
    /// sidebar's scrolled area within the window): a row scrolled away, or
    /// a sidebar slid off.
    static func rowCorner(row: CGRect, visible: CGRect, widths: [CGFloat], flagHeight: CGFloat) -> [Spot]? {
        let total = widths.reduce(0, +) + flagGap * CGFloat(max(widths.count - 1, 0))
        let flags = CGRect(
            x: row.maxX - rowCornerInset - rowBadgeWidth - total,
            y: row.maxY - rowCornerInset - flagHeight,
            width: total,
            height: flagHeight
        )
        guard !widths.isEmpty, row.width >= total + 2 * rowCornerInset + rowBadgeWidth, visible.contains(flags) else { return nil }
        var edge = flags.maxX
        return widths.map { width in
            edge -= width
            defer { edge -= flagGap }
            return Spot(x: edge, top: flags.minY, pinnedRight: false)
        }
    }
}
