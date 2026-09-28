import XCTest
@testable import Parking

/// Repeating a tap's Idempotency-Key, and reading back what committed (ADR-007).
///
/// Each test names the behaviour that would be lost without it. The fakes answer the way the
/// backend on `feature/reservation-idempotency` does: a repeat of a key gets the first
/// request's outcome, or `IDEMPOTENCY_IN_PROGRESS` while it runs.
final class ReservationRetryTests: XCTestCase {

    private let winner = Reservation(
        id: 1, spaceNumber: 7, date: .distantFuture, amountPaid: 10, newBalance: 40,
        queuePosition: 1, totalProcessingMs: 67
    )

    /// What `GET /reservations/me` returns: no balance, no queue telemetry.
    private let readBack = Reservation(
        id: 1, spaceNumber: 7, date: .distantFuture, amountPaid: 10, newBalance: nil,
        queuePosition: nil, totalProcessingMs: nil
    )

    private let timedOut = APIError.transport(message: "timed out", failure: .timedOut)

    private func business(_ code: BusinessErrorCode, status: Int = 409) -> APIError {
        .business(ErrorResponse(
            status: status, error: "", message: "", code: code,
            timestamp: .distantPast, path: "/reservations", validationErrors: nil
        ))
    }

    /// A board that shows our suffix on space 7. If a test that must not consult the board
    /// ends up `probablyHeld(7)`, it consulted the board.
    private let boardShowingUs = FakeSpacesService(stubbed: SpaceGrid(
        date: .distantFuture, totalSpaces: 1, availableSpaces: 0, reservedSpaces: 1,
        spaces: [ParkingSpace(number: 7, isAvailable: false, plateLast3: "001")]
    ))

    private func coordinator(
        _ service: FakeReservationService,
        policy: ReservationCoordinator.RetryPolicy = .init(maxAttempts: 4, delay: .zero),
        sleep: @escaping @Sendable (Duration) async -> Void = { _ in }
    ) -> ReservationCoordinator {
        ReservationCoordinator(
            reservations: service, spaces: boardShowingUs, reauth: AlwaysAllowReauthenticator(),
            policy: policy, sleep: sleep
        )
    }

    // MARK: - The key

    /// Today's rule was "never retry a timeout". With a key the repeat is the same attempt,
    /// so it is safe, and it is how the reply that went missing is recovered.
    func testTimeoutIsRepeatedWithTheSameKeyUntilTheReplyArrives() async {
        let service = FakeReservationService(script: [.fail(timedOut), .fail(timedOut), .succeed(winner)])

        let outcome = await coordinator(service).attempt(preferredSpace: 7, plate: "TEST-001")

        XCTAssertEqual(outcome, .won(winner))
        let keys = await service.sentKeys()
        XCTAssertEqual(keys.count, 3)
        XCTAssertEqual(Set(keys).count, 1, "Every repeat of one tap must carry that tap's key")
    }

    /// A key is an intent, not a session: reusing it across taps would replay the first tap's
    /// outcome to the second, and the user could never try again.
    func testEachTapGetsItsOwnKey() async {
        let service = FakeReservationService(.fail(business(.spaceUnavailable)))
        let coordinator = coordinator(service)

        _ = await coordinator.attempt(preferredSpace: 7, plate: "TEST-001")
        _ = await coordinator.attempt(preferredSpace: 8, plate: "TEST-001")

        let keys = await service.sentKeys()
        XCTAssertEqual(keys.count, 2)
        XCTAssertNotEqual(keys[0], keys[1])
    }

    func testInProgressIsRepeatedUntilTheOutcomeIsKnown() async {
        let inProgress = business(.idempotencyInProgress)
        let service = FakeReservationService(script: [.fail(inProgress), .fail(inProgress), .succeed(winner)])

        let outcome = await coordinator(service).attempt(preferredSpace: 7, plate: "TEST-001")

        XCTAssertEqual(outcome, .won(winner))
        let calls = await service.calls()
        XCTAssertEqual(calls, 3)
    }

    /// The repeat after a timeout comes back as the first send's failure. That is the true
    /// outcome of the tap, so it is shown as it is, with nothing further asked.
    func testReplayedFailureAfterATimeoutIsFinal() async {
        let service = FakeReservationService(script: [.fail(timedOut), .fail(business(.lotFull))])

        let outcome = await coordinator(service).attempt(preferredSpace: 7, plate: "TEST-001")

        XCTAssertEqual(outcome, .lost(.lotFull))
        let readBacks = await service.readBacks()
        XCTAssertEqual(readBacks, 0)
    }

    func testRepeatsWaitBetweenSendsAndNotBeforeTheFirst() async {
        let pauses = PauseRecorder()
        let service = FakeReservationService(.fail(timedOut), mine: .success(nil))

        _ = await coordinator(
            service, policy: .init(maxAttempts: 4, delay: .seconds(1)),
            sleep: { await pauses.record($0) }
        ).attempt(preferredSpace: 7, plate: "TEST-001")

        let recorded = await pauses.all()
        XCTAssertEqual(recorded, [.seconds(1), .seconds(1), .seconds(1)])
    }

    // MARK: - When the repeats run out

    /// The read-back is authoritative: a row exists, so the space is the user's.
    func testExhaustedRepeatsReadBackAndFindTheReservation() async {
        let service = FakeReservationService(.fail(timedOut), mine: .success(readBack))

        let outcome = await coordinator(service).attempt(preferredSpace: 7, plate: "TEST-001")

        XCTAssertEqual(outcome, .won(readBack))
        let calls = await service.calls()
        XCTAssertEqual(calls, 4)
    }

    /// Nothing committed yet is not a loss: a send of ours may still be queued. And the board
    /// must not be consulted over the server's own answer.
    func testNothingReadBackStaysUnknownAndIgnoresTheBoard() async {
        let service = FakeReservationService(.fail(timedOut), mine: .success(nil))

        let outcome = await coordinator(service).attempt(preferredSpace: 7, plate: "TEST-001")

        XCTAssertEqual(outcome, .unknown(.noEvidence(cause: .timedOut)))
    }

    func testStillInProgressWhenRepeatsRunOutSaysSo() async {
        let service = FakeReservationService(.fail(business(.idempotencyInProgress)), mine: .success(nil))

        let outcome = await coordinator(service).attempt(preferredSpace: 7, plate: "TEST-001")

        XCTAssertEqual(outcome, .unknown(.noEvidence(cause: .alreadyInFlight)))
    }

    /// The first send timed out, so it may have committed. A repeat that then fails to leave
    /// the device proves nothing about the first, and must not be reported as "can't reach
    /// the server", which reads as "nothing happened".
    func testUnsentRepeatAfterATimeoutIsNotReportedAsAFailure() async {
        let unsent = APIError.transport(message: "refused", failure: .notSent)
        let service = FakeReservationService(script: [.fail(timedOut), .fail(unsent)], mine: .success(nil))

        let outcome = await coordinator(service).attempt(preferredSpace: 7, plate: "TEST-001")

        XCTAssertEqual(outcome, .unknown(.noEvidence(cause: .timedOut)))
    }

    // MARK: - Another attempt for the same day

    /// With a key, DUPLICATE_REQUEST is about some other attempt, such as an earlier tap this
    /// device never heard back from. Repeating our key cannot answer it; the read-back can.
    func testDuplicateRequestReadsBackWithoutRepeating() async {
        let service = FakeReservationService(.fail(business(.duplicateRequest)), mine: .success(readBack))

        let outcome = await coordinator(service).attempt(preferredSpace: 7, plate: "TEST-001")

        XCTAssertEqual(outcome, .won(readBack))
        let calls = await service.calls()
        XCTAssertEqual(calls, 1)
    }

    // MARK: - A backend without keys

    /// Against a backend that ignores the header, a repeat is a real second attempt. The
    /// `never` policy keeps "one tap, one attempt" there, and falls back to today's route.
    func testNeverPolicySendsOnceAndReconcilesAgainstTheBoard() async {
        let service = FakeReservationService(.fail(timedOut))

        let outcome = await coordinator(service, policy: .never).attempt(preferredSpace: 7, plate: "TEST-001")

        XCTAssertEqual(outcome, .unknown(.probablyHeld(space: 7)))
        let calls = await service.calls()
        XCTAssertEqual(calls, 1)
    }

    // MARK: - The screen

    /// A win read back carries no balance. The header must show the server's figure, not the
    /// one from before the tap, and not one the app worked out itself.
    @MainActor
    func testWinReadBackRefetchesTheBalance() async {
        let model = GridViewModel(environment: makeEnvironment(
            wallet: StubWallet(balanceResult: .success(90)),
            reservations: StubReservations(result: .failure(timedOut), mineResult: .success(readBack))
        ))

        await model.reserve(space: 7)

        XCTAssertEqual(model.outcome, .won(readBack))
        XCTAssertEqual(model.balance, 90)
    }
}

private actor PauseRecorder {
    private var pauses: [Duration] = []
    func record(_ pause: Duration) { pauses.append(pause) }
    func all() -> [Duration] { pauses }
}
