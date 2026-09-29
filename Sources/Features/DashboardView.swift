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

            // Nothing selected still offers a reservation — the web client's "Reserve Any
            // Space". Without it the only route to a space was picking one, which is both an
            // extra decision and the losing strategy under contention. Suppressed while a
            // space is held, like the confirm bar, since the backend allows one per day.
            if model.mySpace == nil, !isWide, model.state.grid != nil {
                confirmBar(model.selectedSpace)
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
                HoldingBanner(spaceNumber: space, isConfirmed: model.hasConfirmedReservation)
            }

            board
        }
        .padding(.horizontal, Theme.Metric.gutter)
        .padding(.top, 2)
        // The bar is now present whenever a reservation is possible, selected or not, and it
        // is the same height either way — so the board reserves room for it unconditionally
        // rather than resizing under the user at the moment they tap a space.
        .padding(.bottom, model.mySpace == nil && model.state.grid != nil ? 84 : 6)
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
                        HoldingBanner(spaceNumber: space, isConfirmed: model.hasConfirmedReservation)
                    }
                    if model.mySpace == nil, model.state.grid != nil {
                        confirmPanel(model.selectedSpace)
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
            // Tighter than the other cards, and deliberately so — see `boardCardPadding`.
            // Those eight points of padding are the difference between a 43pt cell and the
            // 44pt Default, because the board is eight columns wide.
            .card(padding: Theme.Metric.boardCardPadding)
        }
    }

    private func confirmBar(_ selected: Int?) -> some View {
        confirm(selected, style: .bar)
    }

    private func confirmPanel(_ selected: Int?) -> some View {
        confirm(selected, style: .panel)
    }

    /// One bar for both cases. `selected == nil` is "any free space", and there is nothing to
    /// cancel in that state — the bar is the resting state of the screen, not a response to a
    /// tap, so offering Cancel would suggest a selection the user never made.
    private func confirm(_ selected: Int?, style: ConfirmBar.Style) -> some View {
        ConfirmBar(
            spaceNumber: selected,
            balance: model.balance,
            isWindowOpen: model.isWindowOpen,
            isReserving: model.isReserving,
            style: style,
            onCancel: selected.map { _ in { withAnimation(.snappy) { model.selectedSpace = nil } } },
            onConfirm: { Task { await model.reserve(space: selected) } }
        )
    }
}
// MARK: - Supporting views

/// Says a space is held, and is careful about how strongly.
///
/// `mySpace` is matched on the last three plate characters, which is evidence and not proof —
/// so the banner may only state possession outright when the server actually returned a
/// receipt. Without one it hedges, matching the outcome sheet word for word. The two
/// disagreeing was visible on a single screen: the sheet said "Space 7 looks like yours … the
/// server never sent a receipt" while the banner behind it said "Space 7 is yours".
private struct HoldingBanner: View {
    let spaceNumber: Int
    /// True only when a reservation came back with an id, an amount and a balance.
    let isConfirmed: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isConfirmed ? "checkmark.seal.fill" : "checkmark.seal")
                .font(.title3)
                .foregroundStyle(Theme.Palette.mine)
            VStack(alignment: .leading, spacing: 1) {
                Text(isConfirmed ? "Space \(spaceNumber) is yours" : "Space \(spaceNumber) looks like yours")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.Palette.ink)
                Text(isConfirmed
                     ? "One reservation per vehicle per day"
                     : "Showing your plate, but never confirmed by the server")
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
