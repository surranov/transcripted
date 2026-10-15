import CoreGraphics

// Where the Anchored paste marker's flag goes for the field's box
// (AnchorMarkerPlacement). Accessibility coordinates: top-left origin.

func testAnchorMarkerPlacement() {
    let flag = CGSize(width: 120, height: 22)
    let gap = AnchorMarkerPlacement.fieldGap

    runSuite("AnchorMarkerPlacement puts the flag 3 pt above the text box, left edges lined up") {
        // T3 Code's window and composer card, measured.
        let window = CGRect(x: 1172, y: 1633, width: 1512, height: 949)
        let card = CGRect(x: 1571, y: 2229, width: 1056, height: 329)
        let spot = AnchorMarkerPlacement.spot(box: card, window: window, flagSize: flag)
        assertEqual(spot, .init(x: 1571, top: 2229 - 3 - 22, pinnedRight: false), "bottom edge 3 pt above the card")

        let grown = CGRect(x: 1571, y: 2129, width: 1056, height: 429)
        let grownSpot = AnchorMarkerPlacement.spot(box: grown, window: window, flagSize: flag)
        assertEqual(grownSpot.top, spot.top - 100, "a composer growing upward takes the flag up with it")
    }

    runSuite("AnchorMarkerPlacement keeps the flag inside the window") {
        let window = CGRect(x: 0, y: 0, width: 800, height: 600)
        let leftOfWindow = CGRect(x: -50, y: 400, width: 300, height: 60)
        assertEqual(AnchorMarkerPlacement.spot(box: leftOfWindow, window: window, flagSize: flag).x, AnchorMarkerPlacement.edgeMargin, "a box reaching past the left edge")
        let atRightEdge = CGRect(x: 760, y: 400, width: 40, height: 30)
        assertEqual(AnchorMarkerPlacement.spot(box: atRightEdge, window: window, flagSize: flag).x, 800 - AnchorMarkerPlacement.edgeMargin - 120, "a narrow box at the right edge")
    }

    runSuite("AnchorMarkerPlacement never covers the title bar") {
        let window = CGRect(x: 0, y: 0, width: 800, height: 600)
        let underTitleBar = CGRect(x: 10, y: 30, width: 200, height: 24)
        assertEqual(
            AnchorMarkerPlacement.spot(box: underTitleBar, window: window, flagSize: flag),
            .init(x: 10, top: 54 + gap, pinnedRight: false),
            "a search field right under the title bar: below it"
        )
        let filling = CGRect(x: 0, y: 28, width: 800, height: 572)
        assertEqual(
            AnchorMarkerPlacement.spot(box: filling, window: window, flagSize: flag),
            .init(x: 800 - AnchorMarkerPlacement.edgeMargin - gap, top: 28 + gap, pinnedRight: true),
            "a terminal filling the window: inside its top-right corner"
        )
        let scrolledDocument = CGRect(x: 0, y: -2000, width: 800, height: 5000)
        assertEqual(
            AnchorMarkerPlacement.spot(box: scrolledDocument, window: window, flagSize: flag).top,
            AnchorMarkerPlacement.titleBarHeight + gap,
            "a box starting above the window: under the title bar"
        )
    }

    runSuite("Several takes' flags over one box sit side by side, left to right") {
        let start = AnchorMarkerPlacement.Spot(x: 100, top: 50, pinnedRight: false)
        let row = AnchorMarkerPlacement.row(from: start, widths: [120, 49, 49])
        let gap = AnchorMarkerPlacement.flagGap
        assertEqual(row.map(\.x), [100, 100 + 120 + gap, 100 + 120 + gap + 49 + gap], "the newest take's full flag first, then the background ones")
        assertTrue(row.allSatisfy { $0.top == 50 && !$0.pinnedRight }, "one line, from their left edges")
        let pinned = AnchorMarkerPlacement.row(from: .init(x: 700, top: 40, pinnedRight: true), widths: [120, 49])
        assertEqual(pinned.map(\.x), [700, 700 - 120 - gap], "inside a filling box's top-right corner the row grows leftward")
        assertEqual(AnchorMarkerPlacement.row(from: start, widths: [120]), [start], "one take: one flag, where it always was")
    }

    runSuite("Over one box the newest take's flag is full and the older takes' are compact") {
        // Takes in the order they started: "first" now finishes in the background.
        let two = AnchorMarkerPlacement.boxOrder(["first", "second"])
        assertEqual(two.map(\.flag), ["second", "first"], "the newest first, then the older one")
        assertEqual(two.map(\.compact), [false, true], "only the newest is full")
        let three = AnchorMarkerPlacement.boxOrder(["first", "second", "third"])
        assertEqual(three.map(\.flag), ["third", "first", "second"], "older ones in the order they started")
        assertEqual(three.map(\.compact), [false, true, true], "every older one compact")
        let one = AnchorMarkerPlacement.boxOrder(["only"])
        assertEqual(one.map(\.compact), [false], "a lone take's flag is full")
        assertTrue(AnchorMarkerPlacement.boxOrder([String]()).isEmpty, "no takes, no flags")
    }

    runSuite("On another thread, a flag sits in the bottom-right corner of its thread's sidebar row") {
        // T3 Code's sidebar, measured: a row 391 x 86 in the scrolled area.
        let visible = CGRect(x: 1254, y: 1743, width: 409, height: 796)
        let row = CGRect(x: 1263, y: 2279, width: 391, height: 85)
        let inset = AnchorMarkerPlacement.rowCornerInset
        let edge = row.maxX - inset - AnchorMarkerPlacement.rowBadgeWidth
        let spots = AnchorMarkerPlacement.rowCorner(row: row, visible: visible, widths: [49], flagHeight: 22)
        assertEqual(spots, [.init(x: edge - 49, top: row.maxY - inset - 22, pinnedRight: false)], "its right end left of the agent badge")
        // The badge, measured: x 1628...1648, y 2351...2369.
        assertTrue(edge <= 1628, "clear of the badge")
        let two = AnchorMarkerPlacement.rowCorner(row: row, visible: visible, widths: [49, 27], flagHeight: 22)
        assertEqual(two?.map(\.x), [edge - 49, edge - 49 - AnchorMarkerPlacement.flagGap - 27], "two takes into one thread: right to left")
    }

    runSuite("A flag whose sidebar row can't be seen hides") {
        let visible = CGRect(x: 1254, y: 1743, width: 409, height: 796)
        let above = CGRect(x: 1263, y: 1642, width: 391, height: 86)
        assertNil(AnchorMarkerPlacement.rowCorner(row: above, visible: visible, widths: [49], flagHeight: 22), "scrolled up out of the list")
        let cut = CGRect(x: 1263, y: 2500, width: 391, height: 86)
        assertNil(AnchorMarkerPlacement.rowCorner(row: cut, visible: visible, widths: [49], flagHeight: 22), "its corner below the list's bottom edge")
        let slidOff = CGRect(x: 1263, y: 2000, width: 391, height: 86)
        assertNil(AnchorMarkerPlacement.rowCorner(row: slidOff, visible: .zero, widths: [49], flagHeight: 22), "a sidebar slid off the window")
        assertNil(AnchorMarkerPlacement.rowCorner(row: CGRect(x: 0, y: 2000, width: 40, height: 86), visible: visible, widths: [49], flagHeight: 22), "a row too narrow for it")
    }
}
