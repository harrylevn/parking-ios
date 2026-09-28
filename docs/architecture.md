# Architecture decision records

Seven records, one per decision that would actually be argued in review. Each gives the context
that forced it, what was decided, what else was considered, and what it costs.

This is the decision log. [`design.md`](design.md) carries the problem, the interface, the
defence of each deviation, and the Guardrail/Default compliance matrix; [`codebase.md`](codebase.md)
is the map of where things live. Where a decision deviates from the brief's Default column, the
deviation is named explicitly.

| # | Decision | Status |
|---|---|---|
| [001](#adr-001) | Three layers, no dependencies, generated project, Swift 6 | Accepted |
| [002](#adr-002) | Never claim a reservation the client cannot prove | Accepted — deviates from Default; its retry rule superseded by 007 |
| [003](#adr-003) | Classify errors on the payload, not the HTTP status | Accepted |
| [004](#adr-004) | Server time and refresh without a push channel | Accepted |
| [005](#adr-005) | Fit all 80 cells, and adapt when there is room | Accepted — supersedes an earlier reading |
| [006](#adr-006) | Keychain, biometric re-authentication, and the pinning gap | Accepted — one item **not built** |
| [007](#adr-007) | Repeat a tap's Idempotency-Key, then read back what committed | Accepted — supersedes part of 002 |

> The first six were consolidated from nineteen finer-grained records. The finer records were
> mostly one mechanism each, which made the log tedious to review and hid which decisions were
> genuinely contestable. Nothing was dropped: every decision, deviation and open risk below
> was in the longer log, including the one correction that matters, in ADR-005.

---

<a name="adr-001"></a>
## ADR-001 — Three layers, no dependencies, generated project, Swift 6

**Status:** Accepted

**Context.** 6.1 makes "services behind protocols and injected, fakeable in tests" a Guardrail,
and asks in the Default column for a layered architecture, structured concurrency,
`-strict-concurrency=complete` clean, and every dependency justified.

**Decision.** Four settings that together fix the shape of the codebase.

*Three layers, one composition root.* Features (SwiftUI views and `@MainActor` view models),
Domain (models, protocols, the reservation logic) and Data (HTTP, Keychain, biometrics).
Domain imports nothing but Foundation. Every service is a protocol, injected from
`AppEnvironment`, so every collaborator is fakeable and the 109 unit tests need no backend.

*No third-party dependencies.* `URLSession`, `Security` and `LocalAuthentication` cover
everything the app does.

*Swift 6 language mode*, with `SWIFT_STRICT_CONCURRENCY = complete` and warnings as errors.
Note that `SWIFT_VERSION` selects the language mode, not the compiler — the toolchain is Swift
6.2 either way.

*The Xcode project is generated.* `project.yml` is the source of truth; `Parking.xcodeproj` is
gitignored and rebuilt by `make project`, which CI runs on every job.

*CI runs on a self-hosted runner* on the development machine, because 6.4's "CI on every push"
is a Guardrail and GitHub Free bills macOS minutes at 10×: roughly 200 effective minutes a
month against a ~6-minute workflow is about twelve runs for the entire fortnight.

**Alternatives.** A dependency for networking or keychain access — none would save more than a
few dozen lines, and in a banking client every dependency is supply-chain surface. Swift 5
language mode, which is what this record originally decided: deferred on the reasoning that
complete strict concurrency already surfaces every diagnostic Swift 6 enforces. That prediction
was never measured; when it was, the project built and passed all 45 tests under Swift 6 with
**no source changes**, because passing complete strict concurrency *is* the migration. Committing
the `.xcodeproj` — conventional and fine on a solo project, but it hides settings like
`SWIFT_STRICT_CONCURRENCY` from review. Hosted macOS runners — arithmetically cannot meet
"every push"; trimming CI to lint and unit tests with everything else nightly is the documented
fallback in the runbook, but does not meet the Guardrail as written.

**Consequences.** Strict concurrency caught two genuine issues: non-`Sendable`
`ISO8601DateFormatter` statics, and an attempted `@retroactive` conformance on a same-module
type. One `nonisolated(unsafe)` survives, on the date formatters, with the reasoning at the call
site. Under Swift 6 mode the safety no longer depends on `SWIFT_TREAT_WARNINGS_AS_ERRORS`, which
a contributor could remove without realising what it protected. A fresh clone does not open in
Xcode until `make project` has run, which the README and runbook both state. The repository
**must stay private**: GitHub's guidance is that self-hosted runners should not be used with
public repositories, because a fork's pull request would execute arbitrary code on the machine.

---

<a name="adr-002"></a>
## ADR-002 — Never claim a reservation the client cannot prove

**Status:** Accepted — **deviates from the 6.2 Default column**

**Context.** Two things force this, and they compound.

*The outcome of a timed-out reservation is genuinely unknowable.* The backend derives
idempotency server-side from `(userId, date)`. There is no client-supplied key, no
`GET /reservations`, and `ReservationService.reserve` clears the key in its `finally` block on
failure — so a retry returns `DUPLICATE_REQUEST`, which means "still in flight" *or* "already
succeeded", with no way to tell (D4).

*Almost everybody loses.* Measured against the real backend at 1,000 virtual users: exactly 80
of 1,000 win, a p95 of 248 ms, p99 of 368 ms.

**Decision.** The client is pessimistic and says so when it does not know.

- `ReservationOutcome` has four cases — `won`, `lost`, `rejected` and `unknown`. The UI renders
  `unknown` as a designed state, not as an error. `unknown` carries an `Uncertainty` naming
  which of three situations holds — the space probably *is* ours, two plates share our suffix,
  or there is no evidence either way — because a single sheet for all three was reported as
  distressing at the week-1 checkpoint, and the flattening was most of the reason.
- The cell does not change until the server confirms it. Optimistic updates are used only where
  contention does not apply, such as deposits.
- One tap is exactly one attempt: `ReservationCoordinator` is an `actor` holding an
  `attemptInFlight` flag, and a second call while one is in flight is refused, not queued.
- *(Superseded by [ADR-007](#adr-007) once the backend accepted an Idempotency-Key. Kept as
  written, because it was right for the backend it was written against.)*
  A timeout is **never** retried. The client reconciles against `GET /spaces` by the last three
  characters of its own plate: exactly one match is evidence, two is a suffix collision and
  yields `unknown`, zero yields `unknown`. `ALREADY_RESERVED` is trusted without reconciliation,
  because it comes from the database's `uk_user_date` constraint rather than from Redis (D7).
- The request timeout is 3 seconds — an order of magnitude above the measured p99, because
  every spurious timeout lands a user in `unknown`. Timeout length is therefore a correctness
  decision, not a performance one.

**Alternatives.** Optimistic UI with rollback, as the Default offers. Rejected on the
measurement: an optimistic cell would be wrong **92%** of the time, so rollback would be the
modal experience rather than the exception — a space appearing to be yours and then being taken
away. Against a p95 of 248 ms the wait costs the user almost nothing. Collapsing `unknown` into
success or failure and guessing — in a banking context, stating that a reservation exists when
that cannot be proven is the worst available outcome. Retry with backoff — would double-book or
return the same ambiguous `DUPLICATE_REQUEST`. Enforcing one-attempt with a `@MainActor` boolean
on the view model — makes a Guardrail a property of the UI layer, testable only through the UI.

**Consequences.** Slightly less responsive on the winning path, which is the rare one. The UI
has to handle a state most apps do not have, and its copy had to be written carefully so it
reads as honesty rather than as a bug. `plateLast3` is three characters across 80 cells, so
reconciliation is a strong hint and not proof; the code says so and the collision case is
tested. `testConcurrentTapsProduceExactlyOneAttempt` fires two concurrent attempts and asserts
the service saw one. This is the deviation most likely to be challenged in review, and the
80-of-1,000 measurement is the whole of the defence.

---

<a name="adr-003"></a>
## ADR-003 — Classify errors on the payload, not the HTTP status

**Status:** Accepted

**Context.** The backend's HTTP semantics are not the conventional ones, in two ways that each
break a standard client.

`WINDOW_CLOSED` is returned as **HTTP 429** (D2), which conventionally means rate limiting and
which most HTTP middleware treats as retry-with-backoff. And there are **two different 401
shapes**: a missing, malformed or expired token is rejected by the Spring Security filter chain
*before* `GlobalExceptionHandler` runs, producing an empty body with `WWW-Authenticate: Bearer`,
while a wrong password on `/auth/login` reaches the controller and returns a full JSON body with
`code: AUTH_FAILED`. The backend's `openapi.yml` documents neither (D3, D6).

**Decision.** `APIError` classification reads the business `code` field, and
`isSafelyRetryable` is `false` for `windowClosed` despite its 429. `HTTPClient.decodeFailure`
checks `data.isEmpty` **first**, and only the bare 401 sets `requiresReauthentication`.

**Alternatives.** A status-code-driven retry policy, which is the conventional design and is
actively harmful here: retrying a closed window is useless — it opens on a clock, not on backoff
— and at 20:00 across a thousand clients it is a self-inflicted thundering herd. Decoding every
non-2xx as JSON — throws on the empty body, losing the fact that the session is dead. Treating
every 401 as an expired session — signs the user out when they mistype a password, which is
exactly what the reference web client does (`frontend/src/services/api.ts` clears storage and
redirects on any 401).

**Consequences.** The client is coupled to the backend's code vocabulary rather than to HTTP
semantics. Acceptable: the codes are stable and enumerated, and a status-driven client would be
wrong. Two tests pin the decoding against bytes captured from the running backend, because it is
the kind of thing a refactor silently breaks.

---

<a name="adr-004"></a>
## ADR-004 — Server time and refresh without a push channel

**Status:** Accepted

**Context.** 6.2 makes the countdown deriving from server time a Guardrail, and asks in the
Default column for a refresh strategy "chosen and defended … with no full-grid flicker or scroll
jump on update". The backend offers neither a time endpoint (D5) nor a push channel, and
`SpaceService` caches `/spaces` in Redis with a **5-second TTL**, and `ReservationService`
clears that cache in the `finally` of every reservation attempt, won or lost.

**Decision.** `ServerClock` is an actor that ingests the `Date` response header from every
response, anchors it to a `ContinuousClock` instant and extrapolates. Before the first reading
the UI shows "Checking server time…" and no countdown; skew beyond 30 seconds is surfaced to the
user. The window hour is configuration (`PARKING_WINDOW_HOUR`), never a hardcoded 20.

The grid polls every 5 seconds from a `Task` owned by the view model and cancelled on teardown.
`refresh()` compares the new `GridState` with the current one and assigns only if they differ;
`updateClock()` does the same per property.

**Alternatives.** `Date()` — trivially defeated by changing the device clock, which is the
obvious way to cheat a countdown. Adding a `/time` endpoint — forbidden, the backend is
read-only. A faster poll — at rest it sees nothing the TTL has not already shown; during the
race it would see newer data, but only because every attempt empties the cache, so each poll
becomes a Postgres read (or, past the 500 ms rebuild lock, a direct one) in the second the
reservation path needs the database. Push or SSE — unsupported by the
backend; a written design for that migration is in `design.md` §7.

**Consequences.** Two limits are surfaced rather than hidden: the `Date` header has one-second
granularity, so the countdown claims no sub-second precision, and the reading includes one
network leg, so server time skews late by up to a round trip. `ReservationWindow` models the
backend's gate exactly — `getHour() >= windowHour` with no upper bound — so the window opens on
the hour and shuts at midnight, which is what the server actually does.

The no-op check is not only an efficiency measure. Writing an identical value to an `@Published`
property still fires `objectWillChange`, and the unguarded version invalidated the entire screen
at 1 Hz — which, besides wasting battery, left the view hierarchy permanently unsettled and made
the board untappable under UI test.

---

<a name="adr-005"></a>
## ADR-005 — Fit all 80 cells, and adapt when there is room

**Status:** Accepted — supersedes an earlier decision, recorded below

**Context.** 6.3 asks for all 80 spaces legible on a 6.1-inch screen without pinch-zoom, and
also for 44pt minimum touch targets. At 80 cells on a 393×852 screen these conflict.

**The decision this replaces, and why it was wrong.** The first version honoured the 44pt target
and let the board scroll. That resolved the conflict backwards: the two requirements are in
*different columns*. "All 80 spaces legible" is a **Guardrail**; "44pt minimum touch targets"
sits in the **Default** column. So the earlier decision sacrificed the non-negotiable
requirement to protect the negotiable one — and then defended the result in prose.

The root cause is worth recording. The brief's tables are two-column PDF tables that flatten
into a single text stream when extracted, so column membership was guesswork. Column assignment
is now recovered from glyph x-coordinates, and re-auditing all five modules the same way turned
up three further gaps.

**Decision.** `BoardLayout` searches candidate column counts and picks the largest cell size
fitting every cell in the space available, ranking a layout that meets 44pt outright above one
that does not. Chrome was reduced — the countdown and the counts share one card, the oversized
portrait title was dropped — which bought roughly 110pt of vertical space.

When width allows, the layout goes side by side: `horizontalSizeClass == .regular` (iPad, either
orientation) or `verticalSizeClass == .compact` (iPhone landscape) puts the board on the leading
side at full height, with the header, countdown, holding banner and confirm control as a
sidebar. The confirm control has two chrome styles over one implementation — docked to the
bottom in portrait, a card in the sidebar when wide.

**Consequences.** Neither requirement has to yield. On the 6.1-inch reference the board lands on
**7 columns × 12 rows at 44×43pt**, an effective target of 48.7 × 47.2pt including the gutter,
all 80 visible, no scrolling. `BoardLayoutTests` asserts this against a 393×852 reference rather
than whichever simulator is installed, because the smallest device available locally is 6.3
inches and would not catch a regression; one test exists purely to fail if a future change
reintroduces the trade-off. The same 80 cells land on 10×8 in iPhone landscape and 6×14 on iPad,
cells growing rather than the board scrolling. A bottom-docked bar on a 13-inch iPad would put
the action a hand's travel from the board it refers to, which is why the control moves rather
than merely resizing.

**Amended after the fact — the figures above were not what the app did.** They came from
`BoardLayoutTests`, which modelled the screen's chrome instead of measuring it, and were kept
here as the record of what this ADR originally claimed. Measured off the running app on a
393×852 screen, the 6.1-inch board is **8 × 10 at 40×40pt cells, a 44×44pt target**, with no
scrolling; `BoardGeometryUITests` now asserts that on the device. iPhone landscape never landed
on 10×8: it scrolls by decision, at 9 columns and 44pt. [design.md §5.2 and §5.5](design.md)
have both measurements and how the model went wrong.

The board is still allowed to scroll at accessibility text sizes, where a fixed layout would
clip. Clipping is worse than scrolling, and the Guardrail concerns the default reading size.

One bug surfaced along the way: the app was not scene-based, because the target supplies its own
`Info.plist` and nothing synthesised a `UIApplicationSceneManifest`, so the window never resized
at all.

---

<a name="adr-006"></a>
## ADR-006 — Keychain, biometric re-authentication, and the pinning gap

**Status:** Accepted — **one item is not built; a biometric deviation was reversed**

**Context.** 6.5 makes the session token in the Keychain "with a justified accessibility class"
a Guardrail, and asks in the Default column for biometric re-authentication before a reservation
and for certificate pinning against the local backend. "Before a reservation" is read here as
the floor, not the ceiling — see *Scope* below.

**Decision.**

*Keychain:* `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, with writes as delete-then-add
rather than `SecItemUpdate`.

*Biometrics:* re-authentication is required **before every attempt**, with no grace period and
no session-scoped exemption. The policy is `.deviceOwnerAuthentication`, not the biometrics-only
variant, so the device passcode is the automatic fallback. Each attempt builds a fresh
`LAContext`, because a stored one reintroduces the same exemption through
`touchIDAuthenticationAllowableReuseDuration`.

*Scope: every action that moves money, not only the reservation.* The Default column names the
reservation, and the control was first built there alone. That read the requirement as a rule
about spending rather than about the money path: a deposit credits the wallet, and leaving it
unchallenged meant anyone holding the unlocked handset could top the balance up while only the
spend was contested. Both now prompt, and the prompt names the amount, because the control
exists to evidence consent to *this* transaction. Raised at the week-1 checkpoint.

*Pinning:* **not implemented.** `security.md` documents the threat, what production would use —
a `URLSessionDelegate` validating the leaf's SPKI hash against a pinned set with at least one
backup pin, the bypass compiled out with `#if DEBUG`, and a rotation runbook — and why it is out
of scope against an `http://localhost:8080` backend with no TLS anywhere in the exercise.

**Alternatives.** `AfterFirstUnlock` for the token — correct for apps doing background refresh,
which this one does not; it would leave the token readable from first unlock until reboot.
Omitting `ThisDeviceOnly` — the token would ride encrypted backups and iCloud Keychain onto
other devices, which a bearer token authorising payments should not do.

**A biometric grace period, which this record previously accepted and now reverses.** The
original decision exempted any attempt within 120 seconds of a successful check, reasoning that
a modal in the critical path of a race decided in milliseconds would make the security control
the reason users lose — and that since one reservation per vehicle per day is a backend
invariant, the attempts it covered were overwhelmingly retries after losing, where no second
charge is possible anyway.

That reasoning is about cost, and it never established what the control is for. Step-up
authentication on a payment is not a proportionality measure keyed to the amount; it produces
the evidence that the account holder authorised *this* debit. A session-scoped exemption
removes that evidence for every attempt after the first, and it is free to anyone holding the
handset while it is unlocked — the party it should be most expensive for. The repository's own
`CLAUDE.md` asserts a banking bar; the exemption sat on the only action that moves money.

The race cost is therefore accepted rather than engineered around. It has **not** been measured
on device, and a simulator figure would flatter it, so the measurement is carried as a day-9
Instruments item rather than quoted here. If it proves decisive, the alternative that satisfies
both constraints is capturing the authorisation *before* the window opens — arming a choice
during the countdown — which keeps per-transaction consent while moving the prompt out of the
race. That is a feature, not a tuning parameter, and it is not built.

Rejected outright: no re-auth at all, which abandons the requirement rather than adapting it.

**The pinning gap is a risk, not a clean deviation.** The brief allows a Default to be swapped
"provided your alternative stays inside the guardrails, you defend the trade-off in
docs/design.md, and you actually build and demo it". An omission with a rationale is not a swap:
nothing was built. Pinning a self-signed certificate generated for the demo would exercise the
API call but not the control, since the hard parts in production are rotation, backup pins and
failure modes, none of which a localhost stub reaches. **If time allows**, the honest fix is to
terminate TLS locally with a self-signed certificate, pin its SPKI hash, and demonstrate the
client refusing a connection under a deliberately wrong pin — which is what the Default actually
asks for.

**Consequences.** The user signs in again after a device migration, which is the right trade in
a banking context; delete-then-add matters because `SecItemUpdate` would silently retain a
previously stored accessibility class. Every reservation attempt now costs a biometric prompt,
including retries after losing, which is a real and unmeasured handicap in the 20:00 race
against a web client carrying no such control — that cost is disclosed rather than hidden.
`ReservationCoordinatorTests` asserts three attempts produce three authorisations, which pins
the coordinator's contract but not the concrete evaluator — that one is stateless by
construction rather than by assertion. On a device with no passcode there is nothing to
authenticate against, and that is treated as a pass, where production would hard-block; with
the grace period gone it is the only remaining gap in the control. Pinning remains the one
Default neither kept nor replaced with something built, and it is carried openly as an open
risk rather than presented as a defended swap.

---

<a name="adr-007"></a>
## ADR-007 — Repeat a tap's Idempotency-Key, then read back what committed

**Status:** Accepted — **supersedes ADR-002's "a timeout is never retried"**

**Context.** ADR-002's rule followed from the backend: idempotency was derived server-side from
`(userId, date)`, the key was cleared on failure, and there was nothing to ask, so a retry could
not be told apart from a second attempt (D4). The reviewer agreed the backend could change. It
now accepts an optional `Idempotency-Key` header and answers every repeat of a key with the
first request's outcome, failures included, or `409 IDEMPOTENCY_IN_PROGRESS` while it runs.
`GET /reservations/me` reads back what committed. The design is in the backend repo, on
`feature/reservation-idempotency`, under `backend/docs/idempotency/`.

**Decision.**

- One UUID per tap, made after the biometric prompt succeeds. A declined prompt sends nothing
  and uses no key; the next tap is a new intent with a new key.
- A timeout, a dropped connection or `IDEMPOTENCY_IN_PROGRESS` repeats **the same key**, up to
  four sends one second apart (the server's `Retry-After`). A repeat is the same attempt, not a
  second one, so "one tap, one attempt" still holds; the actor's in-flight flag still refuses a
  second tap.
- A replayed failure is final: it is the first send's real outcome.
- Once any send may have reached the server, no later failure is reported as "nothing
  happened". A repeat that fails to leave the device proves nothing about the first send.
- When the repeats run out, or the server answers `DUPLICATE_REQUEST` (some other attempt for
  the day), `GET /reservations/me` decides. A reservation found there is authoritative and
  reported as `won`, with the balance fetched from the wallet because the read-back carries
  none. Nothing found is still `unknown`, not `lost`: a send may still be queued.
- Only if the read-back cannot be reached does the board get consulted, exactly as ADR-002
  did. That also keeps the app correct against a backend without the endpoint.
- `PARKING_IDEMPOTENCY_KEYS=0` turns repeats off. Against a backend that ignores the header, a
  repeat after a failure the client never heard about is a genuine second attempt, which would
  break the Guardrail.

**Alternatives.** Keep ADR-002 unchanged and only send the key — wastes the one thing the key
makes possible. Retry without limit — every repeat is load in the minute the server can least
afford it, and the user is staring at "Reserving…". Read back first and repeat only if nothing
is found — a `404` while our request is still queued looks exactly like "nothing happened",
whereas a repeat of the key gets `IDEMPOTENCY_IN_PROGRESS`, which is the true answer. Drop the
board reconciliation — it would be dead code against the new backend, but it is the fallback
against the old one and while the read-back is unreachable.

**Consequences.** `ReservationOutcome.unknown` now means "the server could not be reached, or
was still processing when the repeats ran out", rather than "every timeout". The worst case in
front of the user grows from 3 s to about 15 s of "Reserving…" with the elapsed timer running.
`Reservation.newBalance` became optional, for the read-back. The Guardrail row "retry after
timeout idempotent and cannot double-book" is now met by the server's key rather than by never
retrying. `ReservationRetryTests` covers the repeats, the key per tap, the replayed failure,
the read-back both ways, the unsent repeat and the `never` policy.
