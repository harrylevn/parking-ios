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

    /// Held here, not only inside `ReservationCoordinator`, because reserving is not the
    /// only action that moves money: a deposit credits the wallet and must carry the same
    /// step-up evidence. See `GridViewModel.deposit`.
    let reauth: Reauthenticating

    /// True when the app is driven by a UI test.
    ///
    /// Two things hang off it, both of which are about removing nondeterminism a test cannot
    /// control rather than about changing what the app does:
    ///
    /// * **Animations are suppressed.** A test drives the app faster than any human, and an
    ///   in-flight transition is a window in which a tap lands on nothing.
    /// * **AutoFill content types are omitted on the login fields.** With them, a successful
    ///   sign-in makes iOS present its "Save Password?" sheet over the app. It is presented
    ///   inside the app's own element tree, so the board underneath still reports itself
    ///   hittable while every touch lands on the dialog — and it appears on some iOS
    ///   runtimes and not others, at a moment no wait can be relied on to catch.
    ///
    /// Real users keep both. This is a property of the run, not of the product.
    let isUITesting: Bool

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
        retryPolicy: ReservationCoordinator.RetryPolicy = .standard,
        isUITesting: Bool = false
    ) {
        self.auth = auth
        self.spaces = spaces
        self.wallet = wallet
        self.reservations = reservations
        self.tokenStore = tokenStore
        self.serverClock = serverClock
        self.window = window
        self.isUITesting = isUITesting
        self.reauth = reauth
        self.coordinator = ReservationCoordinator(
            reservations: reservations, spaces: spaces, reauth: reauth, policy: retryPolicy
        )
    }

    /// The real app: Keychain-backed session, live HTTP, biometric re-auth.
    static func live(
        configuration: APIConfiguration = .fromEnvironment(LaunchSettings.current)
    ) -> AppEnvironment {
        let tokenStore = KeychainTokenStore()
        let serverClock = ServerClock()
        let client = HTTPClient(
            configuration: configuration,
            // Ephemeral: no disk cache and no persistent cookies, so balances and bookings are
            // never written to Library/Caches. Nothing was, checked on 29/09, but only because
            // the backend sends `Cache-Control: no-store` (Spring Security's default), and a
            // client should not depend on a header it does not control.
            session: URLSession(configuration: .ephemeral),
            tokenStore: tokenStore,
            serverClock: serverClock
        )
        // The window hour is configuration, not a constant: the demo runs with
        // app.reservation.window-hour shifted, and hardcoding 20 would break it.
        let environment = LaunchSettings.current
        let hour = Int(environment["PARKING_WINDOW_HOUR"] ?? "") ?? 20
        // Repeating a key is safe only against a backend that honours Idempotency-Key. One
        // that ignores it runs a repeat as a second attempt whenever the first failed without
        // the client hearing, so `PARKING_IDEMPOTENCY_KEYS=0` turns repeats off for running
        // against the backend's master branch. See ADR-007.
        let retryPolicy: ReservationCoordinator.RetryPolicy =
            environment["PARKING_IDEMPOTENCY_KEYS"] == "0" ? .never : .standard
        return AppEnvironment(
            auth: AuthService(client: client),
            spaces: SpacesService(client: client),
            wallet: WalletService(client: client),
            reservations: ReservationService(client: client),
            tokenStore: tokenStore,
            serverClock: serverClock,
            reauth: Self.reauthenticator(),
            window: ReservationWindow(openingHour: hour),
            retryPolicy: retryPolicy
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

    /// The environment this launch runs in. Test modes exist in debug builds only: in a
    /// release build `-UITestMode` means nothing, and the fakes and the always-yes
    /// re-authenticator it would select are not compiled in at all. They used to be, and the
    /// release binary carried a complete Face ID bypass behind one launch argument.
    static func forLaunch() -> AppEnvironment {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-UITestMode") {
            return uiTesting()
        }
        #endif
        return live()
    }

    #if DEBUG
    /// Deterministic in-memory stack for UI tests, selected by the `-UITestMode` launch
    /// argument. Guardrail 6.4: tests never run against the live backend, so the UI test
    /// stays green whether or not the Spring Boot service happens to be up.
    static func uiTesting() -> AppEnvironment {
        let tokenStore = InMemoryTokenStore()
        // The stubs never go through HTTPClient, so nothing would ever feed the clock a
        // `Date` header and the UI would sit on "Checking server time…" forever. Seeded
        // synchronously, so the first render is already the final layout — see ServerClock.
        let clock = ServerClock(seededWith: Date())

        // `-UITestOutcome` drives the reserve result. Only the transport failure is stubbed;
        // which of the three uncertain outcomes appears is then decided by the real
        // coordinator reading the real grid, so these screens are reconciled rather than
        // posed. Test-only, like `-UITestSkipReauth`, and reachable only from `uiTesting()`.
        let mode = StubReservationService.Mode.fromLaunchArguments(ProcessInfo.processInfo.arguments)
        // Staged rather than fixed. A grid that already carried our plate would mean the app
        // held the space *before* the tap, so it would show the holding banner and never offer
        // to reserve at all — which is exactly how the first version of this test failed. The
        // spaces appear only once the attempt has been made, which is also what really
        // happens: the reservation lands and the reply is what goes missing.
        //
        // `noEvidence` stages nothing, the common shape of that outcome — the board shows
        // nothing either way. The rarer "grid unreadable too" route to the same sheet is
        // covered by `ReservationCoordinatorTests`; failing the initial load here would leave
        // the board offline with no space to tap.
        let appearing: [Int] = switch mode {
        case .wins, .noEvidence: []
        case .probablyHeld: [7]
        case .ambiguous: [7, 19]
        }
        let staged = StagedGrid(appearingAfterAttempt: appearing)

        return AppEnvironment(
            auth: StubAuthService(tokenStore: tokenStore),
            spaces: StubSpacesService(staged: staged),
            wallet: StubWalletService(),
            reservations: StubReservationService(mode: mode, staged: staged),
            tokenStore: tokenStore,
            serverClock: clock,
            reauth: AlwaysAllowReauthenticator(),
            window: ReservationWindow(openingHour: 0),
            // The repeats still happen, so the flow under test is the real one; they just
            // do not wait a second each.
            retryPolicy: .init(
                maxAttempts: ReservationCoordinator.RetryPolicy.standard.maxAttempts, delay: .zero
            ),
            isUITesting: true
        )
    }
    #endif

    func signOut() {
        try? tokenStore.clear()
        account = nil
    }
}

// MARK: - UI test stubs

#if DEBUG

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

    let staged: StagedGrid

    func grid() async throws -> SpaceGrid {
        let heldByUs = await staged.heldByUs
        let spaces = (1...80).map { number -> ParkingSpace in
            if heldByUs.contains(number) {
                return ParkingSpace(number: number, isAvailable: false, plateLast3: "001")
            }
            return ParkingSpace(
                number: number,
                isAvailable: number % 4 != 0,
                plateLast3: number % 4 == 0 ? "042" : nil
            )
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
    /// What the stub should do, selected by `-UITestOutcome <case>`.
    ///
    /// The uncertain outcomes are the app's signature states and the hardest to reach: they
    /// need a reply that never arrives, which no stub produced, so until now they could only
    /// be seen by standing a delaying proxy in front of the real backend. That is worth doing
    /// for a demo and far too slow for a test, so the transport failure is injected here
    /// instead and the real `ReservationCoordinator` reconciles it exactly as it would in
    /// production — the outcome is computed, not stubbed.
    enum Mode: String {
        case wins
        /// Times out, and the grid then shows our plate on exactly one space.
        case probablyHeld
        /// Times out, and two spaces carry our suffix.
        case ambiguous
        /// Times out, and the grid is unreadable too, so nothing can be inferred.
        case noEvidence

        static func fromLaunchArguments(_ arguments: [String]) -> Mode {
            guard let index = arguments.firstIndex(of: "-UITestOutcome"),
                  arguments.indices.contains(index + 1),
                  let mode = Mode(rawValue: arguments[index + 1]) else { return .wins }
            return mode
        }
    }

    let mode: Mode
    let staged: StagedGrid

    func reserve(preferredSpace: Int?, idempotencyKey: UUID) async throws -> Reservation {
        guard mode == .wins else {
            // The reservation "lands" and then the reply is lost, so the grid the coordinator
            // reconciles against is the one that exists after a successful commit.
            await staged.attemptLanded()
            throw APIError.transport(message: "stubbed timeout", failure: .timedOut)
        }
        return Reservation(
            id: 1, spaceNumber: preferredSpace ?? 1, date: Date(), amountPaid: 10,
            newBalance: 90, queuePosition: 1, totalProcessingMs: 12
        )
    }

    /// Unreachable, as it would be with the backend down. That sends the coordinator on to
    /// the board, which is where the staged uncertain outcomes are decided; a stub that
    /// answered here would make those screens impossible to reach.
    func mine() async throws -> Reservation? {
        throw APIError.transport(message: "stubbed read-back", failure: .notSent)
    }
}

/// Lets the stubbed grid change after the stubbed attempt.
///
/// Shared between the spaces and reservation stubs so the UI tests can stage the situation
/// the uncertain sheets exist for: the reservation committed, and only the reply went missing.
private actor StagedGrid {
    private let appearingAfterAttempt: [Int]
    private(set) var heldByUs: [Int] = []

    init(appearingAfterAttempt: [Int]) {
        self.appearingAfterAttempt = appearingAfterAttempt
    }

    func attemptLanded() {
        heldByUs = appearingAfterAttempt
    }
}
#endif
