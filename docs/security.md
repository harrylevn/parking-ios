# Security

## Session token storage

The JWT lives in the Keychain (`Sources/Data/KeychainTokenStore.swift`), never in
`UserDefaults` or a plist.

**Accessibility class: `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.**

- `WhenUnlocked` — the app does no background work, so the token is only ever needed while
  someone is looking at the screen. Leaving it readable on a locked device buys nothing and
  widens the window in which a lost handset is useful to an attacker.
- `ThisDeviceOnly` — excludes the item from encrypted backups and iCloud Keychain sync. A
  bearer token authorising paid reservations should not survive a restore onto a different
  handset. The cost is re-authentication after a device migration, which is the right trade.
- Not `AfterFirstUnlock`, which keeps the item readable from first unlock until reboot. That
  is the correct class for background refresh, which this app does not do.

Writes are delete-then-add rather than `SecItemUpdate`, so a change of accessibility class
actually takes effect instead of silently retaining the previous one.

## Secrets

No secrets, keys or credentialled endpoints are committed or shipped in the bundle. There
are none to commit: the backend is local and unauthenticated until a user registers, and the
only credentials in the repo are synthetic (`TEST-####`). `.gitignore` blocks `*.p12`,
`*.mobileprovision`, `*.cer` and `.env`.

## Re-authentication

Face ID / Touch ID before **any action that moves money**, via `.deviceOwnerAuthentication` so
the device passcode is the automatic fallback — a user without biometrics, or locked out after
failed attempts, can still reserve. The biometrics-only policy would lock those users out of
the product entirely.

Two actions qualify, and the prompt names the amount in both:

| Action | Prompt |
|---|---|
| Reserve a space (debits $10) | "Confirm your parking reservation" |
| Deposit into the wallet (credits it) | "Confirm a $50 deposit" |

The deposit was added after the week-1 checkpoint raised it. Gating only the reservation read
the requirement as being about spending rather than about the money path, and left the credit
side reachable by anyone holding the unlocked handset.

**Every attempt prompts.** There is no grace period and no session-scoped exemption: a
reservation debits $10, and the control exists to evidence consent to *this* transaction
rather than to one authorised earlier. An earlier build carried a 120-second window, argued
from the race; `docs/design.md` §4 records why that argument was withdrawn.

Each attempt builds a fresh `LAContext`. A context held across attempts would reintroduce the
same exemption through `touchIDAuthenticationAllowableReuseDuration`, which is the form a
reviewer is least likely to spot.

On a device with no passcode configured there is nothing to authenticate against, and this is
treated as a pass. With the grace period gone this is the **only remaining gap** in the
control. It is a deliberate simplification for a simulator demo; in production it would be a
hard block with an onboarding message, because a device with no passcode has no Keychain
protection worth the name either.

## Transport

The local backend is plaintext HTTP, so ATS carries an exception **scoped to `localhost`**
(`Sources/App/Info.plist`). It does not disable ATS globally, and it does not apply to any
other host.

Certificate pinning is **not implemented**, and this is a considered omission rather than an
oversight. There is no certificate to pin: the backend is `http://localhost:8080` with no TLS
termination anywhere in the exercise. Implementing pinning here would mean pinning a
self-signed certificate generated for the demo, which demonstrates the API call but not the
control — the hard parts of pinning in production are rotation, backup pins and failure
modes, none of which a localhost stub exercises. What I would ship:
`URLSessionDelegate` validating the leaf's SPKI hash against a pinned set with at least one
backup pin, the bypass compiled out of release builds with `#if DEBUG` rather than gated at
runtime, and a documented rotation runbook.

## Threat note — what this exercise does not implement

A local-only, synthetic-data exercise on a personal Apple ID. The following are out of scope
here and would not be in production:

**Jailbreak / integrity detection.** Not implemented. In production I would check for common
indicators and, more usefully, attest app integrity server-side (DeviceCheck or App Attest)
so the decision is not made by code an attacker controls. Out of scope here because it is
trivially bypassed on a simulator and would demonstrate nothing.

**Code obfuscation.** Not implemented. Its value is real but narrow — raising the cost of
static analysis — and it complicates crash symbolication. In production it would be applied
to key derivation and pinning logic only, not wholesale.

**Data residency and retention.** Not applicable: nothing leaves the machine and the only
persisted data is a JWT in the Keychain. In production, reservation and payment records are
personal data under Vietnamese law and would need a stated retention period, a deletion path,
and confirmation that the backing store and its backups stay in-region.

**Certificate pinning.** See above.

**Root/debugger detection, anti-tampering, screenshot suppression.** Not implemented. For a
parking app the sensitive data on screen is a licence plate suffix and a balance; the
threat does not justify the cost. In a banking app proper, screenshot suppression on
balance-bearing screens would be table stakes.

**Token lifetime.** The backend issues 24-hour JWTs with no refresh token and no revocation.
The client cannot fix this, but it is worth stating: a stolen token is valid for up to a day
and cannot be revoked. In production this would be a short-lived access token plus a
rotating refresh token, with server-side revocation on sign-out.

## What the client does defensively

- Classifies errors on the business `code`, never on HTTP status, so a 429 that means
  "window closed" is not retried as if it were rate limiting.
- Distinguishes the two 401 shapes, so a mistyped password does not destroy the session.
- Never claims a reservation it cannot substantiate (`docs/design.md` §3).
- Never trusts the device clock for the reservation window, and warns when device and server
  disagree by more than 30 seconds.
