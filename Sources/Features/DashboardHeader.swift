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

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(spacing: isCompact ? 8 : 12) {
            // At accessibility sizes the plate takes its own line. Sharing one with the wallet
            // and the menu, it shrank to "TE…" and the balance vanished from its own pill.
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    plateLabel
                    HStack(spacing: 8) {
                        walletButton
                        menu
                        Spacer(minLength: 0)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 8) {
                    plateLabel
                    Spacer(minLength: 8)
                    walletButton
                    menu
                }
            }

            date(for: date)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, isCompact ? 2 : 4)
    }

    private var plateLabel: some View {
        Label(plate, systemImage: "car.fill")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Theme.Palette.inkMuted)
            .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
            .accessibilityLabel(Text("Signed in as \(plate)"))
    }

    private var walletButton: some View {
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
            // A minimum, not a height: fixed at 34pt it clipped the amount at large sizes.
            .frame(minHeight: Theme.Metric.tapTarget - 10)
            .background(Theme.Palette.accentFill, in: .capsule)
        }
        .accessibilityIdentifier("dashboard.wallet")
        .accessibilityLabel(Text("Balance \(Self.money(balance)). Add funds."))
    }

    private var menu: some View {
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

    /// Which day the board is for.
    ///
    /// Two shapes for one fact. The roomy version is a large title over a spelled-out date,
    /// and it is what runs on iPad and in landscape. In the compact column it collapses to a
    /// single line, because that column has exactly one flexible row — the board — and the
    /// ~27pt the second line costs comes off the cell height. At 80 cells over ten rows those
    /// points are the difference between a 41pt vertical touch target and the 44pt in 6.3's
    /// Default column, which is a poor trade for a date the countdown card already implies.
    @ViewBuilder
    private func date(for date: Date?) -> some View {
        // One line at the default sizes; stacked at accessibility sizes, where side by side
        // they broke "Tomorrow" mid-word.
        if isCompact && !typeSize.isAccessibilitySize {
            HStack(spacing: 6) {
                Text("Tomorrow")
                    .font(.system(.headline, design: .rounded).weight(.bold))
                    .foregroundStyle(Theme.Palette.ink)
                if let date {
                    Text(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                        .font(.subheadline)
                        .foregroundStyle(Theme.Palette.inkMuted)
                }
            }
            .accessibilityElement(children: .combine)
        } else {
            VStack(alignment: .leading, spacing: 1) {
                Text("Tomorrow")
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .foregroundStyle(Theme.Palette.ink)
                if let date {
                    Text(date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .font(.subheadline)
                        .foregroundStyle(Theme.Palette.inkMuted)
                }
            }
        }
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
