import Foundation

/// Where the countdown sits relative to the opening, in the terms the interface changes on.
///
/// The thresholds are about what a person can still do, not about drama. A minute is enough
/// to pick a space and have the confirm bar waiting under a thumb; ten seconds is not enough
/// to start doing that, so the copy stops suggesting it and just says the window is close.
enum CountdownPhase: Equatable {
    /// No server reading yet, so nothing may be claimed about the window at all.
    case waiting
    /// More than a minute out.
    case early
    /// The last minute: time to pick a space before the opening.
    case finalMinute
    /// The last ten seconds.
    case finalSeconds
    case open

    static let finalMinuteThreshold: TimeInterval = 60
    static let finalSecondsThreshold: TimeInterval = 10

    init(countdown: TimeInterval?, isOpen: Bool, hasServerTime: Bool) {
        guard hasServerTime else { self = .waiting; return }
        if isOpen { self = .open; return }
        // A reading with no countdown means the next opening could not be computed, which
        // is not grounds to hurry anyone.
        guard let countdown else { self = .early; return }
        if countdown <= Self.finalSecondsThreshold {
            self = .finalSeconds
        } else if countdown <= Self.finalMinuteThreshold {
            self = .finalMinute
        } else {
            self = .early
        }
    }

    /// Spoken once on entering the phase, so a VoiceOver user is not left polling the
    /// countdown by ear. `nil` for phases nobody needs interrupting for.
    var announcement: String? {
        switch self {
        case .finalMinute: return String(localized: "One minute until reservations open.")
        case .finalSeconds: return String(localized: "Ten seconds until reservations open.")
        case .open: return String(localized: "Reservations are open.")
        case .waiting, .early: return nil
        }
    }
}
