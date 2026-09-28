import XCTest
@testable import Parking

// The 20:00 moment (plan, day 6): the countdown's phases, the refetch at the opening, what the
// board may say about a count it fetched earlier, and what happens to a pick that went stale.

/// Counts `/spaces` requests and serves whatever grid it currently holds, so a test can both
/// observe the refetch at the opening and change the board between polls.
actor CountingSpaces: SpacesServicing {
    private(set) var calls = 0
    private var current: SpaceGrid

    init(_ grid: SpaceGrid) { current = grid }

    func grid() async throws -> SpaceGrid {
        calls += 1
        return current
    }

    func serve(_ grid: SpaceGrid) { current = grid }
}

final class CountdownPhaseTests: XCTestCase {
    func testNoServerReadingIsWaitingWhateverTheCountdownSays() {
        XCTAssertEqual(CountdownPhase(countdown: 5, isOpen: false, hasServerTime: false), .waiting)
        XCTAssertEqual(CountdownPhase(countdown: nil, isOpen: true, hasServerTime: false), .waiting)
    }

    func testPhasesChangeAtTheirThresholdsInclusive() {
        func phase(_ remaining: TimeInterval) -> CountdownPhase {
            CountdownPhase(countdown: remaining, isOpen: false, hasServerTime: true)
        }
        XCTAssertEqual(phase(3_600), .early)
        XCTAssertEqual(phase(61), .early)
        XCTAssertEqual(phase(60), .finalMinute)
        XCTAssertEqual(phase(11), .finalMinute)
        XCTAssertEqual(phase(10), .finalSeconds)
        XCTAssertEqual(phase(1), .finalSeconds)
    }

    func testAnOpenWindowIsOpenRegardlessOfCountdown() {
        XCTAssertEqual(CountdownPhase(countdown: 0, isOpen: true, hasServerTime: true), .open)
    }

    /// A reading without a computable next opening must not hurry anybody.
    func testAMissingCountdownIsNotTreatedAsImminent() {
        XCTAssertEqual(CountdownPhase(countdown: nil, isOpen: false, hasServerTime: true), .early)
    }

    func testOnlyThePhasesWorthInterruptingForAreAnnounced() {
        XCTAssertNil(CountdownPhase.waiting.announcement)
        XCTAssertNil(CountdownPhase.early.announcement)
        XCTAssertNotNil(CountdownPhase.finalMinute.announcement)
        XCTAssertNotNil(CountdownPhase.finalSeconds.announcement)
        XCTAssertNotNil(CountdownPhase.open.announcement)
    }
}

@MainActor
final class OpeningMomentTests: XCTestCase {
    private func at(hour: Int, minute: Int = 0, second: Int = 0) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 28, hour: hour, minute: minute, second: second
        )))
    }

    // MARK: - Refetch at the opening

    func testTheBoardIsRefetchedTheMomentTheWindowOpens() async throws {
        let spaces = CountingSpaces(grid(taken: []))
        let environment = makeEnvironment(spaces: spaces, windowHour: 20)
        let model = GridViewModel(environment: environment)

        await environment.serverClock.ingest(serverDate: try at(hour: 19, minute: 59, second: 59))
        await model.tickClock()
        XCTAssertFalse(model.isWindowOpen)
        let beforeOpening = await spaces.calls

        await environment.serverClock.ingest(serverDate: try at(hour: 20))
        await model.tickClock()

        XCTAssertTrue(model.isWindowOpen)
        let afterOpening = await spaces.calls
        XCTAssertEqual(afterOpening, beforeOpening + 1, "one refetch at the opening, not a burst")

        // Once only: later ticks inside the open window leave refreshing to the poll.
        await environment.serverClock.ingest(serverDate: try at(hour: 20, second: 1))
        await model.tickClock()
        let later = await spaces.calls
        XCTAssertEqual(later, afterOpening)
    }

    /// Launching into a window that is already open is not the window opening; the first
    /// poll is already fetching the board.
    func testLaunchingIntoAnOpenWindowDoesNotRefetch() async throws {
        let spaces = CountingSpaces(grid(taken: []))
        let environment = makeEnvironment(spaces: spaces, windowHour: 20)
        let model = GridViewModel(environment: environment)

        await environment.serverClock.ingest(serverDate: try at(hour: 20, minute: 30))
        await model.tickClock()

        XCTAssertTrue(model.isWindowOpen)
        let calls = await spaces.calls
        XCTAssertEqual(calls, 0)
    }

    // MARK: - A pick that went stale

    /// The loss path: a lost race refetches the board, which now shows the space taken.
    /// Keeping the selection offered "Reserve space 12" for a row that can only refuse.
    func testASelectionIsDroppedOnceTheBoardShowsItTaken() async {
        let spaces = CountingSpaces(grid(taken: []))
        let model = GridViewModel(environment: makeEnvironment(spaces: spaces))
        model.selectedSpace = 12

        await spaces.serve(grid(taken: [(12, "XYZ")]))
        await model.refresh()

        XCTAssertNil(model.selectedSpace, "the bar falls back to any free space")
    }

    func testASelectionSurvivesARefreshWhileItIsStillFree() async {
        let spaces = CountingSpaces(grid(taken: [(3, "XYZ")]))
        let model = GridViewModel(environment: makeEnvironment(spaces: spaces))
        model.selectedSpace = 12

        await model.refresh()

        XCTAssertEqual(model.selectedSpace, 12)
    }

    // MARK: - Age of the count

    func testAFreshCountCarriesNoAge() async throws {
        let environment = makeEnvironment()
        await environment.serverClock.ingest(serverDate: try at(hour: 20, minute: 5))
        let model = GridViewModel(environment: environment)

        await model.refresh()
        await model.tickClock()

        XCTAssertNil(model.staleGridAge)
    }

    func testACountOlderThanTwoPollsSaysHowOldItIs() async throws {
        let environment = makeEnvironment()
        await environment.serverClock.ingest(serverDate: try at(hour: 20, minute: 5))
        let model = GridViewModel(environment: environment)
        await model.refresh()

        // Polls stopped landing: server time moved on, the board did not.
        await environment.serverClock.ingest(serverDate: try at(hour: 20, minute: 5, second: 15))
        await model.tickClock()

        // 14 or 15: the age truncates to whole seconds like the countdown, and the clock is
        // re-anchored between the two readings, so the last microseconds can fall either side.
        let age = try XCTUnwrap(model.staleGridAge, "a 15-second-old count must carry its age")
        XCTAssertTrue((14...15).contains(age), "age was \(age)")

        await model.refresh()
        XCTAssertNil(model.staleGridAge, "a successful poll makes the count current again")
    }

    /// Nine seconds rather than exactly ten: the extrapolated clock drifts by microseconds
    /// between readings, so the boundary itself would be decided by scheduling, not by code.
    func testOneLatePollStillCountsAsFresh() async throws {
        let environment = makeEnvironment()
        await environment.serverClock.ingest(serverDate: try at(hour: 20, minute: 5))
        let model = GridViewModel(environment: environment)
        await model.refresh()

        await environment.serverClock.ingest(serverDate: try at(hour: 20, minute: 5, second: 9))
        await model.tickClock()

        XCTAssertNil(model.staleGridAge, "one late poll must not flap the label")
    }

    // MARK: - In flight

    func testTheInFlightStartIsClearedOnceTheAttemptSettles() async {
        let model = GridViewModel(environment: makeEnvironment())

        await model.reserve(space: nil)

        XCTAssertFalse(model.isReserving)
        XCTAssertNil(model.reservingSince)
    }
}
