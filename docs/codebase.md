# Codebase

A map of what lives where and why, for someone opening this repository cold.
Architecture *decisions* live in [`architecture.md`](architecture.md) as six numbered ADRs,
and [`design.md`](design.md) carries the problem, the interface and the deviations. This file
is the layout.

Roughly 4,100 lines of Swift across 29 files: ~3,000 of app code, ~1,100 of tests.

## Layout

```
project.yml              XcodeGen manifest — the source of truth for the project
Parking.xcodeproj/       generated, NOT committed; run `make project` after a clone
Makefile                 build / test / lint / archive entry points, same ones CI uses
.swiftlint.yml           lint rules; force unwrap and force cast are errors, not warnings
.github/workflows/ci.yml build, lint, unit tests, UI tests, archive
scripts/backend-up.sh    brings Postgres, Redis and the API up from nothing

Sources/
  App/                   composition root and entry point
  Domain/                models, service protocols, and the two pieces of real logic
  Data/                  HTTP, DTOs, Keychain, biometrics — conforms to Domain protocols
  Features/              SwiftUI views and their @MainActor view models
  DesignSystem/          colour, metric and component tokens

Tests/
  UnitTests/             domain and view models, against fakes only
  UITests/               the reserve flow against in-process fakes, plus screenshot capture

docs/                    architecture (ADRs), design, plan, security, runbook, defects,
                         checkpoint deck and notes, AI account
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

Most of this codebase is plumbing. Four files carry the load, and they are the ones to read
first:

| File | What it is |
|---|---|
| `Domain/ReservationCoordinator.swift` | Decides what the app may truthfully claim about a reservation. Enforces one-tap-one-attempt, never retries a timeout, reconciles against the grid, and returns `.unknown` when the result cannot be substantiated. An `actor` because the in-flight flag is the guardrail. |
| `Domain/ServerClock.swift` | Server time from the HTTP `Date` header anchored to a `ContinuousClock`, because the backend has no time endpoint and the device clock cannot be trusted. `ReservationWindow` models the gate exactly as the backend implements it: opens on the hour, shuts at midnight. |
| `Data/HTTPClient.swift` | Exists mainly for `decodeFailure`, which branches on **body emptiness, not status**, because the backend answers with two different shapes and treating them as one is a crash. |
| `Features/BoardLayout.swift` | Sizes the 80-cell board to the space available so every cell fits on a 6.1-inch screen. Pure, so the guardrail is asserted in a unit test rather than eyeballed on a simulator. |

### The rest

**`App/AppEnvironment.swift`** — composition root. Three factories: `live()` (Keychain, real
HTTP, biometrics), `uiTesting()` (in-memory stubs, selected by `-UITestMode`), and
`reauthenticator()`, which honours `-UITestSkipReauth` inside `#if DEBUG` only.

**`Domain/APIError.swift`** — the error taxonomy. `BusinessErrorCode` mirrors the backend's
codes; `APIError` separates a business error from the bare 401, a transport failure and a
malformed response. `requiresReauthentication` is true *only* for the bare 401.
`isSafelyRetryable` is false for `windowClosed` despite its 429.

**`Domain/Models.swift`** — `ParkingSpace`, `SpaceGrid`, `Reservation`, `Account`, and
`ReservationOutcome`, which has four cases because one of the states the backend can leave
you in is genuinely "unknown".

**`Data/ParkingAPI.swift`** — wire DTOs (private to the file) and the four services. DTOs are
separate from domain models so a contract change does not ripple into the UI.

**`Data/KeychainTokenStore.swift`** — `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, with the
reasoning in the file. Delete-then-add rather than update, so a change of accessibility class
actually takes effect. `InMemoryTokenStore` alongside it for tests.

**`Features/GridViewModel.swift`** — the screen's state. `GridState` models the full state
matrix; `mySpace` applies the same never-claim-what-you-cannot-prove rule as the coordinator.
Both `refresh()` and `updateClock()` publish **only on change** — writing an identical value
to an `@Published` property still fires `objectWillChange`, which cost a 1 Hz full-screen
invalidation before it was fixed.

**`Features/DashboardView.swift`** — chooses between a stacked portrait layout and a
side-by-side wide layout (iPad, or iPhone landscape). One `.sheet` modifier driven by an
enum; two `.sheet` modifiers on one view silently lose the second.

**`DesignSystem/Theme.swift`** — tokens in code rather than an asset catalog, so every value
is reviewable in a diff. Note `CardBackground`'s border overlay carries
`.allowsHitTesting(false)`; without it the overlay swallows every touch inside the card.

## Tests

| File | Covers |
|---|---|
| `ErrorDecodingTests` | Both 401 shapes, `WINDOW_CLOSED` as 429, the validation-errors map — against bytes captured from the running backend |
| `ReservationCoordinatorTests` | Won race, lost race, concurrent double-tap, timeout reconciliation, suffix collision, `DUPLICATE_REQUEST` vs `ALREADY_RESERVED` |
| `ServerClockTests` | Extrapolation, skew detection, and the window's open/shut boundaries including the midnight rollover |
| `BoardLayoutTests` | That all 80 cells fit a 6.1-inch screen at a 44pt target — the 6.3 guardrail, asserted rather than eyeballed |
| `ViewModelTests` | `GridViewModel` and `LoginViewModel`: offline vs failed, sign-out rules, balance movement, countdown gating, deposit paths |
| `ReservationFlowUITests` | Login → grid → select → confirm → outcome, against in-process fakes |
| `ScreenshotTests` | Drives the app against the **live** backend and captures each screen. Skipped unless `SCREENSHOTS=1`, so CI never runs it |

No test touches the network except `ScreenshotTests`, which is opt-in.

## Conventions

- `project.yml` is authoritative. Adding a file means `make project`, not editing the
  `.xcodeproj` — which is generated and gitignored.
- Comments explain *why*. A comment restating the code is noise; a comment explaining why a
  `nonisolated(unsafe)` is safe, or why an overlay needs `.allowsHitTesting(false)`, earns
  its place.
- No third-party dependencies. `URLSession`, `Security` and `LocalAuthentication` cover
  everything needed, and a dependency in a banking app is a supply-chain liability.
- Force unwrap, force cast and force try are lint **errors** outside test fixtures.

## Gotchas

**`.build` is a symlink.** It points at `~/Library/Caches/parking-ios-build`. This repository
lives under `~/Documents`, which is cloud-synced, and sync extended attributes break iOS code
signing with `Command CodeSign failed with a nonzero exit code`. If you clone elsewhere the
symlink is unnecessary; if you keep it here, do not replace it with a real directory.

**The countdown needs a server reading.** Until one response has been seen the UI shows
"Checking server time…" rather than a countdown. That is deliberate, not a loading bug.

**The window hour is configuration.** `PARKING_WINDOW_HOUR` in the scheme's environment must
match the hour the backend was started with, or the client will disagree with the server
about whether reservations are open.
