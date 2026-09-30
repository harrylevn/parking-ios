import XCTest
@testable import Parking

/// Answers requests in-process, so the real `HTTPClient` and services run end to end with no
/// backend: the request is built, sent through `URLSession`, and the reply decoded, exactly as
/// in the app. Each test sets `handler`; every request is recorded for inspection.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        var error: URLError?
    }

    nonisolated(unsafe) static var handler: (URLRequest, Data) -> Reply = { _, _ in Reply(status: 500) }
    nonisolated(unsafe) static var recorded: [(request: URLRequest, body: Data)] = []

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLProtocol receives the body as a stream, not as `httpBody`.
        var body = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            stream.close()
        }
        Self.recorded.append((request, body))
        let reply = Self.handler(request, body)
        if let error = reply.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                             headerFields: reply.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class NetworkLayerTests: XCTestCase {

    private var tokenStore = InMemoryTokenStore()
    private var clock = ServerClock()

    override func setUp() {
        super.setUp()
        StubURLProtocol.recorded = []
        StubURLProtocol.handler = { _, _ in StubURLProtocol.Reply(status: 500) }
        tokenStore = InMemoryTokenStore()
        clock = ServerClock()
    }

    private func client() throws -> HTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return HTTPClient(
            configuration: APIConfiguration(baseURL: try XCTUnwrap(URL(string: "http://localhost:8080"))),
            session: URLSession(configuration: configuration),
            tokenStore: tokenStore,
            serverClock: clock
        )
    }

    private func reply(_ status: Int = 200, json: String, headers: [String: String] = [:]) {
        StubURLProtocol.handler = { _, _ in
            StubURLProtocol.Reply(status: status, headers: headers, body: Data(json.utf8))
        }
    }

    private func errorBody(_ status: Int, _ code: String) -> String {
        #"{"status":\#(status),"error":"x","message":"m","code":"\#(code)","#
            + #""timestamp":"2026-09-30T01:00:00Z","path":"/p"}"#
    }

    private var lastRequest: URLRequest? { StubURLProtocol.recorded.last?.request }
    private var lastBody: [String: Any] {
        let body = StubURLProtocol.recorded.last?.body ?? Data()
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    }

    // MARK: - HTTPClient

    func testTheDateHeaderFeedsTheServerClock() async throws {
        reply(json: #"{"balance":50}"#, headers: ["Date": "Wed, 30 Sep 2026 01:00:00 GMT"])
        _ = try await WalletService(client: try client()).balance()
        let hasReading = await clock.hasReading()
        XCTAssertTrue(hasReading, "every response's Date header is the only server-time source")
    }

    func testAJSONErrorBodyBecomesABusinessError() async throws {
        reply(409, json: errorBody(409, "LOT_FULL"))
        do {
            _ = try await WalletService(client: try client()).balance()
            XCTFail("expected an error")
        } catch let error as APIError {
            XCTAssertEqual(error.businessCode, .lotFull)
        }
    }

    /// The filter chain's 401 has no body: the session is dead. Decoding first would lose that.
    func testABare401MeansTheSessionIsDead() async throws {
        reply(401, json: "")
        do {
            _ = try await WalletService(client: try client()).balance()
            XCTFail("expected an error")
        } catch let error as APIError {
            XCTAssertEqual(error, .unauthenticated)
        }
    }

    func testTransportFailuresAreClassifiedByWhetherTheRequestCanHaveArrived() async throws {
        let cases: [(URLError.Code, TransportFailure)] = [
            (.timedOut, .timedOut), (.cannotConnectToHost, .notSent), (.networkConnectionLost, .interrupted)
        ]
        for (code, expected) in cases {
            StubURLProtocol.handler = { _, _ in StubURLProtocol.Reply(error: URLError(code)) }
            do {
                _ = try await WalletService(client: try client()).balance()
                XCTFail("expected \(code) to fail")
            } catch APIError.transport(_, let failure) {
                XCTAssertEqual(failure, expected, "\(code)")
            }
        }
    }

    func testTheStoredTokenIsSentOnAuthenticatedRequests() async throws {
        try tokenStore.save("session-token")
        reply(json: #"{"balance":50}"#)
        _ = try await WalletService(client: try client()).balance()
        XCTAssertEqual(lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer session-token")
    }

    /// A stale token on sign-in makes the backend answer 401 before the credentials are read,
    /// so the token could never be replaced. Sign-in must not send it.
    func testSignInNeverSendsTheStoredToken() async throws {
        try tokenStore.save("stale-token")
        reply(json: #"{"userId":1,"licensePlate":"TEST-0001","token":"fresh","balance":100}"#)
        _ = try await AuthService(client: try client()).login(licensePlate: "TEST-0001", password: "secret1")
        XCTAssertNil(lastRequest?.value(forHTTPHeaderField: "Authorization"))
    }

    // MARK: - Services

    func testSignInStoresTheNewTokenAndReturnsTheAccount() async throws {
        reply(json: #"{"userId":7,"licensePlate":"TEST-0007","token":"fresh","balance":100.5}"#)
        let auth = AuthService(client: try client())
        let account = try await auth.login(licensePlate: "TEST-0007", password: "secret1")
        let expected = Account(userId: 7, licensePlate: "TEST-0007", balance: Decimal(string: "100.5") ?? 0)
        XCTAssertEqual(account, expected)
        XCTAssertEqual(try tokenStore.read(), "fresh")
        XCTAssertEqual(lastRequest?.url?.path, "/auth/login")
        XCTAssertEqual(lastBody["licensePlate"] as? String, "TEST-0007")
    }

    /// The backend sends a plate on a free space whose booking has passed (D9); the grid must
    /// not carry it.
    func testTheGridMapsSpacesAndDropsAPlateOnAFreeSpace() async throws {
        reply(json: #"""
        {"date":"2026-10-01","totalSpaces":2,"availableSpaces":1,"reservedSpaces":1,
         "spaces":[{"spaceNumber":1,"available":true,"plateLast3":"999"},
                   {"spaceNumber":2,"available":false,"plateLast3":"042"}]}
        """#)
        let grid = try await SpacesService(client: try client()).grid()
        XCTAssertEqual(grid.spaces.map(\.number), [1, 2])
        XCTAssertNil(grid.spaces[0].plateLast3)
        XCTAssertEqual(grid.spaces[1].plateLast3, "042")
        XCTAssertEqual(grid.availableSpaces, 1)
    }

    func testTheBalanceIsReadDefensivelyAndADepositReturnsTheNewBalance() async throws {
        reply(json: #"{"amount":42}"#)  // not the documented key: the first value is taken
        let balance = try await WalletService(client: try client()).balance()
        XCTAssertEqual(balance, 42)

        reply(json: "{}")
        do {
            _ = try await WalletService(client: try client()).balance()
            XCTFail("an empty balance map is malformed")
        } catch let error as APIError {
            guard case .malformedResponse = error else { return XCTFail("\(error)") }
        }

        reply(json: #"{"newBalance":150,"depositedAmount":50}"#)
        let newBalance = try await WalletService(client: try client()).deposit(amount: 50)
        XCTAssertEqual(newBalance, 150)
        XCTAssertEqual(lastBody["amount"] as? Int, 50)
    }

    func testAReservationCarriesItsIdempotencyKeyAndMapsTheReceipt() async throws {
        reply(json: #"""
        {"reservationId":9,"spaceNumber":12,"reservationDate":"2026-10-01","amountPaid":10,
         "newBalance":90,"queuePosition":3,"lockWaitMs":1,"totalProcessingMs":40}
        """#)
        let key = UUID()
        let service = ReservationService(client: try client())
        let reservation = try await service.reserve(preferredSpace: 12, idempotencyKey: key)

        XCTAssertEqual(lastRequest?.value(forHTTPHeaderField: "Idempotency-Key"), key.uuidString)
        XCTAssertEqual(lastRequest?.timeoutInterval, APIConfiguration.localBackend.reservationTimeout)
        XCTAssertEqual(lastBody["preferredSpaceNumber"] as? Int, 12)
        XCTAssertEqual(reservation.spaceNumber, 12)
        XCTAssertEqual(reservation.newBalance, 90)
        XCTAssertEqual(reservation.queuePosition, 3)
    }

    /// "Any space" sends no preferred space at all.
    func testReservingAnySpaceSendsNoPreferredSpace() async throws {
        reply(json: #"""
        {"reservationId":9,"spaceNumber":1,"reservationDate":"2026-10-01","amountPaid":10,"newBalance":90}
        """#)
        let service = ReservationService(client: try client())
        _ = try await service.reserve(preferredSpace: nil, idempotencyKey: UUID())
        XCTAssertNil(lastBody["preferredSpaceNumber"] as? Int)
    }

    func testTheReadBackReturnsAReservationWithNoBalance() async throws {
        reply(json: #"{"reservationId":9,"spaceNumber":12,"reservationDate":"2026-10-01","amountPaid":10}"#)
        let held = try await ReservationService(client: try client()).mine()
        XCTAssertEqual(held?.spaceNumber, 12)
        XCTAssertNil(held?.newBalance, "the read-back carries no balance; the caller asks the wallet")
        XCTAssertEqual(lastRequest?.url?.path, "/reservations/me")
    }

    /// Nothing committed is an answer, not an error; any other failure still is one.
    func testNotFoundIsNilButOtherReadBackFailuresAreErrors() async throws {
        reply(404, json: errorBody(404, "RESERVATION_NOT_FOUND"))
        let none = try await ReservationService(client: try client()).mine()
        XCTAssertNil(none)

        reply(500, json: errorBody(500, "INTERNAL_ERROR"))
        do {
            _ = try await ReservationService(client: try client()).mine()
            XCTFail("a server error is not 'nothing reserved'")
        } catch let error as APIError {
            XCTAssertEqual(error.businessCode, .internalError)
        }
    }
}
