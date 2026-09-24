# Design

Native iOS client for the Parking Space Reservation System. SwiftUI, iOS 17 minimum.

This document is the narrative: the problem, the interface, and the argument for the
deviations. The *decisions* — with the alternatives weighed and the costs accepted — are six
records in [`architecture.md`](architecture.md); this document cites them rather than repeating
them. [`codebase.md`](codebase.md) maps where everything lives.

Where I deviated from the brief's Default column, the deviation and its justification are in
§4, which is where the brief requires them to be.

---

## 1. The problem, honestly stated

80 spaces open at 20:00 for the next day. Roughly a thousand users compete. Measured against
the live backend at 1000 VUs: **80 users win and 920 lose.**

That number drove most of what follows. This is not a product where reserving a space is the
common path with a few error cases around the edges — 92% of the people using it at 20:00
will fail, and the quality of the app is mostly the quality of how it handles that.

## 2. The shape of the client

```
Features/   SwiftUI views + @MainActor view models
Domain/     models, service protocols, ReservationCoordinator, ServerClock  (Foundation only)
Data/       HTTPClient, DTOs, Keychain, biometrics          (conforms to Domain protocols)
App/        AppEnvironment — the single composition root
```

Every service is a protocol (`Sources/Domain/Services.swift`), constructed in `AppEnvironment`
and injected downwards, so tests substitute fakes and nothing reaches for a singleton. No view
touches networking or persistence.

async/await throughout, no completion handlers. View models are `@MainActor`; shared mutable
state is actor-isolated where it has to be — `ServerClock` because every response writes to it
from an arbitrary executor, `ReservationCoordinator` because its in-flight flag is what enforces
one-tap-one-attempt under concurrent taps. The grid poll loop is a `Task` owned by the view
model and cancelled on teardown.

No third-party dependencies. Swift 6 language mode, complete strict concurrency, warnings as
errors. One `nonisolated(unsafe)` survives, on two `ISO8601DateFormatter` statics, with the
reasoning at the call site.

→ [ADR-001](architecture.md#adr-001) for why each of those, and what was considered instead.

## 3. What the backend's actual behaviour forced

I stood the backend up and exercised it before designing against it. The evidence is in
[`defects.md`](defects.md); the decisions those findings forced are in the ADRs. What matters
here is the chain from observation to consequence:

| Observed | Consequence for the client | Decision |
|---|---|---|
| Idempotency keyed server-side on `(userId, date)`; no client key, no `GET /reservations`, key cleared on failure | A timed-out reservation is genuinely indeterminate, and a retry returns an equally ambiguous `DUPLICATE_REQUEST` | [ADR-002](architecture.md#adr-002) |
| p95 248 ms, p99 368 ms, max 867 ms under 1000 VUs | The timeout is a correctness setting, not a performance one — every spurious timeout manufactures an indeterminate outcome | [ADR-002](architecture.md#adr-002) |
| `WINDOW_CLOSED` returned as **HTTP 429** | A conventional transport-layer retry policy would back off and retry a window that opens on a clock — and at 20:00 scale, a self-inflicted thundering herd | [ADR-003](architecture.md#adr-003) |
| Two 401 shapes: bare filter-chain 401, and JSON `AUTH_FAILED` | Decoding must branch on body emptiness before status, or mistyping a password signs you out — which is what the reference web client does | [ADR-003](architecture.md#adr-003) |
| No time endpoint | The countdown anchors the HTTP `Date` header to a monotonic clock; `Date()` would be trivially defeated by changing the device clock | [ADR-004](architecture.md#adr-004) |
| `/spaces` Redis-cached at 5s | Polling faster cannot surface anything newer, so the interval is the server's, not a matter of taste | [ADR-004](architecture.md#adr-004) |

The rule the first two rows produce, and the one this client is built around:
**never claim a reservation the client cannot substantiate.** `ReservationOutcome` has four
cases rather than two, and one of them is `.unknown`, because there are states where "we don't
know yet" is the only true thing the app can say.

## 4. Deviations from the brief's Default column

### Deviation — pessimistic reservation, optimistic elsewhere

The brief permits optimistic UI with visible rollback. I am **not** applying it to the
reservation itself.

With 80 winners in 1000, an optimistic "reserved" cell is wrong about 92% of the time.
Rollback would stop being the exception and become the common path: the modal experience
would be a space appearing to be yours and then being taken away. That is a worse experience
than a 250 ms wait, and in a banking context an interface that shows you holding something
you do not hold is exactly the wrong instinct.

Optimistic updates are used where the success rate justifies them — deposits, which do not
contend.

### Not a deviation — re-authentication, and an argument I withdrew

The Default column puts Face ID before a reservation is submitted. It is built as written:
**every attempt prompts**, retries after losing included.

It did not start there. The first implementation carried a 120-second grace period, defended
from the race — a biometric prompt in the critical path of a contest decided in milliseconds
costs seconds, and since one reservation per vehicle per day is a backend invariant, nearly
every re-attempt is a retry after losing. On those grounds the prompt looked like a tax on the
common path that bought no security.

That argument weighs the wrong thing, and this document is the right place to say so rather
than quietly ship the better version. Step-up authentication in a banking context is not a
proportionality control keyed to the amount at risk; it exists to produce evidence that the
account holder consented to *this* transaction. A session-scoped exemption destroys exactly
that evidence, and it is free to anyone holding the unlocked handset — the wrong party to make
it cheap for. `CLAUDE.md` opens by claiming a banking bar for this repository; an exemption on
the one action that moves money was the clearest place that claim was not being met.

The race cost is real, and it is now accepted rather than designed around. It is also not yet
measured on device; a simulator figure would flatter it, so the measurement is a day-9
Instruments item rather than a number quoted here.

What is tested is the *contract*: `ReservationCoordinatorTests` asserts three attempts produce
three authorisations, so nothing can start caching consent between the tap and the request.
What is **not** tested is the concrete `BiometricReauthenticator`, because with the grace
period gone it holds no state — the guarantee there rests on a stateless struct and a fresh
`LAContext` per call, not on an assertion. That matters because `LAContext` carries a reuse
window of its own in `touchIDAuthenticationAllowableReuseDuration`, so a context stored across
attempts would be the same exemption in a form no test currently catches.

Fallback is `.deviceOwnerAuthentication`, not the biometrics-only policy, so a user without
Face ID or locked out after failed attempts falls back to the passcode rather than being
locked out of the product.

### Not a deviation — certificate pinning

The third Default I did not implement as written is certificate pinning, and I am not claiming
it as a swap. Nothing was built, so it is carried as an open risk in
[ADR-006](architecture.md#adr-006) and in [`security.md`](security.md), and it is the one row
in §8's matrix that is neither kept nor replaced.

## 5. The interface

Screens: [`screenshots/`](screenshots/). Captured by `ScreenshotTests`, which drives the real
app against the live backend — so they record behaviour rather than a mock-up, and re-running
them is the demo rehearsal.

Sign in, and then the board. The state matrix — loading, empty, offline, error, insufficient
balance, race lost, success, and *unknown* — is modelled in `GridState` and `ReservationOutcome`
rather than in booleans, so the compiler enforces that each is handled.

There is also a registration screen, which the brief does not ask for; it exists so accounts can
be made without curl. It is a plain form, kept off the sign-in screen because a form can only
submit the fields it has and a password being created should be typed twice. It states the
plate and password rules the backend enforces rather than letting a 400 explain them, and it
surfaced one real gap: `DUPLICATE_RESOURCE`, the code for a plate that already has an account,
was missing from `BusinessErrorCode`, and an unrecognised code makes the whole error body fail
to decode.

### 5.1 Why the board does not look like the reference web client

The web client paints available spaces green and taken spaces **red**. At 20:00 the board
goes almost entirely taken, so that design renders 80 red tiles — a screen that reads as
80 errors when nothing has gone wrong. Someone else simply got there first.

Here, taken is a calm slate with a dashed border, and colour is spent only where it carries
meaning: green for what you can act on, amber for the space that is yours. Availability is
carried by border *style* as well as colour, so the board survives greyscale and
colour-blindness. Every cell has a VoiceOver label naming the space and its state.

### 5.2 Density versus touch target — and which one wins

Section 6.3 puts these in different columns, and that decides the argument:

| Guardrail (non-negotiable) | Default (swappable if defended) |
|---|---|
| **All 80 spaces legible on a 6.1-inch screen without relying on pinch-zoom** | Dynamic Type, VoiceOver labels, **44pt minimum touch targets**, contrast |

At 80 cells on a 393×852 screen these pull against each other, and an earlier version of this
document resolved it the wrong way round — honouring 44pt and letting the board scroll, which
sacrifices the non-negotiable item to protect the negotiable one. Corrected; the reading error
and its root cause are recorded in [ADR-005](architecture.md#adr-005).

In the end neither has to yield. `BoardLayout` searches column counts for the largest cell size
that puts all 80 in the space available, ranking a layout that meets 44pt above one that does
not. Folding the countdown and the counts into one card, and dropping the oversized portrait
title, bought roughly 110pt — enough that on the 6.1-inch reference the board lands on
**7 columns × 12 rows at 44×43pt cells**, an effective target of 48.7 × 47.2pt including the
gutter. All 80 visible, no scrolling, 44pt comfortably cleared.

`BoardLayoutTests` asserts this against the 393×852 reference rather than whatever simulator
happens to be installed — the smallest device available locally is 6.3 inches, and a layout that
fits there can still breach the guardrail on the screen the brief names. One of those tests
exists purely to fail if a future change quietly reintroduces the trade-off.

The one place the board is allowed to scroll is at accessibility text sizes, where a fixed board
would clip. Clipping content is worse than scrolling it, and the guardrail is about legibility
at the default reading size.

### 5.3 Selecting and confirming are separate

One tap on the board selects; a second, deliberate tap on the confirm bar spends the money.
The guardrail is one tap, one attempt — and a board of 80 small targets is a bad place to
commit $10 on a mis-tap. The confirm bar states the space, the price and the balance after,
so the commitment is legible before it is made.

### 5.4 The losing sheet is designed, not a fallback

92% of users lose. `OutcomeSheet` therefore gives losing the same care as winning: it names
what happened, never blames the user, and always offers a next action ("Pick another space").
The fourth state — *"We're not sure yet"* — is the one most clients would not have, and it
exists because §3 means there are genuinely outcomes the client cannot resolve.

### 5.5 iPad and landscape

Side-by-side whenever there is width to spare, rather than a second codebase: the board takes
the leading side at full height, and the header, countdown, holding banner and confirm panel
become a sidebar. The same 80 cells land on **10 × 8** in iPhone landscape and **6 × 14** on
iPad, cells growing rather than the board scrolling. The confirm control is docked to the bottom
in portrait, where the thumb is, and becomes a card in the sidebar when wide — same view, two
chrome styles, so copy and behaviour cannot drift apart.

Cells grow with the screen, but the ceiling on that growth is relative to the cell's own width
rather than a fixed number of points. It was a flat 64pt, which is invisible on a phone — the
height available per row is smaller than that anyway — and wrong on a 13-inch iPad, where the
rows stopped growing with about a third of the card empty beneath them. All 80 spaces were
visible and comfortably above 44pt, so nothing was *broken*; it simply looked unfinished, which
on a screen a reviewer will open is much the same thing.

→ [ADR-005](architecture.md#adr-005) for the size-class rules and why the control moves rather
than merely resizing.

## 6. What building the interface surfaced

Six real defects, none of them visible to the unit tests, and the last not visible to the UI
tests either — it needed the app driven against the real backend by hand. That is the argument
for the rehearsals as much as for the tests.

1. **A card's hairline overlay swallowed every touch inside it.** The `.overlay(...)` carrying
   the border sat above the card's contents, so all 80 grid cells were untappable while
   controls outside a card still worked. Fixed with `.allowsHitTesting(false)`.
2. **The clock published at 1 Hz whether or not anything changed.** Writing an identical value
   to an `@Published` property still fires `objectWillChange`, so the entire screen invalidated
   60 times a minute at rest. `updateClock()` now assigns only on change, and `refresh()` skips
   publishing when the board is byte-identical — the common case, since the grid changes at most
   80 times a day. This is what "no full-grid flicker" actually requires.
3. **Two `.sheet` modifiers on one view.** SwiftUI silently ignores the second, so the outcome
   sheet never appeared unless the wallet sheet had been opened first. Replaced with a single
   sheet driven by an `ActiveSheet` enum.
4. **The app was not scene-based.** Because the target supplies its own `Info.plist`, nothing
   synthesised a `UIApplicationSceneManifest`, so the window never resized: rotating an iPhone
   left a portrait-shaped app letterboxed on a landscape screen, and iPad multitasking would not
   have worked either.
5. **`app.screenshot()` ignores interface orientation**, so a correctly-rotated app comes back
   as rotated content in a portrait frame. The evidence that the app was fine was the frame
   assertion, not the picture; the capture now uses `XCUIScreen.main.screenshot()`.
6. **The stored token was attached to sign-in itself**, which wedged the app permanently. The
   shared request builder added `Authorization` to every request, `/auth/**` included. That
   endpoint is `permitAll`, but permitAll means *authentication is not required* — it does not
   mean a token present in the request is ignored, and Spring's bearer-token filter rejects one
   it cannot verify with a bare 401 before the authorisation rules are consulted. Tokens last 24
   hours and the app never restores a session, so every launch went through sign-in carrying a
   dead token, and the only thing that could replace it was the request it was blocking.
   Verified at the wire: `POST /auth/login` answers normally with no header and 401 with a stale
   one. This is the one on this list that would have ended a demo.

## 7. What I would do differently in production

- **Push or SSE instead of polling.** The backend supports neither. A 5-second poll across
  1000 clients at 20:00 is 200 req/s of pure overhead for data that changes 80 times total.
- **A client-supplied idempotency key**, which would delete most of ADR-002.
- **A time endpoint**, which would delete most of ADR-004.
- **Certificate pinning** against a real host. Against a local HTTP backend there is nothing
  to pin; see [`security.md`](security.md).
- **A queue-position UI.** The backend already returns `queuePosition` and
  `totalProcessingMs`. With push, "you are 340th of 1000" would turn the 92% failure case
  from a rejection into something legible.

---

## 8. Guardrail / Default compliance matrix

Section 6 scores five modules independently, and the two columns mean different things:
Guardrail items are non-negotiable, Default items may be swapped if the alternative is
defended *and* built. Getting a row in the wrong column is therefore a scoring error, not a
pedantic one — and I made exactly that mistake in §5.2 before correcting it.

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
| D | Zero build warnings, `-strict-concurrency=complete` clean, SPM only, each dependency justified | kept, and exceeded — Swift 6 language mode, so the diagnostics are errors by language rule rather than by build setting. Zero dependencies |

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
| D | HIG, dark mode, no hardcoded user-facing strings (String Catalog or equivalent) | **partly** — HIG and dark mode kept. SwiftUI's `Text("…")` and `Button("…")` literals are `LocalizedStringKey` and extractable, but components taking a plain `String` parameter bypass that, and there is no String Catalog yet. Scheduled day 7. (A *populated* second locale is Stretch, not this row) |
| D | Dynamic Type to accessibility sizes, VoiceOver labels, 44pt targets, contrast | kept; board scrolls only at accessibility sizes, rather than clipping |
| D | The 20:00 moment designed deliberately | kept |

### 6.4 Testing and delivery discipline

| Col | Item | State |
|---|---|---|
| **G** | Unit tests on the domain **and view models**, race and retry logic genuinely tested | met — view-model tests were missing until this audit |
| **G** | At least one UI test covering login, grid and reserve | met |
| **G** | CI on every push: build, lint, unit tests, UI tests on a simulator | met — `.github/workflows/ci.yml` runs lint, build, unit tests, UI tests and archive on every push to `main`, on the runner below. It has caught a UI test that was green only because of a simulator setting I had changed by hand |
| D | Tests against fakes never the live backend; SwiftLint in CI at zero violations | kept, with one exception: `ScreenshotTests` drives the live backend deliberately. Skipped unless `SCREENSHOTS=1`, so CI never runs it |
| D | `xcodebuild archive` in CI, build number from the commit, `docs/runbook.md` | kept (`make archive` derives from `git rev-list --count`) |
| D | CI on a self-hosted runner on the development machine | runner `harry-mbp-m4` registered and online; conditions in `docs/runbook.md` §7 |

### 6.5 Standards: security bar and AI-assisted workflow

| Col | Item | State |
|---|---|---|
| **G** | Session token in the Keychain with a justified accessibility class | met (`KeychainTokenStore`) |
| **G** | No secrets, keys or credentialled endpoints in the repo or app bundle | met |
| **G** | `docs/security.md` threat note: what is not implemented, what production would do, why out of scope | met |
| **G** | AI working agreement committed: conventions and quality gates AI code must clear | met (`CLAUDE.md`) |
| **G** | An honest account of where AI helped and where it failed | met — `docs/ai-workflow.md` was referenced but missing until this audit |
| D | Face ID / Touch ID re-auth before a reservation, correct non-biometric fallback | kept as written — every attempt prompts; `.deviceOwnerAuthentication` fallback |
| D | Certificate pinning against the local backend, bypass gated to debug builds | **not built** — see the risk note below |
| D | A proposal for measuring AI contribution on a mobile repo | met (`CLAUDE.md`) |
| D | Data-privacy limits for an AI tool in a banking context | met (`CLAUDE.md`) |

### Stretch items, which the brief does not require

Listed because several are done and it would be odd to leave them unclaimed, and because the
unfinished ones are scheduled rather than abandoned.

| Module | Item | State |
|---|---|---|
| 6.1 | Swift 6 language mode | built |
| 6.2 | A visible warning when clock skew exceeds 30 seconds | built (`CountdownHero`) |
| 6.2 | A written design for moving to push or SSE | §7 |
| 6.3 | iPad **or** landscape layouts | both built |
| 6.5 | A reusable Claude Code skill for a mobile task, demonstrated working | three, in `.claude/skills/` |
| 6.2 | The k6 race rehearsal, and an Instruments trace under load | day 9 |
| 6.3 | A second locale populated | day 7 |
| 6.1 | SPM modularisation, or a unidirectional architecture such as TCA | not pursued |
| 6.4 | Signed `.ipa` on device, fastlane, snapshot tests, a coverage gate | not pursued |

### Known risk

Certificate pinning is the one Default I have neither kept nor replaced with something built.
`docs/security.md` argues it cannot be meaningfully demonstrated against a plaintext
`http://localhost` backend, and describes what production would use. That reasoning is sound
but the brief is explicit that a swap requires you to *build and demo* the alternative, and an
omission is not a swap. If time allows, the honest fix is to terminate TLS locally with a
self-signed certificate and pin its SPKI hash, so the control exists and can be demonstrated
failing on a wrong pin.
