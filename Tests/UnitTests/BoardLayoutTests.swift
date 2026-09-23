import XCTest
@testable import Parking

/// Proof for the 6.3 **guardrail**: "All 80 spaces legible on a 6.1-inch screen without
/// relying on pinch-zoom."
///
/// Asserted here rather than eyeballed on a simulator, because the smallest device available
/// locally is 6.3 inches — a layout that fits there can still breach the guardrail on the
/// screen the brief actually names.
final class BoardLayoutTests: XCTestCase {

    /// Chrome measured from the built portrait layout on a 6.1-inch screen: safe areas,
    /// the single header row, the combined countdown + stats card, the legend and padding.
    /// Deliberately generous — if the real layout is tighter the guardrail still holds.
    private let chromeHeight: CGFloat = 290

    private var boardAreaOn61Inch: CGSize {
        let screen = BoardLayout.Metrics.referenceScreen
        return CGSize(
            width: screen.width - 2 * Theme.Metric.gutter - 24,
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

    /// The 44pt figure sits in the **Default** column, so it would yield to the guardrail if
    /// the two genuinely conflicted. After trimming the chrome they do not: the board fits
    /// on a 6.1-inch screen *and* clears 44pt on both axes. This test is what stops a future
    /// change quietly reintroducing the trade-off.
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

    func testBoardGrowsIntoTheSpaceAvailableOnALargerScreen() throws {
        let phone = try XCTUnwrap(BoardLayout.fitting(count: 80, in: boardAreaOn61Inch))
        let pad = try XCTUnwrap(
            BoardLayout.fitting(count: 80, in: CGSize(width: 700, height: 900))
        )

        XCTAssertGreaterThan(pad.cellWidth, phone.cellWidth, "Cells should grow on iPad")
        XCTAssertTrue(pad.meetsPreferredTouchTarget,
                      "With room to spare there is no excuse for missing 44pt")
    }

    func testLandscapeStripStillFitsEveryCell() throws {
        // iPhone 16 landscape, board occupying the leading two-thirds.
        let landscape = CGSize(width: 480, height: 330)
        let layout = try XCTUnwrap(
            BoardLayout.fitting(count: 80, in: landscape),
            "The board must still fit in landscape"
        )

        XCTAssertLessThanOrEqual(layout.totalHeight, landscape.height)
        XCTAssertGreaterThan(layout.columns, 8, "Landscape should spread wider than portrait")
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
