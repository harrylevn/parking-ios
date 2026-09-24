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
    /// Registration only: the plate already has an account. Absent from this enum until a
    /// registration screen existed to hit it, and its absence was not harmless — an unknown
    /// code fails to decode, so the whole `ErrorResponse` was discarded and a duplicate plate
    /// surfaced as "the server sent something we couldn't read".
    case duplicateResource = "DUPLICATE_RESOURCE"
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

/// Whether a failed request could have reached the server.
///
/// A timeout is not the only indeterminate failure. Killing the backend mid-request closes
/// its socket, and URLSession reports that at once as `networkConnectionLost` — the request
/// may already have been committed, exactly as after a timeout. So the question the client
/// needs answered is not "did it time out" but "can it have arrived".
enum TransportFailure: Sendable, Equatable {
    /// Failed before the request left the device (no route, host unreachable). Nothing
    /// can have happened server-side.
    case notSent
    case timedOut
    /// Failed after the request may have been sent: the connection dropped mid-flight.
    case interrupted
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

    /// Transport failed. `failure` matters: unless the request provably never left the
    /// device, the outcome of a reservation is genuinely unknown and must be reconciled,
    /// never blindly retried.
    case transport(message: String, failure: TransportFailure)

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
        case .transport(_, let failure):
            // Only a request that never left the device is safe to repeat. An interrupted
            // one may have been processed, so for a mutating call a retry could double-act.
            return failure == .notSent
        case .business(let response):
            return response.code == .lockTimeout
        case .unauthenticated, .malformedResponse:
            return false
        }
    }
}
