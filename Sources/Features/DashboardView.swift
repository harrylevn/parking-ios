import SwiftUI

struct DashboardView: View {
    @StateObject var model: GridViewModel
    @State private var activeSheet: Sheet?

    /// One sheet modifier, not two. Attaching two `.sheet` modifiers to the same view is
    /// unreliable in SwiftUI — the second is silently ignored — which showed up as the
    /// outcome sheet never appearing unless the wallet sheet had been opened first.
    private enum Sheet: Identifiable {
        case deposit
        case outcome(ReservationOutcome)

        var id: String {
            switch self {
            case .deposit: return "deposit"
            case .outcome(let outcome): return "outcome-\(outcome.id)"
            }
        }
    }

    // Drives the countdown at 1 Hz. The grid is still only refetched every 5 seconds —
    // server time is extrapolated locally, so a smooth countdown costs zero requests.
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Theme.Palette.canvas.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 14) {
                        DashboardHeader(
                            plate: model.plate,
                            balance: model.balance,
                            date: model.state.grid?.date,
                            onWallet: { activeSheet = .deposit },
                            onSignOut: { model.signOut() }
                        )

                        CountdownHero(
                            countdown: model.countdown,
                            isOpen: model.isWindowOpen,
                            hasServerTime: model.hasServerTime,
                            isSkewed: model.isClockSkewed,
                            availableSpaces: model.state.grid?.availableSpaces ?? 0
                        )

                        if let space = model.mySpace {
                            HoldingBanner(spaceNumber: space)
                        }

                        content
                    }
                    .padding(.horizontal, Theme.Metric.gutter)
                    .padding(.top, 8)
                    .padding(.bottom, model.selectedSpace == nil ? 24 : 132)
                }
                .refreshable { await model.refresh() }
                .scrollDismissesKeyboard(.immediately)

                if let selected = model.selectedSpace, model.mySpace == nil {
                    ConfirmBar(
                        spaceNumber: selected,
                        balance: model.balance,
                        isWindowOpen: model.isWindowOpen,
                        isReserving: model.isReserving,
                        onCancel: { withAnimation(.snappy) { model.selectedSpace = nil } },
                        onConfirm: { Task { await model.reserve(space: selected) } }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task { model.startPolling() }
            .onDisappear { model.stopPolling() }
            .onReceive(tick) { _ in Task { await model.tickClock() } }
            .onChange(of: model.outcome) { _, outcome in
                if let outcome { activeSheet = .outcome(outcome) }
            }
            .sheet(item: $activeSheet, onDismiss: { model.dismissOutcome() }, content: { sheet in
                switch sheet {
                case .deposit:
                    DepositSheet(model: model)
                        .presentationDetents([.height(340)])
                        .presentationDragIndicator(.visible)
                case .outcome(let outcome):
                    OutcomeSheet(outcome: outcome) { activeSheet = nil }
                        .presentationDetents([.height(380)])
                }
            })
        }
        .tint(Theme.Palette.accent)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            SkeletonBoard()
        case .empty:
            StatusCard(
                icon: "square.grid.3x3.slash", tint: Theme.Palette.inkMuted,
                title: "No spaces configured",
                message: "The lot has no spaces for tomorrow."
            )
        case .offline:
            StatusCard(
                icon: "wifi.slash", tint: Theme.Palette.warning,
                title: "You're offline",
                message: "Showing nothing rather than something that might not be true. Pull to retry."
            )
        case .failed(let message):
            StatusCard(
                icon: "exclamationmark.triangle.fill", tint: Theme.Palette.danger,
                title: "Something went wrong", message: message
            )
        case .loaded(let grid):
            BoardView(grid: grid, model: model)
        }
    }

    private var outcomeBinding: Binding<ReservationOutcome?> {
        Binding(get: { model.outcome }, set: { _ in model.dismissOutcome() })
    }
}

// MARK: - Board

private struct BoardView: View {
    let grid: SpaceGrid
    @ObservedObject var model: GridViewModel
    /// Honoured rather than ignored: selection still happens instantly, it just does not
    /// slide. Also makes the flow deterministic under UI test, which cannot reliably
    /// interact with a view that is mid-transition.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Adaptive rather than a fixed column count: 44pt minimum satisfies both the touch
    // target and "all 80 legible without pinch-zoom", and the board reflows as Dynamic
    // Type grows instead of clipping.
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 5), count: 7)

    var body: some View {
        VStack(spacing: 14) {
            StatStrip(grid: grid)

            LazyVGrid(columns: columns, spacing: 5) {
                ForEach(grid.spaces) { space in
                    SpaceCell(space: space, appearance: appearance(for: space)) {
                        select(space)
                    }
                }
            }

            Legend()
        }
        .card(padding: 14)
    }

    private func appearance(for space: ParkingSpace) -> SpaceCell.Appearance {
        if space.number == model.mySpace { return .mine }
        if space.number == model.selectedSpace { return .selected }
        return space.isAvailable ? .available : .reserved
    }

    private func select(_ space: ParkingSpace) {
        guard model.mySpace == nil else { return }
        Haptics.select()
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {
            model.selectedSpace = model.selectedSpace == space.number ? nil : space.number
        }
    }
}

private struct StatStrip: View {
    let grid: SpaceGrid

    var body: some View {
        HStack(spacing: 0) {
            stat(value: grid.availableSpaces, label: "Free", tint: Theme.Palette.available)
            divider
            stat(value: grid.reservedSpaces, label: "Taken", tint: Theme.Palette.reserved)
            divider
            stat(value: grid.totalSpaces, label: "Total", tint: Theme.Palette.inkMuted)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(grid.availableSpaces) free of \(grid.totalSpaces) spaces, \(grid.reservedSpaces) taken"
        )
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.Palette.hairline)
            .frame(width: 1, height: 26)
    }

    private func stat(value: Int, label: String, tint: Color) -> some View {
        VStack(spacing: 1) {
            Text("\(value)")
                .font(.system(.title3, design: .rounded).weight(.bold))
                .monospacedDigit()
                .foregroundStyle(tint)
                .contentTransition(.numericText())
                .animation(.snappy, value: value)
            Text(label)
                .font(.caption2.weight(.medium))
                .textCase(.uppercase)
                .foregroundStyle(Theme.Palette.inkMuted)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct Legend: View {
    var body: some View {
        HStack(spacing: 14) {
            item(
                color: Theme.Palette.available, fill: Theme.Palette.availableFill,
                text: "Free", dashed: false
            )
            item(
                color: Theme.Palette.reserved, fill: Theme.Palette.reservedFill,
                text: "Taken", dashed: true
            )
            item(
                color: Theme.Palette.mine, fill: Theme.Palette.mineFill,
                text: "Yours", dashed: false
            )
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    private func item(color: Color, fill: Color, text: String, dashed: Bool) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 4)
                .fill(fill)
                .frame(width: 14, height: 14)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(color, style: StrokeStyle(lineWidth: 1, dash: dashed ? [2.5, 2] : []))
                )
            Text(text)
                .font(.caption2)
                .foregroundStyle(Theme.Palette.inkMuted)
        }
    }
}

// MARK: - Supporting views

private struct HoldingBanner: View {
    let spaceNumber: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title3)
                .foregroundStyle(Theme.Palette.mine)
            VStack(alignment: .leading, spacing: 1) {
                Text("Space \(spaceNumber) is yours")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.Palette.ink)
                Text("One reservation per vehicle per day")
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.inkMuted)
            }
            Spacer(minLength: 0)
        }
        .card(padding: 12)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("dashboard.holding")
    }
}

private struct StatusCard: View {
    let icon: String
    let tint: Color
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 34))
                .foregroundStyle(tint)
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.Palette.ink)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.Palette.inkMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .card()
    }
}

/// Shimmerless skeleton: shows the board's shape while loading so the layout does not jump
/// when data lands.
private struct SkeletonBoard: View {
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 5), count: 7)
    @State private var dim = false

    var body: some View {
        LazyVGrid(columns: columns, spacing: 5) {
            ForEach(1...80, id: \.self) { _ in
                RoundedRectangle(cornerRadius: Theme.Metric.corner)
                    .fill(Theme.Palette.reservedFill)
                    .frame(height: 46)
            }
        }
        .opacity(dim ? 0.5 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dim)
        .onAppear { dim = true }
        .card(padding: 14)
        .accessibilityIdentifier("grid.loading")
        .accessibilityLabel("Loading spaces")
    }
}

/// The commit step. Selecting a space and confirming it are deliberately separate: one tap
/// must produce exactly one reservation attempt, and a board of 80 small targets is a bad
/// place to spend money on a mis-tap.
private struct ConfirmBar: View {
    let spaceNumber: Int
    let balance: Decimal
    let isWindowOpen: Bool
    let isReserving: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private var canAfford: Bool { balance >= 10 }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Space \(spaceNumber)")
                        .font(.headline)
                        .foregroundStyle(Theme.Palette.ink)
                    Text("$10.00 · balance after $\(afterBalance)")
                        .font(.caption)
                        .foregroundStyle(Theme.Palette.inkMuted)
                        .monospacedDigit()
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.Palette.inkMuted)
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
                    Label("Confirm with Face ID", systemImage: "faceid")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isReserving || !isWindowOpen || !canAfford)
            .accessibilityIdentifier("dashboard.confirm")
        }
        .padding(Theme.Metric.gutter)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.Palette.hairline).frame(height: 1)
        }
    }

    private var afterBalance: String {
        NSDecimalNumber(decimal: balance - 10).stringValue
    }
}
