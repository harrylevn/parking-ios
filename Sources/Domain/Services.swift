import Foundation

// Every service is a protocol so the view models can be driven by fakes in tests.
//
// 6.1 guardrail: services behind protocols and injected, fakeable in tests. Running those
// tests against fakes rather than the live backend is 6.4's Default column, kept as written.

protocol AuthServicing: Sendable {
    func register(licensePlate: String, password: String) async throws -> Account
    func login(licensePlate: String, password: String) async throws -> Account
}

protocol SpacesServicing: Sendable {
    func grid() async throws -> SpaceGrid
}

protocol WalletServicing: Sendable {
    func balance() async throws -> Decimal
    func deposit(amount: Decimal) async throws -> Decimal
}

protocol ReservationServicing: Sendable {
    /// One call, one request. Never retries internally; `ReservationCoordinator` decides
    /// whether to repeat it, and a repeat carries the same `idempotencyKey`, so the server
    /// answers it with the first request's outcome rather than running a second attempt.
    func reserve(preferredSpace: Int?, idempotencyKey: UUID) async throws -> Reservation

    /// The caller's committed reservation for tomorrow, or `nil` if the server holds none.
    /// `nil` is final only once no request of ours is still being processed.
    func mine() async throws -> Reservation?
}

protocol TokenStoring: Sendable {
    func save(_ token: String) throws
    func read() throws -> String?
    func clear() throws
}

/// Re-authentication ahead of a reservation. Abstracted so tests need no biometrics
/// and so the non-biometric fallback is exercised rather than assumed.
protocol Reauthenticating: Sendable {
    func authenticate(reason: String) async throws
}
