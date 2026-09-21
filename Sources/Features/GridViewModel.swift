import Foundation

/// The full state matrix the brief requires be handled visually (6.3).
enum GridState: Equatable {
    case loading
    case loaded(SpaceGrid)
    case empty
    case offline
    case failed(String)
}

@MainActor
final class GridViewModel: ObservableObject {
    /// `/spaces` is cached server-side in Redis with a 5-second TTL, so polling faster than
    /// that cannot surface anything newer — it only burns battery and backend CPU. The
    /// interval is therefore set by the server's cache, not by taste.
    static let pollInterval: Duration = .seconds(5)

    @Published private(set) var state: GridState = .loading
    @Published private(set) var outcome: ReservationOutcome?
    @Published private(set) var isReserving = false
    @Published private(set) var countdown: TimeInterval?
    @Published private(set) var isWindowOpen = false
    @Published private(set) var isClockSkewed = false
    @Published var balance: Decimal = 0

    private let environment: AppEnvironment
    private var pollTask: Task<Void, Never>?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    deinit {
        pollTask?.cancel()
    }

    /// Structured concurrency: the loop is owned by a task that is cancelled on view
    /// teardown, so nothing keeps polling behind a dismissed screen.
    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                await self?.updateClock()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        do {
            let grid = try await environment.spaces.grid()
            // Diffing is left to SwiftUI's identity: cells are keyed on space number, so a
            // refresh that changes two cells redraws two cells, with no full-grid flicker
            // and no scroll jump.
            state = grid.spaces.isEmpty ? .empty : .loaded(grid)
        } catch let error as APIError {
            switch error {
            case .unauthenticated:
                environment.signOut()
            case .transport:
                state = .offline
            default:
                state = .failed(error.userFacingMessage)
            }
        } catch {
            state = .failed(String(describing: error))
        }
    }

    private func updateClock() async {
        guard await environment.serverClock.hasReading(),
              let now = await environment.serverClock.now() else {
            // No server reading yet: show no countdown at all rather than fall back to the
            // device clock, which the user can trivially change.
            countdown = nil
            return
        }
        isWindowOpen = environment.window.isOpen(at: now)
        countdown = environment.window.timeUntilOpening(from: now)
        isClockSkewed = await environment.serverClock.isSkewSignificant()
    }

    func reserve(space: Int?) async {
        guard !isReserving, let plate = environment.account?.licensePlate else { return }
        isReserving = true
        defer { isReserving = false }

        outcome = await environment.coordinator.attempt(preferredSpace: space, plate: plate)

        if case .won(let reservation) = outcome {
            balance = reservation.newBalance
        }
        await refresh()
    }

    func dismissOutcome() {
        outcome = nil
    }
}

extension APIError {
    /// User-facing copy. Deliberately distinguishes the two 409s the reference web client
    /// renders identically, and never blames the user for losing a race.
    var userFacingMessage: String {
        switch self {
        case .unauthenticated:
            return String(localized: "Your session expired. Please sign in again.")
        case .transport(_, let isTimeout):
            return isTimeout
                ? String(localized: "The request timed out before we heard back.")
                : String(localized: "Can't reach the server.")
        case .malformedResponse:
            return String(localized: "The server sent something we couldn't read.")
        case .business(let response):
            switch response.code {
            case .spaceUnavailable:
                return String(localized: "Someone took that space first.")
            case .lotFull:
                return String(localized: "Every space is taken for tomorrow.")
            case .alreadyReserved:
                return String(localized: "This vehicle already holds a space for tomorrow.")
            case .duplicateRequest, .alreadyQueued:
                return String(localized: "Your attempt is still being processed.")
            case .insufficientBalance:
                return String(localized: "Not enough balance. Add funds and try again.")
            case .windowClosed:
                return String(localized: "Reservations aren't open yet.")
            case .validationError:
                return response.validationErrors?.values.first
                    ?? String(localized: "That request wasn't valid.")
            case .lockTimeout:
                return String(localized: "The server was busy. Try again.")
            case .authFailed:
                return String(localized: "Incorrect licence plate or password.")
            case .internalError:
                return String(localized: "Something went wrong on the server.")
            }
        }
    }
}
