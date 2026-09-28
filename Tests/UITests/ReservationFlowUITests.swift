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
    @discardableResult
    func dismissSavePasswordPromptIfPresent(in app: XCUIApplication, timeout: TimeInterval = 0) -> Bool {
        let sheet = app.sheets["Save Password?"]
        let present = timeout > 0 ? sheet.waitForExistence(timeout: timeout) : sheet.exists
        guard present else { return false }

        // The button is queried both through the sheet and at app level: the sheet is a
        // remote view, and which query resolves it is not consistent across runtimes.
        let candidates = ["Not Now", "Never for This App"]
        let button = candidates.lazy
            .flatMap { [sheet.buttons[$0], app.buttons[$0]] }
            .first { $0.exists && $0.isHittable }
        (button ?? sheet.buttons.firstMatch).tap()

        // Wait for it to actually go away. Tapping the cell while the sheet is still
        // animating out puts the touch back into the same hole it just came out of.
        let deadline = Date().addingTimeInterval(3)
        while sheet.exists && Date() < deadline {
            _ = app.wait(for: .runningForeground, timeout: 0.1)
        }
        // The element leaves the tree before the presentation finishes animating out, and a
        // tap delivered in that gap is swallowed.
        _ = app.wait(for: .runningForeground, timeout: 0.6)
        return true
    }

    /// Taps an element and confirms the effect actually landed.
    ///
    /// iOS offers to save the password on its own schedule. Measured on iOS 26.3: the sheet
    /// is *not* on screen when the grid appears, and *is* on screen immediately after the
    /// tap — so it materialises in the window between the two and swallows the touch.
    /// Dismissing beforehand cannot catch that, and no fixed wait is reliable, because
    /// whether it appears at all depends on the runtime and on AutoFill state left behind by
    /// earlier runs.
    ///
    /// So: tap, and if the tap was swallowed *and a sheet is now up*, dismiss it and tap
    /// again, up to three times. The retry is deliberately conditional on a dialog actually
    /// being present — a tap that vanishes with nothing on screen is a real bug and still
    /// fails the test rather than being retried into a pass.
    /// `landed` is what the tap was supposed to achieve — a cell becoming selected, a sheet
    /// appearing. Checking the effect rather than the tap is the point: a tap that iOS
    /// swallowed and a tap that did nothing look identical otherwise.
    func tap(
        _ element: XCUIElement,
        in app: XCUIApplication,
        attempts: Int = 3,
        until landed: () -> Bool
    ) {
        for _ in 0..<attempts {
            let dismissed = dismissSavePasswordPromptIfPresent(in: app)
            element.tap()
            if landed() { return }

            // Retry while the dialog is still in play — either it is up now and ate this
            // tap, or it was up a moment ago and this tap landed during its dismissal.
            // Measured: attempt 0 is eaten by the sheet appearing, attempt 1 by the sheet
            // animating out, attempt 2 lands. Stopping after a successful dismissal was the
            // original bug: it gave up exactly one tap too early.
            guard app.sheets["Save Password?"].exists || dismissed else { return }
        }
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

    /// "Create an account" opens its own screen. It used to submit the sign-in form, which
    /// meant it was disabled until that form was valid and silently did nothing — and it could
    /// never collect the password confirmation registration actually needs.
    func testCreateAnAccountOpensItsOwnScreen() {
        let app = launchApp()
        let register = app.buttons["login.register"]
        XCTAssertTrue(register.waitForExistence(timeout: 10))

        // Reachable from an untouched form: it is navigation, not a second submit.
        XCTAssertTrue(register.isEnabled)
        XCTAssertGreaterThanOrEqual(register.frame.height, 44, "6.3 Default: 44pt touch target")
        register.tap()

        XCTAssertTrue(app.textFields["register.plate"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["register.confirm"].exists, "the field sign-in lacks")
        XCTAssertFalse(app.buttons["register.submit"].isEnabled, "nothing typed yet")
    }

    /// The plate rule is stated before it is broken, rather than arriving as a 400 with a
    /// field map nobody sees. Only the plate is exercised here: iOS puts its Automatic Strong
    /// Password cover view over a second secure field, so the password rules are pinned in
    /// `RegisterViewModelTests` where no keyboard is in the way.
    func testRegistrationStatesThePlateRuleBeforeItIsBroken() {
        let app = launchApp()
        app.buttons["login.register"].tap()

        let plate = app.textFields["register.plate"]
        XCTAssertTrue(plate.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["register.plate.note"].exists, "the rule, stated up front")

        plate.tap()
        plate.typeText("AB")
        XCTAssertEqual(app.staticTexts["register.plate.note"].label, "Between 3 and 20 characters.")
        XCTAssertFalse(app.buttons["register.submit"].isEnabled)
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
        tap(firstFree, in: app) { firstFree.waitForSelected(timeout: 2) }

        // Two separate waits, so a failure says whether the tap was lost or the bar failed
        // to appear after a registered tap. Collapsing them hides which half broke.
        XCTAssertTrue(
            firstFree.waitForSelected(timeout: 5),
            "the tap on space 1 did not register as a selection"
        )

        let confirm = app.buttons["dashboard.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "a selected space should raise the confirm bar")

        // The confirm button needs the same treatment: iOS can put its sheet up at any
        // point, and a swallowed confirm looks exactly like a reservation that never
        // resolved.
        let dismiss = app.buttons["outcome.dismiss"]
        tap(confirm, in: app) { dismiss.waitForExistence(timeout: 8) }

        // Whatever the result, the attempt must resolve into something the user can read.
        XCTAssertTrue(dismiss.exists, "an attempt must always resolve visibly")
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

/// The three uncertain outcomes, driven end to end.
///
/// These are the app's signature states and were the least observed: reaching one needs a
/// reply that never arrives, which until now meant standing a delaying proxy in front of the
/// real backend by hand. `-UITestOutcome` injects the transport failure instead, and the real
/// `ReservationCoordinator` reconciles against the real grid — so what these assert is that
/// the right *situation* is detected and the right sheet is shown, not that a stub returned a
/// string. The week-1 checkpoint reported the old single sheet as distressing; these pin the
/// three that replaced it.
@MainActor
final class UncertainOutcomeUITests: XCTestCase {

    private func reserveSpaceOne(outcome: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestMode", "-UITestSkipReauth", "-UITestOutcome", outcome]
        app.launch()

        let plate = app.textFields["login.plate"]
        XCTAssertTrue(plate.waitForExistence(timeout: 10))
        plate.tap()
        plate.typeText("TEST-001")
        let password = app.secureTextFields["login.password"]
        password.tap()
        password.typeText("probation123")
        app.buttons["login.submit"].tap()

        let firstFree = app.buttons["space.1"]
        XCTAssertTrue(firstFree.waitForExistence(timeout: 10), "grid should appear after sign in")
        tap(firstFree, in: app) { firstFree.waitForSelected(timeout: 2) }

        let confirm = app.buttons["dashboard.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        let dismiss = app.buttons["outcome.dismiss"]
        tap(confirm, in: app) { dismiss.waitForExistence(timeout: 8) }
        XCTAssertTrue(dismiss.exists, "an attempt must always resolve visibly")

        // Kept as an attachment: these three sheets are the hardest screens in the app to
        // reach by hand, and the week-2 walkthrough shows them rather than describing them.
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "outcome-\(outcome)"
        shot.lifetime = .keepAlways
        add(shot)

        return app
    }

    /// One space carries our suffix, so the sheet may point at it — while still not claiming
    /// a receipt exists. This is the case the old copy served worst: near-certain good news
    /// under a heading that said we did not know.
    func testProbableHoldNamesTheSpaceWithoutClaimingAReceipt() {
        let app = reserveSpaceOne(outcome: "probablyHeld")

        XCTAssertTrue(app.staticTexts["Space 7 looks like yours"].exists, "should name the space")
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'never sent a receipt'"))
                .firstMatch.exists,
            "must not read as a confirmation"
        )
    }

    /// Two plates share our suffix, so neither space may be named.
    func testSuffixCollisionRefusesToNameASpace() {
        let app = reserveSpaceOne(outcome: "ambiguous")

        XCTAssertTrue(app.staticTexts["Can't tell which space"].exists)
        XCTAssertFalse(
            app.staticTexts["Space 7 looks like yours"].exists,
            "a colliding suffix must never be reported as a held space"
        )
    }

    /// Nothing to go on. The sheet says what was sent and what to watch for, and — the part
    /// the checkpoint said was missing — where the money stands.
    func testNoEvidenceSaysWhatToWatchForAndWhatHappensToTheMoney() {
        let app = reserveSpaceOne(outcome: "noEvidence")

        XCTAssertTrue(app.staticTexts["Still checking"].exists)
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'nothing was charged'"))
                .firstMatch.exists,
            "the money question must be answered on the sheet"
        )
    }
}
