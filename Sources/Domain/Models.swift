import Foundation

struct ParkingSpace: Identifiable, Equatable, Sendable {
    let number: Int
    let isAvailable: Bool
    /// Last three *characters* of the holder's plate, not digits. Not unique:
    /// collisions across 80 cells are possible, so this identifies a space's
    /// holder only as a hint, never as proof that it is you.
    ///
    /// **Always `nil` when the space is available**, enforced below rather than trusted
    /// from the wire. The backend computes `available` against tomorrow but returns
    /// `plate_last3` from the row whatever date it holds, so the two fields contradict each
    /// other for every space whose booking has already passed.
    let plateLast3: String?

    /// A free space has no holder. The backend can say otherwise; this type cannot, so no
    /// reader has to remember the rule and no view can print a stale plate on a free tile.
    init(number: Int, isAvailable: Bool, plateLast3: String?) {
        self.number = number
        self.isAvailable = isAvailable
        self.plateLast3 = isAvailable ? nil : plateLast3
    }

    var id: Int { number }
}

struct SpaceGrid: Equatable, Sendable {
    let date: Date
    let totalSpaces: Int
    let availableSpaces: Int
    let reservedSpaces: Int
    let spaces: [ParkingSpace]

    static let empty = SpaceGrid(
        date: .distantPast, totalSpaces: 0, availableSpaces: 0, reservedSpaces: 0, spaces: []
    )
}

struct Reservation: Equatable, Sendable {
    let id: Int64
    let spaceNumber: Int
    let date: Date
    let amountPaid: Decimal
    let newBalance: Decimal
    /// Server-side contention telemetry, surfaced in the demo rather than hidden.
    let queuePosition: Int64?
    let totalProcessingMs: Int64?
}

struct Account: Equatable, Sendable {
    let userId: Int64
    let licensePlate: String
    var balance: Decimal
}

/// What the client can truthfully say about a reservation attempt.
///
/// `unknown` exists because the backend makes it unavoidable: idempotency is keyed
/// server-side on (userId, date) with no client-supplied key and no `GET /reservations`
/// to reconcile against, so a timeout leaves a genuinely indeterminate outcome. The UI
/// must be able to say "we don't know yet" rather than guess.
enum ReservationOutcome: Equatable, Sendable {
    case won(Reservation)
    case lost(BusinessErrorCode)
    case unknown(Uncertainty)
    case rejected(APIError)
    /// The user declined or failed re-authentication. The request was never sent.
    case notConfirmed
}

/// What the client can actually substantiate when a reservation does not come back with a
/// receipt. Three genuinely different situations, which used to share one sheet headed
/// "We're not sure yet" — including the case where the space is almost certainly yours.
/// The week-1 checkpoint reported that sheet as distressing and hard to understand, and the
/// flattening was most of the reason: it answered "does the app know?" when the user was
/// asking "did I get a space, and did it take my $10?".
///
/// Deliberately carries no user-facing wording. The reason strings used to live here, which
/// put English in the Domain layer and out of reach of a String Catalog; the copy now sits
/// in `OutcomeSheet` next to the rest of it.
enum Uncertainty: Equatable, Sendable {
    /// Exactly one space now carries our plate suffix. Strong evidence, but the server never
    /// sent an id, an amount or a balance, so it is not proof.
    case probablyHeld(space: Int)

    /// More than one space carries our suffix — three characters across 80 cells collide.
    /// The app cannot say which, if either, is ours, so it claims neither.
    case ambiguous(suffix: String)

    /// Nothing to go on: the reply never arrived and the grid adds no evidence either way.
    case noEvidence(cause: Cause)

    /// Why the outcome was never confirmed. Distinguished because the honest sentence
    /// differs: a request that was never sent is not the same as one that may have landed.
    enum Cause: Equatable, Sendable {
        /// Sent, but the reply did not arrive in time. It may still land.
        case timedOut
        /// The connection closed before the reply — a backend dying mid-request lands here.
        case connectionDropped
        /// The server is already processing an attempt for this user and date.
        case alreadyInFlight
    }
}
