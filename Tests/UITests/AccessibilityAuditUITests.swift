import XCTest

/// 6.3's accessibility row, checked by Apple's own audit instead of asserted in a table.
///
/// `performAccessibilityAudit` checks contrast, Dynamic Type, clipped text, hit regions,
/// labels and traits against the running app. Each tour visits every screen a user can
/// reach, in one appearance and text size. Any issue fails the test unless it is in
/// `accepted`, where each exception names its screen and element and says why it is not a
/// defect. The findings and fixes are written up in docs/accessibility.md.
@MainActor
final class AccessibilityAuditUITests: XCTestCase {

    private static let largestText = [
        "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
    ]

    func testAuditLight() { tour("light") }

    /// Dark mode is where every primary button failed contrast: white on the brightened
    /// dark-mode tints measured between 1.7:1 and 2.8:1.
    func testAuditDark() {
        XCUIDevice.shared.appearance = .dark
        defer { XCUIDevice.shared.appearance = .light }
        tour("dark")
    }

    /// The largest accessibility size, where the outcome sheet used to cut every line to one.
    func testAuditLargestText() { tour("largest", Self.largestText) }

    /// The header's wallet and menu are drawn at 34pt so the header stays one line and the
    /// board keeps its height. A 44pt target needs taps 5pt outside that to land. They do, and
    /// without any help from this app: measured on 29/09, iOS accepts taps up to 10pt outside
    /// the drawn edge and none at 14pt. A modifier written to grow the target was removed once
    /// probing showed it changed nothing. This keeps the requirement guarded, against an
    /// overlay or a layout change taking that margin away.
    func testHeaderWalletAcceptsATapJustOutsideItsDrawnEdge() {
        let app = launch()
        signIn(app)
        app.buttons["dashboard.wallet"]
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
            .withOffset(CGVector(dx: 0, dy: -5))
            .tap()
        XCTAssertTrue(
            app.buttons["deposit.submit"].waitForExistence(timeout: 5),
            "a tap 5pt above the wallet's drawn edge did not open the deposit sheet"
        )
    }

    // MARK: - Tours

    private func tour(_ mode: String, _ arguments: [String] = []) {
        let app = launch(arguments)
        audit(app, "\(mode) login")

        app.buttons["login.register"].tap()
        XCTAssertTrue(app.buttons["register.cancel"].waitForExistence(timeout: 5))
        audit(app, "\(mode) register")
        app.buttons["register.cancel"].tap()
        XCTAssertTrue(app.textFields["login.plate"].waitForExistence(timeout: 5))

        signIn(app)
        selectSpace(app.buttons["space.1"], in: app)
        audit(app, "\(mode) board")

        app.buttons["dashboard.wallet"].tap()
        XCTAssertTrue(app.buttons["deposit.submit"].waitForExistence(timeout: 5))
        audit(app, "\(mode) deposit")
        app.terminate()

        // The win, and the longest uncertain outcome: the one a fixed-height sheet truncated
        // even at the default size.
        for outcome in ["wins", "ambiguous"] {
            let app = launch(arguments, outcome: outcome)
            signIn(app)
            selectSpace(app.buttons["space.1"], in: app)
            tap(app.buttons["dashboard.confirm"], in: app) {
                app.buttons["outcome.dismiss"].waitForExistence(timeout: 8)
            }
            audit(app, "\(mode) outcome-\(outcome)")
            app.terminate()
        }
    }

    // MARK: - Accepted findings

    private struct Exception {
        let type: XCUIAccessibilityAuditType
        /// The element's identifier, or `nil` for an issue the audit reports with no element.
        let identifier: String?
        /// Screen names this applies to, matched by substring.
        let screens: [String]
        let reason: String
    }

    private let accepted: [Exception] = [
        Exception(
            type: .contrast, identifier: "login.submit", screens: ["login"],
            reason: "Disabled until the form is valid. WCAG 1.4.3 exempts inactive controls, "
                + "and the faded state is what tells the user it cannot be pressed yet."
        ),
        Exception(
            type: .contrast, identifier: "register.submit", screens: ["register"],
            reason: "Disabled until the form is valid; as above."
        ),
        Exception(
            type: .contrast, identifier: nil, screens: ["largest board"],
            reason: "Board text scrolled under the confirm bar's translucent material, the "
                + "standard iOS treatment for content passing behind a bar."
        ),
        Exception(
            type: .dynamicType, identifier: "register.cancel", screens: ["register"],
            reason: "A system toolbar button. iOS limits toolbar text growth by design."
        ),
        Exception(
            type: .dynamicType, identifier: "register.plate.note", screens: ["register"],
            reason: "The caption2 text style, growing to the largest size and wrapping over four "
                + "lines in the screenshots. The audit reports it as partial."
        ),
        Exception(
            type: .dynamicType, identifier: "register.password.note", screens: ["register"],
            reason: "The same field note, in the same text style."
        ),
        Exception(
            type: .textClipped, identifier: "login.password", screens: ["login"],
            reason: "A secure field. Its placeholder fits at every size in the screenshots, and "
                + "the audit cannot read the field's content to say what it measured."
        ),
        Exception(
            type: .textClipped, identifier: nil, screens: ["deposit", "outcome"],
            reason: "The board behind a part-height sheet, cut by the sheet's top edge. It is "
                + "outside the accessibility tree while the sheet is up, hence no element; the "
                + "sheet's own text fits, because the sheet is sized to it (`fitsContentDetent`)."
        ),
        Exception(
            type: .elementDetection, identifier: nil, screens: ["board", "deposit", "outcome"],
            reason: "Visible text VoiceOver skips on purpose: the legend, because every cell's "
                + "label already says free, taken or yours; the \"$\", because the amount field "
                + "is labelled \"Deposit amount in dollars\"."
        )
    ]

    private func isAccepted(_ issue: XCUIAccessibilityAuditIssue, on screen: String) -> Bool {
        let identifier = issue.element?.identifier
        let id = identifier?.isEmpty == false ? identifier : nil
        return accepted.contains { exception in
            exception.type == issue.auditType
                && exception.identifier == id
                && exception.screens.contains { screen.contains($0) }
        }
    }

    private func audit(_ app: XCUIApplication, _ screen: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = screen
        shot.lifetime = .deleteOnSuccess
        add(shot)
        do {
            try app.performAccessibilityAudit { issue in
                let accepted = self.isAccepted(issue, on: screen)
                if !accepted {
                    let element = issue.element.map { "\($0.identifier) \"\($0.label)\"" } ?? "no element"
                    print("AUDIT [\(screen)] type=\(issue.auditType.rawValue) "
                        + "\(issue.compactDescription): \(element)")
                }
                return accepted
            }
        } catch {
            XCTFail("[\(screen)] \(error)")
        }
    }

    // MARK: - Helpers

    private func launch(_ arguments: [String] = [], outcome: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestMode", "-UITestSkipReauth"] + arguments
        if let outcome { app.launchArguments += ["-UITestOutcome", outcome] }
        app.launch()
        XCTAssertTrue(app.textFields["login.plate"].waitForExistence(timeout: 15))
        return app
    }

    private func signIn(_ app: XCUIApplication) {
        app.textFields["login.plate"].tap()
        app.textFields["login.plate"].typeText("TEST-001")
        app.secureTextFields["login.password"].tap()
        app.secureTextFields["login.password"].typeText("probation123")
        app.buttons["login.submit"].tap()
        XCTAssertTrue(app.buttons["space.1"].waitForExistence(timeout: 15))
        dismissSavePasswordPromptIfPresent(in: app, timeout: 2)
    }
}
