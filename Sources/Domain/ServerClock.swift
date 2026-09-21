import Foundation

/// Authoritative time for the 20:00 window, derived from the server rather than the device.
///
/// The backend exposes **no time endpoint**, so the only server-time signal available is the
/// `Date` response header, which every response carries. `ServerClock` anchors that reading to
/// a `ContinuousClock` instant and extrapolates forward, so the countdown survives the user
/// changing the device clock — the obvious way to cheat a client-side countdown.
///
/// Two limits are deliberate and documented rather than hidden:
///  * `Date` is RFC 1123 with **one-second** granularity, so the countdown never claims
///    sub-second precision.
///  * The reading includes one network leg of latency, so server time is skewed *late* by
///    up to a round trip. Under the measured 1000-VU load that is p99 ≈ 368 ms.
actor ServerClock {
    private struct Anchor {
        let serverTime: Date
        let observedAt: ContinuousClock.Instant
        let deviceTime: Date
    }

    /// Skew beyond this is surfaced to the user rather than silently absorbed.
    static let skewWarningThreshold: TimeInterval = 30

    private var anchor: Anchor?
    private let clock = ContinuousClock()

    /// Feed in the `Date` header of any response. Latest reading wins.
    func ingest(serverDate: Date, deviceDate: Date = Date()) {
        anchor = Anchor(serverTime: serverDate, observedAt: clock.now, deviceTime: deviceDate)
    }

    /// Best estimate of current server time, or `nil` before any response has been seen.
    func now() -> Date? {
        guard let anchor else { return nil }
        let elapsed = anchor.observedAt.duration(to: clock.now)
        return anchor.serverTime.addingTimeInterval(elapsed.timeInterval)
    }

    /// How far the device clock sits from the server's, positive when the device runs fast.
    func skew() -> TimeInterval? {
        guard let anchor else { return nil }
        return anchor.deviceTime.timeIntervalSince(anchor.serverTime)
    }

    func isSkewSignificant() -> Bool {
        guard let skew = skew() else { return false }
        return abs(skew) > Self.skewWarningThreshold
    }

    /// Whether the clock has ever been anchored. Until it has, the UI must not show a
    /// countdown at all rather than fall back to the device clock.
    func hasReading() -> Bool { anchor != nil }
}

extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) * 1e-18
    }
}

/// Where the reservation window sits relative to a given instant.
///
/// The hour is configuration, never a hardcoded 20: the brief requires the demo to run with
/// `app.reservation.window-hour` shifted. The time zone is configuration for a worse reason —
/// the backend gates on `LocalTime.now()` in the **JVM default zone** and exposes no way to
/// discover it, so the client cannot derive it and must be told. Logged in docs/defects.md.
struct ReservationWindow: Equatable, Sendable {
    let openingHour: Int
    let timeZone: TimeZone

    init(openingHour: Int = 20, timeZone: TimeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh") ?? .current) {
        self.openingHour = openingHour
        self.timeZone = timeZone
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// The backend's gate is `LocalTime.now().getHour() < windowHour`, with **no upper
    /// bound** — so the window runs from the top of `openingHour` until midnight, when
    /// `LocalDate.now().plusDays(1)` rolls over and it shuts. Modelled exactly, because a
    /// client that assumes a 24-hour window would show "open" for the hours it is shut.
    func isOpen(at instant: Date) -> Bool {
        calendar.component(.hour, from: instant) >= openingHour
    }

    /// The next instant the window opens, at or after `instant`.
    func nextOpening(after instant: Date) -> Date? {
        guard let todaysOpening = calendar.date(
            bySettingHour: openingHour, minute: 0, second: 0, of: instant
        ) else { return nil }

        if todaysOpening > instant { return todaysOpening }
        if isOpen(at: instant) { return todaysOpening }
        return calendar.date(byAdding: .day, value: 1, to: todaysOpening)
    }

    /// Time until the window opens; zero when it is already open.
    func timeUntilOpening(from instant: Date) -> TimeInterval? {
        if isOpen(at: instant) { return 0 }
        guard let next = nextOpening(after: instant) else { return nil }
        return max(0, next.timeIntervalSince(instant))
    }
}
