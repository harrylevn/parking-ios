import SwiftUI

struct DepositSheet: View {
    @ObservedObject var model: GridViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var amount: Decimal = 50
    @State private var isBusy = false

    private let presets: [Decimal] = [10, 20, 50, 100]

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 3) {
                Text("Add funds")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Theme.Palette.ink)
                Text("Balance \(DashboardHeader.money(model.balance))")
                    .font(.subheadline)
                    .foregroundStyle(Theme.Palette.inkMuted)
                    .monospacedDigit()
            }
            .padding(.top, 20)

            HStack(spacing: 8) {
                ForEach(presets, id: \.self) { preset in
                    Button {
                        Haptics.select()
                        amount = preset
                    } label: {
                        Text(DashboardHeader.money(preset))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity)
                            .frame(height: Theme.Metric.tapTarget)
                            .background(
                                amount == preset ? Theme.Palette.accentFill : Theme.Palette.canvas,
                                in: .rect(cornerRadius: 10)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(
                                        amount == preset ? Theme.Palette.accent : Theme.Palette.hairline,
                                        lineWidth: amount == preset ? 1.5 : 1
                                    )
                            )
                            .foregroundStyle(
                                amount == preset ? Theme.Palette.accent : Theme.Palette.ink
                            )
                    }
                    .accessibilityIdentifier("deposit.preset.\(preset)")
                    .accessibilityAddTraits(amount == preset ? [.isButton, .isSelected] : [.isButton])
                }
            }

            if let error = model.depositError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(Theme.Palette.danger)
                    .multilineTextAlignment(.center)
            }

            Spacer(minLength: 0)

            Button {
                Task {
                    isBusy = true
                    await model.deposit(amount)
                    isBusy = false
                    if model.depositError == nil { dismiss() }
                }
            } label: {
                if isBusy {
                    ProgressView().tint(.white)
                } else {
                    Text("Deposit \(DashboardHeader.money(amount))")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isBusy)
            .accessibilityIdentifier("deposit.submit")
        }
        .padding(Theme.Metric.gutter)
        .background(Theme.Palette.surface)
    }
}
