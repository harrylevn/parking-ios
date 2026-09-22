# Design

Native iOS client for the Parking Space Reservation System. SwiftUI, iOS 17 minimum.

This document is the narrative: the argument in prose, for a reader who wants to follow the
reasoning end to end. [`architecture.md`](architecture.md) is the same decisions as a numbered
ADR log, including one superseded record and one open risk; [`codebase.md`](codebase.md) maps
where everything lives. Where I deviated from the brief's Default column, the deviation and its
justification are marked **Deviation**.

---

## 1. The problem, honestly stated

80 spaces open at 20:00 for the next day. Roughly a thousand users compete. Measured against
the live backend at 1000 VUs: **80 users win and 920 lose.**

That number drove most of what follows. This is not a product where reserving a space is the
common path with a few error cases around the edges — 92% of the people using it at 20:00
will fail, and the quality of the app is mostly the quality of how it handles that.

## 2. Architecture

MVVM with three layers and no view touching networking or persistence.

```
Features/   SwiftUI views + @MainActor view models
Domain/     models, service protocols, ReservationCoordinator, ServerClock  (no Foundation URL types)
Data/       HTTPClient, DTOs, Keychain, biometrics          (conforms to Domain protocols)
App/        AppEnvironment — the single composition root
```

Every service is a protocol (`Sources/Domain/Services.swift`), constructed in
`AppEnvironment` and injected downwards. Tests substitute fakes; nothing reaches for a
singleton.

**Concurrency.** async/await throughout, no completion handlers and no `DispatchSemaphore`.
View models are `@MainActor`. Mutable shared state is actor-isolated: `ServerClock` is an
actor because every response writes to it from an arbitrary executor, and
`ReservationCoordinator` is an actor because its in-flight flag is what enforces the
one-tap-one-attempt guardrail under concurrent taps. The grid poll loop is a `Task` owned by
the view model and cancelled in `stopPolling()` on view teardown.

Builds clean under `-strict-concurrency=complete` with warnings as errors. One
`nonisolated(unsafe)` is used, on two `ISO8601DateFormatter` statics, with the reasoning
written at the call site: Foundation documents these as thread-safe for parsing, they are
never mutated after construction, and date decoding sits on the reservation hot path.

**Dependencies: none.** SPM is configured but nothing is pulled in. Everything needed —
`URLSession`, `Security`, `LocalAuthentication` — ships with the platform. A dependency in a
banking app is a supply-chain liability and an App Review surface; none here would save more
than a few dozen lines.

## 3. Decisions that follow from the backend's actual behaviour

I stood the backend up and exercised it before designing against it. Full evidence is in
`docs/defects.md`; the decisions those findings forced are below.

### 3.1 The client can be made to lie, and the fix is architectural

Idempotency is keyed **server-side** on `(userId, date)`. There is no client-supplied
idempotency key, no `GET /reservations`, and the server clears the key on failure. So after a
network timeout the outcome is genuinely indeterminate, and retrying returns
`DUPLICATE_REQUEST`, which is equally ambiguous.

This is why `ReservationOutcome` has four cases rather than two, and why one of them is
`.unknown`. The app is required to be able to say *"we don't know yet"*, because there are
states where that is the only true thing it can say. `ReservationCoordinator` will reconcile
against the grid by matching `plateLast3`, but that is three characters across 80 cells, so
when two spaces match it reports that it cannot tell rather than picking one.

The rule: **never claim a reservation the client cannot substantiate.**

### 3.2 Timeout length is a correctness decision

Measured under 1000-VU load: p95 248 ms, p99 368 ms, max 867 ms. The reservation timeout is
**3 seconds** — an order of magnitude above p99. A tighter timeout would not improve
responsiveness; it would manufacture indeterminate outcomes, because every spurious timeout
lands the user in §3.1.

### 3.3 Classify on `code`, never on HTTP status

`WINDOW_CLOSED` arrives as **429**. Any conventional transport-layer retry policy would
back off and retry it, which is both useless (the window opens on a clock) and, at 20:00
scale, a self-inflicted thundering herd. `APIError.isSafelyRetryable` is false for it.

### 3.4 Two 401 shapes

A missing or expired token produces a bare 401 with an empty body; a wrong password produces
a 401 with a full JSON `AUTH_FAILED` body. Decoding branches on **body emptiness, not
status**, and only the bare 401 sets `requiresReauthentication`. The reference web client in
`frontend/` signs the user out on both, so mistyping a password logs you out — the bug this
design exists to avoid.

### 3.5 Countdown from server time, never the device clock

There is no time endpoint. `ServerClock` anchors the HTTP `Date` header — present on every
response — against a `ContinuousClock` instant and extrapolates, so changing the device clock
does not move the countdown. Before the first reading the UI shows *"Checking server time…"*
rather than falling back to `Date()`; a wrong countdown is worse than no countdown.

Two limits are surfaced rather than hidden: `Date` has one-second granularity, so the
countdown never claims sub-second precision; and the reading includes one network leg, so
server time skews late by up to a round trip. Device/server skew beyond 30 seconds is shown
to the user.

The window hour is **configuration**, not a constant — the demo runs with
`window-hour` shifted. The backend's gate is `getHour() < windowHour` with no upper bound, so
`ReservationWindow` models a window that opens on the hour and shuts at midnight, which is
what the server actually does.

### 3.6 Grid refresh is bounded by the server, not by taste

`/spaces` is cached in Redis with a **5-second TTL**. Polling faster cannot surface anything
newer, so the poll interval is 5 seconds. Cells are identified by space number, so SwiftUI
diffs a refresh down to the cells that changed — no full-grid flicker, no scroll jump.

## 4. Deviations from the brief's Default column

### Deviation 1 — pessimistic reservation, optimistic elsewhere

The brief permits optimistic UI with visible rollback. I am **not** applying it to the
reservation itself.

With 80 winners in 1000, an optimistic "reserved" cell is wrong about 92% of the time.
Rollback would stop being the exception and become the common path: the modal experience
would be a space appearing to be yours and then being taken away. That is a worse experience
than a 250 ms wait, and in a banking context an interface that shows you holding something
you do not hold is exactly the wrong instinct.

Optimistic updates are used where the success rate justifies them — deposits, which do not
contend.

### Deviation 2 — re-authentication has a grace period, not per-tap

The Default column puts Face ID before a reservation is submitted. Implemented, with a
**120-second grace period** after a successful check.

A biometric prompt inside the critical path of a race decided in milliseconds costs the user
seconds. Requiring it on every tap would make the security control the reason users lose. The
grace period keeps re-authentication in front of the session's first reservation — which is
where it has security value — without putting a modal in the middle of the race.

Fallback is `.deviceOwnerAuthentication`, not the biometrics-only policy, so a user without
Face ID or locked out after failed attempts falls back to the passcode rather than being
locked out of the product.

## 5. Interface

One screen after sign-in: the grid. An 80-cell adaptive layout with a 44 pt minimum, which
satisfies both "all 80 legible on a 6.1-inch screen without pinch-zoom" and the 44 pt touch
target, and reflows as Dynamic Type grows rather than clipping.

Availability is carried by **shape as well as colour** — reserved cells get a dashed border —
so the grid survives colour-blindness and greyscale. Every cell has a VoiceOver label naming
the space and its state. All user-facing strings go through `String(localized:)`.

The state matrix (loading, empty, offline, error, insufficient balance, race lost, success,
and *unknown*) is modelled in `GridState` and `ReservationOutcome` rather than in booleans, so
the compiler enforces that each is handled.

## 6. What I would do differently in production

- **Push or SSE instead of polling.** The backend supports neither. A 5-second poll across
  1000 clients at 20:00 is 200 req/s of pure overhead for data that changes 80 times total.
- **A client-supplied idempotency key**, which would delete most of §3.1.
- **A time endpoint**, which would delete most of §3.5.
- **Certificate pinning** against a real host. Against a local HTTP backend there is nothing
  to pin; see `docs/security.md`.
- **A queue-position UI.** The backend already returns `queuePosition` and
  `totalProcessingMs`. With push, "you are 340th of 1000" would turn the 92% failure case
  from a rejection into something legible.

---

## 7. Interface, as built

Screens: `docs/screenshots/`. Captured by `ScreenshotTests`, which drives the real app
against the live backend — so they are a record of behaviour, not a mock-up, and re-running
them is the demo rehearsal.

### 7.1 Why the board does not look like the reference web client

The web client paints available spaces green and taken spaces **red**. At 20:00 the board
goes almost entirely taken, so that design renders 80 red tiles — a screen that reads as
80 errors when nothing has gone wrong. Someone else simply got there first.

Here, taken is a calm slate with a dashed border, and colour is spent only where it carries
meaning: green for what you can act on, amber for the space that is yours. Availability is
carried by border *style* as well as colour, so the board survives greyscale and
colour-blindness.

### 7.2 Density versus touch target — and which one wins

Section 6.3 puts these in different columns, and that decides the argument:

| Guardrail (non-negotiable) | Default (swappable if defended) |
|---|---|
| **All 80 spaces legible on a 6.1-inch screen without relying on pinch-zoom** | Dynamic Type, VoiceOver labels, **44pt minimum touch targets**, contrast |

At 80 cells on a 393×852 screen these pull against each other, and an earlier version of this
document resolved it the wrong way round — honouring 44pt and letting the board scroll, which
sacrifices the non-negotiable item to protect the negotiable one. Corrected.

The board now fits. `BoardLayout` searches column counts and picks the largest cell size that
puts all 80 in the space available, ranking candidates so that a layout meeting 44pt outright
always beats one that does not; only if none does would the Default yield.

In the end neither has to yield. Folding the countdown and the counts into one card, and
dropping the oversized title in portrait, bought roughly 110pt of vertical space — enough that
on the 6.1-inch reference screen the board lands on **7 columns × 12 rows at 44×43pt cells**,
an effective target of 48.7 × 47.2pt including the gutter. All 80 visible, no scrolling, 44pt
comfortably cleared.

`BoardLayoutTests` asserts this against the 393×852 reference rather than against whatever
simulator happens to be installed — the smallest device available locally is 6.3 inches, and a
layout that fits there can still breach the guardrail on the screen the brief actually names.
One of those tests exists purely to fail if a future change quietly reintroduces the
trade-off.

The one place the board is allowed to scroll is at accessibility text sizes, where a fixed
board would clip. Clipping content is worse than scrolling it, and the guardrail is about
legibility at the default reading size.

### 7.3 Selecting and confirming are separate

One tap on the board selects; a second, deliberate tap on the confirm bar spends the money.
The guardrail is one tap, one attempt — and a board of 80 small targets is a bad place to
commit $10 on a mis-tap. The confirm bar states the space, the price and the balance after,
so the commitment is legible before it is made.

### 7.4 The losing sheet is designed, not a fallback

92% of users lose. `OutcomeSheet` therefore gives losing the same care as winning: it names
what happened, never blames the user, and always offers a next action ("Pick another space").
The fourth state — *"We're not sure yet"* — is the one most clients would not have, and it
exists because §3.1 means there are genuinely outcomes the client cannot resolve.

## 8. Bugs this design work surfaced

Three real defects, all found by building the interface rather than by reading code:

1. **A card's hairline overlay swallowed every touch inside it.** The `.overlay(...)`
   carrying the border sat above the card's contents, so all 80 grid cells were untappable
   while controls outside a card still worked. Fixed with `.allowsHitTesting(false)`.
2. **The clock published at 1 Hz whether or not anything changed.** Writing an identical
   value to an `@Published` property still fires `objectWillChange`, so the entire screen
   invalidated 60 times a minute at rest. `updateClock()` now assigns only on change, and
   `refresh()` skips publishing when the board is byte-identical — which is the common case,
   since the grid changes at most 80 times a day. This is what the "no full-grid flicker"
   guardrail actually requires.
3. **Two `.sheet` modifiers on one view.** SwiftUI silently ignores the second, so the
   outcome sheet never appeared unless the wallet sheet had been opened first. Replaced with
   a single sheet driven by an `ActiveSheet` enum.

All three were invisible to the unit tests and only showed up when the UI was driven for
real. That is the argument for the UI test existing at all.


## 9. iPad and landscape

Stretch, from 6.3. Both use the same responsive machinery rather than a second codebase.

**Layout switch.** Side-by-side whenever there is width to spare — `horizontalSizeClass ==
.regular` (iPad, either orientation) or `verticalSizeClass == .compact` (iPhone landscape).
The board takes the leading side at full height; the header, countdown, holding banner and
confirm panel become a sidebar.

Stacking the portrait layout into a landscape phone would squeeze the board into a letterbox
strip. Spreading wide instead lets `BoardLayout` use the extra width: the same 80 cells land
on **10 columns × 8 rows** in iPhone landscape and **6 × 14** on iPad, with cells growing
rather than the board scrolling.

**The confirm control moves with the layout.** Docked to the bottom of the screen in portrait,
where the thumb is; a card in the sidebar when wide, next to the board it refers to. A
bottom-docked bar on a 13-inch iPad would put the action a hand's travel from the thing it
acts on. Same view, two chrome styles, so the copy and behaviour cannot drift apart.

**A bug this surfaced.** The app was not scene-based: because the target supplies its own
`Info.plist`, nothing synthesised a `UIApplicationSceneManifest`, so the window never
resized. Rotating an iPhone left a portrait-shaped app letterboxed on a landscape screen, and
iPad multitasking would not have worked either. Declaring the manifest fixed both.

A second, smaller trap worth recording: `app.screenshot()` captures the app's window without
accounting for interface orientation, so a correctly-rotated app comes back as rotated content
in a portrait frame. The evidence that the app itself was fine was the frame assertion, not the
picture — `XCUIScreen.main.screenshot()` is what the capture uses now.

---

## 10. Guardrail / Default compliance matrix

Section 6 scores five modules independently, and the two columns mean different things:
Guardrail items are non-negotiable, Default items may be swapped if the alternative is
defended *and* built. Getting a row in the wrong column is therefore a scoring error, not a
pedantic one — and I made exactly that mistake in §7.2 before correcting it.

The brief's tables are two-column PDF tables, which flatten into a single text stream when
extracted. Column membership below was recovered from the glyph x-coordinates rather than
read off the flattened text, because the flattened version is what produced the original
error.

### 6.1 App architecture and Swift concurrency

| Col | Item | State |
|---|---|---|
| **G** | Native iOS, SwiftUI, minimum deployment target iOS 17 | met (`project.yml`) |
| **G** | Services behind protocols and injected, fakeable in tests | met (`Sources/Domain/Services.swift`) |
| D | MVVM or Clean Architecture; UI/domain/data separated, no view reaching networking or persistence | kept as written |
| D | Structured concurrency only; `@MainActor` explicit; space cache and wallet balance actor-isolated | kept as written |
| D | Zero build warnings, `-strict-concurrency=complete` clean, SPM only, each dependency justified | kept as written; zero dependencies |

### 6.2 Contention, resilience and UX truth

| Col | Item | State |
|---|---|---|
| **G** | 80-space grid with availability and plate suffix, **deposit field** and balance display | met — the deposit *field* was missing until this audit; presets alone are not a field |
| **G** | Window opens at 20:00, countdown from server time not the device clock, do not hardcode 20:00 | met (`ServerClock`, `ReservationWindow`; hour is configuration) |
| **G** | One tap, exactly one attempt; retry after timeout idempotent and cannot double-book | met (`ReservationCoordinator`, actor-guarded; never retries a timeout) |
| **G** | Two response shapes handled, not one — JSON `ErrorResponse` **and** the bare 401 | met (`HTTPClient.decodeFailure` branches on body emptiness) |
| D | Optimistic UI permitted, with correct visible rollback | **swapped** — reservation stays pessimistic, defended in §4 |
| D | Grid refresh strategy chosen and defended, no full-grid flicker or scroll jump | kept; 5s poll bounded by the server's Redis TTL, no-op diffing |

### 6.3 UI/UX design and accessibility

| Col | Item | State |
|---|---|---|
| **G** | Screen and information architecture designed by you, rationale in `docs/design.md` | met |
| **G** | All 80 spaces legible on a 6.1-inch screen without pinch-zoom | met — 7×12 at 44×43pt, asserted in `BoardLayoutTests` |
| **G** | Full state matrix: loading, empty, error, offline, insufficient balance, race lost, success | met (`GridState`, `ReservationOutcome`) |
| D | HIG, dark mode, no hardcoded user-facing strings | kept |
| D | Dynamic Type to accessibility sizes, VoiceOver labels, 44pt targets, contrast | kept; board scrolls only at accessibility sizes, rather than clipping |
| D | The 20:00 moment designed deliberately | kept |

### 6.4 Testing and delivery discipline

| Col | Item | State |
|---|---|---|
| **G** | Unit tests on the domain **and view models**, race and retry logic genuinely tested | met — view-model tests were missing until this audit |
| **G** | At least one UI test covering login, grid and reserve | met |
| **G** | CI on every push: build, lint, unit tests, UI tests on a simulator | **not yet met** — workflow written, no runner registered, so it has never run |
| D | Tests against fakes never the live backend; SwiftLint in CI at zero violations | kept, with one exception: `ScreenshotTests` drives the live backend deliberately. Skipped unless `SCREENSHOTS=1`, so CI never runs it |
| D | `xcodebuild archive` in CI, build number from the commit, `docs/runbook.md` | kept (`make archive` derives from `git rev-list --count`) |
| D | CI on a self-hosted runner on the development machine | runner `harry-mbp-m4` registered and online; conditions in `docs/runbook.md` §6 |

### 6.5 Standards: security bar and AI-assisted workflow

| Col | Item | State |
|---|---|---|
| **G** | Session token in the Keychain with a justified accessibility class | met (`KeychainTokenStore`) |
| **G** | No secrets, keys or credentialled endpoints in the repo or app bundle | met |
| **G** | `docs/security.md` threat note: what is not implemented, what production would do, why out of scope | met |
| **G** | AI working agreement committed: conventions and quality gates AI code must clear | met (`CLAUDE.md`) |
| **G** | An honest account of where AI helped and where it failed | met — `docs/ai-workflow.md` was referenced but missing until this audit |
| D | Face ID / Touch ID re-auth before a reservation, correct non-biometric fallback | kept, with a 120s grace period defended in §4 |
| D | Certificate pinning against the local backend, bypass gated to debug builds | **not built** — see the risk note below |
| D | A proposal for measuring AI contribution on a mobile repo | met (`CLAUDE.md`) |
| D | Data-privacy limits for an AI tool in a banking context | met (`CLAUDE.md`) |

### Known risk

Certificate pinning is the one Default I have neither kept nor replaced with something built.
`docs/security.md` argues it cannot be meaningfully demonstrated against a plaintext
`http://localhost` backend, and describes what production would use. That reasoning is sound
but the brief is explicit that a swap requires you to *build and demo* the alternative, and an
omission is not a swap. If time allows, the honest fix is to terminate TLS locally with a
self-signed certificate and pin its SPKI hash, so the control exists and can be demonstrated
failing on a wrong pin.
