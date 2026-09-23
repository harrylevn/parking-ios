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

Guardrail rows are non-negotiable; Default rows may be swapped if the alternative is
defended *and* built.

| Requirement | Col | Status | Implementation |
|---|---|---|---|
| Native iOS, SwiftUI, iOS 17 minimum | G | ✅ Built | `project.yml` |
| Services behind injected protocols, fakeable | G | ✅ Built | `Sources/Domain/Services.swift` |
| 80-space grid, availability, plate suffix, deposit field, balance | G | ✅ Built | `BoardView`, `DepositSheet` |
| Countdown from server time, 20:00 not hardcoded | G | ✅ Built | `ServerClock`, hour is configuration |
| One tap = exactly one attempt; retry cannot double-book | G | ✅ Built | `ReservationCoordinator` (actor) |
| Both response shapes handled, not one | G | ✅ Built | `HTTPClient.decodeFailure` |
| All 80 spaces legible on 6.1-inch, no pinch-zoom | G | ✅ Built | 7×12 at 44×43pt, asserted in tests |
| Full state matrix incl. offline, race lost, unknown | G | ✅ Built | `GridState`, `ReservationOutcome` |
| Unit tests on domain **and view models** | G | ✅ Built | 46 tests |
| At least one UI test: login, grid, reserve | G | ✅ Built | `ReservationFlowUITests` |
| CI on every push: build, lint, unit, UI | G | ✅ Built | Self-hosted runner, green on head |
| Token in Keychain, justified accessibility class | G | ✅ Built | `KeychainTokenStore` |
| No secrets in repo or bundle | G | ✅ Built | — |
| `docs/security.md` threat note | G | ✅ Built | — |
| AI working agreement + honest account | G | ✅ Built | `CLAUDE.md`, `docs/ai-workflow.md` |
| Optimistic UI with rollback | D | 🔄 Swapped | Pessimistic submit — see §9.1 |
| Face ID before reserving | D | 🔄 Adapted | 120s grace period — see §9.2 |
| Certificate pinning | D | ⏳ Not built | Deliberate, disclosed — see §9.3 |
| Dynamic Type, VoiceOver, 44pt, contrast | D | ✅ Built | Board scrolls at accessibility sizes |
| iPad and landscape | D | ✅ Built | — |
| No hardcoded user-facing strings | D | ⏳ Partial | String catalog scheduled day 7 |

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

---

## 4. Architecture Decisions

Six ADRs in [`architecture.md`](architecture.md). The four that carry the product:

### ADR-001 — Three layers, no dependencies, Swift 6
**Decision:** Features / Domain / Data, MVVM, every service a protocol

**Why:**
- Domain imports nothing but Foundation — the race logic is testable without a network
- Every collaborator is fakeable, so 46 unit tests need no backend
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
       │   1. Biometric re-auth (120s grace)
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

---

## 6. Testing & CI

| Layer | Count | Runs against |
|---|---|---|
| Unit tests | 45 | Fakes only — no backend needed |
| UI tests | 2 | Simulator, login → grid → reserve |
| Screenshot tests | 3 | **Live backend, deliberately** — skipped unless `SCREENSHOTS=1` |

**CI — every push to `main`, self-hosted runner on the development machine:**

```
lint → build → unit tests → UI tests → archive → upload results
```

Self-hosted because the free tier does not cover macOS minutes for the fortnight; the
registration conditions are in [`runbook.md`](runbook.md) §6.

**CI has already earned its place:** it caught a UI test that was green locally only because
I had switched Reduce Motion on in the simulator by hand.

---

## 7. Security

| Control | State |
|---|---|
| Session token in the Keychain | `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — justified in `security.md` |
| Biometric re-auth before reserving | Built, 120s grace period, `.deviceOwnerAuthentication` fallback |
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

### 9.2 Biometric re-auth with a 120-second grace period — **built**
A modal in the critical path of a race decided in milliseconds would make the security
control the reason users lose. Re-auth still gates the session's first reservation.

### 9.3 Certificate pinning — **not built, and I want to be explicit**
The backend is `http://localhost:8080` with no TLS anywhere in the exercise, so there is
nothing to pin. I am flagging this rather than presenting it as a defended swap, because
**an omission with a rationale is not a swap**.

The honest version: terminate TLS locally with a self-signed certificate, pin its SPKI hash,
and show the client refusing a connection under a deliberately wrong pin. Roughly an hour.
Your call whether it is worth a day-8 slot.

### 9.4 One test suite deliberately uses the live backend
`ScreenshotTests`. Skipped unless `SCREENSHOTS=1`, so CI never runs it and the
"tests against fakes" Default holds for everything CI executes. Flagged so it is not a surprise.

---

## 10. Next Steps

Full day-by-day in [`plan.md`](plan.md).

| Days | Focus |
|---|---|
| 6 | The 20:00 moment — clock-skew warning, contention feedback, the loss path |
| 7 | Accessibility audit, string catalog, second locale |
| 8 | Security module — pinning if ratified |
| 9 | Three rehearsals: won race, lost race, backend killed mid-reservation |
| 10 | Clean-clone build, doc pass, two full demo run-throughs |

**Risks I am carrying:**
- 16 GB machine is tight with colima, Xcode and simulators together — already one OOM kill
- A backend started with the gate bypassed looks identical to one with it on until you
  reserve outside the window, so every rehearsal asserts `WINDOW_CLOSED` first

---

## Questions For You

1. Do you accept the pessimistic-reservation and grace-period deviations as built?
2. Is certificate pinning against a locally-terminated TLS endpoint worth a day-8 slot, or is
   the written design sufficient?
3. Anything else you want covered at the Week-2 demo that is not already in the plan?

---
