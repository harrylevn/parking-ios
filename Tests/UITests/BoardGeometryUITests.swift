import XCTest

/// 6.3, checked against the running app instead of a model of it.
///
/// `BoardLayoutTests` proves that `BoardLayout` fills whatever rectangle it is handed. It
/// cannot prove the rectangle is the one the screen actually has — that came from a
/// `chromeHeight` constant, and when the constant drifted 44pt light every assertion there
/// went on passing while spaces 73 to 80 sat below the fold of a scroll view on the 6.1-inch
/// screen the guardrail names. Only a query against the real hierarchy catches that, so this
/// asks the app where the cells ended up.
@MainActor
final class BoardGeometryUITests: XCTestCase {

    /// The screen 6.3 is written about. Smaller phones — a mini, an SE — are allowed to
    /// scroll, so the guardrail is asserted at this size and above.
    private let reference = CGSize(width: 393, height: 852)

    func testAllEightyAreOnScreenAndMeetTheTargetInPortrait() throws {
        try assertBoardGuardrail(in: signedInApp())
    }

    /// The same guardrail in the second locale. Vietnamese runs longer than English, and the
    /// board's height is whatever the header and banner above it leave, so a translation that
    /// wraps one more line is exactly what could push spaces 73 to 80 below the fold.
    func testVietnameseKeepsAllEightyOnScreenAndTheTarget() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(vi)", "-AppleLocale", "vi_VN"]
        launchAndWaitForLogin(app)

        // Proves the locale took effect, so this cannot pass by quietly running in English.
        XCTAssertEqual(app.buttons["login.submit"].label, "Đăng nhập")
        attachScreenshot(named: "vi-login")

        signIn(app)
        attachScreenshot(named: "vi-board")
        try assertBoardGuardrail(in: app)
    }

    private func assertBoardGuardrail(in app: XCUIApplication) throws {
        let screen = app.frame.size
        try XCTSkipIf(
            screen.height < reference.height || screen.width < reference.width,
            "Below the 6.1-inch reference the board may scroll: \(screen)"
        )

        // Hittable is the whole assertion. A cell inside a scroll view that has not been
        // scrolled to still *exists* and still reports a frame, which is exactly how the
        // breach hid: `space.80` was present, addressable, and off-screen.
        for number in [1, 40, 73, 80] {
            let cell = app.buttons["space.\(number)"]
            XCTAssertTrue(cell.exists, "space \(number) missing from the board")
            XCTAssertTrue(
                hittable(cell, in: app),
                "space \(number) is not on screen — the board is scrolling on a \(screen) screen, "
                    + "which breaches the 6.3 guardrail"
            )
        }

        // Then the Default column of the same row, in the same sign-in. Asserted second and
        // with its own message, so a run that fits all 80 but loses the target still says
        // which of the two gave way — but not in its own test, because every extra sign-in
        // is another chance for iOS to raise its password prompt over the next test.
        //
        // The gutter counts toward the target: a tap in the gap between two tiles resolves to
        // the nearer one, which is exactly what these frames report.
        for number in [1, 8, 40, 73, 80] {
            let frame = app.buttons["space.\(number)"].frame
            XCTAssertGreaterThanOrEqual(frame.width, 44, "space \(number) is \(frame.width)pt wide")
            XCTAssertGreaterThanOrEqual(frame.height, 44, "space \(number) is \(frame.height)pt tall")
        }

        // Report the board's extent, so `BoardLayoutTests.chromeHeight` can be re-derived
        // from a measurement rather than guessed at when the chrome changes.
        let first = app.buttons["space.1"].frame
        let last = app.buttons["space.80"].frame
        print("BOARD screen=\(screen) grid=\(first.minY)...\(last.maxY) "
            + "height=\(last.maxY - first.minY) chrome=\(screen.height - (last.maxY - first.minY))")
    }

    /// `isHittable` with the password prompt accounted for.
    ///
    /// iOS offers to save the credential on its own schedule — after sign-in, and sometimes
    /// only after the grid is already up. While that sheet is on screen every element behind
    /// it reports `isHittable == false`, so a bare check turns "iOS put a dialog up" into
    /// "the board is scrolling", which is a guardrail breach that never happened. Seen once
    /// in a full-suite run and not in isolation, which is the signature of the AutoFill state
    /// left behind by the test before it.
    private func hittable(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            if element.isHittable { return true }
            dismissSavePasswordPromptIfPresent(in: app)
            _ = app.wait(for: .runningForeground, timeout: 0.3)
        } while Date() < deadline
        return element.isHittable
    }

    private func signedInApp() -> XCUIApplication {
        let app = XCUIApplication()
        launchAndWaitForLogin(app)
        signIn(app)
        return app
    }

    private func launchAndWaitForLogin(_ app: XCUIApplication) {
        app.launchArguments += ["-UITestMode", "-UITestSkipReauth"]
        app.launch()
        XCTAssertTrue(app.textFields["login.plate"].waitForExistence(timeout: 15))
    }

    private func attachScreenshot(named name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func signIn(_ app: XCUIApplication) {
        let plate = app.textFields["login.plate"]
        plate.tap()
        plate.typeText("TEST-0001")
        let password = app.secureTextFields["login.password"]
        password.tap()
        password.typeText("probation123")
        app.buttons["login.submit"].tap()

        XCTAssertTrue(app.buttons["space.1"].waitForExistence(timeout: 15), "grid should load")
        dismissSavePasswordPromptIfPresent(in: app, timeout: 3)
    }
}
