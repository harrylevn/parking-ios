import Foundation

/// The backend's business error codes, as observed against the running service.
///
/// Classification is on `code`, never on HTTP status. Two statuses make that
/// essential: `WINDOW_CLOSED` arrives as **429**, which a conventional
/// transport-level retry policy would happily retry, and `AUTH_FAILED` arrives
/// as **401**, which a conventional session policy would treat as an expired
/// session and sign the user out mid-login.
enum BusinessErrorCode: String, Decodable, Sendable {
    case spaceUnavailable = "SPACE_UNAVAILABLE"
    case alreadyReserved = "ALREADY_RESERVED"
    case alreadyQueued = "ALREADY_QUEUED"
    case duplicateRequest = "DUPLICATE_REQUEST"
    case insufficientBalance = "INSUFFICIENT_BALANCE"
    case windowClosed = "WINDOW_CLOSED"
    case authFailed = "AUTH_FAILED"
    case validationError = "VALIDATION_ERROR"
    case lotFull = "LOT_FULL"
    case lockTimeout = "LOCK_TIMEOUT"
    case internalError = "INTERNAL_ERROR"
}

/// The JSON error body. `validationErrors` is present only on a 400.
struct ErrorResponse: Decodable, Sendable, Equatable {
    let status: Int
    let error: String
    let message: String
    let code: BusinessErrorCode
    let timestamp: Date
    let path: String
    let validationErrors: [String: String]?
}

/// Every way a call can fail, as the client must distinguish them.
enum APIError: Error, Sendable, Equatable {
    /// A decoded `ErrorResponse` body.
    case business(ErrorResponse)

    /// A bare 401: empty body, `WWW-Authenticate: Bearer`, no code. Emitted by the
    /// Spring Security filter chain for a missing, malformed or expired token —
    /// it never reaches the controller advice, so there is no JSON to decode.
    /// This, and only this, means "the session is dead".
    case unauthenticated

    /// Transport failed. `isTimeout` matters: after a timeout on a reservation the
    /// outcome is genuinely unknown and must be reconciled, never blindly retried.
    case transport(message: String, isTimeout: Bool)

    /// A 2xx body that did not decode, or a non-2xx with an unrecognised shape.
    case malformedResponse(String)

    var businessCode: BusinessErrorCode? {
        if case let .business(response) = self { return response.code }
        return nil
    }

    /// True only for a genuinely dead session. A wrong password is `AUTH_FAILED`,
    /// which is a failed sign-in attempt, not an expired session — signing the user
    /// out on it (as the reference web client does) is wrong.
    var requiresReauthentication: Bool {
        self == .unauthenticated
    }

    /// Whether retrying the identical request is safe and could succeed.
    ///
    /// Deliberately false for `windowClosed` despite its 429: the window opens on a
    /// clock, not on backoff, and hammering it is both useless and rude.
    var isSafelyRetryable: Bool {
        switch self {
        case .transport(_, let isTimeout):
            // A timeout on a *mutating* call is not retryable; the caller decides,
            // because only the caller knows whether the request had side effects.
            return !isTimeout
        case .business(let response):
            return response.code == .lockTimeout
        case .unauthenticated, .malformedResponse:
            return false
        }
    }
}
