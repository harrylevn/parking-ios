import SwiftUI
import XCTest
@testable import Parking

/// What the screens look like, pinned. The accessibility audit catches contrast and clipping;
/// these catch any visual change at all, including the ones nobody meant: last week's
/// contrast fixes and the truncated outcome sheets would each have changed an image here.
@MainActor
final class ViewSnapshotTests: XCTestCase {

    private let receipt = Reservation(
        id: 1, spaceNumber: 12, date: Date(timeIntervalSince1970: 1_790_812_800), amountPaid: 10,
        newBalance: 90, queuePosition: 3, totalProcessingMs: 40
    )

    private func sheet(_ outcome: ReservationOutcome) -> some View {
        OutcomeSheet(outcome: outcome) {}
    }

    // MARK: - Outcome sheets

    func testOutcomeSheets() {
        let outcomes: [(String, ReservationOutcome)] = [
            ("won", .won(receipt)),
            ("lost-space", .lost(.spaceUnavailable)),
            ("lost-lot-full", .lost(.lotFull)),
            ("lost-balance", .lost(.insufficientBalance)),
            ("unknown-probably-held", .unknown(.probablyHeld(space: 12))),
            ("unknown-ambiguous", .unknown(.ambiguous(suffix: "001"))),
            ("unknown-no-evidence", .unknown(.noEvidence(cause: .timedOut)))
        ]
        for (name, outcome) in outcomes {
            assertSnapshot(sheet(outcome), named: "sheet-\(name)")
        }
    }

    /// Dark mode is where every primary button once failed contrast.
    func testOutcomeSheetsInDarkMode() {
        let outcomes: [(String, ReservationOutcome)] = [
            ("won", .won(receipt)), ("lost-space", .lost(.spaceUnavailable)),
            ("unknown-no-evidence", .unknown(.noEvidence(cause: .timedOut)))
        ]
        for (name, outcome) in outcomes {
            assertSnapshot(sheet(outcome).environment(\.colorScheme, .dark), named: "sheet-\(name)-dark")
        }
    }

    /// The largest text size, where every line of an outcome was once cut to one.
    func testOutcomeSheetsAtTheLargestTextSize() {
        let outcomes: [(String, ReservationOutcome)] = [
            ("won", .won(receipt)), ("unknown-ambiguous", .unknown(.ambiguous(suffix: "001")))
        ]
        for (name, outcome) in outcomes {
            assertSnapshot(
                sheet(outcome).environment(\.dynamicTypeSize, .accessibility5),
                named: "sheet-\(name)-largest-text", height: 1_400, inWindow: true
            )
        }
    }

    // MARK: - Board cells

    private var cells: some View {
        HStack(spacing: 7) {
            cell(1, available: true, plate: nil, .available)
            cell(4, available: false, plate: "042", .reserved)
            cell(12, available: false, plate: "001", .mine)
            cell(20, available: true, plate: nil, .selected)
        }
        .padding(12)
        .background(Theme.Palette.surface)
    }

    private func cell(
        _ number: Int, available: Bool, plate: String?, _ look: SpaceCell.Appearance
    ) -> SpaceCell {
        let space = ParkingSpace(number: number, isAvailable: available, plateLast3: plate)
        return SpaceCell(space: space, appearance: look) {}
    }

    func testTheFourCellAppearances() {
        assertSnapshot(cells, named: "cells", width: 240)
        assertSnapshot(cells.environment(\.colorScheme, .dark), named: "cells-dark", width: 240)
    }

    // MARK: - The confirm bar

    private func bar(space: Int?, balance: Decimal = 100, open: Bool = true, free: Int? = 60) -> some View {
        ConfirmBar(
            spaceNumber: space, balance: balance, isWindowOpen: open, availableSpaces: free,
            isReserving: false, style: .bar, onCancel: space.map { _ in {} }, onConfirm: {}
        )
        .background(Theme.Palette.canvas)
    }

    func testTheConfirmBarStates() {
        assertSnapshot(bar(space: nil), named: "bar-any-space")
        assertSnapshot(bar(space: 12), named: "bar-named-space")
        assertSnapshot(bar(space: 12, open: false), named: "bar-picked-before-opening")
        assertSnapshot(bar(space: nil, free: 0), named: "bar-lot-full")
        assertSnapshot(bar(space: nil, balance: 5), named: "bar-not-enough-balance")
        assertSnapshot(bar(space: nil).environment(\.colorScheme, .dark), named: "bar-any-space-dark")
    }
}
