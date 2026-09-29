import XCTest

/// The three demo rehearsals (plan, day 9), run end to end against the real backend.
///
/// Skipped unless `scripts/rehearse.sh` runs them: it starts the backend, registers and funds
/// the accounts, passes them in through the environment, and afterwards checks the database
/// agrees with what the app said. Every other UI test runs on in-process fakes.
@MainActor
final class RehearsalUITests: XCTestCase {

    private var environment: [String: String] { ProcessInfo.processInfo.environment }
    private let backend = "http://localhost:8080"
    private let space = 12

    private func requireRehearsal(_ scenario: String) throws {
        try XCTSkipUnless(
            environment["REHEARSAL"] == scenario,
            "Run scripts/rehearse.sh; this is the \(scenario) rehearsal"
        )
    }

    // MARK: - Rehearsals

    /// A clean board, a funded account: the space is won and the app says so, with the
    /// receipt. The script then checks the reservation and the $10 in the database.
    func testWonRace() throws {
        try requireRehearsal("won")
        let app = signedIn()

        reserveSpace(in: app)

        XCTAssertTrue(app.staticTexts["Space \(space) is yours"].waitForExistence(timeout: 15))
        capture("rehearsal-won")
    }

    /// A real lost race, made reliable. The space is selected while the board shows it free,
    /// then a rival books it through the API, then the user confirms: the board is up to five
    /// seconds behind, exactly as it is at 20:00. The app must say someone was faster and
    /// must not have taken the $10, which the script checks.
    func testLostRace() async throws {
        try requireRehearsal("lost")
        let rivalToken = try XCTUnwrap(environment["REHEARSAL_RIVAL_TOKEN"])
        let app = signedIn()

        let cell = app.buttons["space.\(space)"]
        selectSpace(cell, in: app)
        let rivalStatus = try await reserveAsRival(token: rivalToken)
        XCTAssertEqual(rivalStatus, 200, "the rival must hold the space before the user confirms")
        confirm(in: app)

        XCTAssertTrue(app.staticTexts["Someone was faster"].waitForExistence(timeout: 15))
        capture("rehearsal-lost")
    }

    /// The backend dies while the reservation is in flight. The script holds a database lock
    /// on this user's row, so the request is genuinely inside the server, and kills the backend
    /// the moment it is seen waiting. Nothing can confirm the outcome, so the app must say it
    /// is still checking, and why, rather than guess. The script then restarts the backend and
    /// checks that nothing was booked or charged, which is what the sheet told the user.
    func testBackendKilledMidReservation() throws {
        try requireRehearsal("killed")
        let app = signedIn()

        reserveSpace(in: app)

        XCTAssertTrue(app.staticTexts["Still checking"].waitForExistence(timeout: 60))
        XCTAssertTrue(app.staticTexts["The connection dropped before the reply came back."].exists)
        capture("rehearsal-killed")
    }

    // MARK: - Steps

    private func signedIn() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestSkipReauth"]
        app.launchEnvironment["PARKING_BASE_URL"] = backend
        app.launchEnvironment["PARKING_WINDOW_HOUR"] = environment["REHEARSAL_WINDOW_HOUR"]
        app.launch()

        let plate = app.textFields["login.plate"]
        XCTAssertTrue(plate.waitForExistence(timeout: 15))
        plate.tap()
        plate.typeText(environment["REHEARSAL_PLATE"] ?? "")
        let password = app.secureTextFields["login.password"]
        password.tap()
        password.typeText(environment["REHEARSAL_PASSWORD"] ?? "")
        app.buttons["login.submit"].tap()

        XCTAssertTrue(app.buttons["space.\(space)"].waitForExistence(timeout: 20), "the board should load")
        dismissSavePasswordPromptIfPresent(in: app, timeout: 3)
        return app
    }

    private func reserveSpace(in app: XCUIApplication) {
        selectSpace(app.buttons["space.\(space)"], in: app)
        confirm(in: app)
    }

    private func confirm(in app: XCUIApplication) {
        let confirm = app.buttons["dashboard.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
    }

    private func reserveAsRival(token: String) async throws -> Int {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(backend)/reservations")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data("{\"preferredSpaceNumber\":\(space)}".utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
