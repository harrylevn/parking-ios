import SwiftUI

/// What the user sees after an attempt.
///
/// Losing is the *modal* experience of this product: measured against the real backend,
/// 80 of 1000 users win and 920 lose. So the losing sheet gets the same design attention as
/// the winning one — it is calm, it explains what happened without blaming the user, and it
/// always offers something to do next.
///
/// The fourth case is the one most clients would not have. When the reply is lost and neither
/// repeating the tap's key nor reading back what committed settles it (ADR-007), the app says
/// it does not know rather than guessing. That is the honest state and it is designed, not an
/// error fallback.
struct OutcomeSheet: View {
    let outcome: ReservationOutcome
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)

            ZStack {
                Circle()
                    .fill(style.tint.opacity(0.14))
                    .frame(width: 84, height: 84)
                Image(systemName: style.icon)
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(style.tint)
                    .symbolRenderingMode(.hierarchical)
            }
            // Decorative: the title says the same thing in words. Left in, VoiceOver read
            // the SF Symbol's name, "checkmark circle badge questionmark", before the outcome.
            .accessibilityHidden(true)
            .padding(.bottom, 18)

            Text(style.title)
                .font(.title2.weight(.bold))
                .foregroundStyle(Theme.Palette.ink)
                .multilineTextAlignment(.center)
                // Which outcome, independent of the language it is written in: a test that
                // matched "Space 12 is yours" failed on a simulator set to Vietnamese.
                .accessibilityIdentifier("outcome.title.\(outcome.id)")

            Text(style.message)
                .font(.subheadline)
                .foregroundStyle(Theme.Palette.inkMuted)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
                .padding(.horizontal, 8)

            if let detail = style.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.inkMuted)
                    .padding(.top, 12)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Theme.Palette.canvas, in: .rect(cornerRadius: 10))
            }

            Spacer(minLength: 16)

            Button(action: onDismiss) {
                Text(style.action)
            }
            .buttonStyle(PrimaryButtonStyle(tint: style.tint))
            .accessibilityIdentifier("outcome.dismiss")
        }
        .padding(Theme.Metric.gutter)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .scrollsAtLargeText()
        .background(Theme.Palette.surface)
    }

    private struct Style {
        let icon: String
        let tint: Color
        let title: String
        let message: String
        var detail: String?
        var action: String
    }

    private var style: Style {
        switch outcome {
        case .won(let reservation):
            return Style(
                icon: "checkmark.circle.fill",
                tint: Theme.Palette.available,
                title: String(localized: "Space \(reservation.spaceNumber) is yours"),
                message: String(localized: "Reserved for tomorrow. $10.00 has been deducted."),
                // Two whole sentences rather than one with a clause spliced on, so a translation
                // is never asked to agree with a fragment it cannot see.
                detail: reservation.queuePosition.map { position in
                    reservation.totalProcessingMs.map { settled in
                        String(localized: """
                            You were number \(position) in the queue · settled in \(settled) ms
                            """)
                    } ?? String(localized: "You were number \(position) in the queue")
                },
                action: String(localized: "Done")
            )

        case .lost(let code):
            return lostStyle(code)

        case .unknown(let uncertainty):
            return unknownStyle(uncertainty)

        case .notConfirmed:
            // Not presented by GridViewModel, which drops it silently; handled so the switch
            // stays exhaustive and a future caller cannot render a blank sheet.
            return Style(
                icon: "faceid", tint: Theme.Palette.inkMuted,
                title: String(localized: "Not reserved"),
                message: String(localized: """
                    You didn't confirm it was you, so nothing was sent and nothing was charged.
                    """),
                detail: nil, action: String(localized: "Close")
            )

        case .rejected(let error):
            return Style(
                icon: "exclamationmark.triangle.fill",
                tint: Theme.Palette.danger,
                title: String(localized: "Couldn't reserve"),
                message: error.userFacingMessage,
                detail: nil,
                action: String(localized: "Close")
            )
        }
    }

    /// Copy for the three uncertain outcomes.
    ///
    /// Rewritten after the week-1 checkpoint reported the old single sheet — "We're not sure
    /// yet", over a line explaining that we would rather admit ignorance than mislead — as
    /// distressing and hard to follow. Three things were wrong with it, and only one was
    /// wording:
    ///
    /// 1. It flattened three situations into one, so a user whose space was almost certainly
    ///    theirs got the same alarming sheet as one with nothing to go on.
    /// 2. It answered "does the app know?" when the question is "did I get a space, and did it
    ///    take my $10?". The money went unmentioned.
    /// 3. It explained the app's design philosophy to someone who was worried about $10.
    ///
    /// So each case now leads with what *is* known, says what happens to the money, and ends
    /// with what the user should watch for — rather than with our epistemics. What none of
    /// them do is claim a reservation: that part of the old copy was right, and the
    /// underlying ambiguity is the backend's to remove (`docs/presentation.md` §3).
    private func unknownStyle(_ uncertainty: Uncertainty) -> Style {
        switch uncertainty {
        case .probablyHeld(let space):
            // The friendliest of the three, and the one the old sheet served worst: this is
            // good news. Still not phrased as a confirmation — there is no receipt, and the
            // match is three plate characters across 80 cells.
            return Style(
                icon: "checkmark.circle.badge.questionmark",
                tint: Theme.Palette.warning,
                title: String(localized: "Space \(space) looks like yours"),
                message: String(localized: """
                    It's showing your plate on the board, but the server never sent a receipt to confirm it.
                    """),
                detail: String(localized: """
                    Your balance above has been refreshed, so it shows whether the $10 was taken. The board \
                    keeps updating.
                    """),
                action: String(localized: "Got it")
            )

        case .ambiguous(let suffix):
            return Style(
                icon: "questionmark.circle.fill",
                tint: Theme.Palette.warning,
                title: String(localized: "Can't tell which space"),
                message: String(localized: """
                    Two spaces show a plate ending in \(suffix), so we can't tell you which one is yours — \
                    or whether either of them is.
                    """),
                detail: String(localized: """
                    Your balance above has been refreshed, so it shows whether the $10 was taken.
                    """),
                action: String(localized: "Got it")
            )

        case .noEvidence(let cause):
            return Style(
                icon: "questionmark.circle.fill",
                tint: Theme.Palette.warning,
                title: String(localized: "Still checking"),
                message: cause.message,
                // Both branches, so the user knows what to look for either way. True because
                // a failed reservation charges nothing, and the board polls every 5 seconds.
                detail: String(localized: """
                    If it went through, your space appears on the board in a few seconds and $10 leaves your \
                    balance. If the board doesn't change, nothing was reserved and nothing was charged.
                    """),
                action: String(localized: "Watch the board")
            )
        }
    }

    private func lostStyle(_ code: BusinessErrorCode) -> Style {
        switch code {
        case .spaceUnavailable, .lotFull, .insufficientBalance:
            return contentionStyle(code)
        default:
            return stateStyle(code)
        }
    }

    /// Losing to another driver, or to your own balance — the three outcomes that are about
    /// the race itself rather than about the state of your account.
    private func contentionStyle(_ code: BusinessErrorCode) -> Style {
        switch code {
        case .spaceUnavailable:
            return Style(
                icon: "person.2.fill", tint: Theme.Palette.accent,
                title: String(localized: "Someone was faster"),
                message: String(localized: "That space went to another driver. Nothing was charged."),
                // No claim about what is left: the lot changes hands in about 250 ms, so a
                // lost named space usually means a full one, and the board is what knows.
                // The advice is "any space" because naming one is the losing strategy under
                // contention; the button only closes the sheet, so its label says so.
                detail: String(localized: """
                    Reserve any space takes the first one still free, if any are left.
                    """),
                action: String(localized: "Back to the board")
            )
        case .lotFull:
            return Style(
                icon: "nosign", tint: Theme.Palette.reserved,
                title: String(localized: "Tomorrow is full"),
                message: String(localized: """
                    All 80 spaces are taken. Try again when the window opens for the next day.
                    """),
                detail: nil, action: String(localized: "Close")
            )
        case .insufficientBalance:
            return Style(
                icon: "wallet.bifold.fill", tint: Theme.Palette.warning,
                title: String(localized: "Not enough balance"),
                message: String(localized: "A space costs $10.00. Top up your wallet and try again."),
                detail: nil, action: String(localized: "Add funds")
            )
        default:
            return stateStyle(code)
        }
    }

    private func stateStyle(_ code: BusinessErrorCode) -> Style {
        switch code {
        case .alreadyReserved:
            return Style(
                icon: "checkmark.seal.fill", tint: Theme.Palette.mine,
                title: String(localized: "You already have a space"),
                message: String(localized: "Each vehicle can hold one reservation per day."),
                detail: nil, action: String(localized: "Got it")
            )
        case .windowClosed:
            return Style(
                icon: "clock.fill", tint: Theme.Palette.accent,
                title: String(localized: "Not open yet"),
                message: String(localized: """
                    Reservations open later today. The countdown at the top follows the server clock.
                    """),
                detail: nil, action: String(localized: "Close")
            )
        case .lockTimeout:
            return Style(
                icon: "hourglass", tint: Theme.Palette.warning,
                title: String(localized: "The server was busy"),
                message: String(localized: """
                    Too many people arrived at once and your turn timed out. Nothing was charged.
                    """),
                detail: nil, action: String(localized: "Try again")
            )
        default:
            return Style(
                icon: "exclamationmark.circle.fill", tint: Theme.Palette.danger,
                title: String(localized: "Couldn't reserve"),
                message: APIError.business(ErrorResponse(
                    status: 409, error: "", message: String(localized: ""), code: code,
                    timestamp: .distantPast, path: "", validationErrors: nil
                )).userFacingMessage,
                detail: nil, action: String(localized: "Close")
            )
        }
    }
}

extension ReservationOutcome: Identifiable {
    var id: String {
        switch self {
        case .won(let reservation): return "won-\(reservation.spaceNumber)"
        case .lost(let code): return "lost-\(code.rawValue)"
        case .unknown(let reason): return "unknown-\(reason)"
        case .rejected: return "rejected"
        case .notConfirmed: return "not-confirmed"
        }
    }
}

private extension Uncertainty.Cause {
    /// What is known, stated as a fact about the request rather than about our confidence.
    /// "Your request was sent" is the part the user can act on; "we could not confirm the
    /// result", which these lines used to end with, only restates the sheet's own title.
    var message: String {
        switch self {
        case .timedOut:
            return String(localized: "Your request was sent, but the reply didn't arrive in time.")
        case .connectionDropped:
            return String(localized: "The connection dropped before the reply came back.")
        case .alreadyInFlight:
            return String(localized: "An earlier attempt is still being processed.")
        }
    }
}
