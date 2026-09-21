import SwiftUI

/// The 80-space grid.
///
/// Layout: an adaptive grid with a 44pt minimum cell, which satisfies both the "all 80 legible
/// on a 6.1-inch screen without pinch-zoom" guardrail and the 44pt minimum touch target, and
/// reflows to fewer columns as Dynamic Type grows rather than clipping.
struct GridView: View {
    @ObservedObject var model: GridViewModel
    @EnvironmentObject private var environment: AppEnvironment

    private let columns = [GridItem(.adaptive(minimum: 44), spacing: 8)]

    var body: some View {
        NavigationStack {
            Group {
                switch model.state {
                case .loading:
                    ProgressView("Loading spaces")
                        .accessibilityIdentifier("grid.loading")
                case .empty:
                    ContentUnavailableView(
                        "No spaces", systemImage: "square.grid.3x3",
                        description: Text("The lot has no spaces configured.")
                    )
                case .offline:
                    ContentUnavailableView(
                        "Offline", systemImage: "wifi.slash",
                        description: Text("Showing nothing rather than something untrue.")
                    )
                case .failed(let message):
                    ContentUnavailableView(
                        "Something went wrong", systemImage: "exclamationmark.triangle",
                        description: Text(message)
                    )
                case .loaded(let grid):
                    loadedGrid(grid)
                }
            }
            .navigationTitle("Tomorrow's spaces")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Sign out") { environment.signOut() }
                }
            }
            .safeAreaInset(edge: .top) { header }
            .task { model.startPolling() }
            .onDisappear { model.stopPolling() }
            .refreshable { await model.refresh() }
            .alert(item: outcomeBinding) { outcome in
                Alert(
                    title: Text(outcome.title),
                    message: Text(outcome.detail),
                    dismissButton: .default(Text("OK")) { model.dismissOutcome() }
                )
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        VStack(spacing: 4) {
            if model.isClockSkewed {
                Label(
                    "Your device clock is more than 30 seconds off the server.",
                    systemImage: "clock.badge.exclamationmark"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            }

            if let countdown = model.countdown, countdown > 0 {
                Text("Opens in \(formatted(countdown))")
                    .font(.headline.monospacedDigit())
                    .accessibilityIdentifier("grid.countdown")
            } else if model.isWindowOpen {
                Text("Reservations are open")
                    .font(.headline)
                    .foregroundStyle(.green)
            } else {
                // No server reading yet: say nothing rather than trust the device clock.
                Text("Checking server time…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(.bar)
    }

    private func loadedGrid(_ grid: SpaceGrid) -> some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(grid.spaces) { space in
                    SpaceCell(space: space) {
                        Task { await model.reserve(space: space.number) }
                    }
                    .disabled(model.isReserving || !space.isAvailable)
                }
            }
            .padding(16)
        }
        .overlay(alignment: .bottom) {
            if model.isReserving {
                ProgressView("Reserving…")
                    .padding()
                    .background(.regularMaterial, in: .rect(cornerRadius: 12))
                    .padding(.bottom, 24)
            }
        }
    }

    private var outcomeBinding: Binding<ReservationOutcome?> {
        Binding(get: { model.outcome }, set: { _ in model.dismissOutcome() })
    }

    private func formatted(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

struct SpaceCell: View {
    let space: ParkingSpace
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text("\(space.number)")
                    .font(.caption.weight(.semibold))
                Text(space.plateLast3 ?? "—")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 44, minHeight: 44)
            .frame(maxWidth: .infinity)
            .background(
                space.isAvailable ? Color.green.opacity(0.18) : Color.secondary.opacity(0.18),
                in: .rect(cornerRadius: 8)
            )
            // Availability is carried by shape as well as colour, so it survives
            // colour-blindness and greyscale.
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        space.isAvailable ? Color.green : Color.secondary,
                        style: StrokeStyle(lineWidth: 1, dash: space.isAvailable ? [] : [3, 2])
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("space.\(space.number)")
        .accessibilityLabel(
            space.isAvailable
                ? Text("Space \(space.number), available")
                : Text("Space \(space.number), reserved by plate ending \(space.plateLast3 ?? "unknown")")
        )
        .accessibilityAddTraits(space.isAvailable ? [.isButton] : [.isButton, .isSelected])
    }
}

extension ReservationOutcome: Identifiable {
    var id: String {
        switch self {
        case .won(let reservation): return "won-\(reservation.spaceNumber)"
        case .lost(let code): return "lost-\(code.rawValue)"
        case .unknown(let reason): return "unknown-\(reason)"
        case .rejected: return "rejected"
        }
    }

    var title: String {
        switch self {
        case .won: return String(localized: "Space reserved")
        case .lost: return String(localized: "You didn't get a space")
        case .unknown: return String(localized: "We're not sure yet")
        case .rejected: return String(localized: "Couldn't reserve")
        }
    }

    var detail: String {
        switch self {
        case .won(let reservation):
            return String(localized: "Space \(reservation.spaceNumber) is yours for tomorrow.")
        case .lost(let code):
            return APIError.business(
                ErrorResponse(
                    status: 409, error: "", message: "", code: code,
                    timestamp: .distantPast, path: "", validationErrors: nil
                )
            ).userFacingMessage
        case .unknown(let reason):
            return reason
        case .rejected(let error):
            return error.userFacingMessage
        }
    }
}
