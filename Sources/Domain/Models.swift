import Foundation

struct ParkingSpace: Identifiable, Equatable, Sendable {
    let number: Int
    let isAvailable: Bool
    /// Last three *characters* of the holder's plate, not digits. Not unique:
    /// collisions across 80 cells are possible, so this identifies a space's
    /// holder only as a hint, never as proof that it is you.
    let plateLast3: String?

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
    case unknown(reason: String)
    case rejected(APIError)
}
