import XCTest

/// 6.4 **guardrail**: at least one UI test covering login, grid and reserve.
///
/// Runs against the app's in-process fakes (`-UITestMode`), so it never touches the live
/// backend and stays green whether or not Spring Boot happens to be running.
@MainActor
extension XCTestCase {
    /// Dismisses iOS's "Save Password?" prompt.
    ///
    /// The login screen sets `.textContentType(.username)` and `.password`, which is correct
    /// for real users — it enables Keychain autofill — and causes iOS to offer to save the
    /// credential after a successful sign-in. The prompt belongs to SpringBoard, not to the
    /// app, so the app's own elements still report themselves hittable while every touch
    /// actually lands on the dialog. That is why a tap could be delivered to the right
    /// coordinates and still do nothing.
    ///
    /// It is runtime-dependent: iOS 26.3 shows it, 26.0 and 26.1 do not. Since CI resolves
    /// `name=iPhone 17 Pro` to the newest installed runtime, the suite passed on this laptop
    /// and failed on the runner for the whole of that difference.
    /// The prompt is presented as a sheet **inside the app's own element tree**
    /// (`app.sheets["Save Password?"]`), not as a SpringBoard alert — which is why querying
    /// SpringBoard for it finds nothing.
    func dismissSavePasswordPromptIfPresent(in app: XCUIApplication, timeout: TimeInterval = 5) {
        let sheet = app.sheets["Save Password?"]
        guard sheet.waitForExistence(timeout: timeout) else { return }
        for label in ["Not Now", "Never for This App", "Save"] {
            let button = sheet.buttons[label]
            if button.exists {
                button.tap()
                return
            }
        }
        sheet.buttons.firstMatch.tap()
    }
}

@MainActor
extension XCUIElement {
    /// `waitForExistence` has no `isSelected` equivalent, and polling by hand is what makes
    /// these tests flaky under load.
    func waitForSelected(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isSelected { return true }
            _ = XCUIApplication().wait(for: .runningForeground, timeout: 0.1)
        }
        return isSelected
    }
}

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
        dismissSavePasswordPromptIfPresent(in: app)

        // Grid
        let firstFree = app.buttons["space.1"]
        XCTAssertTrue(firstFree.waitForExistence(timeout: 10), "grid should appear after sign in")

        // Selecting is deliberately separate from committing, so the confirm bar must appear
        // before any money can move.
        firstFree.tap()

        // Two separate waits, so a failure says whether the tap was lost or the bar failed
        // to appear after a registered tap. Collapsing them hides which half broke.
        XCTAssertTrue(
            firstFree.waitForSelected(timeout: 5),
            "the tap on space 1 did not register as a selection"
        )

        let confirm = app.buttons["dashboard.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "a selected space should raise the confirm bar")

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
        dismissSavePasswordPromptIfPresent(in: app)

        // The stub marks every fourth space as taken.
        let taken = app.buttons["space.4"]
        XCTAssertTrue(taken.waitForExistence(timeout: 10))
        XCTAssertFalse(taken.isEnabled, "a taken space must not be interactive")
    }
}
