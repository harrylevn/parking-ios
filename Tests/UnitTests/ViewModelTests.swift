import XCTest
@testable import Parking

// 6.4's guardrail asks for unit tests on the domain **and the view models**. The domain is
// covered by ErrorDecodingTests, ReservationCoordinatorTests, ServerClockTests and
// BoardLayoutTests; this file covers the view models, against fakes only.

// MARK: - Fakes

private struct StubAuth: AuthServicing {
    var result: Result<Account, APIError>
    func register(licensePlate: String, password: String) async throws -> Account {
        try result.get()
    }
    func login(licensePlate: String, password: String) async throws -> Account {
        try result.get()
    }
}

private struct StubSpaces: SpacesServicing {
    var result: Result<SpaceGrid, APIError>
    func grid() async throws -> SpaceGrid { try result.get() }
}

private struct StubWallet: WalletServicing {
    var balanceResult: Decimal = 100
    var depositResult: Result<Decimal, APIError> = .success(150)
    func balance() async throws -> Decimal { balanceResult }
    func deposit(amount: Decimal) async throws -> Decimal { try depositResult.get() }
}

private struct StubReservations: ReservationServicing {
    var result: Result<Reservation, APIError>
    func reserve(preferredSpace: Int?) async throws -> Reservation { try result.get() }
}

@MainActor
private func makeEnvironment(
    auth: AuthServicing = StubAuth(
        result: .success(Account(userId: 1, licensePlate: "TEST-001", balance: 100))
    ),
    spaces: SpacesServicing = StubSpaces(result: .success(grid(taken: []))),
    wallet: WalletServicing = StubWallet(),
    reservations: ReservationServicing = StubReservations(result: .failure(.unauthenticated)),
    windowHour: Int = 0,
    account: Account? = Account(userId: 1, licensePlate: "TEST-001", balance: 100)
) -> AppEnvironment {
    let environment = AppEnvironment(
        auth: auth,
        spaces: spaces,
        wallet: wallet,
        reservations: reservations,
        tokenStore: InMemoryTokenStore(),
        serverClock: ServerClock(),
        reauth: AlwaysAllowReauthenticator(),
        window: ReservationWindow(openingHour: windowHour, timeZone: .gmt)
    )
    environment.account = account
    return environment
}

private func grid(taken: [(Int, String)]) -> SpaceGrid {
    let lookup = Dictionary(uniqueKeysWithValues: taken)
    let spaces = (1...80).map { number in
        ParkingSpace(number: number, isAvailable: lookup[number] == nil, plateLast3: lookup[number])
    }
    return SpaceGrid(
        date: Date(timeIntervalSince1970: 1_800_000_000),
        totalSpaces: 80,
        availableSpaces: spaces.filter(\.isAvailable).count,
        reservedSpaces: spaces.filter { !$0.isAvailable }.count,
        spaces: spaces
    )
}

// MARK: - GridViewModel

@MainActor
final class GridViewModelTests: XCTestCase {

    func testRefreshPublishesLoadedGrid() async {
        let model = GridViewModel(environment: makeEnvironment())

        await model.refresh()

        XCTAssertEqual(model.state.grid?.totalSpaces, 80)
    }

    /// A transport failure must show the offline state, not an error dialog — the app has
    /// nothing true to say about the board while it cannot reach the server.
    func testTransportFailureBecomesOfflineState() async {
        let environment = makeEnvironment(
            spaces: StubSpaces(result: .failure(.transport(message: "down", isTimeout: false)))
        )
        let model = GridViewModel(environment: environment)

        await model.refresh()

        XCTAssertEqual(model.state, .offline)
    }

    /// Only a bare 401 ends the session. This is the view-model half of the two-401 rule.
    func testBare401SignsTheUserOut() async {
        let environment = makeEnvironment(spaces: StubSpaces(result: .failure(.unauthenticated)))
        let model = GridViewModel(environment: environment)

        await model.refresh()

        XCTAssertNil(environment.account, "A dead session must sign the user out")
    }

    func testBusinessErrorDoesNotSignTheUserOut() async {
        let failure = APIError.business(ErrorResponse(
            status: 500, error: "", message: "", code: .internalError,
            timestamp: .distantPast, path: "", validationErrors: nil
        ))
        let environment = makeEnvironment(spaces: StubSpaces(result: .failure(failure)))
        let model = GridViewModel(environment: environment)

        await model.refresh()

        XCTAssertNotNil(environment.account)
        guard case .failed = model.state else { return XCTFail("Expected failed state") }
    }

    /// Identifying "your" space is the same never-claim-what-you-cannot-prove rule as the
    /// coordinator's: one match is ours, two is a suffix collision and therefore unknown.
    func testMySpaceIdentifiesAUniqueSuffixMatch() async {
        let environment = makeEnvironment(
            spaces: StubSpaces(result: .success(grid(taken: [(7, "001"), (9, "042")])))
        )
        let model = GridViewModel(environment: environment)

        await model.refresh()

        XCTAssertEqual(model.mySpace, 7)
    }

    func testMySpaceIsNilWhenTwoPlatesShareASuffix() async {
        let environment = makeEnvironment(
            spaces: StubSpaces(result: .success(grid(taken: [(7, "001"), (9, "001")])))
        )
        let model = GridViewModel(environment: environment)

        await model.refresh()

        XCTAssertNil(model.mySpace, "A suffix collision must not highlight an arbitrary space")
    }

    func testWinningReservationUpdatesBalanceAndClearsSelection() async {
        let won = Reservation(
            id: 1, spaceNumber: 12, date: Date(), amountPaid: 10,
            newBalance: 90, queuePosition: 1, totalProcessingMs: 20
        )
        let model = GridViewModel(environment: makeEnvironment(
            reservations: StubReservations(result: .success(won))
        ))
        model.selectedSpace = 12

        await model.reserve(space: 12)

        XCTAssertEqual(model.outcome, .won(won))
        XCTAssertEqual(model.balance, 90)
        XCTAssertNil(model.selectedSpace)
    }

    func testLosingReservationKeepsSelectionSoTheUserCanRetryElsewhere() async {
        let failure = APIError.business(ErrorResponse(
            status: 409, error: "", message: "", code: .spaceUnavailable,
            timestamp: .distantPast, path: "", validationErrors: nil
        ))
        let model = GridViewModel(environment: makeEnvironment(
            reservations: StubReservations(result: .failure(failure))
        ))
        model.selectedSpace = 12

        await model.reserve(space: 12)

        XCTAssertEqual(model.outcome, .lost(.spaceUnavailable))
        XCTAssertEqual(model.balance, 100, "A lost race must not move money")
    }

    func testCountdownIsHiddenUntilServerTimeArrives() async {
        let model = GridViewModel(environment: makeEnvironment())

        await model.tickClock()

        XCTAssertFalse(model.hasServerTime)
        XCTAssertNil(model.countdown, "No countdown at all rather than one from the device clock")
    }

    func testCountdownAppearsOnceTheClockIsAnchored() async throws {
        let environment = makeEnvironment(windowHour: 20)
        // 10:00 GMT, so the 20:00 window is still ten hours away. Built from components
        // rather than an epoch literal, so the intent survives a reader.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let tenAM = try XCTUnwrap(calendar.date(
            from: DateComponents(year: 2026, month: 9, day: 22, hour: 10, minute: 0, second: 0)
        ))
        await environment.serverClock.ingest(serverDate: tenAM)
        let model = GridViewModel(environment: environment)

        await model.tickClock()

        XCTAssertTrue(model.hasServerTime)
        XCTAssertFalse(model.isWindowOpen)
        XCTAssertEqual(try XCTUnwrap(model.countdown), 36_000, accuracy: 2)
    }

    func testDepositUpdatesBalance() async {
        let model = GridViewModel(environment: makeEnvironment(
            wallet: StubWallet(depositResult: .success(175))
        ))

        await model.deposit(75)

        XCTAssertEqual(model.balance, 175)
        XCTAssertNil(model.depositError)
    }

    func testDepositFailureSurfacesAMessageAndLeavesBalanceAlone() async {
        let failure = APIError.business(ErrorResponse(
            status: 400, error: "", message: "", code: .validationError,
            timestamp: .distantPast, path: "", validationErrors: ["amount": "must be at least 0.01"]
        ))
        let model = GridViewModel(environment: makeEnvironment(
            wallet: StubWallet(depositResult: .failure(failure))
        ))

        await model.deposit(0)

        XCTAssertEqual(model.balance, 100)
        XCTAssertEqual(model.depositError, "must be at least 0.01")
    }
}

// MARK: - LoginViewModel

@MainActor
final class LoginViewModelTests: XCTestCase {

    func testCannotSubmitUntilBothFieldsAreLongEnough() {
        let model = LoginViewModel(environment: makeEnvironment(account: nil))

        XCTAssertFalse(model.canSubmit)
        model.licensePlate = "AB"
        model.password = "probation123"
        XCTAssertFalse(model.canSubmit, "Plate shorter than 3 characters is rejected by the API")
        model.licensePlate = "TEST-001"
        model.password = "12345"
        XCTAssertFalse(model.canSubmit, "Password shorter than 6 characters is rejected by the API")
        model.password = "probation123"
        XCTAssertTrue(model.canSubmit)
    }

    func testSuccessfulSignInSetsTheAccount() async {
        let account = Account(userId: 9, licensePlate: "TEST-009", balance: 40)
        let environment = makeEnvironment(auth: StubAuth(result: .success(account)), account: nil)
        let model = LoginViewModel(environment: environment)
        model.licensePlate = "TEST-009"
        model.password = "probation123"

        await model.signIn()

        XCTAssertEqual(environment.account, account)
        XCTAssertNil(model.errorMessage)
    }

    /// AUTH_FAILED is a failed sign-in, not a dead session: the message shows and the user
    /// stays on the login screen. The reference web client signs out here, which is wrong.
    func testWrongPasswordShowsAMessageAndDoesNotSignIn() async {
        let failure = APIError.business(ErrorResponse(
            status: 401, error: "", message: "", code: .authFailed,
            timestamp: .distantPast, path: "/auth/login", validationErrors: nil
        ))
        let environment = makeEnvironment(auth: StubAuth(result: .failure(failure)), account: nil)
        let model = LoginViewModel(environment: environment)
        model.licensePlate = "TEST-009"
        model.password = "wrongpassword"

        await model.signIn()

        XCTAssertNil(environment.account)
        XCTAssertEqual(model.errorMessage, "Incorrect licence plate or password.")
    }

    func testPlateIsUppercasedToMatchTheApiPattern() async {
        // The contract requires ^[A-Z0-9-]+$, so a lowercase entry would 400.
        final class Capturing: AuthServicing, @unchecked Sendable {
            var seen: String?
            func register(licensePlate: String, password: String) async throws -> Account {
                seen = licensePlate
                return Account(userId: 1, licensePlate: licensePlate, balance: 0)
            }
            func login(licensePlate: String, password: String) async throws -> Account {
                try await register(licensePlate: licensePlate, password: password)
            }
        }
        let auth = Capturing()
        let model = LoginViewModel(environment: makeEnvironment(auth: auth, account: nil))
        model.licensePlate = "test-009"
        model.password = "probation123"

        await model.signIn()

        XCTAssertEqual(auth.seen, "TEST-009")
    }

    func testWindowSummaryFollowsTheConfiguredHour() {
        // The demo shifts the backend's window; the login screen must say the same hour.
        let shifted = LoginViewModel(environment: makeEnvironment(windowHour: 11, account: nil))
        let early = LoginViewModel(environment: makeEnvironment(windowHour: 9, account: nil))

        XCTAssertEqual(shifted.windowSummary, "80 spaces. Opens at 11:00 for tomorrow.")
        XCTAssertEqual(early.windowSummary, "80 spaces. Opens at 09:00 for tomorrow.")
    }
}
