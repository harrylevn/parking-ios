import XCTest
@testable import Parking

// Shared fakes and builders for the view-model tests. Extracted from ViewModelTests when a
// second test file needed them — and because that file had grown past the 400-line lint limit.

struct StubAuth: AuthServicing {
    var result: Result<Account, APIError>
    func register(licensePlate: String, password: String) async throws -> Account {
        try result.get()
    }
    func login(licensePlate: String, password: String) async throws -> Account {
        try result.get()
    }
}

struct StubSpaces: SpacesServicing {
    var result: Result<SpaceGrid, APIError>
    func grid() async throws -> SpaceGrid { try result.get() }
}

struct StubWallet: WalletServicing {
    var balanceResult: Result<Decimal, APIError> = .success(100)
    var depositResult: Result<Decimal, APIError> = .success(150)
    func balance() async throws -> Decimal { try balanceResult.get() }
    func deposit(amount: Decimal) async throws -> Decimal { try depositResult.get() }
}

struct StubReservations: ReservationServicing {
    var result: Result<Reservation, APIError>
    func reserve(preferredSpace: Int?) async throws -> Reservation { try result.get() }
}

@MainActor
func makeEnvironment(
    auth: AuthServicing = StubAuth(
        result: .success(Account(userId: 1, licensePlate: "TEST-001", balance: 100))
    ),
    spaces: SpacesServicing = StubSpaces(result: .success(grid(taken: []))),
    wallet: WalletServicing = StubWallet(),
    reservations: ReservationServicing = StubReservations(result: .failure(.unauthenticated)),
    reauth: Reauthenticating = AlwaysAllowReauthenticator(),
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
        reauth: reauth,
        window: ReservationWindow(openingHour: windowHour, timeZone: .gmt)
    )
    environment.account = account
    return environment
}

func grid(taken: [(Int, String)]) -> SpaceGrid {
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
