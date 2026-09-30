import Foundation

/// What this launch is configured with.
///
/// The scheme's environment first: that is how Xcode runs and the tests configure the app.
/// Then, in debug builds only, the values the build wrote into `Info.plist` from
/// `Config/*.xcconfig`. A build installed on a device and opened from the home screen has no
/// scheme, so without the second source it would fall back to `localhost`, which on a phone
/// is the phone. Release builds read the environment alone, as before.
enum LaunchSettings {
    static let keys = ["PARKING_BASE_URL", "PARKING_WINDOW_HOUR", "PARKING_SPKI_PINS"]

    static var current: [String: String] {
        merged(environment: ProcessInfo.processInfo.environment, infoDictionary: Bundle.main.infoDictionary)
    }

    static func merged(environment: [String: String], infoDictionary: [String: Any]?) -> [String: String] {
        var settings = environment
        #if DEBUG
        for key in keys where (settings[key] ?? "").isEmpty {
            // Empty when the xcconfig leaves it unset; "$(…)" if a build ever failed to expand it.
            guard let value = infoDictionary?[key] as? String,
                  !value.isEmpty, !value.hasPrefix("$(") else { continue }
            settings[key] = value
        }
        #endif
        return settings
    }
}
