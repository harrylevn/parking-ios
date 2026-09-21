import Foundation

/// Composition root. Everything is constructed here and injected downwards, so no view
/// ever reaches for networking or persistence and every collaborator can be faked in tests.
@MainActor
final class AppEnvironment: ObservableObject {
    let auth: AuthServicing
    let spaces: SpacesServicing
    let wallet: WalletServicing
    let reservations: ReservationServicing
    let tokenStore: TokenStoring
    let serverClock: ServerClock
    let coordinator: ReservationCoordinator
    let window: ReservationWindow

    @Published var account: Account?

    init(
        auth: AuthServicing,
        spaces: SpacesServicing,
        wallet: WalletServicing,
        reservations: ReservationServicing,
        tokenStore: TokenStoring,
        serverClock: ServerClock,
        reauth: Reauthenticating,
        window: ReservationWindow
    ) {
        self.auth = auth
        self.spaces = spaces
        self.wallet = wallet
        self.reservations = reservations
        self.tokenStore = tokenStore
        self.serverClock = serverClock
        self.window = window
        self.coordinator = ReservationCoordinator(
            reservations: reservations, spaces: spaces, reauth: reauth
        )
    }

    /// The real app: Keychain-backed session, live HTTP, biometric re-auth.
    static func live(configuration: APIConfiguration = .localBackend) -> AppEnvironment {
        let tokenStore = KeychainTokenStore()
        let serverClock = ServerClock()
        let client = HTTPClient(
            configuration: configuration,
            session: .shared,
            tokenStore: tokenStore,
            serverClock: serverClock
        )
        // The window hour is configuration, not a constant: the demo runs with
        // app.reservation.window-hour shifted, and hardcoding 20 would break it.
        let hour = Int(ProcessInfo.processInfo.environment["PARKING_WINDOW_HOUR"] ?? "") ?? 20
        return AppEnvironment(
            auth: AuthService(client: client),
            spaces: SpacesService(client: client),
            wallet: WalletService(client: client),
            reservations: ReservationService(client: client),
            tokenStore: tokenStore,
            serverClock: serverClock,
            reauth: BiometricReauthenticator(),
            window: ReservationWindow(openingHour: hour)
        )
    }

    /// Deterministic in-memory stack for UI tests, selected by the `-UITestMode` launch
    /// argument. Guardrail 6.4: tests never run against the live backend, so the UI test
    /// stays green whether or not the Spring Boot service happens to be up.
    static func uiTesting() -> AppEnvironment {
        let tokenStore = InMemoryTokenStore()
        let spaces = StubSpacesService()
        return AppEnvironment(
            auth: StubAuthService(tokenStore: tokenStore),
            spaces: spaces,
            wallet: StubWalletService(),
            reservations: StubReservationService(),
            tokenStore: tokenStore,
            serverClock: ServerClock(),
            reauth: AlwaysAllowReauthenticator(),
            window: ReservationWindow(openingHour: 0)
        )
    }

    func signOut() {
        try? tokenStore.clear()
        account = nil
    }
}

// MARK: - UI test stubs

private struct StubAuthService: AuthServicing {
    let tokenStore: TokenStoring

    func register(licensePlate: String, password: String) async throws -> Account {
        try await login(licensePlate: licensePlate, password: password)
    }

    func login(licensePlate: String, password: String) async throws -> Account {
        try tokenStore.save("ui-test-token")
        return Account(userId: 1, licensePlate: licensePlate, balance: 100)
    }
}

private struct StubSpacesService: SpacesServicing {
    func grid() async throws -> SpaceGrid {
        let spaces = (1...80).map {
            ParkingSpace(number: $0, isAvailable: $0 % 4 != 0, plateLast3: $0 % 4 == 0 ? "042" : nil)
        }
        return SpaceGrid(
            date: Date(), totalSpaces: 80,
            availableSpaces: spaces.filter(\.isAvailable).count,
            reservedSpaces: spaces.filter { !$0.isAvailable }.count,
            spaces: spaces
        )
    }
}

private struct StubWalletService: WalletServicing {
    func balance() async throws -> Decimal { 100 }
    func deposit(amount: Decimal) async throws -> Decimal { 100 + amount }
}

private struct StubReservationService: ReservationServicing {
    func reserve(preferredSpace: Int?) async throws -> Reservation {
        Reservation(
            id: 1, spaceNumber: preferredSpace ?? 1, date: Date(), amountPaid: 10,
            newBalance: 90, queuePosition: 1, totalProcessingMs: 12
        )
    }
}
