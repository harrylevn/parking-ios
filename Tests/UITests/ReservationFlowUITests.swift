import XCTest

/// Guardrail 6.4: at least one UI test covering login, grid and reserve.
/// Driven against the app's own UI with a launch argument that swaps in fakes, so it
/// never touches the live backend.
@MainActor
final class ReservationFlowUITests: XCTestCase {

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestMode"]
        app.launch()
        return app
    }

    func testLoginThenGridThenReserve() {
        let app = launchApp()

        let plate = app.textFields["login.plate"]
        XCTAssertTrue(plate.waitForExistence(timeout: 10))
        plate.tap()
        plate.typeText("TEST-001")

        let password = app.secureTextFields["login.password"]
        password.tap()
        password.typeText("probation123")

        app.buttons["login.submit"].tap()

        let firstSpace = app.buttons["space.1"]
        XCTAssertTrue(firstSpace.waitForExistence(timeout: 10), "Grid should appear after sign in")

        firstSpace.tap()

        // Whatever the outcome, the app must say something definite rather than hang.
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "An attempt must always resolve visibly")
    }
}
