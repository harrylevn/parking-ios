import Foundation

/// The full state matrix 6.3's **guardrail** requires be handled visually.
enum GridState: Equatable {
    case loading
    case loaded(SpaceGrid)
    case empty
    case offline
    case failed(String)

    var grid: SpaceGrid? {
        if case .loaded(let grid) = self { return grid }
        return nil
    }
}

@MainActor
final class GridViewModel: ObservableObject {
    /// `/spaces` is cached server-side in Redis with a 5-second TTL, and every reservation
    /// attempt clears that cache (`ReservationService`'s `finally`). At rest, then, a faster
    /// poll sees nothing new. During the race it would, but only because each such poll
    /// misses the cache and rebuilds it from Postgres, and a caller that waits more than
    /// 500 ms for the rebuild lock reads Postgres directly. A thousand clients polling
    /// harder would add that load in the same second the reservation path needs the
    /// database. Five seconds is the TTL's own period, so at rest it costs nothing.
    static let pollInterval: Duration = .seconds(5)

    @Published private(set) var state: GridState = .loading
    @Published private(set) var outcome: ReservationOutcome?
    @Published private(set) var isReserving = false
    @Published private(set) var countdown: TimeInterval?
    @Published private(set) var isWindowOpen = false
    @Published private(set) var isClockSkewed = false
    /// The server answered `WINDOW_CLOSED` while this app believed the window was open, so the
    /// app's configured opening hour disagrees with the backend's. The backend exposes no way
    /// to read its hour, so this is the only point at which the disagreement is observable.
    @Published private(set) var isWindowHourMismatched = false
    @Published private(set) var hasServerTime = false
    @Published private(set) var balance: Decimal = 0

    /// True once the server has returned an actual reservation — an id, an amount and a new
    /// balance. `mySpace` alone is not enough: it is a three-character plate match, which is
    /// evidence, so without this the board stated possession as fact on the same screen where
    /// the outcome sheet was saying the server never confirmed it.
    @Published private(set) var hasConfirmedReservation = false
    @Published private(set) var depositError: String?
    @Published var selectedSpace: Int?

    /// When the attempt in flight was sent, for the elapsed time on the button.
    ///
    /// Device time, the one place on this screen it is right. SwiftUI's timer text counts
    /// against the device clock, so a start taken from the server clock would display the
    /// skew as elapsed time. A duration is skew-free as long as both ends use the same clock,
    /// and nothing is decided on it.
    @Published private(set) var reservingSince: Date?

    /// How old the board's free-space count is, in whole seconds — but only once it is old
    /// enough to matter. `nil` means fresh: within two poll intervals of server time.
    ///
    /// Bucketed rather than published every second. A per-second age would invalidate the
    /// whole screen for as long as the window is open, which is the same never-settling
    /// view hierarchy `updateClock` exists to avoid. In normal running a poll lands every
    /// five seconds and this never leaves `nil`; it only starts counting when polls are
    /// failing or hanging, which under a 20:00 race is exactly when a count stops being true.
    @Published private(set) var staleGridAge: Int?

    /// Fresh enough to state without an age: two poll intervals, so one late poll does not
    /// flap the label.
    static let staleGridThreshold: TimeInterval = 10

    /// Server time of the last successful `/spaces` response.
    private var gridFetchedAt: Date?
    /// The window has been seen shut with a server reading. The refresh at the opening fires
    /// only on that transition, not on a launch into an already-open window, where the
    /// ordinary first poll is already on its way.
    private var hasSeenWindowClosed = false

    private let environment: AppEnvironment
    private var pollTask: Task<Void, Never>?

    init(environment: AppEnvironment) {
        self.environment = environment
        self.balance = environment.account?.balance ?? 0
    }

    deinit {
        pollTask?.cancel()
    }

    var plate: String { environment.account?.licensePlate ?? "" }

    var disablesAnimations: Bool { environment.isUITesting }

    /// The space this vehicle appears to hold, matched on the last three plate characters.
    ///
    /// Returns `nil` when two spaces share our suffix: with three characters across 80 cells
    /// a collision is possible, and highlighting the wrong space is worse than highlighting
    /// none. Same rule as `ReservationCoordinator` — never claim what cannot be substantiated.
    var mySpace: Int? {
        guard let grid = state.grid, !plate.isEmpty else { return nil }
        let suffix = String(plate.suffix(3))
        let matches = grid.spaces.filter { !$0.isAvailable && $0.plateLast3 == suffix }
        return matches.count == 1 ? matches.first?.number : nil
    }

    var canReserve: Bool {
        isWindowOpen && mySpace == nil && !isReserving
    }

    var countdownPhase: CountdownPhase {
        CountdownPhase(countdown: countdown, isOpen: isWindowOpen, hasServerTime: hasServerTime)
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
            // Two levels of diffing, both required by the "no full-grid flicker or scroll
            // jump on update" guardrail:
            //  1. If the poll returns an identical board — the common case, since the grid
            //     changes at most 80 times in a day — nothing is published at all, so
            //     SwiftUI does no work.
            //  2. When it does differ, cells are keyed on space number, so SwiftUI redraws
            //     only the cells that actually changed.
            let next: GridState = grid.spaces.isEmpty ? .empty : .loaded(grid)
            if state != next { state = next }
            gridFetchedAt = await environment.serverClock.now()
            if staleGridAge != nil { staleGridAge = nil }
            dropSelectionIfTaken(in: grid)
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

    /// The countdown ticks once a second, but the grid is only refetched every 5 seconds —
    /// the clock is extrapolated locally, so a smooth countdown costs no requests.
    func tickClock() async {
        await updateClock()
    }

    /// Assigns only on change.
    ///
    /// This ticks once a second. Writing the same value back to an `@Published` property
    /// still fires `objectWillChange`, so an unguarded version invalidates the whole screen
    /// 60 times a minute whether or not anything moved — which burns battery, and leaves the
    /// view hierarchy permanently unsettled (UI tests cannot interact with a view that never
    /// stops re-rendering).
    private func updateClock() async {
        let hasReading = await environment.serverClock.hasReading()
        if hasServerTime != hasReading { hasServerTime = hasReading }

        guard hasReading, let now = await environment.serverClock.now() else {
            // No server reading yet: show no countdown at all rather than fall back to the
            // device clock, which the user can trivially change.
            if countdown != nil { countdown = nil }
            return
        }

        let open = environment.window.isOpen(at: now)
        if isWindowOpen != open { isWindowOpen = open }
        if !open { hasSeenWindowClosed = true }

        updateGridAge(at: now)

        // Whole seconds only: the Date header has one-second granularity, so anything finer
        // would be invented precision — and it keeps this to one update per second at most.
        let remaining = environment.window.timeUntilOpening(from: now).map { $0.rounded(.down) }
        if countdown != remaining { countdown = remaining }

        let skewed = await environment.serverClock.isSkewSignificant()
        if isClockSkewed != skewed { isClockSkewed = skewed }

        // The board is refetched the moment the window opens rather than on the next poll.
        // Measured, the lot can change hands in well under the five seconds a poll might be
        // away (p95 248 ms under 1000 users), and a pre-selected space is only worth
        // confirming if the board it was picked from is current. One request, not a faster
        // poll: the cache is cleared on every attempt, so under the race a faster poll would
        // be a Postgres read per client per interval, in the second the reservations need
        // the database (see `pollInterval`). This fires on the 1 Hz tick, so it lands up to a
        // second after the opening — the Date header's own granularity, so nothing finer was
        // available.
        if open, hasSeenWindowClosed {
            hasSeenWindowClosed = false
            await refresh()
        }
    }

    private func updateGridAge(at now: Date) {
        guard isWindowOpen, let fetchedAt = gridFetchedAt else {
            if staleGridAge != nil { staleGridAge = nil }
            return
        }
        let age = now.timeIntervalSince(fetchedAt)
        let next = age > Self.staleGridThreshold ? Int(age) : nil
        if staleGridAge != next { staleGridAge = next }
    }

    /// A selection is a request for one particular row. Once the board shows that row taken,
    /// confirming it can only return `SPACE_UNAVAILABLE`, after a biometric prompt that
    /// implied it might not — so it is dropped and the bar falls back to "any free space",
    /// which is the attempt most likely to succeed after a loss. This is also what makes
    /// picking a space before the opening safe: the board refreshed at the opening decides
    /// whether that pick still stands.
    private func dropSelectionIfTaken(in grid: SpaceGrid) {
        guard let selected = selectedSpace,
              let space = grid.spaces.first(where: { $0.number == selected }),
              !space.isAvailable else { return }
        selectedSpace = nil
    }

    func reserve(space: Int?) async {
        guard !isReserving, !plate.isEmpty else { return }
        isReserving = true
        reservingSince = Date()
        defer {
            isReserving = false
            reservingSince = nil
        }

        let result = await environment.coordinator.attempt(preferredSpace: space, plate: plate)

        switch result {
        case .won(let reservation):
            outcome = result
            hasConfirmedReservation = true
            isWindowHourMismatched = false
            // A read-back carries no balance. Ask the wallet rather than subtract $10 here:
            // the server's figure is the only one that cannot drift.
            if let newBalance = reservation.newBalance {
                balance = newBalance
                environment.account?.balance = newBalance
            } else {
                await refreshBalance()
            }
            selectedSpace = nil
            Haptics.play(.success)
        case .lost(let code):
            outcome = result
            // Only one direction is detectable. An app that thinks the window is still shut
            // never sends the request, so it cannot learn the server opened early.
            if code == .windowClosed, isWindowOpen { isWindowHourMismatched = true }
            Haptics.play(.warning)
            await refreshBalance()
        case .unknown, .rejected:
            outcome = result
            Haptics.play(.error)
            // Only a win returns an authoritative balance. After anything else, $10 may or
            // may not have left the wallet — a timed-out attempt that actually committed
            // would otherwise leave the header showing money the user no longer has.
            await refreshBalance()
        case .notConfirmed:
            // The user cancelled the prompt; nothing was sent. No sheet: telling someone what
            // they just chose to do is noise. The selection stays so they can try again.
            return
        }

        await refresh()
    }

    /// Replaces the displayed balance with the server's. A failure leaves the old value in
    /// place: the grid will already be showing its offline state, which is the signal that
    /// nothing on screen is fresh.
    private func refreshBalance() async {
        guard let latest = try? await environment.wallet.balance() else { return }
        balance = latest
        environment.account?.balance = latest
    }

    /// Credits the wallet, behind the same step-up authentication a reservation carries.
    ///
    /// A deposit moves money, so it is a payment action and not a settings change: the
    /// control exists to evidence that the account holder consented to *this* transaction,
    /// which is why the amount is named in the prompt. Gating only the reservation left the
    /// cheaper half of the money path unguarded — anyone holding the unlocked handset could
    /// top the wallet up, and only the spend was challenged.
    ///
    /// Returns `true` only when the wallet was actually credited. A cancelled prompt is the
    /// user's own choice, so it reports no error — but it must not read as success either,
    /// or the sheet would close over a deposit that never happened.
    @discardableResult
    func deposit(_ amount: Decimal) async -> Bool {
        depositError = nil

        do {
            try await environment.reauth.authenticate(
                reason: "Confirm a \(DashboardHeader.money(amount)) deposit"
            )
        } catch {
            return false
        }

        do {
            balance = try await environment.wallet.deposit(amount: amount)
            environment.account?.balance = balance
            Haptics.play(.success)
            return true
        } catch let error as APIError {
            depositError = error.userFacingMessage
            return false
        } catch {
            depositError = String(describing: error)
            return false
        }
    }

    func dismissOutcome() {
        outcome = nil
    }

    func signOut() {
        stopPolling()
        // Receipts do not survive the session that earned them: a different plate signing in
        // must not inherit "confirmed" and have the board claim a space on its behalf.
        hasConfirmedReservation = false
        environment.signOut()
    }
}

extension APIError {
    /// User-facing copy. Deliberately distinguishes the two 409s the reference web client
    /// renders identically, and never blames the user for losing a race.
    var userFacingMessage: String {
        switch self {
        case .unauthenticated:
            return String(localized: "Your session expired. Please sign in again.")
        case .transport(_, let failure):
            switch failure {
            case .timedOut: return String(localized: "The request timed out before we heard back.")
            case .interrupted: return String(localized: "The connection dropped before we heard back.")
            case .notSent: return String(localized: "Can't reach the server.")
            }
        case .malformedResponse:
            return String(localized: "The server sent something we couldn't read.")
        case .business(let response):
            switch response.code {
            case .spaceUnavailable:
                return String(localized: "Someone reached that space first.")
            case .lotFull:
                return String(localized: "Every space is taken for tomorrow.")
            case .alreadyReserved:
                return String(localized: "This vehicle already holds a space for tomorrow.")
            case .duplicateResource:
                return String(localized: "That plate already has an account. Sign in instead.")
            case .duplicateRequest, .alreadyQueued, .idempotencyInProgress:
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
            case .internalError, .idempotencyKeyReused, .idempotencyKeyInvalid:
                // The key codes are client bugs; the user can do nothing about them either.
                return String(localized: "Something went wrong on the server.")
            case .reservationNotFound:
                return String(localized: "No reservation was found for tomorrow.")
            }
        }
    }
}
