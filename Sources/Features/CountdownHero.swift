import SwiftUI

/// The 20:00 moment.
///
/// Before the window opens this is the largest thing on screen, because until it opens there
/// is nothing else worth doing. It collapses to a slim banner the instant reservations open,
/// handing the screen back to the board.
///
/// It renders nothing at all until `ServerClock` has a reading. A countdown sourced from the
/// device clock would be both wrong and trivially cheatable, and a wrong countdown on a race
/// is worse than no countdown.
struct CountdownHero: View {
    let countdown: TimeInterval?
    let isOpen: Bool
    let hasServerTime: Bool
    let isSkewed: Bool
    /// `nil` when there is no board to count from (loading, offline, error). Deliberately not
    /// defaulted to 0: that rendered "No spaces left for tomorrow" while the server was
    /// unreachable, stating the lot was full when the app had no idea.
    let availableSpaces: Int?
    /// Seconds since the count above was fetched, once that is long enough to matter; see
    /// `GridViewModel.staleGridAge`.
    var staleGridAge: Int?
    /// The server has contradicted this app's opening hour. Replaces the "open" banner rather
    /// than sitting beside it: the app must stop asserting a state the server just denied.
    var isHourMismatched: Bool = false
    /// Collapses the hero to a slim banner once the window is open, handing the screen back
    /// to the board — which is what the 6.3 guardrail needs the space for.
    var isCompact: Bool = false
    /// False when the hero shares a card with the stat strip.
    var isFramed: Bool = true

    private var phase: CountdownPhase {
        CountdownPhase(countdown: countdown, isOpen: isOpen, hasServerTime: hasServerTime)
    }

    /// The last ten seconds take the accent. Colour is a second channel, never the only one:
    /// the words change too, and VoiceOver is told separately.
    private var clockTint: Color {
        phase == .finalSeconds ? Theme.Palette.accent : Theme.Palette.ink
    }

    var body: some View {
        VStack(spacing: 12) {
            if isSkewed {
                Label(
                    "Your device clock is over 30 seconds off the server. The countdown follows the server.",
                    systemImage: "clock.badge.exclamationmark.fill"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.Palette.warning)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
            }

            if !hasServerTime {
                waiting
            } else if isOpen, isHourMismatched {
                mismatchBanner
            } else if isOpen {
                openBanner
            } else if isCompact {
                compactCountdown
            } else {
                closedHero
            }
        }
        .frame(maxWidth: .infinity)
        .modifier(HeroChrome(isFramed: isFramed))
    }

    private var waiting: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Checking server time…")
                .font(.subheadline)
                .foregroundStyle(Theme.Palette.inkMuted)
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("grid.awaitingServerTime")
    }

    private var openBanner: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Theme.Palette.available.opacity(0.18))
                    .frame(width: 30, height: 30)
                Circle()
                    .fill(Theme.Palette.available)
                    .frame(width: 9, height: 9)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("Reservations are open")
                    .font(.headline)
                    .foregroundStyle(Theme.Palette.ink)
                if let availableSpaces {
                    Text(spacesLine(availableSpaces))
                        .font(.caption)
                        .foregroundStyle(Theme.Palette.inkMuted)
                        .contentTransition(.numericText())
                }
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("grid.windowOpen")
    }

    /// The count is the last poll's, never a live figure, and it says so. Once polls stop
    /// landing it carries its age, because under a 20:00 race a number that was true ten
    /// seconds ago is a claim about a lot that no longer exists. A full lot needs no
    /// qualifier: spaces are not handed back once taken.
    private func spacesLine(_ available: Int) -> String {
        if available == 0 { return String(localized: "No spaces left for tomorrow") }
        if let staleGridAge {
            return String(localized: "\(available) free as of \(staleGridAge)s ago")
        }
        return String(localized: "\(available) free at last check")
    }

    /// Short enough to share one line with the clock in the compact layout — that row's
    /// height is part of what the 6.1-inch board is measured against, so the phases change
    /// the words and never the line count.
    private var compactLead: String {
        switch phase {
        case .finalMinute: return String(localized: "Pick a space · opens in")
        case .finalSeconds: return String(localized: "Opening in")
        default: return String(localized: "Opens in")
        }
    }

    private var heroLead: String {
        switch phase {
        case .finalMinute: return String(localized: "Pick a space now. Reservations open in")
        case .finalSeconds: return String(localized: "Get ready. Reservations open in")
        default: return String(localized: "Reservations open in")
        }
    }

    private var mismatchBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(Theme.Palette.warning)

            VStack(alignment: .leading, spacing: 2) {
                Text("The server says reservations aren't open yet")
                    .font(.headline)
                    .foregroundStyle(Theme.Palette.ink)
                Text("This app's opening time doesn't match the server's, so it can't show a countdown.")
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.inkMuted)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("grid.windowHourMismatch")
    }

    /// One line rather than three, for when the board needs the height.
    private var compactCountdown: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.fill")
                .font(.footnote)
                .foregroundStyle(Theme.Palette.accent)
            Text(compactLead)
                .font(.subheadline)
                .foregroundStyle(Theme.Palette.inkMuted)
                .lineLimit(1)
            Text(clockString)
                .font(.system(.title3, design: .rounded).weight(.bold))
                .monospacedDigit()
                .foregroundStyle(clockTint)
                .contentTransition(.numericText(countsDown: true))
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenCountdown)
        .accessibilityIdentifier("grid.countdown")
    }

    private var clockString: String {
        let parts = segments
        return String(format: "%02d:%02d:%02d", parts[0].value, parts[1].value, parts[2].value)
    }

    private var closedHero: some View {
        VStack(spacing: 10) {
            Text(heroLead)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.Palette.inkMuted)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    if index > 0 {
                        Text(":")
                            .font(.system(size: 30, weight: .light, design: .rounded))
                            .foregroundStyle(Theme.Palette.inkMuted)
                            .offset(y: -2)
                    }
                    TimeSegment(value: segment.value, caption: segment.caption, tint: clockTint)
                }
            }
            // The Date header has one-second granularity and carries a network leg of
            // latency, so the countdown does not pretend to sub-second precision.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spokenCountdown)
            .accessibilityIdentifier("grid.countdown")
        }
    }

    private var segments: [(value: Int, caption: String)] {
        let total = Int(countdown ?? 0)
        return [
            (total / 3600, String(localized: "hours", comment: "Caption under the countdown's hours")),
            ((total % 3600) / 60, String(localized: "min", comment: "Caption under the countdown's minutes")),
            (total % 60, String(localized: "sec", comment: "Caption under the countdown's seconds"))
        ]
    }

    private var spokenCountdown: String {
        let parts = segments
        // One key per unit, so each can carry its own plural forms in the catalog: "1 hours" is
        // what VoiceOver used to say an hour before the window opened.
        let hours = String(localized: "\(parts[0].value) hours", comment: "Spoken countdown, hours part")
        let minutes = String(
            localized: "\(parts[1].value) minutes", comment: "Spoken countdown, minutes part"
        )
        let seconds = String(
            localized: "\(parts[2].value) seconds", comment: "Spoken countdown, seconds part"
        )
        return String(localized: "Reservations open in \(hours), \(minutes), \(seconds)")
    }
}

private struct TimeSegment: View {
    let value: Int
    let caption: String
    let tint: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(String(format: "%02d", value))
                .font(.system(size: 42, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .contentTransition(.numericText(countsDown: true))
                .animation(.snappy(duration: 0.2), value: value)
            Text(caption)
                .font(.caption2.weight(.medium))
                .textCase(.uppercase)
                .foregroundStyle(Theme.Palette.inkMuted)
        }
        .frame(minWidth: 58)
    }
}

private struct HeroChrome: ViewModifier {
    let isFramed: Bool

    func body(content: Content) -> some View {
        if isFramed { content.card() } else { content }
    }
}
