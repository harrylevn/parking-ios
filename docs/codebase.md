# Codebase

A map of what lives where and why, for someone opening this repository cold.
Architecture *decisions* live in [`architecture.md`](architecture.md) as seven numbered ADRs,
and [`design.md`](design.md) carries the problem, the interface and the deviations. This file
is the layout.

Roughly 8,600 lines of Swift across 50 files: ~4,800 of app code in 28, ~3,800 of tests in 22.

## Layout

```
project.yml              XcodeGen manifest — the source of truth for the project
Parking.xcodeproj/       generated, NOT committed; run `make project` after a clone
Makefile                 build / test / lint / archive entry points, same ones CI uses
.swiftlint.yml           lint rules; force unwrap and force cast are errors, not warnings
.github/workflows/ci.yml build, lint, unit tests, UI tests, archive
Config/                  Parking.xcconfig, plus gitignored Local and Device overrides
Gemfile, fastlane/       build tooling only: thin lanes over the Makefile, gym for the .ipa
scripts/                 backend-up.sh brings Postgres, Redis and the API up from nothing;
                         the rest drive the demo, rehearsals, concurrency, TLS, the trace,
                         the .ipa, and the coverage and String Catalog checks

Sources/
  App/                   composition root and entry point
  Domain/                models, service protocols, and the two pieces of real logic
  Data/                  HTTP, DTOs, Keychain, biometrics — conforms to Domain protocols
  Features/              SwiftUI views and their @MainActor view models
  DesignSystem/          colour, metric and component tokens

Tests/
  UnitTests/             domain, view models and the network layer, against fakes;
                         snapshot references in __Snapshots__/
  UITests/               the reserve flow, the board's geometry and an accessibility audit
                         against in-process fakes; live suites the scripts run, skipped in CI

docs/                    architecture (ADRs), design, plan, security, runbook, defects,
                         accessibility, performance, AI account, both checkpoint decks
```

## Dependency direction

```
Features ─────┐
              ├──► Domain ◄────── Data
App ──────────┘   (protocols)     (implementations)
```

`Domain` depends on nothing but Foundation. `Data` implements the protocols `Domain`
declares. `Features` talks only to protocols. `App` is the only place that knows which
concrete implementation is used — so no view can reach networking or persistence, and every
collaborator can be replaced with a fake in a test.

## The files that matter

Most of this codebase is plumbing. Five files carry the load, and they are the ones to read
first:

| File | What it is |
|---|---|
| `Domain/ReservationCoordinator.swift` | Decides what the app may truthfully claim about a reservation. Enforces one-tap-one-attempt with one Idempotency-Key per tap, repeats that key after a timeout, reads back with `GET /reservations/me`, falls back to the grid only if that fails, and returns `.unknown` when the result cannot be substantiated. An `actor` because the in-flight flag is the guardrail. |
| `Domain/ServerClock.swift` | Server time from the HTTP `Date` header anchored to a `ContinuousClock`, because the backend has no time endpoint and the device clock cannot be trusted. `ReservationWindow` models the gate exactly as the backend implements it: opens on the hour, shuts at midnight. |
| `Data/HTTPClient.swift` | Exists mainly for `decodeFailure`, which branches on **body emptiness, not status**, because the backend answers with two different shapes and treating them as one is a crash. |
| `Data/CertificatePinning.swift` | Certificate pinning: the SPKI hash, the evaluator (chain must validate for the host **and** carry a pinned key), and the per-request delegate that lets `HTTPClient` tell a refused certificate from any other transport failure. See `security.md`. |
| `Features/BoardLayout.swift` | Sizes the 80-cell board to the space available so every cell fits on a 6.1-inch screen. Pure, so the guardrail is asserted in a unit test rather than eyeballed on a simulator. |

### The rest

**`App/AppEnvironment.swift`** — composition root. Three factories: `live()` (Keychain, real
HTTP, biometrics), `uiTesting()` (in-memory stubs, selected by `-UITestMode`), and
`reauthenticator()`, which honours `-UITestSkipReauth`. Both test hooks are inside
`#if DEBUG`, so a release binary contains neither (`security.md`).

**`App/LaunchSettings.swift`** — the server address, window hour and pins: from the scheme's
environment, then, in debug builds only, from `Info.plist`, so a build opened from a phone's
home screen still knows where the backend is.

**`Domain/Services.swift`** — the service protocols every view model is written against.

**`Domain/APIError.swift`** — the error taxonomy. `BusinessErrorCode` mirrors the backend's
codes; `APIError` separates a business error from the bare 401, a transport failure and a
malformed response. `requiresReauthentication` is true *only* for the bare 401.
`isSafelyRetryable` is false for `windowClosed` despite its 429.

**`Domain/Models.swift`** — `ParkingSpace`, `SpaceGrid`, `Reservation`, `Account`, and
`ReservationOutcome`, with five cases: `won`, `lost`, `rejected`, `notConfirmed` (Face ID
declined, nothing sent), and `unknown`. The last carries an `Uncertainty`, because "probably
yours", "ambiguous" and "no evidence" are different things to tell someone about their $10.

**`Data/ParkingAPI.swift`** — wire DTOs (private to the file) and the four services. DTOs are
separate from domain models so a contract change does not ripple into the UI.

**`Data/BiometricReauthenticator.swift`** — the Face ID prompt before money moves, with the
device passcode as the fallback. The caller supplies the reason, which names the amount.

**`Data/KeychainTokenStore.swift`** — `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, with the
reasoning in the file. Delete-then-add rather than update, so a change of accessibility class
actually takes effect. `InMemoryTokenStore` alongside it for tests.

**`Features/GridViewModel.swift`** — the screen's state. `GridState` models the full state
matrix; `mySpace` applies the same never-claim-what-you-cannot-prove rule as the coordinator.
Both `refresh()` and `updateClock()` publish **only on change** — writing an identical value
to an `@Published` property still fires `objectWillChange`, which cost a 1 Hz full-screen
invalidation before it was fixed. It also owns the 20:00 moment (design.md §5.7): one
refetch as the window opens, the age of the free count once it goes stale, and dropping a
selection the board shows taken.

**`Features/CountdownPhase.swift`** — early, final minute, final ten seconds, open. Pure,
so the thresholds are tested without a clock; the hero picks its copy from it and the
dashboard announces each phase to VoiceOver once.

**`Features/DashboardView.swift`** — chooses between a stacked portrait layout and a
side-by-side wide layout (iPad, or iPhone landscape). One `.sheet` modifier driven by an
enum; two `.sheet` modifiers on one view silently lose the second.

**The other views** — `BoardView`, `SpaceCell`, `ConfirmBar`, `CountdownHero`,
`DashboardHeader`, `OutcomeSheet`, `DepositSheet`, `LoginView`, `RegisterView` and
`DesignSystem/FormField`. Layout and copy; the decisions behind them are in `design.md` §5.

**`DesignSystem/Theme.swift`** — tokens in code rather than an asset catalog, so every value
is reviewable in a diff. Note `CardBackground`'s border overlay carries
`.allowsHitTesting(false)`; without it the overlay swallows every touch inside the card.

## Tests

| File | Covers |
|---|---|
| `ErrorDecodingTests` | Both 401 shapes, `WINDOW_CLOSED` as 429, the validation-errors map — against bytes captured from the running backend |
| `ReservationCoordinatorTests` | Won race, lost race, concurrent double-tap, timeout reconciliation, suffix collision, `DUPLICATE_REQUEST` vs `ALREADY_RESERVED` |
| `ReservationRetryTests` | ADR-007: the same key repeated after a timeout, `IDEMPOTENCY_IN_PROGRESS`, the read-back, and the grid only as the last resort |
| `HoldingClaimTests` | Only a reservation that came back with a receipt makes a space "yours"; a plate-suffix match on the board is evidence, not proof |
| `ServerClockTests` | Extrapolation, skew detection, and the window's open/shut boundaries including the midnight rollover |
| `BoardLayoutTests` | That `BoardLayout` fills whatever rectangle it is handed — the arithmetic of the 6.3 guardrail, against a *modelled* 6.1-inch screen |
| `BoardGeometryUITests` | That the rectangle is the one the screen really has: all 80 cells **hittable** and 44pt in the running app. The model was 44pt light once and the unit tests stayed green through it |
| `ViewModelTests` | `GridViewModel` and `LoginViewModel`: offline vs failed, sign-out rules, balance movement, countdown gating, deposit paths |
| `RegisterViewModelTests` | The screen states the backend's plate and password rules before a 400 can, and a registration signs the user in |
| `NetworkLayerTests` | `HTTPClient` and the four services through a stubbed `URLProtocol`: headers, bodies, the idempotency key, and each error shape |
| `CertificatePinningTests` | The SPKI hash, the evaluator, and the per-request delegate; each check mutation-tested |
| `KeychainTokenStoreTests` | A round trip through the real Keychain, and the accessibility class it stores with |
| `LaunchSettingsTests` | Environment before `Info.plist`, and `Info.plist` ignored when empty or unexpanded |
| `ViewSnapshotTests` | 20 views against reference images, with no library (`Snapshotting.swift`) |
| `AccessibilityAuditUITests` | Apple's audit in light, dark and the largest text, with each accepted finding named |
| `OpeningMomentTests` | Countdown phase thresholds; exactly one refetch at the opening and none on launching into an open window; the count's age; a taken pick dropped, a free one kept |
| `ReservationFlowUITests` | Login → grid → select → confirm → outcome, against in-process fakes |
| `ScreenshotTests` | Drives the app against the **live** backend and captures each screen. Skipped unless `SCREENSHOTS=1`, so CI never runs it |
| `RehearsalUITests`, `PinningDemoUITests` | Live suites driven by `make rehearse`, `make concurrent`, `make trace` and `make pinning-demo`; skipped unless those scripts enable them |

No test touches the network except those live suites, which are opt-in and never run in CI.

## Conventions

- `project.yml` is authoritative. Adding a file means `make project`, not editing the
  `.xcodeproj` — which is generated and gitignored.
- Comments explain *why*. A comment restating the code is noise; a comment explaining why a
  `nonisolated(unsafe)` is safe, or why an overlay needs `.allowsHitTesting(false)`, earns
  its place.
- No third-party dependencies in the app. `URLSession`, `Security`, `CryptoKit` and
  `LocalAuthentication` cover everything needed, and a dependency in a banking app is a
  supply-chain liability. fastlane is the one dependency, and it is build tooling only.
- Force unwrap, force cast and force try are lint **errors** outside test fixtures.

## Gotchas

**Keep the clone out of a cloud-synced folder.** Under an iCloud-synced `~/Documents`, sync
extended attributes break iOS code signing with `Command CodeSign failed with a nonzero exit
code`, and iCloud makes conflict copies such as `Parking 2.xcodeproj` when `make project`
replaces the project. The original working copy got round the first by making `.build` a
symlink to `~/Library/Caches/parking-ios-build`, and has since moved out of `~/Documents`.
A fresh clone elsewhere needs neither: `.build/` is a plain, gitignored directory.

**The countdown needs a server reading.** Until one response has been seen the UI shows
"Checking server time…" rather than a countdown. That is deliberate, not a loading bug.

**The window hour is configuration.** `PARKING_WINDOW_HOUR` in the scheme's environment must
match the hour the backend was started with, or the client will disagree with the server
about whether reservations are open.
