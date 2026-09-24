import XCTest
@testable import Parking

/// The two response shapes are the crash this layer exists to prevent, so they are
/// tested against bytes captured from the running backend rather than invented.
final class ErrorDecodingTests: XCTestCase {

    func testBare401IsUnauthenticatedNotADecodingFailure() {
        // Captured: HTTP/1.1 401, WWW-Authenticate: Bearer, Content-Length: 0.
        let error = HTTPClient.decodeFailure(status: 401, data: Data())
        XCTAssertEqual(error, .unauthenticated)
        XCTAssertTrue(error.requiresReauthentication)
    }

    func testAuthFailed401CarriesJSONAndIsNotASessionExpiry() throws {
        let body = Data("""
        {"status":401,"error":"Unauthorized","message":"Invalid license plate or password",
        "code":"AUTH_FAILED","timestamp":"2026-09-21T08:48:53.431522Z","path":"/auth/login"}
        """.utf8)

        let error = HTTPClient.decodeFailure(status: 401, data: body)

        XCTAssertEqual(error.businessCode, .authFailed)
        // The distinction that matters: a wrong password must not sign the user out.
        XCTAssertFalse(error.requiresReauthentication)
    }

    func testWindowClosedArrivesAs429AndIsNotRetryable() throws {
        // 429 would be auto-retried by any conventional transport backoff policy.
        let body = Data("""
        {"status":429,"error":"Too Many Requests","message":"Reservation window opens at 20:00.",
        "code":"WINDOW_CLOSED","timestamp":"2026-09-21T08:46:24.662790Z","path":"/reservations"}
        """.utf8)

        let error = HTTPClient.decodeFailure(status: 429, data: body)

        XCTAssertEqual(error.businessCode, .windowClosed)
        XCTAssertFalse(error.isSafelyRetryable)
    }

    func testValidationErrorCarriesFieldMap() throws {
        let body = Data("""
        {"status":400,"error":"Bad Request","message":"Validation failed","code":"VALIDATION_ERROR",
        "timestamp":"2026-09-21T08:47:20.086530Z","path":"/reservations",
        "validationErrors":{"preferredSpaceNumber":"Space number must be between 1 and 80"}}
        """.utf8)

        let error = HTTPClient.decodeFailure(status: 400, data: body)

        guard case .business(let response) = error else { return XCTFail("Expected business error") }
        XCTAssertEqual(response.validationErrors?["preferredSpaceNumber"],
                       "Space number must be between 1 and 80")
    }

    func testNonEmptyUnrecognisedBodyIsMalformedNotSilentlySwallowed() {
        let error = HTTPClient.decodeFailure(status: 500, data: Data("<html>oops</html>".utf8))
        guard case .malformedResponse = error else {
            return XCTFail("Expected malformedResponse, got \(error)")
        }
    }

    func testEmptyNon401BodyIsMalformedRatherThanUnauthenticated() {
        let error = HTTPClient.decodeFailure(status: 502, data: Data())
        guard case .malformedResponse = error else {
            return XCTFail("Expected malformedResponse, got \(error)")
        }
    }
}

/// The sign-in endpoints must go out **without** the stored token.
///
/// `/auth/**` is `permitAll` on the backend, but a token that is present and unverifiable is
/// rejected by the bearer-token filter with a bare 401 before authorisation is consulted. A
/// stale Keychain token therefore breaks registration and login together, which leaves no way
/// to replace it — the app is wedged until its Keychain item is cleared by hand.
final class HTTPClientRequestTests: XCTestCase {

    private func makeClient(storing token: String?) throws -> HTTPClient {
        let store = InMemoryTokenStore()
        if let token { try store.save(token) }
        return HTTPClient(
            configuration: .localBackend,
            session: .shared,
            tokenStore: store,
            serverClock: ServerClock()
        )
    }

    func testAuthEndpointsGoOutWithoutTheStoredToken() throws {
        let client = try makeClient(storing: "a.stale.token")

        let register = client.request("auth/register", method: "POST", authenticated: false)
        let login = client.request("auth/login", method: "POST", authenticated: false)

        XCTAssertNil(register.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(login.value(forHTTPHeaderField: "Authorization"))
    }

    func testEveryOtherRequestStillCarriesTheToken() throws {
        let client = try makeClient(storing: "a.live.token")

        let spaces = client.request("spaces", method: "GET")

        XCTAssertEqual(spaces.value(forHTTPHeaderField: "Authorization"), "Bearer a.live.token")
    }

    func testNoTokenMeansNoHeaderRatherThanAnEmptyOne() throws {
        let client = try makeClient(storing: nil)

        XCTAssertNil(client.request("spaces", method: "GET").value(forHTTPHeaderField: "Authorization"))
    }
}

extension ErrorDecodingTests {
    /// Registering a plate that already exists. An unknown `code` makes the whole body fail to
    /// decode, so a missing case does not degrade gracefully — it discards the message too.
    func testDuplicateResourceDecodesRatherThanFallingBackToMalformed() {
        let body = Data("""
        {"status":409,"error":"Conflict","message":"License plate already registered: TEST-001",
        "code":"DUPLICATE_RESOURCE","timestamp":"2026-09-23T07:47:05.664144Z","path":"/auth/register"}
        """.utf8)

        let error = HTTPClient.decodeFailure(status: 409, data: body)

        XCTAssertEqual(error.businessCode, .duplicateResource)
        XCTAssertFalse(error.requiresReauthentication)
    }
}

/// Transport failures are classified by whether the request can have reached the server,
/// because that — not "was it a timeout" — decides whether a reservation outcome is unknown.
final class TransportFailureTests: XCTestCase {

    /// The backend killed mid-request. The case that used to be misread as a plain failure.
    func testDroppedConnectionIsInterruptedNotUnsent() {
        XCTAssertEqual(HTTPClient.transportFailure(for: .networkConnectionLost), .interrupted)
    }

    func testTimeoutIsItsOwnCase() {
        XCTAssertEqual(HTTPClient.transportFailure(for: .timedOut), .timedOut)
    }

    /// The backend already down before the tap: nothing left the device.
    func testRefusedConnectionIsUnsent() {
        XCTAssertEqual(HTTPClient.transportFailure(for: .cannotConnectToHost), .notSent)
        XCTAssertEqual(HTTPClient.transportFailure(for: .notConnectedToInternet), .notSent)
    }

    /// Anything not on the provably-unsent allowlist must be treated as possibly delivered.
    func testUnlistedCodeDefaultsToInterrupted() {
        XCTAssertEqual(HTTPClient.transportFailure(for: .badServerResponse), .interrupted)
    }

    func testOnlyAnUnsentRequestIsSafelyRetryable() {
        XCTAssertTrue(APIError.transport(message: "", failure: .notSent).isSafelyRetryable)
        XCTAssertFalse(APIError.transport(message: "", failure: .interrupted).isSafelyRetryable)
        XCTAssertFalse(APIError.transport(message: "", failure: .timedOut).isSafelyRetryable)
    }

    func testLocalBackendURLParses() {
        XCTAssertEqual(APIConfiguration.localBackend.baseURL.absoluteString, "http://localhost:8080")
    }
}
