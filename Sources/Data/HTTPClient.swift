import Foundation

struct APIConfiguration: Sendable {
    var baseURL: URL
    /// Comfortably above the measured p99 under 1000-VU load (368 ms, max 867 ms).
    /// Set too low, this manufactures timeouts — and a timeout on a reservation is a
    /// correctness problem here, not a latency one, because the outcome becomes unknown.
    var requestTimeout: TimeInterval = 10
    var reservationTimeout: TimeInterval = 3

    static let localBackend: APIConfiguration = {
        // A literal that cannot fail to parse, but `!` is banned outside fixtures (CLAUDE.md
        // gate 4). The explicit trap says what went wrong if someone edits it badly, and
        // `testLocalBackendURLParses` fails in CI before any build could ship with it.
        guard let url = URL(string: "http://localhost:8080") else {
            preconditionFailure("localBackend base URL literal is malformed")
        }
        return APIConfiguration(baseURL: url)
    }()
}

/// Thin async/await HTTP layer. No completion handlers, no semaphores.
///
/// Its whole reason for existing is `decode`: the backend answers with **two different
/// shapes**, and treating them as one is the crash this layer prevents.
struct HTTPClient: Sendable {
    let configuration: APIConfiguration
    let session: URLSession
    let tokenStore: TokenStoring
    let serverClock: ServerClock

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = ISO8601DateFormatter.withFractionalSeconds.date(from: raw) { return date }
            if let date = ISO8601DateFormatter.plain.date(from: raw) { return date }
            // `reservationDate` is a bare yyyy-MM-dd, not ISO 8601.
            if let date = DateFormatter.yearMonthDay.date(from: raw) { return date }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unrecognised date: \(raw)"
            )
        }
        return decoder
    }()

    func get<Response: Decodable & Sendable>(
        _ path: String, as type: Response.Type = Response.self
    ) async throws -> Response {
        try await send(request(path, method: "GET"), as: type)
    }

    func post<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        _ path: String,
        body: Body,
        timeout: TimeInterval? = nil,
        authenticated: Bool = true,
        as type: Response.Type = Response.self
    ) async throws -> Response {
        var request = request(path, method: "POST", authenticated: authenticated)
        request.httpBody = try JSONEncoder().encode(body)
        if let timeout { request.timeoutInterval = timeout }
        return try await send(request, as: type)
    }

    /// A Keychain read can fail (locked device, corrupted item); an unauthenticated
    /// request is the right fallback, because the server answers it with a bare 401
    /// that the client already knows how to handle.
    private var currentToken: String? {
        guard let token = try? tokenStore.read() else { return nil }
        return token
    }

    /// Pass `authenticated: false` for the sign-in endpoints, and mean it.
    ///
    /// `/auth/**` is `permitAll` on the backend, but permitAll only means *authentication is
    /// not required* — it does not mean a token present in the request is ignored. Spring's
    /// bearer-token filter runs whenever an `Authorization` header exists and rejects a token
    /// it cannot verify with a bare 401, before the authorisation rules are consulted.
    ///
    /// So attaching a stale Keychain token to sign-in wedges the app permanently: register
    /// and login both answer 401, which means the dead token can never be replaced by a live
    /// one. Verified against the running backend — `POST /auth/register` returns 201 with no
    /// header and 401 with a bad one.
    ///
    /// Internal rather than private so `HTTPClientRequestTests` can assert the header is
    /// absent; there is no URLProtocol stub in this suite to observe it through `send`.
    func request(_ path: String, method: String, authenticated: Bool = true) -> URLRequest {
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = configuration.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authenticated, let token = currentToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func send<Response: Decodable & Sendable>(
        _ request: URLRequest, as type: Response.Type
    ) async throws -> Response {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw APIError.transport(
                message: error.localizedDescription,
                failure: Self.transportFailure(for: error.code)
            )
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.malformedResponse("Response was not HTTP")
        }

        // Every response carries a Date header; it is the only server-time source there is.
        if let raw = http.value(forHTTPHeaderField: "Date"),
           let serverDate = DateFormatter.rfc1123.date(from: raw) {
            await serverClock.ingest(serverDate: serverDate)
        }

        guard (200..<300).contains(http.statusCode) else {
            throw Self.decodeFailure(status: http.statusCode, data: data)
        }

        do {
            return try Self.decoder.decode(Response.self, from: data)
        } catch {
            throw APIError.malformedResponse("Could not decode \(Response.self): \(error)")
        }
    }

    /// Classify a URLError by whether the request can have reached the server.
    ///
    /// An allowlist of provably-unsent codes, with everything else treated as interrupted.
    /// The asymmetry is deliberate: misclassifying an unsent request as interrupted costs one
    /// reconciliation and an honest "we're not sure"; the reverse tells a user who may have
    /// just paid $10 that the reservation failed.
    static func transportFailure(for code: URLError.Code) -> TransportFailure {
        switch code {
        case .timedOut:
            return .timedOut
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet,
             .dataNotAllowed, .internationalRoamingOff, .badURL, .unsupportedURL,
             .appTransportSecurityRequiresSecureConnection:
            return .notSent
        default:
            return .interrupted
        }
    }

    /// Turn a non-2xx into the right `APIError`.
    ///
    /// The ordering matters. A bare 401 from the Spring Security filter chain has an **empty
    /// body** — attempting to decode it first would throw a decoding error and lose the fact
    /// that the session is dead. A 401 from `/auth/login` with bad credentials, by contrast,
    /// carries a full JSON body with `AUTH_FAILED` and must *not* be treated as a dead session.
    /// So: branch on emptiness, not on status.
    static func decodeFailure(status: Int, data: Data) -> APIError {
        guard !data.isEmpty else {
            return status == 401
                ? .unauthenticated
                : .malformedResponse("HTTP \(status) with an empty body")
        }
        if let response = try? decoder.decode(ErrorResponse.self, from: data) {
            return .business(response)
        }
        return .malformedResponse("HTTP \(status) with an unrecognised body")
    }
}

// `ISO8601DateFormatter` is not marked `Sendable`, but Foundation documents its
// formatting and parsing methods as thread-safe on Apple platforms, and neither
// instance below is mutated after construction. Creating one per parse instead would
// cost far more than it buys: date decoding sits on the reservation hot path.
extension ISO8601DateFormatter {
    nonisolated(unsafe) static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) static let plain = ISO8601DateFormatter()
}

extension DateFormatter {
    static let yearMonthDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// RFC 1123, as used by the HTTP `Date` header. Fixed locale so a user's regional
    /// settings cannot break time parsing.
    static let rfc1123: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
}
