import XCTest
@testable import Parking

// MARK: - Claiming a space
/// The board and the outcome sheet have to agree. `mySpace` is a three-character plate match,
/// so it is evidence; only a reservation that came back with an id, an amount and a balance
/// lets the UI say a space *is* yours. Found by looking at the running app: the sheet read
/// "Space 7 looks like yours … the server never sent a receipt" over a banner that said
/// "Space 7 is yours".
final class HoldingClaimTests: XCTestCase {

    @MainActor
    func testASuffixMatchAloneIsNotAConfirmedReservation() async {
        let model = GridViewModel(environment: makeEnvironment(
            spaces: StubSpaces(result: .success(grid(taken: [(7, "001")]))),
            reservations: StubReservations(result: .failure(.transport(message: "", failure: .timedOut)))
        ))

        await model.refresh()
        await model.reserve(space: 7)

        XCTAssertEqual(model.mySpace, 7, "The grid does show our suffix")
        XCTAssertFalse(
            model.hasConfirmedReservation,
            "A timed-out attempt never produced a receipt, so nothing may be claimed outright"
        )
    }

    @MainActor
    func testAWinIsAConfirmedReservation() async {
        let won = Reservation(
            id: 1, spaceNumber: 7, date: .distantFuture, amountPaid: 10,
            newBalance: 90, queuePosition: nil, totalProcessingMs: nil
        )
        let model = GridViewModel(environment: makeEnvironment(
            reservations: StubReservations(result: .success(won))
        ))

        await model.reserve(space: 7)

        XCTAssertTrue(model.hasConfirmedReservation)
    }

    @MainActor
    func testSigningOutDropsTheReceipt() async {
        let won = Reservation(
            id: 1, spaceNumber: 7, date: .distantFuture, amountPaid: 10,
            newBalance: 90, queuePosition: nil, totalProcessingMs: nil
        )
        let model = GridViewModel(environment: makeEnvironment(
            reservations: StubReservations(result: .success(won))
        ))
        await model.reserve(space: 7)

        model.signOut()

        XCTAssertFalse(
            model.hasConfirmedReservation,
            "The next plate to sign in must not inherit this one's confirmation"
        )
    }
}
