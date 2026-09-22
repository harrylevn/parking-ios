import XCTest
@testable import Parking

// MARK: - Fakes (6.4 Default: tests run against fakes, never the live backend)

actor FakeReservationService: ReservationServicing {
    enum Behaviour: Sendable {
        case succeed(Reservation)
        case fail(APIError)
    }

    private var behaviour: Behaviour
    private(set) var callCount = 0
    private let delay: Duration

    init(_ behaviour: Behaviour, delay: Duration = .zero) {
        self.behaviour = behaviour
        self.delay = delay
    }

    func reserve(preferredSpace: Int?) async throws -> Reservation {
        callCount += 1
        if delay != .zero { try? await Task.sleep(for: delay) }
        switch behaviour {
        case .succeed(let reservation): return reservation
        case .fail(let error): throw error
        }
    }

    func calls() -> Int { callCount }
}

struct FakeSpacesService: SpacesServicing {
    let stubbed: SpaceGrid
    func grid() async throws -> SpaceGrid { stubbed }
}

// MARK: - Tests

final class ReservationCoordinatorTests: XCTestCase {

    private let winner = Reservation(
        id: 1, spaceNumber: 7, date: .distantFuture, amountPaid: 10, newBalance: 40,
        queuePosition: 1, totalProcessingMs: 67
    )

    private func grid(_ spaces: [ParkingSpace]) -> SpaceGrid {
        SpaceGrid(date: .distantFuture, totalSpaces: spaces.count,
                  availableSpaces: spaces.filter(\.isAvailable).count,
                  reservedSpaces: spaces.filter { !$0.isAvailable }.count, spaces: spaces)
    }

    private func makeCoordinator(
        reservations: ReservationServicing, spaces: SpacesServicing
    ) -> ReservationCoordinator {
        ReservationCoordinator(
            reservations: reservations, spaces: spaces, reauth: AlwaysAllowReauthenticator()
        )
    }

    func testWinningRaceReturnsReservation() async {
        let coordinator = makeCoordinator(
            reservations: FakeReservationService(.succeed(winner)),
            spaces: FakeSpacesService(stubbed: grid([]))
        )

        let outcome = await coordinator.attempt(preferredSpace: 7, plate: "TEST-001")

        XCTAssertEqual(outcome, .won(winner))
    }

    func testLosingRaceIsReportedAsLostNotAsAnError() async {
        let error = APIError.business(ErrorResponse(
            status: 409, error: "Conflict", message: "Space #9 is not available",
            code: .spaceUnavailable, timestamp: .distantPast, path: "/reservations",
            validationErrors: nil
        ))
        let coordinator = makeCoordinator(
            reservations: FakeReservationService(.fail(error)), spaces: FakeSpacesService(stubbed: grid([]))
        )

        let outcome = await coordinator.attempt(preferredSpace: 9, plate: "TEST-001")

        XCTAssertEqual(outcome, .lost(.spaceUnavailable))
    }

    /// The guardrail: one tap produces exactly one reservation attempt.
    func testConcurrentTapsProduceExactlyOneAttempt() async {
        let service = FakeReservationService(.succeed(winner), delay: .milliseconds(100))
        let coordinator = makeCoordinator(
            reservations: service, spaces: FakeSpacesService(stubbed: grid([]))
        )

        async let first = coordinator.attempt(preferredSpace: 7, plate: "TEST-001")
        async let second = coordinator.attempt(preferredSpace: 7, plate: "TEST-001")
        let outcomes = await [first, second]

        let attempts = await service.calls()
        XCTAssertEqual(attempts, 1, "A second tap must not issue a second attempt")
        XCTAssertEqual(outcomes.filter { $0 == .won(self.winner) }.count, 1)
    }

    /// A timeout is not retried: the outcome is unknown and must be reconciled.
    func testTimeoutReconcilesFromGridWhenSuffixIsUnique() async {
        let coordinator = makeCoordinator(
            reservations: FakeReservationService(.fail(.transport(message: "timed out", isTimeout: true))),
            spaces: FakeSpacesService(stubbed: grid([
                ParkingSpace(number: 7, isAvailable: false, plateLast3: "001"),
                ParkingSpace(number: 8, isAvailable: true, plateLast3: nil)
            ]))
        )

        let outcome = await coordinator.attempt(preferredSpace: 7, plate: "TEST-001")

        guard case .unknown(let reason) = outcome else {
            return XCTFail("A timeout must never be reported as a win, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("7"), "Should point at the space that appears to be ours")
    }

    /// Suffix collision: two plates end in the same three characters, so the app must
    /// refuse to claim either space.
    func testTimeoutWithSuffixCollisionRefusesToClaimASpace() async {
        let coordinator = makeCoordinator(
            reservations: FakeReservationService(.fail(.transport(message: "timed out", isTimeout: true))),
            spaces: FakeSpacesService(stubbed: grid([
                ParkingSpace(number: 7, isAvailable: false, plateLast3: "001"),
                ParkingSpace(number: 8, isAvailable: false, plateLast3: "001")
            ]))
        )

        let outcome = await coordinator.attempt(preferredSpace: 7, plate: "TEST-001")

        guard case .unknown(let reason) = outcome else {
            return XCTFail("Expected unknown, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("cannot confirm"), "Must admit it cannot tell: \(reason)")
    }

    /// DUPLICATE_REQUEST is ambiguous by construction and must reconcile, not be shown raw.
    func testDuplicateRequestReconcilesRatherThanReportingFailure() async {
        let error = APIError.business(ErrorResponse(
            status: 409, error: "Conflict", message: "Duplicate reservation request",
            code: .duplicateRequest, timestamp: .distantPast, path: "/reservations",
            validationErrors: nil
        ))
        let coordinator = makeCoordinator(
            reservations: FakeReservationService(.fail(error)),
            spaces: FakeSpacesService(stubbed: grid([
                ParkingSpace(number: 12, isAvailable: false, plateLast3: "001")
            ]))
        )

        let outcome = await coordinator.attempt(preferredSpace: 12, plate: "TEST-001")

        guard case .unknown = outcome else {
            return XCTFail("DUPLICATE_REQUEST is ambiguous and must not be stated as fact")
        }
    }

    /// ALREADY_RESERVED comes from the database's unique constraint, so unlike
    /// DUPLICATE_REQUEST it is trustworthy and needs no reconciliation.
    func testAlreadyReservedIsTrustedWithoutReconciliation() async {
        let error = APIError.business(ErrorResponse(
            status: 409, error: "Conflict", message: "Vehicle already has a reservation",
            code: .alreadyReserved, timestamp: .distantPast, path: "/reservations",
            validationErrors: nil
        ))
        let coordinator = makeCoordinator(
            reservations: FakeReservationService(.fail(error)), spaces: FakeSpacesService(stubbed: grid([]))
        )

        let outcome = await coordinator.attempt(preferredSpace: 12, plate: "TEST-001")

        XCTAssertEqual(outcome, .lost(.alreadyReserved))
    }
}
