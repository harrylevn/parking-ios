import Foundation

/// Every service is a protocol so the view models can be driven by fakes in tests.
/// Guardrail 6.4: tests run against fakes, never the live backend.

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
    /// One call, one attempt. Never retries internally: after a timeout the outcome is
    /// indeterminate (see `ReservationOutcome.unknown`) and only reconciliation can settle it.
    func reserve(preferredSpace: Int?) async throws -> Reservation
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
