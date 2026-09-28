import SwiftUI

/// What the user sees after an attempt.
///
/// Losing is the *modal* experience of this product: measured against the real backend,
/// 80 of 1000 users win and 920 lose. So the losing sheet gets the same design attention as
/// the winning one — it is calm, it explains what happened without blaming the user, and it
/// always offers something to do next.
///
/// The fourth case is the one most clients would not have. When a reservation times out the
/// backend gives no way to learn the outcome, so the app says it does not know rather than
/// guessing. That is the honest state and it is designed, not an error fallback.
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
            .padding(.bottom, 18)

            Text(style.title)
                .font(.title2.weight(.bold))
                .foregroundStyle(Theme.Palette.ink)
                .multilineTextAlignment(.center)

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
                title: "Space \(reservation.spaceNumber) is yours",
                message: "Reserved for tomorrow. $10.00 has been deducted.",
                detail: reservation.queuePosition.map { position in
                    "You were number \(position) in the queue"
                        + (reservation.totalProcessingMs.map { " · settled in \($0) ms" } ?? "")
                },
                action: "Done"
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
                title: "Not reserved",
                message: "You didn't confirm it was you, so nothing was sent and nothing was charged.",
                detail: nil, action: "Close"
            )

        case .rejected(let error):
            return Style(
                icon: "exclamationmark.triangle.fill",
                tint: Theme.Palette.danger,
                title: "Couldn't reserve",
                message: error.userFacingMessage,
                detail: nil,
                action: "Close"
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
                title: "Space \(space) looks like yours",
                message: "It's showing your plate on the board, but the server never sent a "
                    + "receipt to confirm it.",
                detail: "Your balance above has been refreshed, so it shows whether the $10 "
                    + "was taken. The board keeps updating.",
                action: "Got it"
            )

        case .ambiguous(let suffix):
            return Style(
                icon: "questionmark.circle.fill",
                tint: Theme.Palette.warning,
                title: "Can't tell which space",
                message: "Two spaces show a plate ending in \(suffix), so we can't tell you "
                    + "which one is yours — or whether either of them is.",
                detail: "Your balance above has been refreshed, so it shows whether the $10 "
                    + "was taken.",
                action: "Got it"
            )

        case .noEvidence(let cause):
            return Style(
                icon: "questionmark.circle.fill",
                tint: Theme.Palette.warning,
                title: "Still checking",
                message: cause.message,
                // Both branches, so the user knows what to look for either way. True because
                // a failed reservation charges nothing, and the board polls every 5 seconds.
                detail: "If it went through, your space appears on the board in a few seconds "
                    + "and $10 leaves your balance. If the board doesn't change, nothing was "
                    + "reserved and nothing was charged.",
                action: "Watch the board"
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
                title: "Someone was faster",
                message: "That space went to another driver. Plenty of others may still be free.",
                detail: nil, action: "Pick another space"
            )
        case .lotFull:
            return Style(
                icon: "nosign", tint: Theme.Palette.reserved,
                title: "Tomorrow is full",
                message: "All 80 spaces are taken. Try again when the window opens for the next day.",
                detail: nil, action: "Close"
            )
        case .insufficientBalance:
            return Style(
                icon: "wallet.bifold.fill", tint: Theme.Palette.warning,
                title: "Not enough balance",
                message: "A space costs $10.00. Top up your wallet and try again.",
                detail: nil, action: "Add funds"
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
                title: "You already have a space",
                message: "Each vehicle can hold one reservation per day.",
                detail: nil, action: "Got it"
            )
        case .windowClosed:
            return Style(
                icon: "clock.fill", tint: Theme.Palette.accent,
                title: "Not open yet",
                message: "Reservations open later today. The countdown at the top follows the server clock.",
                detail: nil, action: "Close"
            )
        case .lockTimeout:
            return Style(
                icon: "hourglass", tint: Theme.Palette.warning,
                title: "The server was busy",
                message: "Too many people arrived at once and your turn timed out. Nothing was charged.",
                detail: nil, action: "Try again"
            )
        default:
            return Style(
                icon: "exclamationmark.circle.fill", tint: Theme.Palette.danger,
                title: "Couldn't reserve",
                message: APIError.business(ErrorResponse(
                    status: 409, error: "", message: "", code: code,
                    timestamp: .distantPast, path: "", validationErrors: nil
                )).userFacingMessage,
                detail: nil, action: "Close"
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
