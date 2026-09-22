import XCTest

/// Drives the real app against the **live** backend and captures each screen as a test
/// attachment. Not a correctness test — it is demo rehearsal, so the Week-2 walkthrough is
/// a replay of something already known to work rather than a live improvisation.
///
/// Skipped unless `SCREENSHOTS=1`, because it needs the backend up and CI does not have it.
@MainActor
final class ScreenshotTests: XCTestCase {

    private var isEnabled: Bool {
        ProcessInfo.processInfo.environment["SCREENSHOTS"] == "1"
    }

    /// `XCUIScreen.main` rather than `app.screenshot()`: the latter captures the app's
    /// window without accounting for interface orientation, so a landscape run comes back as
    /// rotated content in a portrait-shaped frame even though the app resized correctly.
    /// The hour the backend is running with. Defaults to *now*, so a capture run works
    /// whatever time of day it happens at — hard-coding 20 meant the run silently produced
    /// a closed-window board every morning.
    private var windowHour: String {
        ProcessInfo.processInfo.environment["PARKING_WINDOW_HOUR"]
            ?? String(Calendar.current.component(.hour, from: Date()))
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testCaptureFlow() throws {
        try XCTSkipUnless(isEnabled, "Set SCREENSHOTS=1 and start the backend")

        let app = XCUIApplication()
        app.launchArguments += ["-UITestSkipReauth"]
        app.launchEnvironment["PARKING_WINDOW_HOUR"] = windowHour
        app.launch()

        capture(app, "01-login")

        let plate = app.textFields["login.plate"]
        XCTAssertTrue(plate.waitForExistence(timeout: 10))
        plate.tap()
        plate.typeText("TEST-001")

        app.secureTextFields["login.password"].tap()
        app.secureTextFields["login.password"].typeText("probation123")
        app.buttons["login.submit"].tap()

        XCTAssertTrue(app.buttons["space.1"].waitForExistence(timeout: 15), "grid should load")
        capture(app, "02-board")

        // Select a free space to raise the confirm bar.
        for number in 1...80 where app.buttons["space.\(number)"].exists {
            let cell = app.buttons["space.\(number)"]
            if cell.isEnabled {
                cell.tap()
                break
            }
        }
        XCTAssertTrue(app.buttons["dashboard.confirm"].waitForExistence(timeout: 5))
        capture(app, "03-confirm")

        // Wallet sheet.
        app.buttons["dashboard.wallet"].tap()
        XCTAssertTrue(app.buttons["deposit.submit"].waitForExistence(timeout: 5))
        capture(app, "04-deposit")
        app.swipeDown(velocity: .fast)

        // Commit, and capture whatever the truth turns out to be.
        if app.buttons["dashboard.confirm"].waitForExistence(timeout: 5) {
            app.buttons["dashboard.confirm"].tap()
            let dismiss = app.buttons["outcome.dismiss"]
            XCTAssertTrue(dismiss.waitForExistence(timeout: 15), "an attempt must always resolve visibly")
            capture(app, "05-outcome")
            dismiss.tap()
        }

        XCTAssertTrue(app.descendants(matching: .any)["dashboard.holding"].waitForExistence(timeout: 10),
                      "after a win the board should show which space is held")
        capture(app, "06-holding")
    }

    /// Landscape and iPad use the side-by-side layout: board on the leading side taking the
    /// full height, everything else in a sidebar. A bottom-docked confirm bar on iPad would
    /// put the action a hand's travel from the board it refers to.
    func testCaptureWideLayout() throws {
        try XCTSkipUnless(isEnabled, "Set SCREENSHOTS=1 and start the backend")

        let app = XCUIApplication()
        app.launchArguments += ["-UITestSkipReauth"]
        app.launchEnvironment["PARKING_WINDOW_HOUR"] = windowHour
        app.launch()

        let plate = app.textFields["login.plate"]
        XCTAssertTrue(plate.waitForExistence(timeout: 10))
        plate.tap()
        plate.typeText("TEST-001")
        app.secureTextFields["login.password"].tap()
        app.secureTextFields["login.password"].typeText("probation123")
        app.buttons["login.submit"].tap()

        XCTAssertTrue(app.buttons["space.1"].waitForExistence(timeout: 15))

        XCUIDevice.shared.orientation = .landscapeLeft
        // Wait for the window to actually resize, not just for the rotation to be requested —
        // capturing mid-rotation yields a portrait-shaped frame on a landscape screen.
        let rotated = expectation(for: NSPredicate { _, _ in
            let frame = XCUIApplication().frame
            return frame.width > frame.height
        }, evaluatedWith: app)
        wait(for: [rotated], timeout: 10)
        XCTAssertTrue(app.buttons["space.1"].waitForExistence(timeout: 10))
        capture(app, "10-landscape")

        for number in 1...80 where app.buttons["space.\(number)"].isEnabled {
            app.buttons["space.\(number)"].tap()
            break
        }
        _ = app.buttons["dashboard.confirm"].waitForExistence(timeout: 5)
        capture(app, "11-landscape-confirm")

        XCUIDevice.shared.orientation = .portrait
    }

    /// The window-closed state: the countdown hero at full size.
    func testCaptureCountdown() throws {
        try XCTSkipUnless(isEnabled, "Set SCREENSHOTS=1 and start the backend")

        let app = XCUIApplication()
        // A window hour just ahead of now forces the closed state regardless of wall clock.
        app.launchArguments += ["-UITestSkipReauth"]
        // An hour ahead of now forces the closed state whatever the wall clock says.
        let nextHour = (Calendar.current.component(.hour, from: Date()) + 1) % 24
        app.launchEnvironment["PARKING_WINDOW_HOUR"] = String(nextHour)
        app.launch()

        let plate = app.textFields["login.plate"]
        XCTAssertTrue(plate.waitForExistence(timeout: 10))
        plate.tap()
        plate.typeText("TEST-001")
        app.secureTextFields["login.password"].tap()
        app.secureTextFields["login.password"].typeText("probation123")
        app.buttons["login.submit"].tap()

        XCTAssertTrue(app.buttons["space.1"].waitForExistence(timeout: 15))
        capture(app, "07-countdown")
    }
}
