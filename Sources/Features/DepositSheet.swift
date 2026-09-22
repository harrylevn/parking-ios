import SwiftUI

/// Wallet top-up.
///
/// 6.2's guardrail names "the deposit field and balance display", and §4 of the brief calls
/// deposit "a simple amount field" — so a free-text amount is required, not merely a set of
/// preset buttons. The presets stay as quick fills on top of it, because at 20:00 nobody
/// wants to type.
struct DepositSheet: View {
    @ObservedObject var model: GridViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var amountFocused: Bool
    @State private var amountText = "50"
    @State private var isBusy = false

    private let presets: [Decimal] = [10, 20, 50, 100]

    /// The backend rejects anything below 0.01; the client says so before spending a
    /// round trip to find out.
    private var amount: Decimal? {
        guard let value = Decimal(string: amountText.replacingOccurrences(of: ",", with: ".")),
              value >= 0.01 else { return nil }
        return value
    }

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 2) {
                Text("Add funds")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Theme.Palette.ink)
                Text("Balance \(DashboardHeader.money(model.balance))")
                    .font(.subheadline)
                    .foregroundStyle(Theme.Palette.inkMuted)
                    .monospacedDigit()
                    .accessibilityIdentifier("deposit.balance")
            }
            .padding(.top, 18)

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("$")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.Palette.inkMuted)
                TextField("0.00", text: $amountText)
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.leading)
                    .focused($amountFocused)
                    .accessibilityIdentifier("deposit.amount")
                    .accessibilityLabel("Deposit amount in dollars")
            }
            .padding(.horizontal, 14)
            .frame(height: 60)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Palette.canvas, in: .rect(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        amountFocused ? Theme.Palette.accent : Theme.Palette.hairline,
                        lineWidth: amountFocused ? 1.5 : 1
                    )
                    .allowsHitTesting(false)
            )

            HStack(spacing: 8) {
                ForEach(presets, id: \.self) { preset in
                    Button {
                        Haptics.select()
                        amountText = NSDecimalNumber(decimal: preset).stringValue
                    } label: {
                        Text(DashboardHeader.money(preset))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity)
                            .frame(height: Theme.Metric.tapTarget)
                            .background(Theme.Palette.canvas, in: .rect(cornerRadius: 10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(Theme.Palette.hairline, lineWidth: 1)
                                    .allowsHitTesting(false)
                            )
                            .foregroundStyle(Theme.Palette.accent)
                    }
                    .accessibilityIdentifier("deposit.preset.\(preset)")
                }
            }

            if let error = model.depositError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(Theme.Palette.danger)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("deposit.error")
            }

            Spacer(minLength: 0)

            Button {
                guard let amount else { return }
                Task {
                    isBusy = true
                    await model.deposit(amount)
                    isBusy = false
                    if model.depositError == nil { dismiss() }
                }
            } label: {
                if isBusy {
                    ProgressView().tint(.white)
                } else if let amount {
                    Text("Deposit \(DashboardHeader.money(amount))")
                } else {
                    Text("Enter an amount")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isBusy || amount == nil)
            .accessibilityIdentifier("deposit.submit")
        }
        .padding(Theme.Metric.gutter)
        .background(Theme.Palette.surface)
    }
}
