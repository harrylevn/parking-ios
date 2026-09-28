import Foundation

/// Decides what the app may truthfully claim about a reservation attempt.
///
/// Each tap gets one Idempotency-Key, and the backend answers every repeat of that key with
/// the first request's outcome: its success, its failure, or `IDEMPOTENCY_IN_PROGRESS` while
/// it runs. That changes what a lost reply means. Before, a timeout was unknowable, because
/// retrying got `DUPLICATE_REQUEST` for both "still running" and "already succeeded", so the
/// coordinator never retried and reconciled against the board. Now a repeat of the same key
/// is safe and informative, so the coordinator asks again. See ADR-007.
///
///  * One tap is still exactly one attempt. The repeats carry the tap's key, so the server
///    treats them as the same attempt, never a second one; and a second tap while one is in
///    flight is refused here, where it is testable and a double tap cannot defeat it.
///  * If the repeats run out, `GET /reservations/me` reads back what committed. A found
///    reservation is authoritative.
///  * Only if that cannot be read either does the board get consulted, matched on
///    `plateLast3`: three characters, so it is evidence, never proof.
///
/// The rule this type enforces is unchanged: **never claim a reservation the client cannot
/// substantiate.** Where the truth is still unknown, `ReservationOutcome.unknown` says so.
actor ReservationCoordinator {
    /// How many times one tap may send its key, and how long to wait between sends.
    struct RetryPolicy: Sendable {
        /// Including the first send. `1` means never repeat, which is the only safe setting
        /// against a backend that ignores Idempotency-Key: there, a repeat after a failure
        /// the client never heard about is a genuine second attempt.
        let maxAttempts: Int
        /// The server's `Retry-After` for `IDEMPOTENCY_IN_PROGRESS` is 1 s. Used for every
        /// repeat rather than parsed from the header, because the header reaches only the
        /// in-progress case, and a timeout needs a pause just as much.
        let delay: Duration

        /// Four sends a second apart: a 3 s reservation timeout makes the worst case about
        /// 15 s of "Reserving…", which the elapsed timer on the button keeps legible. More
        /// would add load in the one minute the server can least afford it.
        static let standard = RetryPolicy(maxAttempts: 4, delay: .seconds(1))
        static let never = RetryPolicy(maxAttempts: 1, delay: .zero)
    }

    private let reservations: ReservationServicing
    private let spaces: SpacesServicing
    private let reauth: Reauthenticating
    private let policy: RetryPolicy
    private let makeKey: @Sendable () -> UUID
    private let sleep: @Sendable (Duration) async -> Void

    /// Guards the "one tap, one attempt" guardrail across concurrent callers.
    private var attemptInFlight = false

    init(
        reservations: ReservationServicing,
        spaces: SpacesServicing,
        reauth: Reauthenticating,
        policy: RetryPolicy = .standard,
        makeKey: @escaping @Sendable () -> UUID = { UUID() },
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.reservations = reservations
        self.spaces = spaces
        self.reauth = reauth
        self.policy = policy
        self.makeKey = makeKey
        self.sleep = sleep
    }

    var isAttemptInFlight: Bool { attemptInFlight }

    /// Attempt a reservation. A second call while one is in flight is refused, not queued.
    func attempt(preferredSpace: Int?, plate: String) async -> ReservationOutcome {
        guard !attemptInFlight else {
            return .unknown(.noEvidence(cause: .alreadyInFlight))
        }
        attemptInFlight = true
        defer { attemptInFlight = false }

        do {
            try await reauth.authenticate(reason: "Confirm your parking reservation")
        } catch {
            // Not a transport error, though it used to be dressed as one — which showed a user
            // who had just cancelled Face ID "Can't reach the server". Nothing was sent, so
            // nothing is unknown and nothing was charged.
            return .notConfirmed
        }

        // One key per tap, made after the prompt: a declined prompt sends nothing, so it
        // needs no key, and the next tap is a new intent with a new one.
        return await send(key: makeKey(), preferredSpace: preferredSpace, plate: plate)
    }

    /// Sends the tap's key until the outcome is known or the policy runs out.
    private func send(key: UUID, preferredSpace: Int?, plate: String) async -> ReservationOutcome {
        // Set once any send may have reached the server. From then on, no later failure can
        // be reported as "nothing happened": the earlier send may have committed.
        var pending: Uncertainty.Cause?

        for sendIndex in 0..<max(policy.maxAttempts, 1) {
            if sendIndex > 0 { await sleep(policy.delay) }
            let failure: APIError
            do {
                let reservation = try await reservations.reserve(
                    preferredSpace: preferredSpace, idempotencyKey: key
                )
                return .won(reservation)
            } catch {
                failure = error as? APIError ?? .malformedResponse(String(describing: error))
            }

            switch classify(failure) {
            case .final(let outcome):
                return outcome
            case .indeterminate(let cause):
                pending = cause
            case .ambiguous:
                // Another attempt for the day: repeating our key will not change the answer,
                // so go straight to asking what committed.
                return await resolve(cause: .alreadyInFlight, plate: plate)
            case .failed:
                guard let pending else { return .rejected(failure) }
                return await resolve(cause: pending, plate: plate)
            }
        }

        return await resolve(cause: pending ?? .timedOut, plate: plate)
    }

    private enum Classification {
        /// A definite outcome for this tap. Replays included: a replayed failure is the true
        /// outcome of the first send.
        case final(ReservationOutcome)
        /// This send may have reached the server and its outcome is not known. Repeat the key.
        case indeterminate(Uncertainty.Cause)
        /// Something else for the same day is running or has succeeded. Repeating our key
        /// cannot tell which.
        case ambiguous
        /// Not an outcome. Final only if no earlier send may have landed.
        case failed
    }

    private func classify(_ error: APIError) -> Classification {
        switch error {
        case .transport(_, .timedOut):
            return .indeterminate(.timedOut)

        case .transport(_, .interrupted):
            // The backend dying mid-request lands here, not as a timeout: its socket closes
            // and URLSession fails at once. The commit may already have happened.
            return .indeterminate(.connectionDropped)

        case .business(let response):
            switch response.code {
            case .idempotencyInProgress:
                // Our own key, still running. The one 409 that means "ask again".
                return .indeterminate(.alreadyInFlight)

            case .duplicateRequest, .alreadyQueued:
                // With a key, these are about another attempt for the same user and day, such
                // as an earlier tap whose outcome this device never learned.
                return .ambiguous

            case .alreadyReserved:
                // Unambiguous: the database's unique (user, date) constraint fired, so a
                // reservation definitely exists. With a key it is not ours — our own row would
                // have been replayed as a success — so it is an earlier tap's.
                return .final(.lost(.alreadyReserved))

            case .spaceUnavailable, .lotFull, .insufficientBalance,
                 .windowClosed, .validationError, .lockTimeout:
                return .final(.lost(response.code))

            case .authFailed, .internalError, .duplicateResource,
                 .idempotencyKeyReused, .idempotencyKeyInvalid, .reservationNotFound:
                // The key codes are client bugs, and the rest cannot come from this endpoint.
                // Listed rather than defaulted so a new code has to be thought about.
                return .failed
            }

        case .unauthenticated, .malformedResponse, .transport:
            // `.transport(_, .notSent)` included: on a first send it proves nothing happened,
            // but on a repeat the first send may still have landed.
            return .failed
        }
    }

    /// Ask what committed: the server first, the board only if the server cannot say.
    private func resolve(cause: Uncertainty.Cause, plate: String) async -> ReservationOutcome {
        do {
            if let held = try await reservations.mine() {
                // Authoritative: the row exists. It carries no balance, so the caller fetches it.
                return .won(held)
            }
            // Nothing committed yet. Not "you lost": a send of ours may still be queued.
            return .unknown(.noEvidence(cause: cause))
        } catch {
            // Unreachable, or a backend without the endpoint. The board is the last evidence.
            return await reconcile(plate: plate, cause: cause)
        }
    }

    /// Ask the grid whether a space now carries our plate suffix.
    ///
    /// Returns `unknown` unless exactly one space matches. Two matches means a suffix
    /// collision and the app cannot tell which is ours, so it must not claim either.
    private func reconcile(
        plate: String, cause: Uncertainty.Cause
    ) async -> ReservationOutcome {
        let suffix = String(plate.suffix(3))
        guard let grid = try? await spaces.grid() else {
            return .unknown(.noEvidence(cause: cause))
        }

        let matches = grid.spaces.filter { !$0.isAvailable && $0.plateLast3 == suffix }

        guard matches.count == 1, let match = matches.first else {
            if matches.count > 1 {
                return .unknown(.ambiguous(suffix: suffix))
            }
            return .unknown(.noEvidence(cause: cause))
        }

        // A space matching our suffix is strong evidence, but the reservation id, amount
        // and new balance are unknown, so this is reported as a confirmed-by-grid state
        // rather than fabricating a `Reservation` the server never returned.
        return .unknown(.probablyHeld(space: match.number))
    }
}
