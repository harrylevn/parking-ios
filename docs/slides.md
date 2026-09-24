# Parking Space Reservation — iOS Client
## Week-1 Checkpoint

Native iOS client for the Parking Space Reservation System.
Deck format mirrors the backend status update; the speaker notes behind these slides are
[`presentation.md`](presentation.md).

---

## Agenda

1. Project Overview
2. Requirements Checklist
3. What the Backend Actually Does
4. Architecture Decisions
5. The 20:00 Moment
6. Testing & CI
7. Security
8. How I Applied AI To My Work
9. Scope Points To Ratify
10. Next Steps

---

## 1. Project Overview

**What I'm building:**
- Native iOS client for the 80-space reservation system
- The client half of the 20:00 race — 1,000 users, 80 winners
- Truthful UX under contention: the app never claims what it cannot prove

**Tech Stack:**
- SwiftUI, iOS 17 minimum — **Swift 6 language mode**, the stretch beyond the Default
- MVVM over three layers — Features / Domain / Data
- Structured concurrency, `-strict-concurrency=complete`, warnings as errors
- XcodeGen (`project.yml` is source of truth)
- **Zero third-party dependencies**

**Status:** day 2 of 10. Functionally complete against the local backend, green in CI.

---

## 2. Requirements Checklist

Column membership recovered from the PDF's glyph coordinates, not from its flattened text —
the tables are two-column and flatten into one stream when copied, which is how I got a row
into the wrong column once already.

### Guardrail — non-negotiable

| Module | Item | State |
|---|---|---|
| 6.1 | Native iOS, SwiftUI, deployment target iOS 17 | ✅ |
| 6.1 | Services behind protocols and injected, fakeable in tests | ✅ |
| 6.2 | 80-space grid: availability, plate suffix, **deposit field**, balance | ✅ |
| 6.2 | Window opens 20:00, countdown from **server** time, 20:00 not hardcoded | ✅ |
| 6.2 | One tap = exactly one attempt; retry after timeout cannot double-book | ✅ |
| 6.2 | **Two** response shapes handled — JSON `ErrorResponse` and the bare 401 | ✅ |
| 6.3 | Screen and information architecture designed by me, rationale in `design.md` | ✅ |
| 6.3 | All 80 spaces legible on a 6.1-inch screen without pinch-zoom | ✅ |
| 6.3 | Full state matrix: loading, empty, error, offline, no balance, race lost, success | ✅ |
| 6.4 | Unit tests on domain **and view models**, race and retry genuinely tested | ✅ 57 |
| 6.4 | At least one UI test covering login, grid and reserve | ✅ 4 |
| 6.4 | CI on every push: build, lint, unit tests, UI tests on a simulator | ✅ |
| 6.5 | Session token in the Keychain with a justified accessibility class | ✅ |
| 6.5 | No secrets, keys or credentialled endpoints in the repo or bundle | ✅ |
| 6.5 | `docs/security.md` threat note: not implemented, production, out of scope | ✅ |
| 6.5 | AI working agreement committed: conventions and quality gates | ✅ |
| 6.5 | An honest account of where AI helped and where it failed | ✅ |

**All seventeen met.**

### Default — defensible, swappable if the alternative is built and demoed

| Module | Item | State |
|---|---|---|
| 6.1 | Layered architecture, no view reaching networking or persistence | ✅ kept |
| 6.1 | Structured concurrency only; `@MainActor` explicit; cache and balance actor-isolated | ✅ kept |
| 6.1 | Zero warnings, `-strict-concurrency=complete`, SPM only, each dependency justified | ✅ kept — zero dependencies |
| 6.2 | Optimistic UI with visible rollback | 🔄 **swapped** — §9.1 |
| 6.2 | Grid refresh strategy chosen and defended, no flicker or scroll jump | ✅ kept |
| 6.3 | HIG, dark mode, no hardcoded strings (String Catalog or equivalent) | ⏳ **partial** — no catalog yet |
| 6.3 | Dynamic Type to accessibility sizes, VoiceOver, 44pt, contrast | ✅ kept |
| 6.3 | The 20:00 moment designed deliberately | ✅ kept |
| 6.4 | Tests against fakes never the live backend; SwiftLint at zero violations | ✅ kept — one disclosed exception, §9.4 |
| 6.4 | `xcodebuild archive` in CI, build number from the commit, `runbook.md` | ✅ kept |
| 6.4 | CI on a self-hosted runner | ✅ kept |
| 6.5 | Face ID / Touch ID before a reservation, correct non-biometric fallback | ✅ kept — every attempt prompts |
| 6.5 | Certificate pinning, bypass gated to debug builds | ⏳ **not built** — §9.3 |
| 6.5 | A proposal for measuring AI contribution on a mobile repo | ✅ kept |
| 6.5 | Data-privacy limits for an AI tool in a banking context | ✅ kept |

**Thirteen kept, one deviation defended, one not built and disclosed.**

### Stretch — not required

| Module | Item | State |
|---|---|---|
| 6.1 | Swift 6 language mode | ✅ built |
| 6.2 | Visible warning when clock skew exceeds 30 seconds | ✅ built |
| 6.2 | Written design for moving to push or SSE | ✅ `design.md` §7 |
| 6.3 | iPad **or** landscape layouts | ✅ both |
| 6.5 | A reusable Claude Code skill for a mobile task, demonstrated working | ✅ three |
| 6.2 | k6 race rehearsal: won, lost, backend killed mid-reservation | ⏳ day 9 |
| 6.2 | Instruments trace of the grid under load | ⏳ day 9 |
| 6.3 | A second locale populated | ⏳ day 7 |
| 6.1 | SPM modularisation; TCA | ✗ not pursued |
| 6.4 | Signed `.ipa` on device; fastlane; snapshot tests; coverage gate | ✗ not pursued |

---

## 3. What the Backend Actually Does

I stood the backend up and measured it **before** designing against it. That cost a day and
changed the design more than the brief did.

### Measured — 1,000 virtual users, clean database, gate on

| Metric | Result |
|---|---|
| Reservations created | **80** — exactly the invariant |
| Duplicate spaces / duplicate `(user, date)` | 0 / 0 |
| Money taken | 800.00 = 80 × 10.00, exact |
| 5xx errors | 0 |
| `POST /reservations` p95 / p99 / max | 248 ms / 368 ms / 867 ms |
| Sustained throughput | ~2,967 req/s |

Two conclusions. The backend's concurrency design is **correct under load** — so any wrong
balance or double booking we see in the app is the client's bug. And **80 of 1,000 win, so
92% lose** — the single number that shaped the interface.

---

### Contract facts the client must survive

| Fact | Consequence for the client |
|---|---|
| `WINDOW_CLOSED` arrives as **HTTP 429** | Any conventional retry policy would back off and retry a closed window. Classify on `code`, never on status |
| **Two different 401 shapes** — bare filter-chain 401 (empty body) and JSON `AUTH_FAILED` | The decoder must not throw on an empty body |
| Idempotency is **server-derived** from `(userId, date)` — no client key | `DUPLICATE_REQUEST` is ambiguous: still in flight, or already succeeded |
| The key is cleared in a `finally` block on failure | The ambiguity is genuinely two-sided |
| **No `GET /reservations`** | A timed-out reservation cannot be resolved by asking |
| No time endpoint | Countdown derives from the HTTP `Date` header, anchored to a monotonic clock |
| `/spaces` is Redis-cached, 5s TTL | Polling faster than 5s cannot reveal anything newer |
| `plateLast3` is 3 chars across 80 spaces | Reconciliation is a strong hint, **not proof** |

Full defect report with reproduction steps: [`defects.md`](defects.md).

### What would remove the ambiguity — for the backend team

The timeout case is not a client bug to be engineered around. It is the Two Generals Problem:
a client that hears nothing back cannot determine whether its request was processed, and no
timeout value changes that. There are exactly two mitigations — **make retrying safe**, and
**make the outcome readable**. The API currently offers neither.

| # | Change | What it buys |
|---|---|---|
| 1 | Return the existing reservation **in the 409 body** | A retry after a timeout becomes self-healing — the conflict *is* the answer. Smallest change here by far |
| 2 | `GET /reservations/me?date=…` | Collapses the unknown state outright: ask, and get id, space, amount and balance. Highest value |
| 3 | Client-supplied `Idempotency-Key`, storing the **response** and never clearing the key on failure | Turns an ambiguous retry into a deterministic replay. The control a bank expects on every money-moving endpoint |
| 4 | `PUT /reservations/{date}` | One reservation per vehicle per day is already a natural key, so replays return the same resource |
| 5 | Read-your-writes on `/spaces` | The 5s cache can serve a grid older than the caller's own write — and that grid is what reconciliation consults |

Two details decide whether (3) actually works: store the **response**, not a dedupe flag, and
**never clear the key on failure**. Clearing it is precisely what makes today's
`DUPLICATE_REQUEST` two-sided.

Only these make the question answerable. Everything the client does is mitigation.

---

## 4. Architecture Decisions

Six ADRs in [`architecture.md`](architecture.md). The four that carry the product:

### ADR-001 — Three layers, no dependencies, Swift 6
**Decision:** Features / Domain / Data, MVVM, every service a protocol

**Why:**
- Domain imports nothing but Foundation — the race logic is testable without a network
- Every collaborator is fakeable, so 71 unit tests need no backend
- `@MainActor` view models, actor-isolated state where contention is real

---

### ADR-002 — Never claim a reservation the client cannot prove
**Decision:** Pessimistic submit, and a fourth outcome that means "I cannot tell"

**Why:**
- 80 winners in 1,000 means an optimistic cell is wrong **92% of the time** — rollback becomes
  the modal experience, not the exception. Against a p95 of 248 ms the wait costs almost nothing
- No client idempotency key and no read endpoint, so a timed-out reservation is genuinely
  indeterminate. `ReservationOutcome.unknown` is a designed state, not an error fallback
- One tap = one attempt, enforced in an actor. A timeout is **never** retried — the client
  reconciles by plate suffix, and when two plates share a suffix it says so
- The 3-second timeout is a *correctness* decision: every spurious timeout lands a user in
  `unknown`, so it sits an order of magnitude above the measured p99 of 368 ms

*Deviates from the 6.2 Default — see §9.1*

---

### ADR-003 — Classify errors on the payload, not the HTTP status
**Decision:** Read the business `code`; check body emptiness before decoding

**Why:**
- `WINDOW_CLOSED` arrives as **429**, which every conventional retry policy reads as
  "back off and try again" — useless against a window that opens on a clock, and a
  self-inflicted thundering herd at 20:00
- **Two 401 shapes:** bare filter-chain 401 with an empty body, and JSON `AUTH_FAILED`.
  Decoding every non-2xx as JSON throws on the first; treating every 401 as a dead session
  signs the user out for a typo — which is what the reference web client does
- Pinned by tests against bytes captured from the running backend

---

### ADR-004 — Server time and refresh without a push channel
**Decision:** Anchor the HTTP `Date` header to a monotonic clock; poll at the server's own cadence

**Why:**
- No time endpoint exists, and `Date()` is trivially defeated by changing the device clock —
  the obvious way to cheat a countdown
- Skew beyond 30s is surfaced to the user; the window hour is configuration, never a hardcoded 20
- `/spaces` is Redis-cached at 5s, so polling faster cannot reveal anything newer
- Publish only on change: writing an identical `@Published` value still fires
  `objectWillChange`, which invalidated the whole screen at 1 Hz and made the board untappable
  under UI test

---

## 5. The 20:00 Moment

```
T-60s  ─────────────────────────────────────────────────────
       │ Countdown from server time, not the device clock
       │   • ServerClock anchors the HTTP Date header
       │     to a monotonic clock
       │   • Device clock skew is surfaced, not swallowed
       ▼
T-0    ─────────────────────────────────────────────────────
       │ Window opens — the board becomes tappable
       ▼
       [User taps one space — exactly one attempt]
       │
       │   1. Biometric re-auth — every attempt, no grace
       │   2. Balance checked before submit
       │   3. POST /reservations, 3s timeout
       │   4. Classify on `code`, never on HTTP status
       ▼
       ┌─────────────┬──────────────┬─────────────┬──────────┐
       │  confirmed  │  lost race   │  no balance │ unknown  │
       │    (8%)     │    (92%)     │             │          │
       └─────────────┴──────────────┴─────────────┴──────────┘
                                                       │
                                       reconcile by plateLast3
                                       → still ambiguous? say so
```

**The design problem is the 92%.** Losing has to read as the honest outcome of a fair race,
not as a failure of the app.

### The unknown path, forced rather than argued

`unknown` carries the most design weight of any state and was the least observed, so I made it
happen on purpose. The backend moved to `:8081`; a proxy on `:8080` forwarded everything
untouched **except** `POST /reservations`, where it forwarded the request, took the real
answer, and held it back for six seconds. Nothing in the app changed, and nothing in the
backend changed.

```
[proxy] POST /reservations -> 200 in 137ms, holding 6.0s
```

**The reservation committed in 137 ms. The client gave up at 3 s.** Server state afterwards:
space 1 held by suffix `434`, balance `90.00`.

What the app showed: *"We're not sure yet — Space 1 appears to be yours. Pull to refresh to
confirm."* Designed behaviour, and it held up.

**Two defects the run exposed that reading the code did not:**

| # | Defect | Why it matters |
|---|---|---|
| 1 | Behind the sheet, the holding card asserts **"Space 1 is yours"** while the sheet in front says it is not sure | Both read the same three-character suffix. The card states as fact what the coordinator refuses to state. And with no read endpoint, *every* holding is inference after a relaunch — the confident wording is only ever earned in the session that saw a `201` |
| 2 | The wallet header showed **$100**; the server said **$90.00** | $10 moved and the UI never noticed. The balance is also **stronger evidence than the plate suffix** — per-user, so it cannot collide the way three characters across 80 cells can — and reconciliation ignores it today |

Neither is a wrong decision. Both are the same decision not carried all the way: proven state
and inferred state are rendered identically. **#2 is fixed** — the balance is re-fetched after
any attempt that did not return one. #1 is day 6.

**A third, found in review:** only a *timeout* was reconciled. Killing the backend mid-request
surfaces as `networkConnectionLost`, not a timeout, so the app would have said "Couldn't
reserve" about a reservation that may have committed. Now every failure except a provably-unsent
request is reconciled; the day-9 kill rehearsal will show it.

*This is also the argument for §3's backend list: the client can only ever narrow the
ambiguity, never end it.*

---

## 6. Testing & CI

| Layer | Count | Runs against |
|---|---|---|
| Unit tests | 71 | Fakes only — no backend needed |
| UI tests | 4 | Simulator, login → grid → reserve, registration |
| Screenshot tests | 5 | **Live backend, deliberately** — skipped unless `SCREENSHOTS=1` |

**CI — every push to `main`, self-hosted runner on the development machine:**

```
lint → build → unit tests → UI tests → archive → upload results
```

Self-hosted because the free tier does not cover macOS minutes for the fortnight; the
registration conditions are in [`runbook.md`](runbook.md) §7.

**CI has already earned its place:** it caught a UI test that was green locally only because
I had switched Reduce Motion on in the simulator by hand.

---

## 7. Security

| Control | State |
|---|---|
| Session token in the Keychain | `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — justified in `security.md` |
| Biometric re-auth before reserving | Built, **every attempt**, `.deviceOwnerAuthentication` fallback |
| No secrets in repo or bundle | Verified — nothing credentialled is committed |
| Certificate pinning | **Not built** — disclosed in §9.3 |
| Threat note | What is not implemented, what production would do, why out of scope |

---

## 8. How I Applied AI To My Work

Working agreement in `CLAUDE.md`; the honest account in [`ai-workflow.md`](ai-workflow.md).

**Where it helped:** boilerplate across 22 files, test scaffolding, keeping the ADRs written as
decisions were taken rather than reconstructed afterwards.

**Where it failed, and what it cost:**

| Failure | Cost | Lesson |
|---|---|---|
| Misread the brief's two-column table — put a Guardrail in the Default column | Built a board that scrolled, then defended the wrong trade-off in writing | The PDF's tables flatten into one text stream; column membership had to be recovered from glyph coordinates |
| Six guesses at a failing UI test before looking at the evidence | Most of an afternoon | The test had been capturing a screenshot the whole time. Open the `.xcresult` **before** forming a hypothesis |

Both are written up in full rather than quietly fixed, because the module asks for the
account, not for a success story.

---

## 9. Scope Points To Ratify

The brief puts trade-off ratification at this checkpoint rather than in a Slack thread.

### 9.1 Pessimistic reservation instead of optimistic UI — **built**
Wrong 92% of the time is not a rollback, it is the modal experience. Reasoning in ADR-002.

### 9.2 Biometric re-auth — **built as written**, after I withdrew an argument
It first shipped with a 120-second grace period, defended from the race. Withdrawn: step-up
auth evidences consent to *this* transaction, not to one given two minutes ago, and the
exemption was free to anyone holding the unlocked handset. Every attempt prompts.

### 9.3 Certificate pinning — **not built, and I want to be explicit**
The backend is `http://localhost:8080` with no TLS anywhere in the exercise, so there is
nothing to pin. I am flagging this rather than presenting it as a defended swap, because
**an omission with a rationale is not a swap**.

Listed as a known gap; **no time planned for it** unless this checkpoint asks. The version
worth building would terminate TLS locally with a self-signed certificate, pin its SPKI hash,
and show the client refusing a connection under a deliberately wrong pin.

### 9.4 One test suite deliberately uses the live backend
`ScreenshotTests`. Skipped unless `SCREENSHOTS=1`, so CI never runs it and the
"tests against fakes" Default holds for everything CI executes. Flagged so it is not a surprise.

---

## 10. Next Steps

Full day-by-day in [`plan.md`](plan.md).

| Days | Focus |
|---|---|
| 6 | The 20:00 moment — countdown states, contention feedback, the loss path, and the two honest-state defects in §5 |
| 7 | Accessibility audit, string catalog, second locale |
| 8 | Security module — pinning if ratified |
| 9 | Three rehearsals: won race, lost race, backend killed mid-reservation |
| 10 | Clean-clone build, doc pass, two full demo run-throughs |

**Risks I am carrying:**
- 16 GB machine is tight with colima, Xcode and simulators together — two OOM kills now, the
  second during ordinary work rather than under load
- A backend started with the gate bypassed looks identical to one with it on until you
  reserve outside the window, so every rehearsal asserts `WINDOW_CLOSED` first

---

## Questions For You

1. Do you accept the pessimistic-reservation deviation as built?
2. Certificate pinning is listed as a known gap, not planned. Is the written risk note in
   `security.md` sufficient, or do you want it built?
3. For the backend team: are §3's first three changes — the reservation in the 409 body, a
   read-back endpoint, and idempotency keys — worth raising? They are what would let the
   client stop guessing, and (1) is close to free.
4. Anything else you want covered at the Week-2 demo that is not already in the plan?

---
