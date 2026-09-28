# Week-1 checkpoint

Roughly 30 minutes. Current status, technical direction and the decisions taken, and the
scope points I would like ratified. No blockers.

This is the source for the slides; the notes under each heading are what I intend to say, not
what goes on screen. The deck itself is [`slides.md`](slides.md), which follows the same format
as the backend team's status update.

---

## 1. Where things stand — day 2 of 10

The client is functionally complete against the local backend and green in CI. That is
earlier than planned, and it is deliberate: the remaining eight days are for hardening the
20:00 race, the security module, and the demo itself, which are the parts that decide the
outcome.

| | |
|---|---|
| App code | 2,985 lines of Swift, 22 files, **zero third-party dependencies** |
| Tests | 73 unit, 4 UI, 5 screenshot — all green |
| Docs | 2,288 lines across 10 documents plus the AI working agreement |
| CI | Self-hosted runner, green on every push: lint, build, unit, UI, archive |
| Commits | 19, on a private repo shared with the team |

Working end to end: sign in and register, the 80-space board with plate suffixes, the
countdown driven by server time, select → confirm → reserve, wallet deposit and balance, the
full state matrix, iPad and landscape layouts, dark mode.

**Not built, and not scheduled unless you ask for it:** certificate pinning (see §5.3) — the
one Default neither kept nor replaced.

**Not done yet, and scheduled:** a String Catalog, and then the Stretch items: a populated second locale,
the k6 race rehearsal as a demo script, the "backend killed mid-reservation" rehearsal, and an
Instruments trace.

**Stretch items already built**, since the brief does not ask for them: Swift 6 language mode,
the clock-skew warning, iPad *and* landscape, the push/SSE migration design, and three Claude
Code skills.

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

## 3. Defects found

Seven are recorded in `docs/defects.md` with reproduction steps. The backend is read-only, so
each is a client workaround plus a written report. Four of them changed the design rather than
merely needing a patch. **Only the last subsection below asks anything of you**, and what it
asks is a conversation with the backend team rather than a decision today.

| | |
|---|---|
| `WINDOW_CLOSED` returns **HTTP 429** | Any conventional retry policy would back off and retry a closed window |
| **Two different 401 shapes** | Bare 401 for a dead session, JSON `AUTH_FAILED` for a wrong password |
| **No idempotency key**, no `GET /reservations` | A timed-out reservation has a genuinely unknowable outcome |
| **No time endpoint** | Yet the countdown must derive from server time |
| `openapi.yml` documents no error shapes | Only 200s; every error the client handles came from reading the source |
| `ALREADY_RESERVED` is unreachable | Redis fires first, so it only appears when Redis and Postgres disagree — which makes it the trustworthy one |
| The repo's k6 stress test | Counts 409 as failure, so it reports red while the system behaves perfectly; and scores 429 as expected, so a run against a closed window reports green with zero reservations |

The first four are behind the three decisions in §4.

### What would remove the ambiguity — for the backend team

The third row is the one worth a conversation, because it is not a client bug to be engineered
around. It is the Two Generals Problem: a client that hears nothing back cannot determine
whether its request was processed, and no timeout value changes that. There are exactly two
mitigations — **make retrying safe**, and **make the outcome readable** — and the API offers
neither. Ranked by value per effort:

| # | Change | What it buys |
|---|---|---|
| 1 | Return the existing reservation **in the 409 body** | A retry after a timeout becomes self-healing: the conflict *is* the answer. By far the smallest change |
| 2 | `GET /reservations/me?date=…` | Collapses the unknown state outright — ask, and get id, space, amount and balance |
| 3 | Client-supplied `Idempotency-Key`, storing the **response** and never clearing the key on failure | Turns an ambiguous retry into a deterministic replay; the control a bank expects on every money-moving endpoint |
| 4 | `PUT /reservations/{date}` | One reservation per vehicle per day is already a natural key, so replays return the same resource |
| 5 | Read-your-writes on `/spaces` | The 5-second cache can serve a grid older than the caller's own write — and that grid is what the client reconciles against |

Two details decide whether (3) works at all: store the **response**, not a dedupe flag, and
**never clear the key on failure**. Clearing it is exactly what makes today's
`DUPLICATE_REQUEST` two-sided.

I am flagging rather than requesting. (1) is close to free and would improve every client the
backend ever has, but the split is the honest part: the client can only narrow this ambiguity,
the backend can end it.

---

## 4. Technical direction

Full reasoning in `docs/design.md`; the decision log is six ADRs in `docs/architecture.md`.

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

### The unknown path, forced rather than argued

That first decision carries more weight than anything else in the client, and until this week
it was the least observed state in the app — so I made it happen deliberately. The backend
moved to `:8081`, and a proxy on `:8080` forwarded everything untouched **except**
`POST /reservations`, where it forwarded the request, took the real answer, and held it back
for six seconds. Nothing in the app changed, and nothing in the backend changed.

```
[proxy] POST /reservations -> 200 in 137ms, holding 6.0s
```

**The reservation committed in 137 ms; the client gave up at 3 s.** Afterwards the server held
space 1 against plate suffix `434`, with a balance of `90.00`. The app said: *"We're not sure
yet — Space 1 appears to be yours. Pull to refresh to confirm."* That is the designed
behaviour, and it held.

It also exposed two defects that reading the code had not:

- **The app contradicts itself in one frame.** Behind that sheet, the holding card asserts
  "Space 1 is yours". Both read the same three-character suffix, so the card states as fact
  what the coordinator explicitly refuses to state. It is worse than a wording slip: with no
  read endpoint, *every* holding is inference after a relaunch, and the confident wording is
  only ever earned in the session that actually saw a `201`.
- **The balance went stale** — $100 on screen against `90.00` on the server. Ten dollars moved
  and the interface never noticed. The balance is also **stronger evidence than the plate
  suffix**, because it is per-user and cannot collide the way three characters across 80 cells
  can, and reconciliation ignores it today.

Neither is a wrong decision; both are the same decision not carried all the way, in that proven
state and inferred state are rendered identically. The balance half is already fixed: after any
attempt that did not return an authoritative balance, the app re-fetches it. The holding-card
wording is day 6.

A review of the same path found a third, in code rather than on screen: only a *timeout* was
reconciled. Killing the backend mid-request closes its socket, which URLSession reports at once
as `networkConnectionLost` — the app would have said "Couldn't reserve" about a reservation that
may have committed. Transport failures are now classified by whether the request can have
arrived, and everything but a provably-unsent request is reconciled. The day-9 kill rehearsal
is what will show it holding. The wider point is the one
in §3: forcing the state was worth more than re-reading the code, and no amount of client work
would have removed the ambiguity that produced it.

---

## 5. Scope points I would like ratified

The brief says trade-off ratification belongs here rather than in a Slack thread. One deviation
to accept, one argument I withdrew, one Default I have deliberately not built, and one
disclosure.

### 5.1 Pessimistic reservation instead of optimistic UI — built

The Default column permits optimistic UI with visible rollback. I am not applying it to the
reservation itself, because with 80 winners in 1,000 an optimistic cell is wrong **92% of the
time**: rollback stops being the exception and becomes the modal experience — a space
appearing to be yours and then being taken away. Against a p95 of 248 ms the wait costs the
user almost nothing.

Optimistic updates are used where contention does not apply, such as deposits.

### 5.2 Biometric re-authentication — built as written, after I withdrew an argument

The Default asks for Face ID before a reservation is submitted. It is built exactly that way:
**every attempt prompts**, retries after losing included. Fallback is
`.deviceOwnerAuthentication`, so a user without biometrics uses the passcode rather than being
locked out.

**Deposit prompts too, as of the week-1 feedback.** The Default names the reservation, and I
built it there alone — which read the requirement as being about spending when it is about the
money path. A deposit credits the wallet: unchallenged, anyone holding the unlocked handset
could move money while only the spend was contested. Both now prompt, and the prompt names the
amount, because consent is to a transaction and not to a session. The argument below was
already written in `design.md`; I had not followed it all the way through.

This is not what I first shipped, and the change is worth a minute of the checkpoint because
the reasoning is the point. The first version carried a 120-second grace period, defended from
the race: a prompt in the critical path of a contest decided in milliseconds costs seconds,
and because one reservation per vehicle per day is a backend invariant, nearly every
re-attempt is a retry after losing — so the prompt looked like a tax on the common path that
bought no security.

The flaw is in what that weighs. Step-up authentication here is not a proportionality control
keyed to $10; it exists to evidence that the account holder consented to *this* transaction.
A session-scoped exemption destroys that evidence, and costs an attacker holding the unlocked
handset nothing. `CLAUDE.md` claims a banking bar for this repository, and an action that
moves money was where that claim was not being met.

The race cost is accepted rather than designed around, and it is not yet measured on device —
that is a day-9 Instruments item, not a number I am willing to assert from a simulator.
`ReservationCoordinatorTests` pins three attempts to three authorisations. That guards the
coordinator's contract; it does not guard the concrete `BiometricReauthenticator`, which now
holds no state to test. The residual risk is a stored `LAContext` — it has a reuse window of
its own — and it is held off by a comment, not by an assertion.

### 5.3 Certificate pinning — not built, and I want to be explicit about it

The Default asks for pinning against the local backend. The backend is `http://localhost:8080`
with no TLS anywhere in the exercise, so there is nothing to pin. `docs/security.md` documents
what production would use and why this is out of scope.

I am flagging it rather than presenting it as a defended swap, because the brief says swapping
a Default means building and demoing the alternative, and **an omission with a rationale is
not a swap**. I am listing it as a known gap and not planning time for it: the fortnight is
better spent on the race and its honest states. If you want the control demonstrated, the
version worth building is to terminate TLS locally with a self-signed certificate, pin its
SPKI hash, and show the client refusing a connection under a deliberately wrong pin — but
only if this checkpoint asks for it.

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

## 7. Plan for the rest of the fortnight

Full day-by-day in [`plan.md`](plan.md).

| Days | Focus |
|---|---|
| 6 | The 20:00 moment: countdown states, contention feedback, the loss path, and the two honest-state defects in §4 |
| 7 | Accessibility audit, string catalog, second locale |
| 8 | Security module: pinning if ratified, threat note |
| 9 | Three rehearsals — won race, lost race, backend killed mid-reservation; Instruments trace |
| 10 | Clean-clone build, documentation pass, two full demo run-throughs |

**Risks I am carrying:** the 16 GB machine is tight with colima, Xcode and simulators
together — it has now triggered two out-of-memory kills, the second during ordinary work
rather than under load; and a backend started with the
gate bypassed looks identical to one with it on until you reserve outside the window, so the
rehearsal asserts a `WINDOW_CLOSED` response before the race is shown.

---

## Questions for you

1. Do you accept the pessimistic-reservation deviation as built?
2. Certificate pinning is listed as a known gap, not planned. Is the written risk note in
   `security.md` sufficient, or do you want it built?
3. Are §3's first three items — the reservation in the 409 body, a read-back endpoint, and
   idempotency keys — worth raising with the backend team? Item (1) is close to free.
4. Anything else you want covered at the Week-2 demo that is not already in the plan?
