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

        case .unknown(let reason):
            return Style(
                icon: "questionmark.circle.fill",
                tint: Theme.Palette.warning,
                title: "We're not sure yet",
                message: reason,
                // "Got it", not "Refresh": dismissing refreshes nothing, and the board and
                // balance already re-fetched when this sheet appeared and keep polling.
                detail: "We'd rather say we don't know than tell you something that might be wrong. "
                    + "The board keeps updating.",
                action: "Got it"
            )

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
