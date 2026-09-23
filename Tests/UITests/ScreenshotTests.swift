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

    /// Creates the account over HTTP rather than through the registration screen. iOS puts its
    /// Automatic Strong Password cover view over any pair of secure fields, and nothing the app
    /// declares dismisses it, so a test cannot type a confirmation. The screen is still
    /// captured; it just is not driven.
    private func makeAccount() async throws -> String {
        let plate = "TEST-\(Int.random(in: 1000...9999))"
        guard let url = URL(string: "http://localhost:8080/auth/register") else { return plate }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"licensePlate":"\#(plate)","password":"probation123"}"#.utf8)
        _ = try await URLSession.shared.data(for: request)
        return plate
    }

    func testCaptureFlow() async throws {
        try XCTSkipUnless(isEnabled, "Set SCREENSHOTS=1 and start the backend")

        let plate = try await makeAccount()

        let app = XCUIApplication()
        app.launchArguments += ["-UITestSkipReauth"]
        app.launchEnvironment["PARKING_WINDOW_HOUR"] = windowHour
        app.launch()

        capture(app, "01-login")

        // The registration screen is captured, not driven — see `makeAccount`.
        app.buttons["login.register"].tap()
        XCTAssertTrue(app.textFields["register.plate"].waitForExistence(timeout: 5))
        capture(app, "02-register")
        app.buttons["register.cancel"].tap()

        // A fresh account each run. One reservation per vehicle per day is a backend
        // invariant, so a fixed plate captures this flow once and then never again that day:
        // the board comes up with the space already held and nothing is selectable.
        let plateField = app.textFields["login.plate"]
        XCTAssertTrue(plateField.waitForExistence(timeout: 10))
        plateField.tap()
        plateField.typeText(plate)
        app.secureTextFields["login.password"].tap()
        app.secureTextFields["login.password"].typeText("probation123")
        app.buttons["login.submit"].tap()
        dismissSavePasswordPromptIfPresent(in: app, timeout: 5)

        XCTAssertTrue(app.buttons["space.1"].waitForExistence(timeout: 15), "grid should load")
        capture(app, "03-board")

        // A new account holds nothing, so fund it before reserving. This is the one place the
        // rehearsal has to *do* something rather than look at it.
        app.buttons["dashboard.wallet"].tap()
        XCTAssertTrue(app.buttons["deposit.submit"].waitForExistence(timeout: 5))
        capture(app, "04-deposit")
        app.buttons["deposit.preset.50"].tap()
        app.buttons["deposit.submit"].tap()

        XCTAssertTrue(app.buttons["space.1"].waitForExistence(timeout: 10), "back on the board")

        // Select a free space to raise the confirm bar.
        for number in 1...80 where app.buttons["space.\(number)"].exists {
            let cell = app.buttons["space.\(number)"]
            if cell.isEnabled {
                cell.tap()
                break
            }
        }
        XCTAssertTrue(app.buttons["dashboard.confirm"].waitForExistence(timeout: 5))
        capture(app, "05-confirm")

        // Commit, and capture whatever the truth turns out to be.
        if app.buttons["dashboard.confirm"].waitForExistence(timeout: 5) {
            app.buttons["dashboard.confirm"].tap()
            let dismiss = app.buttons["outcome.dismiss"]
            XCTAssertTrue(dismiss.waitForExistence(timeout: 15), "an attempt must always resolve visibly")
            capture(app, "06-outcome")
            dismiss.tap()
        }

        XCTAssertTrue(app.descendants(matching: .any)["dashboard.holding"].waitForExistence(timeout: 10),
                      "after a win the board should show which space is held")
        capture(app, "07-holding")
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
        dismissSavePasswordPromptIfPresent(in: app, timeout: 5)

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
        capture(app, "11-landscape")

        for number in 1...80 where app.buttons["space.\(number)"].isEnabled {
            app.buttons["space.\(number)"].tap()
            break
        }
        _ = app.buttons["dashboard.confirm"].waitForExistence(timeout: 5)
        capture(app, "12-landscape-confirm")

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
        dismissSavePasswordPromptIfPresent(in: app, timeout: 5)

        XCTAssertTrue(app.buttons["space.1"].waitForExistence(timeout: 15))
        capture(app, "08-countdown")
    }
}
