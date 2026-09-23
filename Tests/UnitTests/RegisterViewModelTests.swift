import XCTest
@testable import Parking

/// Registration has rules sign-in does not, and the backend enforces them whether or not the
/// client mentions them (`AuthRequest`: 3–20 characters of `[A-Z0-9-]`, password 6–100). These
/// pin that the screen states them rather than letting a 400 explain them afterwards.
@MainActor
final class RegisterViewModelTests: XCTestCase {

    private func makeModel(account: Account? = nil) -> RegisterViewModel {
        RegisterViewModel(environment: makeEnvironment(account: account))
    }

    func testAnUntouchedFormShowsNoProblems() {
        let model = makeModel()
        XCTAssertNil(model.plateProblem)
        XCTAssertNil(model.passwordProblem)
        XCTAssertNil(model.confirmProblem)
        XCTAssertFalse(model.canSubmit, "but it still cannot be submitted")
    }

    func testPlateMustMatchWhatTheBackendAccepts() {
        let model = makeModel()

        model.licensePlate = "AB"
        XCTAssertNotNil(model.plateProblem, "under three characters")

        model.licensePlate = "AB 123"
        XCTAssertNotNil(model.plateProblem, "a space is outside [A-Z0-9-]")

        model.licensePlate = String(repeating: "A", count: 21)
        XCTAssertNotNil(model.plateProblem, "over twenty characters")

        model.licensePlate = "abc-123"
        XCTAssertNil(model.plateProblem, "lower case is fine; it is uppercased before sending")
        XCTAssertEqual(model.normalisedPlate, "ABC-123")
    }

    func testPasswordsMustMatchAndBeLongEnough() {
        let model = makeModel()
        model.licensePlate = "TEST-001"

        model.password = "12345"
        XCTAssertNotNil(model.passwordProblem)

        model.password = "probation123"
        XCTAssertNil(model.passwordProblem)

        model.confirmPassword = "probation124"
        XCTAssertNotNil(model.confirmProblem)
        XCTAssertFalse(model.canSubmit)

        model.confirmPassword = "probation123"
        XCTAssertNil(model.confirmProblem)
        XCTAssertTrue(model.canSubmit)
    }

    func testASuccessfulRegistrationSignsTheUserIn() async {
        let environment = makeEnvironment(account: nil)
        let model = RegisterViewModel(environment: environment)
        model.licensePlate = "TEST-001"
        model.password = "probation123"
        model.confirmPassword = "probation123"

        await model.register()

        XCTAssertEqual(environment.account?.licensePlate, "TEST-001")
        XCTAssertNil(model.errorMessage)
    }

    func testAFailedRegistrationReportsItAndSignsNobodyIn() async {
        let environment = makeEnvironment(
            auth: StubAuth(result: .failure(.business(
                ErrorResponse(
                    status: 409, error: "Conflict",
                    message: "License plate already registered: TEST-001",
                    code: .duplicateResource, timestamp: Date(), path: "/auth/register",
                    validationErrors: nil
                )
            ))),
            account: nil
        )
        let model = RegisterViewModel(environment: environment)
        model.licensePlate = "TEST-001"
        model.password = "probation123"
        model.confirmPassword = "probation123"

        await model.register()

        XCTAssertNil(environment.account)
        // Not "the server sent something we couldn't read": the code decodes, so the message
        // can name the actual problem.
        XCTAssertEqual(model.errorMessage, "That plate already has an account. Sign in instead.")
    }
}
