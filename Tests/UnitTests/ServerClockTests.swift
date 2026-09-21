import XCTest
@testable import Parking

final class ServerClockTests: XCTestCase {

    func testNoReadingMeansNoTimeRatherThanFallingBackToTheDevice() async {
        let clock = ServerClock()
        let hasReading = await clock.hasReading()
        let now = await clock.now()

        XCTAssertFalse(hasReading)
        XCTAssertNil(now, "Without a server reading the app must show no countdown at all")
    }

    func testServerTimeIsUsedEvenWhenTheDeviceClockIsWrong() async {
        let clock = ServerClock()
        let serverNow = Date(timeIntervalSince1970: 1_789_000_000)
        // Device clock a full day ahead — the obvious way to cheat a countdown.
        let deviceNow = serverNow.addingTimeInterval(86_400)

        await clock.ingest(serverDate: serverNow, deviceDate: deviceNow)
        let estimated = await clock.now()

        let drift = try? XCTUnwrap(estimated).timeIntervalSince(serverNow)
        XCTAssertNotNil(drift)
        XCTAssertLessThan(abs(drift ?? .infinity), 1, "Should track the server, not the device")
    }

    func testSkewBeyondThirtySecondsIsFlagged() async {
        let clock = ServerClock()
        let serverNow = Date(timeIntervalSince1970: 1_789_000_000)

        await clock.ingest(serverDate: serverNow, deviceDate: serverNow.addingTimeInterval(45))

        let skewed = await clock.isSkewSignificant()
        XCTAssertTrue(skewed)
    }

    func testSmallSkewIsNotFlagged() async {
        let clock = ServerClock()
        let serverNow = Date(timeIntervalSince1970: 1_789_000_000)

        await clock.ingest(serverDate: serverNow, deviceDate: serverNow.addingTimeInterval(2))

        let skewed = await clock.isSkewSignificant()
        XCTAssertFalse(skewed)
    }
}

final class ReservationWindowTests: XCTestCase {
    private let zone = TimeZone(identifier: "Asia/Ho_Chi_Minh") ?? .gmt

    private func date(_ hour: Int, _ minute: Int = 0, day: Int = 21) -> Date {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = day
        components.hour = hour; components.minute = minute
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: components) ?? .distantPast
    }

    func testWindowIsClosedBeforeTheOpeningHour() {
        let window = ReservationWindow(openingHour: 20, timeZone: zone)
        XCTAssertFalse(window.isOpen(at: date(19, 59)))
    }

    func testWindowIsOpenFromTheTopOfTheHour() {
        let window = ReservationWindow(openingHour: 20, timeZone: zone)
        XCTAssertTrue(window.isOpen(at: date(20, 0)))
        XCTAssertTrue(window.isOpen(at: date(23, 59)))
    }

    /// The backend's gate has no upper bound and the date rolls at midnight, so the
    /// window shuts at 00:00 rather than running a full 24 hours.
    func testWindowShutsAtMidnight() {
        let window = ReservationWindow(openingHour: 20, timeZone: zone)
        XCTAssertFalse(window.isOpen(at: date(0, 1, day: 22)))
    }

    func testCountdownToOpening() {
        let window = ReservationWindow(openingHour: 20, timeZone: zone)
        let remaining = window.timeUntilOpening(from: date(19, 30))
        XCTAssertEqual(remaining ?? 0, 1800, accuracy: 1)
    }

    func testCountdownIsZeroWhileOpen() {
        let window = ReservationWindow(openingHour: 20, timeZone: zone)
        XCTAssertEqual(window.timeUntilOpening(from: date(21, 0)), 0)
    }

    /// The hour is configuration: the demo runs with window-hour shifted, so a
    /// hardcoded 20 would break it.
    func testShiftedWindowHourIsHonoured() {
        let window = ReservationWindow(openingHour: 15, timeZone: zone)
        XCTAssertTrue(window.isOpen(at: date(15, 30)))
        XCTAssertFalse(window.isOpen(at: date(14, 59)))
    }
}
