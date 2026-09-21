import Foundation

/// Decides what the app may truthfully claim about a reservation attempt.
///
/// This exists because of a specific property of the backend. Idempotency is keyed
/// **server-side** on `(userId, date)`; there is no client-supplied idempotency key, and
/// there is no `GET /reservations`. So:
///
///  * One tap issues exactly one attempt. The guardrail "one tap, one attempt" is enforced
///    here rather than in the view, so it is testable and cannot be defeated by a double tap.
///  * After a network timeout the outcome is genuinely unknown: the request may have
///    succeeded, or may still be queued. Retrying returns `DUPLICATE_REQUEST`, which is
///    equally ambiguous, because the server clears the idempotency key on failure.
///  * The only reconciliation surface is `GET /spaces`, matched on `plateLast3` — three
///    characters, so collisions are possible. That makes it evidence, never proof.
///
/// The rule this type enforces: **never claim a reservation the client cannot substantiate.**
/// Where the truth is unknown, `ReservationOutcome.unknown` is returned and the UI says so.
actor ReservationCoordinator {
    private let reservations: ReservationServicing
    private let spaces: SpacesServicing
    private let reauth: Reauthenticating

    /// Guards the "one tap, one attempt" guardrail across concurrent callers.
    private var attemptInFlight = false

    init(reservations: ReservationServicing, spaces: SpacesServicing, reauth: Reauthenticating) {
        self.reservations = reservations
        self.spaces = spaces
        self.reauth = reauth
    }

    var isAttemptInFlight: Bool { attemptInFlight }

    /// Attempt a reservation. A second call while one is in flight is refused, not queued.
    func attempt(preferredSpace: Int?, plate: String) async -> ReservationOutcome {
        guard !attemptInFlight else {
            return .unknown(reason: "An attempt is already in progress.")
        }
        attemptInFlight = true
        defer { attemptInFlight = false }

        do {
            try await reauth.authenticate(reason: "Confirm your parking reservation")
        } catch {
            return .rejected(.transport(message: "Re-authentication failed", isTimeout: false))
        }

        do {
            let reservation = try await reservations.reserve(preferredSpace: preferredSpace)
            return .won(reservation)
        } catch let error as APIError {
            return await interpret(error, plate: plate)
        } catch {
            return .rejected(.malformedResponse(String(describing: error)))
        }
    }

    private func interpret(_ error: APIError, plate: String) async -> ReservationOutcome {
        switch error {
        case .transport(_, isTimeout: true):
            // The request may have landed. Reconcile rather than guess or retry.
            return await reconcile(
                plate: plate,
                fallbackReason: "The network timed out and we could not confirm the result."
            )

        case .business(let response):
            switch response.code {
            case .duplicateRequest, .alreadyQueued:
                // Ambiguous by construction: in flight, or already succeeded. Reconcile.
                return await reconcile(
                    plate: plate,
                    fallbackReason: "A reservation attempt is already being processed."
                )

            case .alreadyReserved:
                // Unambiguous: the database's unique (user, date) constraint fired, so a
                // reservation definitely exists. Surfaces only when Redis and Postgres
                // disagree, which makes it the one trustworthy "you already hold one".
                return .lost(.alreadyReserved)

            case .spaceUnavailable, .lotFull, .insufficientBalance,
                 .windowClosed, .validationError, .lockTimeout:
                return .lost(response.code)

            case .authFailed, .internalError:
                return .rejected(error)
            }

        case .unauthenticated, .malformedResponse, .transport:
            return .rejected(error)
        }
    }

    /// Ask the grid whether a space now carries our plate suffix.
    ///
    /// Returns `unknown` unless exactly one space matches. Two matches means a suffix
    /// collision and the app cannot tell which is ours, so it must not claim either.
    private func reconcile(plate: String, fallbackReason: String) async -> ReservationOutcome {
        let suffix = String(plate.suffix(3))
        guard let grid = try? await spaces.grid() else {
            return .unknown(reason: fallbackReason)
        }

        let matches = grid.spaces.filter { !$0.isAvailable && $0.plateLast3 == suffix }

        guard matches.count == 1, let match = matches.first else {
            if matches.count > 1 {
                return .unknown(
                    reason: "Another plate ends in \(suffix), so we cannot confirm which space is yours."
                )
            }
            return .unknown(reason: fallbackReason)
        }

        // A space matching our suffix is strong evidence, but the reservation id, amount
        // and new balance are unknown, so this is reported as a confirmed-by-grid state
        // rather than fabricating a `Reservation` the server never returned.
        return .unknown(reason: "Space \(match.number) appears to be yours. Pull to refresh to confirm.")
    }
}
