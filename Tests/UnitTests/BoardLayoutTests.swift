import XCTest
@testable import Parking

/// Proof for the 6.3 **guardrail**: "All 80 spaces legible on a 6.1-inch screen without
/// relying on pinch-zoom."
///
/// Asserted here rather than eyeballed on a simulator, because the smallest device available
/// locally is 6.3 inches — a layout that fits there can still breach the guardrail on the
/// screen the brief actually names.
final class BoardLayoutTests: XCTestCase {

    /// Everything on the portrait screen that is not the board: safe areas, the header row,
    /// the date line, the combined countdown + stats card, the legend, the confirm bar and
    /// the padding between them.
    ///
    /// **Read off the running app, not estimated.** `BoardGeometryUITests` launches on a
    /// 6.1-inch screen and reports the height the board is actually handed; 852 minus that
    /// is this number. The previous value, 368, was an estimate that ran 44pt light, so
    /// these tests handed `BoardLayout` a board area the screen does not have and certified
    /// a tenth row it could not show. Every assertion here passed while spaces 73 to 80 sat
    /// below the fold of a scroll view on the very screen the guardrail names.
    ///
    /// If the chrome changes, this number is wrong until it is measured again — which is
    /// what `BoardGeometryUITests` is for. It asserts the guardrail against the real
    /// hierarchy, so a drift here shows up as a failure there rather than as silence.
    private let chromeHeight: CGFloat = 412

    /// Derived from the same constants the layout uses, not restated. The width used to be
    /// `- 24` for the board card's inset; the card was then changed and the literal was not,
    /// so this measured a board 12pt narrower than the one on screen and kept passing.
    private var boardAreaOn61Inch: CGSize {
        let screen = BoardLayout.Metrics.referenceScreen
        return CGSize(
            width: screen.width - 2 * Theme.Metric.gutter - 2 * Theme.Metric.boardCardPadding,
            height: screen.height - chromeHeight
        )
    }

    func testAllEightySpacesFitOnA61InchScreen() throws {
        let layout = try XCTUnwrap(
            BoardLayout.fitting(count: 80, in: boardAreaOn61Inch),
            "No layout fits 80 cells on a 6.1-inch screen — this is a guardrail breach"
        )

        XCTAssertGreaterThanOrEqual(
            layout.columns * layout.rows, 80,
            "Every cell needs a slot: \(layout.columns)x\(layout.rows)"
        )
        XCTAssertLessThan(
            layout.columns * (layout.rows - 1), 80,
            "No wholly empty trailing row: \(layout.columns)x\(layout.rows)"
        )
        XCTAssertLessThanOrEqual(
            layout.totalHeight, boardAreaOn61Inch.height,
            "The board must fit without scrolling"
        )
    }

    func testCellsStayLegibleWhenTheBoardIsFitted() throws {
        let layout = try XCTUnwrap(BoardLayout.fitting(count: 80, in: boardAreaOn61Inch))

        // Below these a two-digit number and a three-character plate suffix stop being
        // readable, which would satisfy the letter of the guardrail and break its intent.
        XCTAssertGreaterThanOrEqual(layout.cellWidth, BoardLayout.Metrics.minCellWidth)
        XCTAssertGreaterThanOrEqual(layout.cellHeight, BoardLayout.Metrics.minCellHeight)
    }

    /// 44pt is **met**, with all 80 cells visible and no scrolling — both columns of 6.3
    /// satisfied at once, on the screen the brief names.
    ///
    /// It was briefly missed. Making the confirm bar permanent took 78pt off the board, which
    /// dropped it to 43pt, and that was recorded as a defended deviation. The deviation was
    /// wrong: the shortfall was horizontal, and no amount of vertical space fixes a
    /// horizontal miss. A cell's effective target is `(boardWidth + spacing) / columns`, so
    /// across eight columns the eight points of padding inside the board card were worth a
    /// full point of target — the whole deficit. Trimming the card to
    /// `Theme.Metric.boardCardPadding` recovered it without touching the bar, the chrome, or
    /// any other card on the screen.
    ///
    /// Kept strict deliberately: this is the test that refuses the trade-off, and the
    /// arithmetic above is why the trade-off was never necessary.
    func testFittedBoardStillClearsFortyFourPointTargets() throws {
        let layout = try XCTUnwrap(BoardLayout.fitting(count: 80, in: boardAreaOn61Inch))

        XCTAssertTrue(
            layout.meetsPreferredTouchTarget,
            """
            Board fits but the touch target regressed to \(layout.cellWidth + layout.spacing) \
            x \(layout.cellHeight + layout.spacing)pt
            """
        )
    }

    /// Every phone larger than the reference clears 44pt with room to spare.
    ///
    /// Worth asserting rather than assuming. `BoardLayout` picks a column count per size, so
    /// a bigger screen is not automatically a better target — it can spend the extra width on
    /// more columns instead of larger cells. It does not, and this is what says so.
    func testLargerPhonesClearFortyFourPointsWithRoom() throws {
        // iPhone 17 Pro (402×874) and 17 Pro Max (440×956), same chrome as the reference.
        for screen in [CGSize(width: 402, height: 874), CGSize(width: 440, height: 956)] {
            let area = CGSize(
                width: screen.width - 2 * Theme.Metric.gutter - 2 * Theme.Metric.boardCardPadding,
                height: screen.height - chromeHeight
            )
            let layout = try XCTUnwrap(BoardLayout.fitting(count: 80, in: area))

            XCTAssertTrue(
                layout.meetsPreferredTouchTarget,
                """
                \(screen.width)x\(screen.height) gives \(layout.columns)x\(layout.rows) at \
                \(layout.cellWidth + layout.spacing)x\(layout.cellHeight + layout.spacing)pt
                """
            )
            XCTAssertGreaterThanOrEqual(
                layout.cellWidth + layout.spacing, 44,
                "A larger phone must not spend its extra width on more columns"
            )
        }
    }

    func testBoardGrowsIntoTheSpaceAvailableOnALargerScreen() throws {
        let phone = try XCTUnwrap(BoardLayout.fitting(count: 80, in: boardAreaOn61Inch))
        let pad = try XCTUnwrap(
            BoardLayout.fitting(count: 80, in: CGSize(width: 700, height: 900))
        )

        XCTAssertGreaterThan(pad.cellWidth, phone.cellWidth, "Cells should grow on iPad")
        XCTAssertTrue(pad.meetsPreferredTouchTarget,
                      "With room to spare there is no excuse for missing 44pt")
    }

    /// iPhone landscape, measured off a capture of the running app rather than estimated:
    /// the tiles span 392pt across and 273pt down beside the 300pt sidebar. The assertions
    /// below are properties — clears 44pt, wider than the fallback, taller than its space —
    /// not exact column counts, so a point either way in the measurement does not matter.
    ///
    /// Two earlier versions of this number were guesses and both were wrong. The first
    /// assumed a 480×330 area the app never gives, so this suite "passed" while the real
    /// screen fell through to the accessibility fallback. The second estimated 390×239 by
    /// subtracting chrome by eye, which was 34pt low — enough to make `fitting` look like it
    /// returns nil here when it does not. Measured, not reckoned.
    private var landscapeBoardArea: CGSize { CGSize(width: 392, height: 273) }

    /// All 80 cells *do* fit an iPhone landscape board — but only by driving the cells down
    /// to the 30pt floor, which is a 34pt target.
    func testLandscapeFitsEveryCellOnlyBelowTheTouchTarget() throws {
        let layout = try XCTUnwrap(BoardLayout.fitting(count: 80, in: landscapeBoardArea))

        XCTAssertEqual(layout.columns, 10)
        XCTAssertEqual(layout.rows, 8)
        XCTAssertFalse(
            layout.meetsPreferredTouchTarget,
            """
            Landscape now meets 44pt at \(layout.cellWidth + layout.spacing) x \
            \(layout.cellHeight + layout.spacing)pt — BoardView can stop scrolling there.
            """
        )
    }

    /// So `BoardView` scrolls instead, and the scrolling layout keeps the target. Scrolling in
    /// landscape was accepted explicitly; a 34pt touch target was not.
    func testLandscapeScrollsRatherThanShrinkingTheTarget() throws {
        let layout = try XCTUnwrap(
            BoardLayout.scrolling(count: 80, width: landscapeBoardArea.width),
            "Landscape must still produce a board"
        )

        XCTAssertGreaterThanOrEqual(layout.cellWidth + layout.spacing, 44)
        XCTAssertGreaterThanOrEqual(layout.cellHeight + layout.spacing, 44)
        XCTAssertGreaterThan(
            layout.columns, 5,
            "Wider than the accessibility fallback, which spends the width on five huge cells"
        )
        XCTAssertGreaterThan(
            layout.totalHeight, landscapeBoardArea.height,
            "This layout is meant to scroll — if it fits, it should have come from `fitting`"
        )
    }

    /// Portrait is not subject to that rule at all. `BoardView` routes on orientation now,
    /// not on whether the target is met: in portrait a fitted layout is taken whatever it
    /// costs the target, because fitting all 80 is the guardrail and 44pt is the Default.
    ///
    /// The earlier ordering asked whether the fitted layout met 44pt and scrolled when it did
    /// not, which is the guardrail yielding to the thing that is supposed to yield to it —
    /// and that is precisely what happened once the chrome figure was corrected.
    ///
    /// So this asserts both halves separately: the board fits, *and* it still clears 44pt.
    /// A future change that costs the target will fail the second assertion while the board
    /// keeps showing all 80, which is the right way round.
    func testTheSixOneInchPortraitBoardFitsAndStillClearsTheTarget() throws {
        let layout = try XCTUnwrap(BoardLayout.fitting(count: 80, in: boardAreaOn61Inch))

        XCTAssertLessThanOrEqual(
            layout.totalHeight, boardAreaOn61Inch.height,
            "The guardrail: all 80 on screen at once, no scrolling"
        )
        XCTAssertTrue(
            layout.meetsPreferredTouchTarget,
            "The Default: \(layout.cellWidth)x\(layout.cellHeight) + \(layout.spacing) misses 44pt"
        )
    }

    func testReturnsNilRatherThanClippingWhenThereIsGenuinelyNoRoom() {
        let impossible = CGSize(width: 200, height: 80)
        XCTAssertNil(
            BoardLayout.fitting(count: 80, in: impossible),
            "Must report failure so the caller can scroll instead of silently clipping"
        )
    }
}

extension BoardLayoutTests {

    /// A 13-inch iPad gives the board roughly 900x1300pt. The cells used to stop growing at a
    /// flat 64pt ceiling, which left about a third of the card empty below the last row — all
    /// 80 spaces visible, comfortably above 44pt, and unmistakably unfinished.
    func testTheBoardUsesTheHeightItIsGivenOnALargeIPad() throws {
        let area = CGSize(width: 900, height: 1300)
        let layout = try XCTUnwrap(BoardLayout.fitting(count: 80, in: area))

        XCTAssertGreaterThan(
            layout.totalHeight, area.height * 0.8,
            """
            Board is \(layout.totalHeight)pt tall in \(area.height)pt of space: \
            \(layout.columns)x\(layout.rows)
            """
        )
        XCTAssertLessThanOrEqual(layout.totalHeight, area.height, "and still fits")
    }

    /// Growing is not the same as stretching. A cell that is much taller than it is wide reads
    /// as a slab rather than a parking space, so the ceiling is relative to the cell's width.
    func testCellsStayRoughlySquareAtEverySize() throws {
        for area in [boardAreaOn61Inch,
                     CGSize(width: 480, height: 330),
                     CGSize(width: 700, height: 900),
                     CGSize(width: 900, height: 1300)] {
            let layout = try XCTUnwrap(BoardLayout.fitting(count: 80, in: area))
            XCTAssertLessThanOrEqual(
                layout.cellHeight, layout.cellWidth * 1.3,
                "Cell is \(layout.cellWidth)x\(layout.cellHeight) in \(area)"
            )
        }
    }
}

// MARK: - ParkingSpace

/// The backend computes `available` against tomorrow but returns `plate_last3` from the row
/// on whatever date it was last held, so a space freed by a past booking arrives available
/// *and* carrying a stranger's plate. On the demo backend that was 15 of 80 spaces, space 4
/// among them — the board showed them as selectable while printing someone else's plate, which
/// reads as taken. Raised at the week-1 checkpoint as "shows spaces already booked today".
final class ParkingSpaceTests: XCTestCase {

    func testAnAvailableSpaceCannotCarryAPlate() {
        let space = ParkingSpace(number: 4, isAvailable: true, plateLast3: "004")

        XCTAssertNil(space.plateLast3, "A free space has no holder to name")
    }

    func testAReservedSpaceKeepsItsPlate() {
        let space = ParkingSpace(number: 4, isAvailable: false, plateLast3: "004")

        XCTAssertEqual(space.plateLast3, "004", "The hint is still needed where it is true")
    }

    /// Reconciliation after a timeout matches on `plateLast3`, and the plate that matters is
    /// three characters across 80 cells. A stale plate left on a free space is a candidate for
    /// a false match on the one path that decides whether the user was charged.
    func testAStalePlateCannotBeMistakenForOurOwn() {
        let grid = [
            ParkingSpace(number: 4, isAvailable: true, plateLast3: "731"),
            ParkingSpace(number: 9, isAvailable: false, plateLast3: "731")
        ]

        let held = grid.filter { $0.plateLast3 == "731" }

        XCTAssertEqual(held.map(\.number), [9], "Only the space actually held may match")
    }
}
