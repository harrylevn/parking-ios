# Week-1 checkpoint

Roughly 30 minutes. Current status, blockers, technical direction and decisions, and the
scope points I would like ratified.

This is the source for the slides; the notes under each heading are what I intend to say, not
what goes on screen.

---

## 1. Where things stand — day 2 of 10

The client is functionally complete against the local backend and green in CI. That is
earlier than planned, and it is deliberate: the remaining eight days are for hardening the
20:00 race, the security module, and the demo itself, which are the parts that decide the
outcome.

| | |
|---|---|
| App code | 2,985 lines of Swift, 29 files, **zero third-party dependencies** |
| Tests | 45 unit, 2 UI, 3 screenshot — all green |
| Docs | 1,849 lines across 7 documents |
| CI | Self-hosted runner, green on every push: lint, build, unit, UI, archive |
| Commits | 15, on a private repo shared with the team |

Working end to end: sign in and register, the 80-space board with plate suffixes, the
countdown driven by server time, select → confirm → reserve, wallet deposit and balance, the
full state matrix, iPad and landscape layouts, dark mode.

**Not done yet, and scheduled:** certificate pinning (see §5), a second locale, haptics and
motion polish, the k6 race rehearsal as a demo script, and the "backend killed
mid-reservation" rehearsal.

---

## 2. What I did before writing any client code

I stood the backend up and exercised it first. That cost a day and changed the design more
than the brief did — every significant decision in §4 comes from something measured rather
than assumed.

**Measured under load** — 1,000 virtual users, clean database, gate on:

| | |
|---|---|
| Reservations created | **80** — exactly the invariant |
| Duplicate spaces, duplicate (user, date) | 0, 0 |
| Money taken | 800.00 = 80 × 10.00, exact |
| 5xx errors | 0 |
| Reservation p95 / p99 / max | 248 ms / 368 ms / 867 ms |
| Sustained throughput | ~2,967 req/s |

Two things follow. The backend's concurrency design is correct under load, so any wrong
balance or double booking we see in the app is the client's bug. And **80 of 1,000 users win,
so 92% lose** — which is the single number that shaped the interface.

---

## 3. Blockers and defects — the one that needs a decision

Eight items are recorded in `docs/defects.md`, split into errors in the brief itself and
backend defects. Seven are worked around in the client and need nothing from you. One does.

### The brief's command for enabling the time gate does not work

Section 4 of the brief says to run the backend with
`-Dapp.reservation.bypass-time-check=false`. Passed that way the gate stays **bypassed**:
`spring-boot:run` forks a separate JVM, and a forked process does not inherit the parent's
`-D` system properties.

Verified by running both forms one minute apart, same `window-hour=20`:

| Form | Application JVM | `POST /reservations` at 09:51 |
|---|---|---|
| As the brief writes it | no `-D` flags at all | **HTTP 200** — reservation created |
| `-Dspring-boot.run.jvmArguments="…"` | carries both flags | **HTTP 429 `WINDOW_CLOSED`** |

It fails silently and in the permissive direction: no warning, no log line, every reservation
succeeds. That is indistinguishable from correct behaviour unless you attempt a reservation
outside the window and expect a rejection.

**What I need from you:** this is an error in VNCDC's own instructions, not a backend defect,
so I cannot work around it — and anyone else given this brief will hit it. It is worth
correcting at source before the next candidate.

### The rest, for completeness

`WINDOW_CLOSED` returns HTTP 429, which any conventional retry policy would back off and
retry. Two different 401 shapes. No idempotency key and no `GET /reservations`, so a timed-out
reservation has a genuinely unknowable outcome. No time endpoint. `openapi.yml` documents no
error shapes at all. The repo's own k6 stress test cannot pass once the lot fills, and passes
green against a closed window.

---

## 4. Technical direction

Full reasoning in `docs/design.md`; the decision log is 19 ADRs in `docs/architecture.md`.

**Architecture.** MVVM in three layers — Features, Domain, Data — with a single composition
root. Domain imports nothing but Foundation. Every service is a protocol, so every
collaborator is fakeable. async/await throughout, `@MainActor` view models, actor-isolated
state where it matters. Builds clean under `-strict-concurrency=complete` with warnings as
errors.

**Zero dependencies.** `URLSession`, `Security` and `LocalAuthentication` cover everything.
In a banking client a dependency is supply-chain surface, and none here would save more than
a few dozen lines.

**The three decisions that carry the product:**

*Never claim a reservation the client cannot substantiate.* Because idempotency is derived
server-side from `(userId, date)` with no client key and no endpoint to ask, a timed-out
reservation is genuinely indeterminate. `ReservationOutcome` therefore has four cases, and one
of them is `unknown` — a designed state, not an error fallback. The client reconciles against
the grid by plate suffix, and when two plates share a suffix it says it cannot tell.

*Timeout length is a correctness decision, not a performance one.* 3 seconds, an order of
magnitude above the measured p99 of 368 ms, because every spurious timeout lands a user in
that unknown state.

*Classify on `code`, never on HTTP status.* Forced by `WINDOW_CLOSED` arriving as 429.

---

## 5. Scope points I would like ratified

The brief says trade-off ratification belongs here rather than in a Slack thread. Four items.

### 5.1 Pessimistic reservation instead of optimistic UI — built

The Default column permits optimistic UI with visible rollback. I am not applying it to the
reservation itself, because with 80 winners in 1,000 an optimistic cell is wrong **92% of the
time**: rollback stops being the exception and becomes the modal experience — a space
appearing to be yours and then being taken away. Against a p95 of 248 ms the wait costs the
user almost nothing.

Optimistic updates are used where contention does not apply, such as deposits.

### 5.2 Biometric re-authentication with a 120-second grace period — built

The Default asks for Face ID before a reservation is submitted. Implemented, with a grace
period, because a modal in the critical path of a race decided in milliseconds would make the
security control the reason users lose. Re-authentication still gates the session's first
reservation. Fallback is `.deviceOwnerAuthentication`, so a user without biometrics uses the
passcode rather than being locked out.

### 5.3 Certificate pinning — not built, and I want to be explicit about it

The Default asks for pinning against the local backend. The backend is `http://localhost:8080`
with no TLS anywhere in the exercise, so there is nothing to pin. `docs/security.md` documents
what production would use and why this is out of scope.

I am flagging it rather than presenting it as a defended swap, because the brief says swapping
a Default means building and demoing the alternative, and **an omission with a rationale is
not a swap**. If you want the control demonstrated, the honest version is to terminate TLS
locally with a self-signed certificate, pin its SPKI hash, and show the client refusing a
connection under a deliberately wrong pin. That is roughly an hour. Your call whether it is
worth the day-10 budget.

### 5.4 One test suite deliberately uses the live backend

`ScreenshotTests` drives the real app against the running backend to capture each screen —
it is demo rehearsal, and it is how the UI evidence in `docs/screenshots/` is produced. It is
skipped unless `SCREENSHOTS=1`, so CI never runs it and the "tests against fakes" Default
holds for everything CI executes. Flagging it so it is not a surprise.

---

## 6. What I would flag about my own process

Two things worth saying out loud, because they cost real time and the brief asks for honesty
about where AI helped and where it did not.

**I misread the guardrail table once.** Section 6.3 puts "all 80 spaces legible on a 6.1-inch
screen" in the Guardrail column and "44pt minimum touch targets" in the Default column. I had
it backwards, built a board that scrolled, and wrote a confident paragraph defending the wrong
trade-off. The cause is mundane — the brief's two-column tables flatten into one text stream
when extracted, so column membership was guesswork. Once corrected I re-audited all five
modules the same way and found three further gaps, all now closed.

**A UI test was green for the wrong reason.** It passed locally only because I had switched
Reduce Motion on in the simulator by hand. CI, on a machine I had not configured, found it.
The real cause turned out to be iOS's "Save Password?" sheet swallowing taps — and it took six
guesses before I stopped theorising and looked at the screenshot the test had been capturing
all along. The lesson is in `docs/runbook.md`: open the `.xcresult` attachment before forming
a hypothesis.

Both are in `docs/ai-workflow.md` in full.

---

## 7. Plan for days 3–10

| Days | Focus |
|---|---|
| 3–4 | The 20:00 moment: clock-skew warning, queue-position feedback, loss-path polish |
| 5 | **This checkpoint.** Ratify §5, then act on it |
| 6–7 | Race rehearsal with k6 — won race, lost race, backend killed mid-reservation |
| 8 | Security module: pinning if ratified, threat note, accessibility audit |
| 9 | Second locale, motion and haptics, Instruments trace under load |
| 10 | Demo rehearsal end to end, twice |

**Risks I am carrying:** the 16 GB machine is tight with colima, Xcode and simulators
together — it has already triggered one out-of-memory kill; and the demo depends on the
backend being configured with the gate genuinely on, which is exactly the thing that fails
silently.

---

## Questions for you

1. Should the brief's `-D` instruction be corrected for the next candidate?
2. Do you accept the pessimistic-reservation and grace-period deviations as built?
3. Is certificate pinning against a locally-terminated TLS endpoint worth a day-10 slot, or
   is the written design sufficient?
4. Anything in the module tables you read differently from how I have read it?
