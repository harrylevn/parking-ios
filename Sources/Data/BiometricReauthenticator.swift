import Foundation
import LocalAuthentication

/// Face ID / Touch ID re-authentication ahead of a reservation (6.5, Default column — kept
/// as written).
///
/// **Every attempt prompts.** An earlier version carried a 120-second grace period, argued
/// from the race: a modal in the critical path of a contest decided in milliseconds costs
/// seconds. That argument weighed the wrong thing. A reservation debits $10, and in a banking
/// context step-up authentication is not a proportionality control keyed to the amount — it
/// exists to evidence that the account holder consented to *this* transaction. A session-scoped
/// exemption destroys exactly that evidence, and it is free for anyone holding the unlocked
/// handset, which is the wrong party to make it cheap for. The race cost is real and is now
/// accepted rather than designed around; see ADR-006.
///
/// `.deviceOwnerAuthentication` rather than `.deviceOwnerAuthenticationWithBiometrics` is
/// deliberate: it falls back to the device passcode automatically, so a user without
/// biometrics, or with Face ID locked out after failed attempts, can still reserve. Using the
/// biometrics-only policy would lock those users out of the product entirely.
///
/// On a device with no passcode at all there is nothing to authenticate against. That is
/// treated as a pass rather than a hard block, because refusing would make the app unusable
/// on the simulator the demo runs on; with the grace period gone this is the single remaining
/// gap in the control, and the trade-off is recorded in docs/security.md.
struct BiometricReauthenticator: Reauthenticating {

    func authenticate(reason: String) async throws {
        // A fresh context per attempt, and never a stored one. `LAContext` keeps its own
        // recent-success window in `touchIDAuthenticationAllowableReuseDuration`; it defaults
        // to zero, but a context held across attempts is the same grace period by another
        // name, reintroduced where no reviewer would think to look for it.
        let context = LAContext()

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No passcode configured; nothing to authenticate against.
            return
        }

        try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
    }
}

#if DEBUG
/// Always-succeeds stand-in for tests and previews, so the non-biometric path is
/// exercised without a device. Debug builds only: it is a Face ID bypass.
struct AlwaysAllowReauthenticator: Reauthenticating {
    func authenticate(reason: String) async throws {}
}
#endif
