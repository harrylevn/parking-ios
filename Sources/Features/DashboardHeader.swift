import SwiftUI

// MARK: - Header

/// Replaces the navigation bar. A standard bar could not hold the plate, the balance and a
/// menu without truncating the plate — and the plate is what tells the user which vehicle
/// they are about to spend money on, so it earns the space.
struct DashboardHeader: View {
    let plate: String
    let balance: Decimal
    let date: Date?
    var isCompact: Bool = false
    let onWallet: () -> Void
    let onSignOut: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Label(plate, systemImage: "car.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.Palette.inkMuted)
                    .lineLimit(1)
                    .accessibilityLabel(Text(verbatim: "Signed in as \(plate)"))

                Spacer(minLength: 8)

                Button(action: onWallet) {
                    HStack(spacing: 5) {
                        Image(systemName: "wallet.bifold.fill")
                            .font(.caption2.weight(.semibold))
                        Text(Self.money(balance))
                            .font(.subheadline.weight(.bold))
                            .monospacedDigit()
                        Image(systemName: "plus.circle.fill")
                            .font(.caption2)
                            .opacity(0.65)
                    }
                    .foregroundStyle(Theme.Palette.accent)
                    .padding(.horizontal, 11)
                    .frame(height: Theme.Metric.tapTarget - 10)
                    .background(Theme.Palette.accentFill, in: .capsule)
                }
                .accessibilityIdentifier("dashboard.wallet")
                .accessibilityLabel(Text(verbatim: "Balance \(Self.money(balance)). Add funds."))

                Menu {
                    Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive,
                           action: onSignOut)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Theme.Palette.inkMuted)
                        .frame(width: Theme.Metric.tapTarget - 10, height: Theme.Metric.tapTarget - 10)
                        .background(Theme.Palette.surface, in: .circle)
                        .overlay(Circle().strokeBorder(Theme.Palette.hairline, lineWidth: 1))
                }
                .accessibilityLabel("More options")
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("Tomorrow")
                    .font(.system(isCompact ? .title2 : .largeTitle, design: .rounded).weight(.bold))
                    .foregroundStyle(Theme.Palette.ink)
                if let date {
                    Text(date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .font(.subheadline)
                        .foregroundStyle(Theme.Palette.inkMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 4)
    }

    /// Explicit en_US locale: the default gives "US$120" on a non-US device, which reads as
    /// a different currency rather than a formatting nicety.
    static func money(_ value: Decimal) -> String {
        value.formatted(
            .currency(code: "USD")
            .locale(Locale(identifier: "en_US"))
            .precision(.fractionLength(0))
        )
    }
}
