import SwiftUI

/// The commit step. Selecting a space and confirming it are deliberately separate: one tap
/// must produce exactly one reservation attempt, and a board of 80 small targets is a bad
/// place to spend money on a mis-tap.
///
/// Two presentations, same content: a bar docked to the bottom in portrait, and a card in the
/// sidebar when there is width for one. A bottom bar on iPad would put the action a hand's
/// travel away from the board it refers to.
struct ConfirmBar: View {
    enum Style { case bar, panel }

    /// `nil` asks the server to assign one, which is the web client's "Reserve Any Space"
    /// and the better bet in the 20:00 race: the backend takes the first free row with
    /// `FOR UPDATE SKIP LOCKED`, so it steps over rows another request is holding instead of
    /// failing on them. Naming a space runs the same `SKIP LOCKED` against a single row, so
    /// losing that one lock is `SPACE_UNAVAILABLE` rather than a different space.
    let spaceNumber: Int?
    let balance: Decimal
    let isWindowOpen: Bool
    let isReserving: Bool
    let style: Style
    let onCancel: (() -> Void)?
    let onConfirm: () -> Void

    private var canAfford: Bool { balance >= 10 }

    /// One row, not two.
    ///
    /// The bar used to stack a title block above the button and stand ~126pt tall, which was
    /// affordable only because it appeared just on selection. Now that it is always present
    /// — so the board no longer reflows under the finger that taps a space — that height
    /// comes off the board on every screen, and at 126pt it pushed the 6.1-inch layout past
    /// the 44pt touch target into a 9-column grid of 39pt cells. Folding the title into the
    /// button's own label buys the board back its rows, and `BoardLayoutTests` measures the
    /// result rather than trusting it.
    var body: some View {
        HStack(spacing: 10) {
            if let onCancel {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.Palette.inkMuted)
                        .frame(width: Theme.Metric.tapTarget, height: Theme.Metric.tapTarget)
                        .background(Theme.Palette.canvas, in: .rect(cornerRadius: 12))
                }
                .accessibilityLabel("Cancel selection")
                .accessibilityIdentifier("dashboard.cancel")
                .transition(.scale.combined(with: .opacity))
            }

            Button(action: onConfirm) {
                if isReserving {
                    HStack(spacing: 8) {
                        ProgressView().tint(.white)
                        Text("Reserving…")
                    }
                } else if !isWindowOpen {
                    Text("Opens later today")
                } else if !canAfford {
                    Text("Add funds to reserve")
                } else {
                    Label(title, systemImage: "faceid")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isReserving || !isWindowOpen || !canAfford)
            .accessibilityIdentifier(spaceNumber == nil ? "dashboard.reserveAny" : "dashboard.confirm")
            .accessibilityHint(Text(hint))
        }
        .modifier(ConfirmChrome(style: style))
    }

    /// The space is named in the button rather than above it, so the row the user is about to
    /// commit with says what it commits to. `$10` rides along because the price is the other
    /// thing worth knowing before a tap, and the balance it leaves is already in the header.
    private var title: String {
        spaceNumber.map { "Reserve space \($0) · $10" } ?? "Reserve any space · $10"
    }

    private var hint: String {
        // Said plainly, because "any" is the option most likely to win and the one a user is
        // least likely to try: the server takes the first free space and the pick is final.
        spaceNumber == nil
            ? "We take the first free space. Balance after, \(DashboardHeader.money(balance - 10))."
            : "Balance after, \(DashboardHeader.money(balance - 10))."
    }
}

private struct ConfirmChrome: ViewModifier {
    let style: ConfirmBar.Style

    func body(content: Content) -> some View {
        switch style {
        case .bar:
            content
                .padding(Theme.Metric.gutter)
                .background(.regularMaterial)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Theme.Palette.hairline)
                        .frame(height: 1)
                        .allowsHitTesting(false)
                }
        case .panel:
            content.card()
        }
    }
}
