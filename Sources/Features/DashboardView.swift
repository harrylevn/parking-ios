import SwiftUI

struct DashboardView: View {
    @StateObject var model: GridViewModel
    @State private var activeSheet: Sheet?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

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

    /// Side-by-side whenever there is width to spare: iPad in either orientation, and iPhone
    /// in landscape, where a stacked layout would leave the board a letterbox strip.
    private var isWide: Bool {
        horizontalSizeClass == .regular || verticalSizeClass == .compact
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.Palette.canvas.ignoresSafeArea()

            // Pinned to the top explicitly. The ZStack is bottom-aligned so the confirm bar docks
            // at the bottom, and a loaded board hides that by filling the height. The offline,
            // empty and error cards are short, and without this the whole column sank to the
            // bottom of the screen, header and countdown included.
            Group {
                if isWide { wideLayout } else { compactLayout }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            if let selected = model.selectedSpace, model.mySpace == nil, !isWide {
                confirmBar(selected)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
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
        .tint(Theme.Palette.accent)
    }

    // MARK: - Layouts

    /// Portrait iPhone. The board is given every point the chrome does not need, so all 80
    /// cells fit on a 6.1-inch screen without scrolling (6.3 guardrail).
    private var compactLayout: some View {
        VStack(spacing: 10) {
            DashboardHeader(
                plate: model.plate,
                balance: model.balance,
                date: model.state.grid?.date,
                isCompact: true,
                onWallet: { activeSheet = .deposit },
                onSignOut: { model.signOut() }
            )

            // Countdown and counts share one card. Two separate cards cost ~110pt of
            // chrome, which is the difference between the board fitting on a 6.1-inch
            // screen at a 44pt target and not fitting at all.
            VStack(spacing: 10) {
                CountdownHero(
                    countdown: model.countdown,
                    isOpen: model.isWindowOpen,
                    hasServerTime: model.hasServerTime,
                    isSkewed: model.isClockSkewed,
                    availableSpaces: model.state.grid?.availableSpaces,
                    isHourMismatched: model.isWindowHourMismatched,
                    isCompact: true,
                    isFramed: false
                )
                if let grid = model.state.grid {
                    Divider().overlay(Theme.Palette.hairline)
                    StatStrip(grid: grid)
                }
            }
            .card(padding: 12)

            if let space = model.mySpace {
                HoldingBanner(spaceNumber: space)
            }

            board
        }
        .padding(.horizontal, Theme.Metric.gutter)
        .padding(.top, 2)
        .padding(.bottom, model.selectedSpace == nil ? 6 : 126)
    }

    /// Landscape iPhone and iPad. The board takes the full height on the leading side and
    /// everything else becomes a sidebar, so the grid stays square-ish instead of being
    /// squashed into a letterbox.
    private var wideLayout: some View {
        HStack(alignment: .top, spacing: 14) {
            board
                .frame(maxWidth: .infinity)

            ScrollView {
                VStack(spacing: 12) {
                    header
                    CountdownHero(
                        countdown: model.countdown,
                        isOpen: model.isWindowOpen,
                        hasServerTime: model.hasServerTime,
                        isSkewed: model.isClockSkewed,
                        availableSpaces: model.state.grid?.availableSpaces,
                        isHourMismatched: model.isWindowHourMismatched,
                        isCompact: false
                    )
                    if let space = model.mySpace {
                        HoldingBanner(spaceNumber: space)
                    }
                    if let selected = model.selectedSpace, model.mySpace == nil {
                        confirmPanel(selected)
                    }
                }
            }
            .frame(width: sidebarWidth)
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(.horizontal, Theme.Metric.gutter)
        .padding(.vertical, 10)
    }

    private var sidebarWidth: CGFloat {
        horizontalSizeClass == .regular ? 340 : 300
    }

    // MARK: - Pieces

    private var header: some View {
        DashboardHeader(
            plate: model.plate,
            balance: model.balance,
            date: model.state.grid?.date,
            isCompact: isWide,
            onWallet: { activeSheet = .deposit },
            onSignOut: { model.signOut() }
        )
    }

    @ViewBuilder
    private var board: some View {
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
            // Not "You're offline": this state covers every transport failure, and the usual
            // cause in practice is the server being down while the phone is fine. Blaming the
            // user's connection would be a claim the app cannot make.
            StatusCard(
                icon: "network.slash", tint: Theme.Palette.warning,
                title: "Can't reach the server",
                message: "Your connection or the server may be down. Retrying every few seconds; "
                    + "the board stays hidden rather than showing spaces that might be wrong."
            )
        case .failed(let message):
            StatusCard(
                icon: "exclamationmark.triangle.fill", tint: Theme.Palette.danger,
                title: "Something went wrong", message: message
            )
        case .loaded(let grid):
            VStack(spacing: 8) {
                if isWide { StatStrip(grid: grid) }
                BoardView(grid: grid, model: model)
                Legend()
            }
            .card(padding: 10)
        }
    }

    private func confirmBar(_ selected: Int) -> some View {
        ConfirmBar(
            spaceNumber: selected,
            balance: model.balance,
            isWindowOpen: model.isWindowOpen,
            isReserving: model.isReserving,
            style: .bar,
            onCancel: { withAnimation(.snappy) { model.selectedSpace = nil } },
            onConfirm: { Task { await model.reserve(space: selected) } }
        )
    }

    private func confirmPanel(_ selected: Int) -> some View {
        ConfirmBar(
            spaceNumber: selected,
            balance: model.balance,
            isWindowOpen: model.isWindowOpen,
            isReserving: model.isReserving,
            style: .panel,
            onCancel: { withAnimation(.snappy) { model.selectedSpace = nil } },
            onConfirm: { Task { await model.reserve(space: selected) } }
        )
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
///
/// Two presentations, same content: a bar docked to the bottom in portrait, and a card in the
/// sidebar when there is width for one. A bottom bar on iPad would put the action a hand's
/// travel away from the board it refers to.
struct ConfirmBar: View {
    enum Style { case bar, panel }

    let spaceNumber: Int
    let balance: Decimal
    let isWindowOpen: Bool
    let isReserving: Bool
    let style: Style
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private var canAfford: Bool { balance >= 10 }

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Space \(spaceNumber)")
                        .font(.headline)
                        .foregroundStyle(Theme.Palette.ink)
                    Text("$10.00 · balance after \(DashboardHeader.money(balance - 10))")
                        .font(.caption)
                        .foregroundStyle(Theme.Palette.inkMuted)
                        .monospacedDigit()
                }
                Spacer(minLength: 8)
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
        .modifier(ConfirmChrome(style: style))
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
