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
