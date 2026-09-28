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

/// Counts prompts so the per-attempt guarantee is asserted rather than assumed.
actor CountingReauthenticator: Reauthenticating {
    struct Denied: Error {}

    private let succeeds: Bool
    private(set) var prompts = 0

    init(succeeds: Bool = true) { self.succeeds = succeeds }

    func authenticate(reason: String) async throws {
        prompts += 1
        if !succeeds { throw Denied() }
    }

    func count() -> Int { prompts }
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
            reservations: FakeReservationService(.fail(.transport(message: "timed out", failure: .timedOut))),
            spaces: FakeSpacesService(stubbed: grid([
                ParkingSpace(number: 7, isAvailable: false, plateLast3: "001"),
                ParkingSpace(number: 8, isAvailable: true, plateLast3: nil)
            ]))
        )

        let outcome = await coordinator.attempt(preferredSpace: 7, plate: "TEST-001")

        XCTAssertEqual(
            outcome, .unknown(.probablyHeld(space: 7)),
            "A timeout must never be reported as a win, and must point at the space that "
                + "appears to be ours: \(outcome)"
        )
    }

    /// Suffix collision: two plates end in the same three characters, so the app must
    /// refuse to claim either space.
    func testTimeoutWithSuffixCollisionRefusesToClaimASpace() async {
        let coordinator = makeCoordinator(
            reservations: FakeReservationService(.fail(.transport(message: "timed out", failure: .timedOut))),
            spaces: FakeSpacesService(stubbed: grid([
                ParkingSpace(number: 7, isAvailable: false, plateLast3: "001"),
                ParkingSpace(number: 8, isAvailable: false, plateLast3: "001")
            ]))
        )

        let outcome = await coordinator.attempt(preferredSpace: 7, plate: "TEST-001")

        XCTAssertEqual(
            outcome, .unknown(.ambiguous(suffix: "001")),
            "Two plates share the suffix, so neither space may be claimed: \(outcome)"
        )
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

    // MARK: - Re-authentication (6.5 Default, kept as written)

    /// Every attempt that can move money prompts — including the retries after losing, which
    /// are the common case at 20:00. An earlier build exempted anything within 120 seconds of
    /// a successful check; this test is what stops that returning, whether as an explicit
    /// grace period or as a reused `LAContext`.
    func testEveryAttemptReAuthenticates() async {
        let reauth = CountingReauthenticator()
        let error = APIError.business(ErrorResponse(
            status: 409, error: "Conflict", message: "Space #9 is not available",
            code: .spaceUnavailable, timestamp: .distantPast, path: "/reservations",
            validationErrors: nil
        ))
        let coordinator = ReservationCoordinator(
            reservations: FakeReservationService(.fail(error)),
            spaces: FakeSpacesService(stubbed: grid([])), reauth: reauth
        )

        for space in [9, 10, 11] {
            _ = await coordinator.attempt(preferredSpace: space, plate: "TEST-001")
        }

        let prompts = await reauth.count()
        XCTAssertEqual(prompts, 3, "Three attempts must mean three authorisations, not one")
    }

    /// A refused prompt must stop before the request is sent: no charge, and no ambiguity
    /// about whether one happened.
    func testRefusedReAuthenticationNeverReachesTheNetwork() async {
        let service = FakeReservationService(.succeed(winner))
        let coordinator = ReservationCoordinator(
            reservations: service, spaces: FakeSpacesService(stubbed: grid([])),
            reauth: CountingReauthenticator(succeeds: false)
        )

        let outcome = await coordinator.attempt(preferredSpace: 7, plate: "TEST-001")

        let calls = await service.calls()
        XCTAssertEqual(calls, 0, "A denied authorisation must not spend money")
        // Its own outcome, not a transport error: it used to surface as "Can't reach the server".
        XCTAssertEqual(outcome, .notConfirmed)
    }

    // MARK: - Dropped connections (the backend killed mid-reservation)

    /// A kill closes the socket and surfaces as `networkConnectionLost`, not a timeout. The
    /// commit may already have happened, so it must reconcile exactly as a timeout does.
    func testDroppedConnectionReconcilesRatherThanReportingFailure() async {
        let coordinator = makeCoordinator(
            reservations: FakeReservationService(.fail(.transport(message: "lost", failure: .interrupted))),
            spaces: FakeSpacesService(stubbed: grid([
                ParkingSpace(number: 7, isAvailable: false, plateLast3: "001")
            ]))
        )

        let outcome = await coordinator.attempt(preferredSpace: 7, plate: "TEST-001")

        XCTAssertEqual(
            outcome, .unknown(.probablyHeld(space: 7)),
            "A dropped connection must never be reported as a failure, and must point at the "
                + "space that appears to be ours: \(outcome)"
        )
    }

    /// The demo case as it really happens: the backend is still dead, so the reconciling
    /// `GET /spaces` fails too. The only true thing left to say is "we don't know".
    func testDroppedConnectionWithBackendStillDownIsUnknownNotRejected() async {
        let coordinator = makeCoordinator(
            reservations: FakeReservationService(.fail(.transport(message: "lost", failure: .interrupted))),
            spaces: FailingSpacesService()
        )

        let outcome = await coordinator.attempt(preferredSpace: 7, plate: "TEST-001")

        XCTAssertEqual(
            outcome, .unknown(.noEvidence(cause: .connectionDropped)),
            "With the grid unreadable too there is no evidence either way: \(outcome)"
        )
    }

    /// A request that provably never left the device cannot have booked anything, so it is a
    /// plain failure — reconciling it would turn a certain answer into a vague one.
    func testUnsentRequestIsRejectedWithoutReconciliation() async {
        let coordinator = makeCoordinator(
            reservations: FakeReservationService(.fail(.transport(message: "refused", failure: .notSent))),
            spaces: FakeSpacesService(stubbed: grid([
                ParkingSpace(number: 7, isAvailable: false, plateLast3: "001")
            ]))
        )

        let outcome = await coordinator.attempt(preferredSpace: 7, plate: "TEST-001")

        XCTAssertEqual(outcome, .rejected(.transport(message: "refused", failure: .notSent)))
    }
}

struct FailingSpacesService: SpacesServicing {
    func grid() async throws -> SpaceGrid {
        throw APIError.transport(message: "refused", failure: .notSent)
    }
}
