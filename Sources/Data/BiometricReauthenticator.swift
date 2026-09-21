import Foundation
import LocalAuthentication

/// Face ID / Touch ID re-authentication ahead of a reservation (6.5, Default column).
///
/// `.deviceOwnerAuthentication` rather than `.deviceOwnerAuthenticationWithBiometrics` is
/// deliberate: it falls back to the device passcode automatically, so a user without
/// biometrics, or with Face ID locked out after failed attempts, can still reserve. Using the
/// biometrics-only policy would lock those users out of the product entirely.
///
/// On a device with no passcode at all there is nothing to authenticate against. That is
/// treated as a pass rather than a hard block, because refusing would make the app unusable
/// on the simulator the demo runs on; the trade-off is recorded in docs/security.md.
struct BiometricReauthenticator: Reauthenticating {
    /// Re-authentication is skipped within this window, so the 20:00 race is not gated on a
    /// biometric prompt for every tap. See docs/design.md — the brief's Default column puts
    /// re-auth before *a* reservation, and a prompt in the critical path of a race that 92%
    /// of users lose costs seconds that decide the outcome.
    let gracePeriod: TimeInterval

    private let lastSuccess: LastSuccessBox

    init(gracePeriod: TimeInterval = 120) {
        self.gracePeriod = gracePeriod
        self.lastSuccess = LastSuccessBox()
    }

    func authenticate(reason: String) async throws {
        if let last = await lastSuccess.value, Date().timeIntervalSince(last) < gracePeriod {
            return
        }

        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No passcode configured; nothing to re-authenticate against.
            await lastSuccess.set(Date())
            return
        }

        try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        await lastSuccess.set(Date())
    }
}

private actor LastSuccessBox {
    var value: Date?
    func set(_ date: Date) { value = date }
}

/// Always-succeeds stand-in for tests and previews, so the non-biometric path is
/// exercised without a device.
struct AlwaysAllowReauthenticator: Reauthenticating {
    func authenticate(reason: String) async throws {}
}
