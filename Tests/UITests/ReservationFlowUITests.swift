import XCTest

/// 6.4 **guardrail**: at least one UI test covering login, grid and reserve.
///
/// Runs against the app's in-process fakes (`-UITestMode`), so it never touches the live
/// backend and stays green whether or not Spring Boot happens to be running.
@MainActor
final class ReservationFlowUITests: XCTestCase {

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestMode", "-UITestSkipReauth"]
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

        // Grid
        let firstFree = app.buttons["space.1"]
        XCTAssertTrue(firstFree.waitForExistence(timeout: 10), "grid should appear after sign in")

        // Selecting is deliberately separate from committing, so the confirm bar must appear
        // before any money can move.
        firstFree.tap()

        let confirm = app.buttons["dashboard.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "selecting a space should raise the confirm bar")

        confirm.tap()

        // Whatever the result, the attempt must resolve into something the user can read.
        let dismiss = app.buttons["outcome.dismiss"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 10), "an attempt must always resolve visibly")
        dismiss.tap()
    }

    /// A taken space must not be tappable at all — the guardrail is that one tap produces
    /// exactly one attempt, and a tap that cannot succeed should not start one.
    func testTakenSpaceIsNotSelectable() {
        let app = launchApp()

        let plate = app.textFields["login.plate"]
        XCTAssertTrue(plate.waitForExistence(timeout: 10))
        plate.tap()
        plate.typeText("TEST-002")
        app.secureTextFields["login.password"].tap()
        app.secureTextFields["login.password"].typeText("probation123")
        app.buttons["login.submit"].tap()

        // The stub marks every fourth space as taken.
        let taken = app.buttons["space.4"]
        XCTAssertTrue(taken.waitForExistence(timeout: 10))
        XCTAssertFalse(taken.isEnabled, "a taken space must not be interactive")
    }
}
