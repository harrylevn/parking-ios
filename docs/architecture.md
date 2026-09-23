# Architecture decision records

Each record is one decision: the context that forced it, what was decided, what else was
considered, and what it costs. Records are immutable — when a decision changes, the old one is
marked **Superseded** and a new record explains why, rather than the history being edited away.

This is the decision log. [`design.md`](design.md) is the narrative version for a reader who
wants the argument in prose, and [`codebase.md`](codebase.md) is the map of where things live.
Where a decision deviates from the brief's Default column, the deviation is named explicitly.

| # | Decision | Status |
|---|---|---|
| [001](#adr-001) | MVVM with protocol-injected services | Accepted |
| [002](#adr-002) | No third-party dependencies | Accepted |
| [003](#adr-003) | Swift 6 language mode with complete strict concurrency | Accepted |
| [004](#adr-004) | `ReservationOutcome` carries an `unknown` case | Accepted |
| [005](#adr-005) | One tap, one attempt, enforced in an actor | Accepted |
| [006](#adr-006) | Never retry a timed-out reservation; reconcile instead | Accepted |
| [007](#adr-007) | Classify errors on `code`, never on HTTP status | Accepted |
| [008](#adr-008) | Decode failures by body emptiness, not status | Accepted |
| [009](#adr-009) | Server time from the HTTP `Date` header | Accepted |
| [010](#adr-010) | Poll `/spaces` every 5s, publish only on change | Accepted |
| [011](#adr-011) | Pessimistic reservation, not optimistic UI | Accepted — deviates from Default |
| [012](#adr-012) | Biometric re-auth with a 120-second grace period | Accepted — deviates from Default |
| [013](#adr-013) | Keychain, `WhenUnlockedThisDeviceOnly` | Accepted |
| [014](#adr-014) | Scroll the board to protect the 44pt target | **Superseded by 015** |
| [015](#adr-015) | Fit all 80 cells; size the board to the screen | Accepted |
| [016](#adr-016) | Side-by-side layout when width allows | Accepted |
| [017](#adr-017) | Generate the Xcode project with XcodeGen | Accepted |
| [018](#adr-018) | Self-hosted CI runner | Accepted |
| [019](#adr-019) | Certificate pinning not implemented | **Rejected for now** — known risk |

---

<a name="adr-001"></a>
## ADR-001 — MVVM with protocol-injected services

**Status:** Accepted

**Context.** 6.1 makes "services behind protocols and injected, fakeable in tests" a
guardrail, and offers "MVVM or Clean Architecture" as a Default. The app is one significant
screen plus a login screen; the complexity is in correctness under contention, not in
navigation or state choreography.

**Decision.** Three layers — `Features` (SwiftUI + `@MainActor` view models), `Domain`
(models, protocols, and the two pieces of real logic), `Data` (HTTP, Keychain, biometrics) —
with `App/AppEnvironment` as the single composition root. `Domain` imports nothing but
Foundation. `Data` implements protocols `Domain` declares. No view touches networking or
persistence.

**Alternatives.** TCA, offered as a stretch. Rejected: it would add the project's only
dependency, and its value — exhaustive state reducers, time-travel debugging — is aimed at
complex state choreography this app does not have. The hard problems here are "what may the
app truthfully claim" and "is the clock trustworthy", neither of which a unidirectional
architecture solves. Clean Architecture with use-case objects was also considered and rejected
as ceremony: the use cases would be one-line pass-throughs to the services.

**Consequences.** Every collaborator is fakeable, which is what makes ADR-004 through ADR-009
testable at all. The cost is a layer of protocol declarations that a smaller app would not
need, and `AppEnvironment` accreting three factory methods (`live`, `uiTesting`, and the
re-auth override).

---

<a name="adr-002"></a>
## ADR-002 — No third-party dependencies

**Status:** Accepted

**Context.** 6.1's Default column permits SPM "with each dependency justified in one line".
This is a banking client.

**Decision.** Zero dependencies. `URLSession`, `Security` and `LocalAuthentication` cover
networking, Keychain and biometrics respectively.

**Alternatives.** Alamofire (would replace ~80 lines of `HTTPClient`), KeychainAccess
(~60 lines), a snapshot-testing library. Each would save less code than it adds in
supply-chain surface, App Review questions, and a version to keep current.

**Consequences.** Nothing to audit, nothing to update, and the "justified in one line"
requirement is satisfied vacuously. The cost is hand-rolled Keychain and HTTP code, which is
why both carry unit tests rather than trust.

---

<a name="adr-003"></a>
## ADR-003 — Swift 6 language mode with complete strict concurrency

**Status:** Accepted

**Context.** 6.1's Default asks for `-strict-concurrency=complete` clean and zero warnings;
Swift 6 language mode is offered separately as a stretch. Note that `SWIFT_VERSION` selects the
language mode, not the compiler — the toolchain is Swift 6.2 either way.

**Decision.** `SWIFT_VERSION = 6.0`, `SWIFT_STRICT_CONCURRENCY = complete`,
`SWIFT_TREAT_WARNINGS_AS_ERRORS = YES`.

This record originally decided `5.0` and deferred the stretch, on the reasoning that complete
strict concurrency already surfaces every data-race diagnostic Swift 6 enforces, so the
language mode would add no safety while making future changes a migration question. That
prediction was never measured. When it was, the project built and passed all 45 tests under
`SWIFT_VERSION=6.0` with **no source changes** — passing complete strict concurrency is the
migration. The stated cost did not exist, so the reasoning no longer supported the decision
and the decision changed.

**Alternatives.** Staying in Swift 5 mode. Rejected because the safety would then rest on
`SWIFT_TREAT_WARNINGS_AS_ERRORS`: a contributor who removed that setting would silently
demote every data-race diagnostic to a warning. Under Swift 6 mode they are errors by language
rule, independent of how the project is configured.

**Consequences.** The build caught two genuine issues: non-`Sendable` `ISO8601DateFormatter`
statics, and an attempted `@retroactive` conformance on a same-module type. One
`nonisolated(unsafe)` survives, on the date formatters, with the reasoning written at the call
site. Region-based isolation (SE-0414) is on by default in Swift 6 mode, which makes the
checker more precise rather than stricter. Reverting is a one-line change if it ever bites.

---

<a name="adr-004"></a>
## ADR-004 — `ReservationOutcome` carries an `unknown` case

**Status:** Accepted

**Context.** The backend derives idempotency server-side from `(userId, date)`. There is no
client-supplied idempotency key, no `GET /reservations`, and `ReservationService.reserve`
clears the key in its `finally` block on failure. After a network timeout the outcome is
therefore genuinely indeterminate, and a retry returns `DUPLICATE_REQUEST`, which is equally
ambiguous — it means "still in flight" *or* "already succeeded". Recorded as D4.

**Decision.** `ReservationOutcome` has four cases: `won`, `lost`, `rejected`, and `unknown`.
The UI renders `unknown` as a designed state — "We're not sure yet" — rather than as an error.

**Alternatives.** Collapse to success/failure and guess. Rejected: in a banking context an
interface that states a reservation exists when it cannot prove one is the worst available
outcome. Optimistically assume success and correct later — same objection, plus it moves money
in the user's mental model.

**Consequences.** The UI must handle a state most apps do not have, and the copy for it had to
be written carefully so it reads as honesty rather than as a bug. In exchange the app is never
wrong, only sometimes uncertain.

---

<a name="adr-005"></a>
## ADR-005 — One tap, one attempt, enforced in an actor

**Status:** Accepted

**Context.** 6.2 guardrail: "One tap produces exactly one reservation attempt." A board of 80
small targets invites mis-taps and double-taps, and the request costs $10.

**Decision.** `ReservationCoordinator` is an `actor` holding an `attemptInFlight` flag. A
second call while one is in flight is refused, not queued. Selecting a space and confirming it
are separate interactions, so the commit step is deliberate.

**Alternatives.** A `@MainActor` boolean on the view model. Rejected: it makes the guardrail a
property of the UI layer, testable only through the UI, and it is racy in principle even if
`@MainActor` makes it safe in practice. Debouncing the button. Rejected: it changes the odds
rather than the guarantee.

**Consequences.** The guardrail is enforced where it can be unit-tested — `testConcurrentTaps
ProduceExactlyOneAttempt` fires two concurrent attempts and asserts the service saw one.

---

<a name="adr-006"></a>
## ADR-006 — Never retry a timed-out reservation; reconcile instead

**Status:** Accepted

**Context.** 6.2 guardrail: "retry after a network timeout is idempotent and cannot
double-book." Given ADR-004's constraints, a literal retry cannot be made idempotent by the
client — there is no key to make it so.

**Decision.** On timeout, the client does not retry. It reconciles against `GET /spaces`,
matching the last three characters of its own plate. Exactly one match is treated as evidence;
two matches are a suffix collision and yield `unknown`; zero matches yield `unknown`.
`DUPLICATE_REQUEST` and `ALREADY_QUEUED` take the same path. `ALREADY_RESERVED` is trusted
without reconciliation, because it comes from the database's `uk_user_date` constraint rather
than from Redis (D7).

**Alternatives.** Retry with backoff — would double-book or return an ambiguous
`DUPLICATE_REQUEST`. Ask the user to check — offloads a correctness problem onto them.

**Consequences.** `plateLast3` is three characters across 80 cells, so reconciliation is a
strong hint and not proof; the code says so and the collision case is tested. The timeout
budget became a correctness decision as a result: 3 seconds, an order of magnitude above the
measured p99 of 368 ms, because every spurious timeout lands a user in `unknown`.

---

<a name="adr-007"></a>
## ADR-007 — Classify errors on `code`, never on HTTP status

**Status:** Accepted

**Context.** `WINDOW_CLOSED` is returned as **HTTP 429** (D2). 429 conventionally means rate
limiting, and most HTTP middleware treats it as retry-with-backoff.

**Decision.** `APIError` classification reads the business `code` field. `isSafelyRetryable`
is `false` for `windowClosed` despite its 429.

**Alternatives.** A status-code-driven retry policy, which is the conventional design.
Rejected because it is actively harmful here: retrying a closed window is useless — the window
opens on a clock, not on backoff — and at 20:00 across a thousand clients it is a
self-inflicted thundering herd.

**Consequences.** The client is coupled to the backend's code vocabulary rather than to HTTP
semantics. Acceptable: the codes are stable and enumerated, and a status-driven client would
be wrong.

---

<a name="adr-008"></a>
## ADR-008 — Decode failures by body emptiness, not status

**Status:** Accepted

**Context.** The backend returns two different 401 shapes. A missing, malformed or expired
token is rejected by the Spring Security filter chain *before* `GlobalExceptionHandler` runs,
producing an empty body with `WWW-Authenticate: Bearer`. A wrong password on `/auth/login`
reaches the controller and returns a full JSON body with `code: AUTH_FAILED`. The brief
documents both; the backend's `openapi.yml` documents neither (D3, D6).

**Decision.** `HTTPClient.decodeFailure` checks `data.isEmpty` first. Only the bare 401 sets
`requiresReauthentication`.

**Alternatives.** Decode every non-2xx as JSON — throws on the empty body, losing the fact
that the session is dead. Treat every 401 as an expired session — signs the user out when they
mistype a password, which is exactly what the reference web client does
(`frontend/src/services/api.ts` clears storage and redirects on any 401).

**Consequences.** Two tests pin this against bytes captured from the running backend, because
it is the kind of thing a refactor silently breaks.

---

<a name="adr-009"></a>
## ADR-009 — Server time from the HTTP `Date` header

**Status:** Accepted

**Context.** 6.2 guardrail: the countdown must derive from server time, not the device clock.
The backend exposes no time endpoint, and the brief says so explicitly (D5).

**Decision.** `ServerClock` is an actor that ingests the `Date` response header from every
response, anchors it to a `ContinuousClock` instant, and extrapolates. Before the first
reading the UI shows "Checking server time…" and no countdown. Device/server skew beyond 30
seconds is surfaced to the user. The window hour is configuration (`PARKING_WINDOW_HOUR`),
never a hardcoded 20.

**Alternatives.** `Date()` — trivially defeated by changing the device clock, which is the
obvious way to cheat a countdown. Adding a `/time` endpoint — forbidden, the backend is
read-only.

**Consequences.** Two limits are surfaced rather than hidden: the header has one-second
granularity, so the countdown claims no sub-second precision; and the reading includes one
network leg, so server time skews late by up to a round trip. `ReservationWindow` also models
the backend's gate exactly — `getHour() >= windowHour` with no upper bound — so the window
opens on the hour and shuts at midnight, which is what the server actually does.

---

<a name="adr-010"></a>
## ADR-010 — Poll `/spaces` every 5s, publish only on change

**Status:** Accepted

**Context.** 6.2's Default asks for a refresh strategy "chosen and defended … with no
full-grid flicker or scroll jump on update". `SpaceService` caches the response in Redis with
a **5-second TTL**, so polling faster cannot surface anything newer.

**Decision.** Poll every 5 seconds from a `Task` owned by the view model and cancelled on
teardown. `refresh()` compares the new `GridState` with the current one and assigns only if
they differ. `updateClock()` does the same per property.

**Alternatives.** A faster poll — cannot beat the server's own cache. Push or SSE — the
backend supports neither; a written design for that migration is in `design.md` §6 as the
stretch asks.

**Consequences.** This is not only an efficiency measure. Writing an identical value to an
`@Published` property still fires `objectWillChange`, and the unguarded version invalidated
the entire screen at 1 Hz — which, besides wasting battery, left the view hierarchy
permanently unsettled and made the board untappable under UI test. The guardrail's "no
full-grid flicker" is satisfied by SwiftUI diffing on space number; the no-op check is what
makes the common case free.

---

<a name="adr-011"></a>
## ADR-011 — Pessimistic reservation, not optimistic UI

**Status:** Accepted — **deviates from the 6.2 Default column**

**Context.** The Default permits "Optimistic UI … with rollback on failure correct and
visible". Measured against the real backend at 1000 VUs: exactly 80 of 1000 users win.

**Decision.** The reservation itself is pessimistic — the cell does not change state until the
server confirms. Optimistic updates are used only where contention does not apply, such as
deposits.

**Alternatives.** Optimistic with rollback, as offered. Rejected on the measurement: an
optimistic cell would be wrong about **92%** of the time, so rollback would be the common path
rather than the exception. The modal experience would be a space appearing to be yours and
then being taken away. Against a measured p95 of 248 ms, the wait costs the user almost
nothing and the honesty is worth more.

**Consequences.** Slightly less responsive on the winning path, which is the rare one. This is
the deviation most likely to be challenged in review, and the 80-of-1000 figure is the whole
of the defence.

---

<a name="adr-012"></a>
## ADR-012 — Biometric re-auth with a 120-second grace period

**Status:** Accepted — **deviates from the 6.5 Default column**

**Context.** The Default asks for "Face ID or Touch ID re-authentication before a reservation
is submitted, with a correct non-biometric fallback". The reservation is submitted inside a
race decided in milliseconds.

**Decision.** Re-authentication is required, with a 120-second grace period after a successful
check. The policy is `.deviceOwnerAuthentication`, not the biometrics-only variant, so the
device passcode is the automatic fallback.

**Alternatives.** A prompt on every attempt, as written. Rejected: a modal in the critical path
of a race costs seconds and would make the security control the reason users lose. No re-auth
at all — abandons the requirement rather than adapting it.

**Consequences.** The security value is retained where it exists — nobody reserves without
authenticating at least once per session — while the race stays winnable. On a device with no
passcode there is nothing to authenticate against, and that is treated as a pass; in production
it would be a hard block, as `security.md` records.

---

<a name="adr-013"></a>
## ADR-013 — Keychain with `WhenUnlockedThisDeviceOnly`

**Status:** Accepted

**Context.** 6.5 guardrail: session token in the Keychain "with a justified accessibility
class", never `UserDefaults` or a plist.

**Decision.** `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Writes are delete-then-add
rather than `SecItemUpdate`.

**Alternatives.** `AfterFirstUnlock` — correct for apps doing background refresh, which this
one does not; it would leave the token readable from first unlock until reboot. Without
`ThisDeviceOnly` — the token would ride encrypted backups and iCloud Keychain onto other
devices, which a bearer token authorising payments should not do.

**Consequences.** The user signs in again after a device migration. That is the right trade in
a banking context. Delete-then-add matters because `SecItemUpdate` would silently retain a
previously stored accessibility class.

---

<a name="adr-014"></a>
## ADR-014 — Scroll the board to protect the 44pt target

**Status:** **Superseded by [ADR-015](#adr-015)**

**Context.** 6.3 asks for all 80 spaces legible on a 6.1-inch screen without pinch-zoom, and
also for 44pt minimum touch targets. At 80 cells on a 393×852 screen these conflict.

**Decision (as taken).** Honour the 44pt target, lay the board out at 7 columns, and let it
scroll.

**Why it was wrong.** The two requirements are in *different columns*. "All 80 spaces legible
on a 6.1-inch screen" is a **Guardrail**; "44pt minimum touch targets" sits in the **Default**
column. Guardrails are non-negotiable and Defaults are swappable with a defence — so this
resolved the conflict backwards, sacrificing the non-negotiable requirement to protect the
negotiable one, and defended the result in prose.

The root cause is worth recording: the brief's tables are two-column PDF tables that flatten
into a single text stream when extracted, so column membership was guesswork. Column
assignment is now recovered from glyph x-coordinates. The same misreading, once corrected,
turned up three further gaps in a follow-up audit.

---

<a name="adr-015"></a>
## ADR-015 — Fit all 80 cells; size the board to the screen

**Status:** Accepted — supersedes [ADR-014](#adr-014)

**Context.** As ADR-014, with the columns read correctly.

**Decision.** `BoardLayout` searches candidate column counts and picks the largest cell size
that fits every cell in the space available, ranking a layout that meets 44pt outright above
one that does not. Chrome was reduced — the countdown and the counts share one card, and the
oversized portrait title was dropped — which bought roughly 110pt of vertical space.

**Consequences.** Neither requirement has to yield. On the 6.1-inch reference the board lands
on **7 columns × 12 rows at 44×43pt**, an effective target of 48.7 × 47.2pt including the
gutter, with all 80 visible and no scrolling. `BoardLayoutTests` asserts this against a
393×852 reference rather than against whichever simulator is installed, because the smallest
device available locally is 6.3 inches and would not catch a regression. One test exists purely
to fail if a future change reintroduces the trade-off.

The board is still allowed to scroll at accessibility text sizes, where a fixed layout would
clip. Clipping is worse than scrolling, and the guardrail concerns the default reading size.

---

<a name="adr-016"></a>
## ADR-016 — Side-by-side layout when width allows

**Status:** Accepted

**Context.** iPad and landscape layouts are a 6.3 stretch. Stacking the portrait layout into a
landscape phone squeezes the board into a letterbox strip.

**Decision.** Switch to a side-by-side layout when `horizontalSizeClass == .regular` (iPad,
either orientation) or `verticalSizeClass == .compact` (iPhone landscape): the board takes the
leading side at full height, and the header, countdown, holding banner and confirm control
become a sidebar. The confirm control has two chrome styles over one implementation — docked
to the bottom in portrait, a card in the sidebar when wide.

**Consequences.** The same 80 cells land on 10×8 in iPhone landscape and 6×14 on iPad, cells
growing rather than the board scrolling. A bottom-docked bar on a 13-inch iPad would put the
action a hand's travel from the board it refers to, which is why the control moves rather than
merely resizing. One bug surfaced: the app was not scene-based, because the target supplies
its own `Info.plist` and nothing synthesised a `UIApplicationSceneManifest`, so the window
never resized at all.

---

<a name="adr-017"></a>
## ADR-017 — Generate the Xcode project with XcodeGen

**Status:** Accepted

**Context.** `.xcodeproj` is a generated-looking file that merges badly and hides build
settings in a format nobody reviews.

**Decision.** `project.yml` is the source of truth; `Parking.xcodeproj` is generated and
gitignored. `make project` regenerates it, and CI does so on every run.

**Alternatives.** Commit the `.xcodeproj` — the conventional choice, and fine on a solo
project, but it makes settings like `SWIFT_STRICT_CONCURRENCY` invisible in review. A Swift
package — would complicate the UI test target and app resources for no gain here.

**Consequences.** Every build setting is reviewable in a diff, and adding a file means
`make project` rather than an IDE mutation. A fresh clone does not open in Xcode until
`make project` has run, which `README.md` and the runbook both state.

---

<a name="adr-018"></a>
## ADR-018 — Self-hosted CI runner

**Status:** Accepted

**Context.** 6.4 guardrail: CI on every push — build, lint, unit tests, UI tests on a
simulator. GitHub Free bills macOS minutes at 10×, giving roughly 200 effective minutes a
month against a ~6-minute workflow: about 12 runs for the whole fortnight.

**Decision.** A self-hosted runner on the development machine, labelled `macOS`, installed as
a launchd service outside any cloud-synced directory.

**Alternatives.** Hosted macOS runners — arithmetically cannot meet "every push". Trimming CI
to lint plus unit tests on push with everything else nightly — cheaper, and the documented
fallback in the runbook if a runner cannot be registered, but it does not meet the guardrail as
written.

**Consequences.** The repository **must stay private**: GitHub's guidance is that self-hosted
runners should not be used with public repositories, because a fork pull request would execute
arbitrary code on the machine. The runner also runs as the developer's user with access to
their Keychain, which is an accepted risk for a personal project and would not be in
production. The workflow pins `PATH` to include Homebrew, because a runner's shell does not
source an interactive profile.

---

<a name="adr-019"></a>
## ADR-019 — Certificate pinning not implemented

**Status:** **Rejected for now** — known risk, see `security.md`

**Context.** 6.5's Default column asks for "certificate pinning against the local backend,
local-development bypass gated to debug builds and documented". The backend is
`http://localhost:8080` with no TLS anywhere in the exercise.

**Decision.** Not implemented. `security.md` documents the threat, what production would use —
`URLSessionDelegate` validating the leaf's SPKI hash against a pinned set with at least one
backup pin, the bypass compiled out with `#if DEBUG`, and a rotation runbook — and why it is
out of scope here.

**Why this is recorded as a risk rather than a clean deviation.** The brief allows a Default to
be swapped "provided your alternative stays inside the guardrails, you defend the trade-off in
docs/design.md, and you actually build and demo it". An omission with a rationale is not a
swap: nothing was built. Pinning a self-signed certificate generated for the demo would
exercise the API call but not the control, since the hard parts in production are rotation,
backup pins and failure modes — none of which a localhost stub reaches.

**If time allows**, the honest fix is to terminate TLS locally with a self-signed certificate,
pin its SPKI hash, and demonstrate the client refusing a connection under a deliberately wrong
pin. That makes the control real and demonstrable, which is what the Default actually asks for.
