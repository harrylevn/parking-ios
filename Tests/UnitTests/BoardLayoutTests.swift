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
    ///
    /// Includes the 78pt the confirm bar takes. It used to appear only once a space was
    /// selected, so the resting board was 78pt taller than this and these tests measured a
    /// board the user only ever saw before tapping. Offering "any free space" made the bar
    /// permanent, which is a real 78pt off the board on every screen — the figure belongs
    /// here rather than in a state the tests never exercised.
    private let chromeHeight: CGFloat = 368

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

    /// The 44pt figure sits in the **Default** column and it now yields, on this screen only,
    /// to the guardrail above it.
    ///
    /// Clearing 44pt horizontally needs 7 columns, which needs 12 rows, which needs 40pt more
    /// height than the board has once the confirm bar is permanent — and the bar is permanent
    /// so that the action is always offered and the board never reflows under the finger
    /// tapping it. The alternative was a board that stood at 44pt until the moment of the tap
    /// and then rearranged itself; the old layout did exactly that, so 42pt was already what
    /// the user actually confirmed on. See `docs/design.md` §6.3.
    ///
    /// This test pins the figure rather than the ideal: 44pt is not met, and a *further*
    /// regression still fails. Large screens are held to the full 44pt by
    /// `testBoardGrowsIntoTheSpaceAvailableOnALargerScreen`.
    func testSixOneInchBoardHoldsTheLineAtFortyTwoPoints() throws {
        let layout = try XCTUnwrap(BoardLayout.fitting(count: 80, in: boardAreaOn61Inch))

        let horizontal = layout.cellWidth + layout.spacing
        let vertical = layout.cellHeight + layout.spacing
        let achieved = "\(horizontal) x \(vertical)pt"

        XCTAssertGreaterThanOrEqual(horizontal, 42, "Touch target regressed to \(achieved)")
        XCTAssertGreaterThanOrEqual(vertical, 44, "Touch target regressed to \(achieved)")
        XCTAssertFalse(
            layout.meetsPreferredTouchTarget,
            """
            44pt is met again at \(achieved) — the chrome must have shrunk. Delete this \
            assertion, restore the strict check, and drop the deviation from docs/design.md.
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
