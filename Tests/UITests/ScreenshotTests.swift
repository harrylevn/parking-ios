import UIKit
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

    private func capture(_ app: XCUIApplication, _ name: String, landscape: Bool = false) {
        // iOS offers to save the password on its own schedule, sometimes well after the board
        // has loaded, and one regenerated set shipped a dark board behind the prompt. Checked
        // here, at the moment of capture, rather than trusting each test to wait long enough.
        dismissSavePasswordPromptIfPresent(in: app)
        let shot = XCTAttachment(image: upright(XCUIScreen.main.screenshot().image, landscape: landscape))
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Rotates a landscape capture the right way up.
    ///
    /// Neither `app.screenshot()` nor `XCUIScreen.main.screenshot()` applies interface
    /// orientation: a correctly rotated app comes back as landscape content inside a
    /// portrait-shaped image. The app resized properly — the evidence for that is the frame
    /// assertion, not the picture — but a sideways PNG in the evidence folder reads as a bug
    /// in the app.
    ///
    /// The capture already knows it is landscape — `UIImage.size` reports 874×402 — but the
    /// rotation lives in `imageOrientation` while the backing buffer stays portrait, and
    /// `XCTAttachment(image:)` writes the buffer and drops the orientation. Redrawing bakes the
    /// orientation into the pixels. The caller says which captures are landscape rather than
    /// the code inferring it, because `XCUIApplication.frame` reports the unrotated frame too.
    private func upright(_ image: UIImage, landscape: Bool) -> UIImage {
        guard landscape else { return image }
        return UIGraphicsImageRenderer(size: image.size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    /// A funded account, created over HTTP rather than through the registration screen.
    ///
    /// Over HTTP because iOS puts its Automatic Strong Password cover view over any pair of
    /// secure fields and nothing the app declares dismisses it, so a test cannot type a
    /// confirmation. Fresh each run because one reservation per vehicle per day is a backend
    /// invariant: a fixed plate captures these flows once and then never again that day, and
    /// the failure is quiet — the board simply comes back with nothing selectable.
    ///
    /// Retries on a taken plate rather than returning it. The demo and rehearsal scripts leave
    /// hundreds of `TEST-####` accounts behind with other passwords, and a plate that collided
    /// used to come back anyway: sign-in then failed on the password, about one
    /// `make screenshots` run in three, and the cleared field looked like lost keystrokes.
    private func makeFundedAccount() async throws -> String {
        guard let register = URL(string: "http://localhost:8080/auth/register"),
              let deposit = URL(string: "http://localhost:8080/wallet/deposit") else {
            throw URLError(.badURL)
        }

        for _ in 0..<20 {
            let plate = "TEST-\(Int.random(in: 1000...9999))"
            var signUp = URLRequest(url: register)
            signUp.httpMethod = "POST"
            signUp.setValue("application/json", forHTTPHeaderField: "Content-Type")
            signUp.httpBody = Data(#"{"licensePlate":"\#(plate)","password":"probation123"}"#.utf8)
            let (body, _) = try await URLSession.shared.data(for: signUp)

            guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let token = json["token"] as? String else { continue }

            var topUp = URLRequest(url: deposit)
            topUp.httpMethod = "POST"
            topUp.setValue("application/json", forHTTPHeaderField: "Content-Type")
            topUp.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            topUp.httpBody = Data(#"{"amount":50.00}"#.utf8)
            _ = try await URLSession.shared.data(for: topUp)
            return plate
        }
        // Thrown, not returned: signing in with a plate this test does not own is the bug.
        throw NSError(domain: "ScreenshotTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "no free TEST-#### plate in 20 attempts"
        ])
    }

    private func signIn(_ app: XCUIApplication, as plate: String) {
        let field = app.textFields["login.plate"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(plate)
        app.secureTextFields["login.password"].tap()
        app.secureTextFields["login.password"].typeText("probation123")
        app.buttons["login.submit"].tap()
        dismissSavePasswordPromptIfPresent(in: app, timeout: 5)
    }

    func testCaptureFlow() async throws {
        try XCTSkipUnless(isEnabled, "Set SCREENSHOTS=1 and start the backend")

        let plate = try await makeFundedAccount()

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
        signIn(app, as: plate)

        XCTAssertTrue(app.buttons["space.1"].waitForExistence(timeout: 15), "grid should load")
        capture(app, "03-board")

        // A new account holds nothing, so fund it before reserving. This is the one place the
        // rehearsal has to *do* something rather than look at it.
        // Through the retrying tap: iOS offers to save the password just after sign-in, and
        // the sheet eats the first tap that follows. Same hazard as in ReservationFlowUITests.
        tap(app.buttons["dashboard.wallet"], in: app) { app.buttons["deposit.submit"].exists }
        XCTAssertTrue(app.buttons["deposit.submit"].waitForExistence(timeout: 5),
                      "the wallet sheet should be open")
        capture(app, "04-deposit")
        app.buttons["deposit.preset.50"].tap()
        app.buttons["deposit.submit"].tap()

        XCTAssertTrue(app.buttons["space.1"].waitForExistence(timeout: 10), "back on the board")

        // The resting bar, before anything is selected, is "Reserve any space" and carries a
        // different identifier from the one below. Asserted here because nothing else in the
        // suite ever touched it: the rest of this test looks for `dashboard.confirm`, so a run
        // against a full lot failed on a missing element rather than on the reason for it.
        XCTAssertTrue(app.buttons["dashboard.reserveAny"].waitForExistence(timeout: 5),
                      "with nothing selected the bar offers any free space")

        // Select a free space to raise the confirm bar.
        var selected = false
        for number in 1...80 where app.buttons["space.\(number)"].isEnabled {
            app.buttons["space.\(number)"].tap()
            selected = true
            break
        }
        XCTAssertTrue(selected, "no free space to select — the lot is full; run make backend-reset")
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
    func testCaptureWideLayout() async throws {
        try XCTSkipUnless(isEnabled, "Set SCREENSHOTS=1 and start the backend")

        let plate = try await makeFundedAccount()

        let app = XCUIApplication()
        app.launchArguments += ["-UITestSkipReauth"]
        app.launchEnvironment["PARKING_WINDOW_HOUR"] = windowHour
        app.launch()

        signIn(app, as: plate)

        XCTAssertTrue(app.buttons["space.1"].waitForExistence(timeout: 15))
        dismissSavePasswordPromptIfPresent(in: app, timeout: 3)

        XCUIDevice.shared.orientation = .landscapeLeft
        // Wait for the window to actually resize, not just for the rotation to be requested —
        // capturing mid-rotation yields a portrait-shaped frame on a landscape screen.
        let rotated = expectation(for: NSPredicate { _, _ in
            let frame = XCUIApplication().frame
            return frame.width > frame.height
        }, evaluatedWith: app)
        await fulfillment(of: [rotated], timeout: 10)
        XCTAssertTrue(app.buttons["space.1"].waitForExistence(timeout: 10))
        capture(app, "11-landscape", landscape: true)

        var selected = false
        for number in 1...80 where app.buttons["space.\(number)"].isEnabled {
            app.buttons["space.\(number)"].tap()
            selected = true
            break
        }
        XCTAssertTrue(selected, "no selectable space — is this account already holding one?")

        // Assert rather than discard the result. Without this the capture silently repeated
        // the previous screen, and the two landscape files were byte-identical for days.
        XCTAssertTrue(app.buttons["dashboard.confirm"].waitForExistence(timeout: 5),
                      "the sidebar confirm panel is the point of this capture")
        capture(app, "12-landscape-confirm", landscape: true)

        XCUIDevice.shared.orientation = .portrait
    }

    /// The window-closed state: the countdown hero at full size.
    /// Dark mode, on both the open board and the closed-window countdown.
    ///
    /// The appearance is set on the simulator by `make screenshots` rather than forced with
    /// `preferredColorScheme`, because an override would photograph the override rather than
    /// the palette the app actually adopts from the system.
    func testCaptureDark() async throws {
        try XCTSkipUnless(isEnabled, "Set SCREENSHOTS=1 and start the backend")

        let plate = try await makeFundedAccount()

        let app = XCUIApplication()
        app.launchArguments += ["-UITestSkipReauth"]
        app.launchEnvironment["PARKING_WINDOW_HOUR"] = windowHour
        app.launch()

        signIn(app, as: plate)
        XCTAssertTrue(app.buttons["space.1"].waitForExistence(timeout: 15))
        capture(app, "09-board-dark")

        // Relaunch against a window an hour ahead, which is the closed state, so the same
        // account serves both captures.
        app.terminate()
        let nextHour = (Calendar.current.component(.hour, from: Date()) + 1) % 24
        app.launchEnvironment["PARKING_WINDOW_HOUR"] = String(nextHour)
        app.launch()

        signIn(app, as: plate)
        XCTAssertTrue(app.buttons["space.1"].waitForExistence(timeout: 15))
        capture(app, "10-countdown-dark")
    }

    /// iPad, which uses the same side-by-side machinery as landscape but at a size class where
    /// the board gets 6 columns and the sidebar is permanent.
    func testCaptureIPad() async throws {
        try XCTSkipUnless(isEnabled, "Set SCREENSHOTS=1 and start the backend")

        let plate = try await makeFundedAccount()

        let app = XCUIApplication()
        app.launchArguments += ["-UITestSkipReauth"]
        app.launchEnvironment["PARKING_WINDOW_HOUR"] = windowHour
        app.launch()

        signIn(app, as: plate)
        XCTAssertTrue(app.buttons["space.1"].waitForExistence(timeout: 15))

        // Reserve, so the capture shows the held state rather than an untouched board — the
        // sidebar is where "space N is yours" lives, and that is the point of the layout.
        var selected = false
        for number in 1...80 where app.buttons["space.\(number)"].isEnabled {
            tap(app.buttons["space.\(number)"], in: app) { app.buttons["dashboard.confirm"].exists }
            selected = true
            break
        }
        XCTAssertTrue(selected, "no selectable space — is this account already holding one?")
        XCTAssertTrue(app.buttons["dashboard.confirm"].waitForExistence(timeout: 5))
        app.buttons["dashboard.confirm"].tap()

        let dismiss = app.buttons["outcome.dismiss"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 15), "an attempt must always resolve visibly")
        dismiss.tap()

        XCTAssertTrue(app.descendants(matching: .any)["dashboard.holding"].waitForExistence(timeout: 10))
        capture(app, "13-ipad")
    }

    func testCaptureCountdown() async throws {
        try XCTSkipUnless(isEnabled, "Set SCREENSHOTS=1 and start the backend")

        let plate = try await makeFundedAccount()

        let app = XCUIApplication()
        // A window hour just ahead of now forces the closed state regardless of wall clock.
        app.launchArguments += ["-UITestSkipReauth"]
        // An hour ahead of now forces the closed state whatever the wall clock says.
        let nextHour = (Calendar.current.component(.hour, from: Date()) + 1) % 24
        app.launchEnvironment["PARKING_WINDOW_HOUR"] = String(nextHour)
        app.launch()

        signIn(app, as: plate)

        XCTAssertTrue(app.buttons["space.1"].waitForExistence(timeout: 15))
        capture(app, "08-countdown")
    }
}
