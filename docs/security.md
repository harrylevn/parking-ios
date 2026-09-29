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

## Secrets, logs and data at rest

Checked on 29/09, not assumed:

- **The repository.** Every commit's diff scanned for private keys, JWTs, cloud and GitHub
  tokens, and credential assignments; no key, certificate or `.env`-style file ever committed.
  The only hits are synthetic test passwords, and every plate in the history is `TEST-…`.
  `.gitignore` blocks `*.p12`, `*.mobileprovision`, `*.cer`, `.env` and the pinning demo's
  `.tls/`, whose keys never leave the machine that generated them.
- **Logs.** The app contains no logging calls at all: no `print`, `os_log`, `Logger` or
  `NSLog`, so nothing it handles can reach the device log.
- **The release bundle.** Seven files: the binary, `Info.plist`, `PkgInfo` and four string
  tables. No certificates, keys or fixtures; no token or credential in the binary's strings.
  One real finding, now fixed: the **UI-test environment was compiled into release builds**.
  Launching the release app with `-UITestMode` would have selected in-memory fakes and an
  always-yes re-authenticator, a Face ID bypass behind one launch argument, against the code's
  own claim that the bypass was compiled out. That environment, its stubs and
  `AlwaysAllowReauthenticator` now exist in debug builds only, and the release binary was
  re-inspected: no stub strings, no symbols.
- **Data at rest.** The session token is the only thing the app stores (Keychain, above). The
  URL cache was empty after a live session, but only because the backend sends
  `Cache-Control: no-store`, Spring Security's default. The app now uses an ephemeral
  `URLSession`, so no response is written to disk whatever the server sends.
- **CI.** No secrets are configured or echoed; the only artifact is test results, whose
  screenshots show synthetic data.

Still read from the environment in release builds: `PARKING_WINDOW_HOUR` (the countdown only;
the server enforces the window) and `PARKING_IDEMPOTENCY_KEYS` (turns retries off). Neither is
a security control. Server URL and pins are not.

**The backend's repository is another matter:** it commits the JWT signing key, so anyone with
the repository can mint a session for any user (`docs/defects.md` D10).

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

### Certificate pinning

**Built on 29/09**, replacing the omission this section used to defend. The backend is
plaintext and read-only, so TLS is terminated in front of it: `make tls` runs an nginx
container on `https://localhost:8443` that forwards to `:8080`. `scripts/tls-proxy.sh`
generates a local root CA and a `localhost` certificate it issues, both P-256, into `.tls/`.
That folder is gitignored, and no private key leaves it. The CA is added to the simulator's
trusted roots, so the chain validates the ordinary way, as a publicly issued certificate would.

**What the app checks** (`Sources/Data/CertificatePinning.swift`). Every HTTPS request goes
through a per-request `URLSessionTaskDelegate`. The server is trusted only if both hold:

1. The chain validates for this host name (`SecTrustEvaluateWithError` under an SSL policy
   for the host).
2. Some certificate in it carries a pinned key: the SHA-256 of its SubjectPublicKeyInfo,
   base64. That is the value `openssl` computes, so `make tls-pin` prints exactly what the app
   compares against.

Pinning narrows validation; it never replaces it. The right key on an untrusted chain is
refused, and so is a valid chain with the wrong key, which is what a certificate mis-issued by
a trusted CA, or one installed by whoever controls the network, looks like.

**How a refusal surfaces.** The handshake is cancelled before any request is sent, and the
client reports `APIError.untrustedServer`: "The server's identity couldn't be verified, so
nothing was sent. Try again on a network you trust." It is never retried, not even a
reservation's Idempotency-Key, because the only server a retry can reach is the one just
refused. It is deliberately not "check your connection", because the network may be the very
thing that is compromised.

**Fail closed.** An HTTPS URL with no pins configured trusts nothing. Plaintext exists only in
debug builds: a release build refuses any non-HTTPS request before sending it, so the
localhost ATS exception in `Info.plist` cannot become a release downgrade path.

**Policy choices, and why.**

- *Keys, not certificates.* A certificate is renewed every year or so and its key need not
  be, so pinning the key survives routine renewal.
- *A backup pin.* The app accepts a pinned key anywhere in the chain, so the issuing CA's key
  can be pinned alongside the server's. `scripts/tls-proxy.sh rotate` issues a new server key
  under the same CA. After that, an app pinning only the old key is locked out until it ships
  a new build, while one that also pinned the CA keeps working. The live demo shows both.
- *Where pins come from.* Debug builds read `PARKING_BASE_URL` and `PARKING_SPKI_PINS` from
  the scheme, because the local certificate is generated per machine. Release builds ignore
  the environment: pins supplied at launch could be replaced by anyone able to launch the app.
  With no production server in this exercise, a release build has nothing to connect to.

**Evidence.**

- `CertificatePinningTests`: nine unit tests on real certificates evaluated by the Security
  framework. Pins match `openssl`. The wrong key, an untrusted chain, the wrong host and an
  empty pin set are each refused, and the CA backup pin is accepted. Removing ordinary
  validation, the pin comparison or the host-name policy each fails its own test.
- `PinningDemoUITests`, run by `make pinning-demo` against the live backend through the proxy:
  - with the proxy's pin, sign-in reaches the backend (its "incorrect password" comes back)
  - with a wrong pin, the app refuses, and the proxy's access log shows no request at all
  - with a stale server pin plus the CA pin, it still connects, which is the post-rotation case

**What production would still add.** Pins for the real host shipped in the build, with at
least two backups from different keys, and a monitored expiry for each. A runbook for rotating
ahead of expiry. Reporting of pin failures, since a spike means either an attack or a botched
rotation. And the ATS exception moved to a debug-only `Info.plist`: here it is a runtime refusal
in release builds rather than an absent exception.

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
