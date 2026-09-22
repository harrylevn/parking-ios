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

    /// Suppresses view transitions under UI test.
    ///
    /// A UI test drives the app faster than any human, and an in-flight transition is a
    /// window in which a tap lands on nothing. Earlier this was handled by switching Reduce
    /// Motion on in the simulator by hand, which made the suite pass on this machine and
    /// fail on CI — a test that is green because of how one laptop is configured is worse
    /// than no test. Carrying it here makes it a property of the run, not the environment.
    let disablesAnimations: Bool

    @Published var account: Account?

    init(
        auth: AuthServicing,
        spaces: SpacesServicing,
        wallet: WalletServicing,
        reservations: ReservationServicing,
        tokenStore: TokenStoring,
        serverClock: ServerClock,
        reauth: Reauthenticating,
        window: ReservationWindow,
        disablesAnimations: Bool = false
    ) {
        self.auth = auth
        self.spaces = spaces
        self.wallet = wallet
        self.reservations = reservations
        self.tokenStore = tokenStore
        self.serverClock = serverClock
        self.window = window
        self.disablesAnimations = disablesAnimations
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
            reauth: Self.reauthenticator(),
            window: ReservationWindow(openingHour: hour)
        )
    }

    /// Biometric re-authentication, unless a UI test has asked for it to be stood down.
    ///
    /// A UI test cannot satisfy Face ID or type a device passcode, so without this the
    /// reserve flow is simply untestable end to end. The override is compiled out of
    /// release builds entirely — it cannot be triggered by launch arguments on a shipped
    /// binary, which is the property that makes it acceptable to have at all.
    private static func reauthenticator() -> Reauthenticating {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-UITestSkipReauth") {
            return AlwaysAllowReauthenticator()
        }
        #endif
        return BiometricReauthenticator()
    }

    /// Deterministic in-memory stack for UI tests, selected by the `-UITestMode` launch
    /// argument. Guardrail 6.4: tests never run against the live backend, so the UI test
    /// stays green whether or not the Spring Boot service happens to be up.
    static func uiTesting() -> AppEnvironment {
        let tokenStore = InMemoryTokenStore()
        // The stubs never go through HTTPClient, so nothing would ever feed the clock a
        // `Date` header and the UI would sit on "Checking server time…" forever. Seeded
        // synchronously, so the first render is already the final layout — see ServerClock.
        let clock = ServerClock(seededWith: Date())
        return AppEnvironment(
            auth: StubAuthService(tokenStore: tokenStore),
            spaces: StubSpacesService(),
            wallet: StubWalletService(),
            reservations: StubReservationService(),
            tokenStore: tokenStore,
            serverClock: clock,
            reauth: AlwaysAllowReauthenticator(),
            window: ReservationWindow(openingHour: 0),
            disablesAnimations: true
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
    /// Fixed, not `Date()`: a stub whose value changes on every poll would defeat the
    /// no-op diffing in `GridViewModel.refresh()` and keep the view permanently redrawing.
    private static let date = Date()

    func grid() async throws -> SpaceGrid {
        let spaces = (1...80).map {
            ParkingSpace(number: $0, isAvailable: $0 % 4 != 0, plateLast3: $0 % 4 == 0 ? "042" : nil)
        }
        return SpaceGrid(
            date: Self.date, totalSpaces: 80,
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
