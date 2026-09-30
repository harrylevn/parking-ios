import XCTest
@testable import Parking

/// A device build opened from the home screen has no scheme environment, so it must find its
/// server in Info.plist; and the scheme must still win when there is one.
final class LaunchSettingsTests: XCTestCase {

    func testInfoPlistFillsWhatTheEnvironmentLeavesOut() {
        let settings = LaunchSettings.merged(
            environment: [:],
            infoDictionary: ["PARKING_BASE_URL": "http://Mac.local:8080", "PARKING_WINDOW_HOUR": "17"]
        )
        XCTAssertEqual(settings["PARKING_BASE_URL"], "http://Mac.local:8080")
        XCTAssertEqual(settings["PARKING_WINDOW_HOUR"], "17")
    }

    func testTheEnvironmentWins() {
        let settings = LaunchSettings.merged(
            environment: ["PARKING_BASE_URL": "https://localhost:8443"],
            infoDictionary: ["PARKING_BASE_URL": "http://Mac.local:8080"]
        )
        XCTAssertEqual(settings["PARKING_BASE_URL"], "https://localhost:8443")
    }

    /// Unset in the xcconfig, or left unexpanded by a build, is not a value.
    func testEmptyAndUnexpandedValuesAreIgnored() {
        let settings = LaunchSettings.merged(
            environment: [:],
            infoDictionary: ["PARKING_BASE_URL": "", "PARKING_WINDOW_HOUR": "$(PARKING_WINDOW_HOUR)"]
        )
        XCTAssertNil(settings["PARKING_BASE_URL"])
        XCTAssertNil(settings["PARKING_WINDOW_HOUR"])
    }

    /// Only the app's own keys are taken from Info.plist, never anything else in it.
    func testOnlyTheAppsKeysAreRead() {
        let settings = LaunchSettings.merged(environment: [:], infoDictionary: ["CFBundleName": "Parking"])
        XCTAssertNil(settings["CFBundleName"])
    }
}
