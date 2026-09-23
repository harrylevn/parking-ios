import Foundation

// MARK: - Wire types
// Kept separate from the domain models so a contract change does not ripple into the UI.

private struct AuthRequestDTO: Encodable, Sendable {
    let licensePlate: String
    let password: String
}

private struct AuthResponseDTO: Decodable, Sendable {
    let userId: Int64
    let licensePlate: String
    let token: String
    let balance: Decimal
}

private struct DepositRequestDTO: Encodable, Sendable {
    let amount: Decimal
}

private struct DepositResponseDTO: Decodable, Sendable {
    let newBalance: Decimal
    let depositedAmount: Decimal
}

private struct ReservationRequestDTO: Encodable, Sendable {
    let preferredSpaceNumber: Int?
}

private struct ReservationResponseDTO: Decodable, Sendable {
    let reservationId: Int64
    let spaceNumber: Int
    let reservationDate: Date
    let amountPaid: Decimal
    let newBalance: Decimal
    let queuePosition: Int64?
    let totalProcessingMs: Int64?
}

private struct SpaceDTO: Decodable, Sendable {
    let spaceNumber: Int
    let available: Bool
    let plateLast3: String?
}

private struct SpacesResponseDTO: Decodable, Sendable {
    let date: Date
    let totalSpaces: Int
    let availableSpaces: Int
    let reservedSpaces: Int
    let spaces: [SpaceDTO]
}

// MARK: - Services

struct AuthService: AuthServicing {
    let client: HTTPClient

    func register(licensePlate: String, password: String) async throws -> Account {
        try await authenticate(path: "auth/register", licensePlate: licensePlate, password: password)
    }

    func login(licensePlate: String, password: String) async throws -> Account {
        try await authenticate(path: "auth/login", licensePlate: licensePlate, password: password)
    }

    private func authenticate(path: String, licensePlate: String, password: String) async throws -> Account {
        // Never send the stored token here: a stale one makes the backend reject sign-in
        // itself, so the token could never be replaced. See `HTTPClient.request`.
        let response: AuthResponseDTO = try await client.post(
            path, body: AuthRequestDTO(licensePlate: licensePlate, password: password),
            authenticated: false
        )
        try client.tokenStore.save(response.token)
        return Account(
            userId: response.userId, licensePlate: response.licensePlate, balance: response.balance
        )
    }
}

struct SpacesService: SpacesServicing {
    let client: HTTPClient

    func grid() async throws -> SpaceGrid {
        let response: SpacesResponseDTO = try await client.get("spaces")
        return SpaceGrid(
            date: response.date,
            totalSpaces: response.totalSpaces,
            availableSpaces: response.availableSpaces,
            reservedSpaces: response.reservedSpaces,
            spaces: response.spaces.map {
                ParkingSpace(number: $0.spaceNumber, isAvailable: $0.available, plateLast3: $0.plateLast3)
            }
        )
    }
}

struct WalletService: WalletServicing {
    let client: HTTPClient

    func balance() async throws -> Decimal {
        // The contract types this as a free-form map rather than a named schema,
        // so the key is read defensively. Logged in docs/defects.md.
        let response: [String: Decimal] = try await client.get("wallet/balance")
        guard let balance = response["balance"] ?? response.values.first else {
            throw APIError.malformedResponse("No balance in wallet response")
        }
        return balance
    }

    func deposit(amount: Decimal) async throws -> Decimal {
        let response: DepositResponseDTO = try await client.post(
            "wallet/deposit", body: DepositRequestDTO(amount: amount)
        )
        return response.newBalance
    }
}

struct ReservationService: ReservationServicing {
    let client: HTTPClient

    func reserve(preferredSpace: Int?) async throws -> Reservation {
        let response: ReservationResponseDTO = try await client.post(
            "reservations",
            body: ReservationRequestDTO(preferredSpaceNumber: preferredSpace),
            timeout: client.configuration.reservationTimeout
        )
        return Reservation(
            id: response.reservationId,
            spaceNumber: response.spaceNumber,
            date: response.reservationDate,
            amountPaid: response.amountPaid,
            newBalance: response.newBalance,
            queuePosition: response.queuePosition,
            totalProcessingMs: response.totalProcessingMs
        )
    }
}
