import XCTest

/// The pinning demo 6.5 asks for, against the real backend through the real TLS proxy.
///
/// Skipped unless `scripts/pinning-demo.sh` runs it, because it needs the backend, the proxy
/// and a simulator that trusts the local CA; every other UI test runs on in-process fakes.
/// Both tests sign in with a password that is deliberately wrong, so what comes back says
/// exactly how far the request got: the backend's own "incorrect password" means the TLS
/// connection was made and trusted; the pinning message means it was refused before anything
/// was sent.
@MainActor
final class PinningDemoUITests: XCTestCase {

    private var environment: [String: String] { ProcessInfo.processInfo.environment }
    private var isEnabled: Bool { environment["PINNING_DEMO"] == "1" }
    private let server = "https://localhost:8443"

    /// A syntactically valid SPKI pin that matches no key.
    private let wrongPin = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

    func testTheRightPinReachesTheServer() throws {
        try XCTSkipUnless(isEnabled, "Run scripts/pinning-demo.sh")
        let pin = try XCTUnwrap(environment["PINNING_PIN"], "the demo script passes the proxy's pin")

        let message = signInWithAWrongPassword(pins: pin)

        XCTAssertEqual(message, "Incorrect licence plate or password.",
                       "the backend's own answer, so the pinned TLS connection was made")
    }

    func testAWrongPinIsRefusedBeforeAnythingIsSent() throws {
        try XCTSkipUnless(isEnabled, "Run scripts/pinning-demo.sh")

        let message = signInWithAWrongPassword(pins: wrongPin)

        XCTAssertEqual(
            message,
            "The server's identity couldn't be verified, so nothing was sent. Try again on a network you trust."
        )
    }

    /// After a rotation the server presents a new key, so its old pin no longer matches. An app
    /// that pinned only that key is locked out until it ships a new release; one that also
    /// pinned the issuing CA's key, as a backup, keeps working. This is that situation: a stale
    /// server pin plus the CA pin.
    func testTheBackupPinSurvivesAServerKeyRotation() throws {
        try XCTSkipUnless(isEnabled, "Run scripts/pinning-demo.sh")
        let caPin = try XCTUnwrap(environment["PINNING_CA_PIN"], "the demo script passes the CA's pin")

        let message = signInWithAWrongPassword(pins: "\(wrongPin),\(caPin)")

        XCTAssertEqual(message, "Incorrect licence plate or password.")
    }

    private func signInWithAWrongPassword(pins: String) -> String? {
        let app = XCUIApplication()
        app.launchEnvironment["PARKING_BASE_URL"] = server
        app.launchEnvironment["PARKING_SPKI_PINS"] = pins
        app.launch()

        let plate = app.textFields["login.plate"]
        XCTAssertTrue(plate.waitForExistence(timeout: 15))
        plate.tap()
        plate.typeText("TEST-9999")
        let password = app.secureTextFields["login.password"]
        password.tap()
        password.typeText("not-the-password")
        app.buttons["login.submit"].tap()

        let error = app.staticTexts["login.error"]
        XCTAssertTrue(error.waitForExistence(timeout: 15), "sign-in should fail visibly either way")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = pins == wrongPin ? "pinning-refused" : "pinning-accepted-\(pins.count)"
        shot.lifetime = .keepAlways
        add(shot)
        return error.label
    }
}
