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
}
