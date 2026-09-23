# Plan

The ten working days, day 1 to day 10. Day 1 is Mon 21/09, day 10 is Fri 02/10.

Section 5 of the brief weighs the five modules independently, and states that strength in four
does not compensate for one neglected. That constraint shapes the plan more than any other:
every day below names the modules it serves, and no module is left untouched past day 8. The
work is sequenced so that the parts which decide the outcome — the 20:00 race, security, and
the demo itself — get the back half of the schedule rather than whatever time is left over.

---

## Week 1 — understand, decide, build the spine

### Day 1 (Mon 21/09) — Orientation and environment

*Modules: all — this day sets the acceptance criteria everything else is scored against*

- Read the brief properly, and extract the five module tables recovering **which column each
  row belongs to**. Guardrail versus Default decides what is negotiable at all, and the
  brief's two-column tables flatten into a single text stream when copied out of the PDF.
  Putting a row in the wrong column is a scoring error, not a pedantic one.
- Stand the backend up: Postgres 15 and Redis 7 under Docker, Spring Boot 3.3.4 on Java 21,
  seed data loaded, and the gate and the reservation window confirmed to behave as documented.
- **Read the backend source, not the OpenAPI spec.** The contract the client has to survive is
  what the code returns, not what the document claims it returns.
- Write the traps down before writing any client code.

**Deliverable:** backend recon notes; a reproducible startup script; a Guardrail/Default matrix
to score myself against.

### Day 2 (Tue 22/09) — Measure, decide, scaffold

*Modules: 6.1 architecture, 6.2 contention, 6.4 delivery*

- Run the stress scenario **before** designing against the backend: 1,000 virtual users, clean
  database, gate on. Record reservations created, duplicate spaces, duplicate `(user, date)`
  pairs, money taken, p95/p99 latency, sustained throughput.
- Let the measurements drive the design rather than the brief. The decisive number is how many
  users lose, because that is what determines whether optimistic UI is honest here.
- Scaffold the repo: an XcodeGen-generated project, three layers (Features, Domain, Data), a
  single composition root, every service behind an injected protocol, builds clean under
  `-strict-concurrency=complete` with warnings as errors, zero third-party dependencies.
- Start `docs/architecture.md` as an ADR log, written **as decisions are taken** rather than
  reconstructed at the end.
- CI on a self-hosted runner on the development machine: lint, build, unit tests, UI tests on a
  simulator, archive.

**Deliverable:** measured numbers that the design can cite; a repo that is green in CI on its
first commit; an ADR log that is already running.

### Day 3 (Wed 23/09) — Domain and data layers

*Modules: 6.1 architecture, 6.2 contention, 6.4 testing*

- Models, the error taxonomy, and the HTTP client. **Classify on the response `code`, never on
  the HTTP status** — the backend answers a closed window with 429, and any conventional retry
  policy would read that as backpressure and retry a window that is shut.
- Handle **both** 401 shapes, not one: the bare filter-chain 401 with an empty body for a dead
  session, and the JSON error response for a rejected password. Decoding assumes a body; one of
  these does not have one.
- A server clock anchored to the HTTP `Date` header against a monotonic clock. The countdown is
  a Guardrail and must not trust the device clock, and there is no time endpoint to ask.
- The reservation coordinator as an actor: one tap means exactly one attempt, a timeout is never
  retried, and there is a fourth outcome — `unknown` — for the case that genuinely cannot be
  proven either way. Idempotency is derived server-side from `(userId, date)` with no client key
  and no endpoint to query, so a timed-out reservation has an unknowable result. That is a state
  to design, not an error to swallow.
- Unit tests over all of it, against fakes.

**Deliverable:** the domain complete and tested, with the race and retry paths genuinely
exercised rather than smoke-tested.

### Day 4 (Thu 24/09) — UI foundation

*Modules: 6.2 UX truth, 6.3 UI/UX and accessibility*

- Design system first — tokens, type scale, surfaces, haptics — then screens, so that the
  interface is designed rather than assembled out of default components.
- The 80-space board, with every space legible on a 6.1-inch screen without pinch-zoom. That is
  a Guardrail, so the layout is chosen to satisfy it and asserted in a test, not eyeballed.
- Login and registration, the dashboard, the deposit field and the balance display. A field, not
  only preset amounts.
- The full state matrix: loading, empty, error, offline, insufficient balance, race lost,
  success, and unknown.

**Deliverable:** every screen navigable, every state reachable, every state screenshotted.

### Day 5 (Fri 25/09) — Week-1 checkpoint

*Modules: all*

- Morning: close the wallet path and biometric re-authentication, and get CI green on head
  before presenting anything.
- **Checkpoint, around 30 minutes:** where things stand, the technical direction, the decisions
  taken and why, and the scope points I want ratified. The brief is explicit that scope
  questions and trade-off ratification belong at this checkpoint rather than in a Slack thread,
  so anything I want accepted has to be raised here.
- Afternoon: act on the answers. Write the ratifications straight back into `docs/design.md`
  while the reasoning is still fresh, and adjust days 6–10 to match what was accepted.

**Deliverable:** each deviation ratified or rejected in writing, and the remaining plan adjusted
to the outcome.

---

## Week 2 — harden, secure, prove

### Day 6 (Mon 28/09) — The 20:00 moment

*Modules: 6.2 contention and UX truth, 6.3 the 20:00 moment designed deliberately*

This day is the product. Everything else is the frame around it.

- Countdown states at T-60s, T-10s and T-0, and a decision about what the board does at the
  instant the window opens.
- A clock-skew warning surfaced to the user when the device and the server disagree. Handling
  skew silently is not enough when the user is watching a countdown and deciding when to tap.
- Contention feedback during the race, so the wait is legible rather than blank.
- **Design the loss path deliberately.** The overwhelming majority of users lose; losing has to
  read as an honest outcome of a fair race, not as a failure of the app.

**Deliverable:** a race designed for the people who lose it, not only for the one who wins.

### Day 7 (Tue 29/09) — Adaptivity, accessibility, localization

*Module: 6.3*

- iPad and landscape layouts. The board holds its Guardrail at every size class, or the
  Guardrail is not met.
- A VoiceOver pass over the board and the race; Dynamic Type up to the accessibility sizes; 44pt
  targets; contrast.
- A string catalog with every user-facing literal extracted, and a second locale. "No hardcoded
  user-facing strings" is only true if it is true everywhere, not in the one file where it was
  convenient.

**Deliverable:** an accessibility audit with findings, rather than a claim in a table.

### Day 8 (Wed 30/09) — Security module

*Module: 6.5*

- The session token in the Keychain with a justified accessibility class, and a check that
  nothing sensitive reaches the logs, the bundle or the repository.
- Certificate pinning against the backend, with the bypass gated to debug builds. If the backend
  is plaintext, terminate TLS locally with a self-signed certificate, pin its SPKI hash, and
  **demo it refusing a connection under a deliberately wrong pin.** The brief requires a swapped
  Default to be built and demoed, so an omission with a rationale attached is not a swap.
- `docs/security.md`: what is not implemented, what production would do instead, and why it is
  out of scope here.
- The AI working agreement, plus an honest account of where AI helped and where it failed —
  including the failures, because the module asks for the account, not for a success story.

**Deliverable:** no Guardrail unmet, and no Default left neither kept nor built.

### Day 9 (Thu 01/10) — Rehearsals and evidence

*Modules: 6.2 resilience, 6.4 delivery discipline*

The demo requires three scripted runs. They have to be repeatable in front of an audience, not
improvised on the day.

- **Won race** and **lost race**, with the load tool repurposed as a demo driver rather than a
  load test, putting the demo user reliably on each side of the outcome.
- **Backend killed mid-reservation**: the timeout, the unknown outcome, reconciliation against
  the grid, and the case where two plates share a suffix and the client says plainly that it
  cannot tell. This is the hardest thing to demo and the most persuasive if it lands.
- Assert a closed-window response before each rehearsal. A backend started with the gate
  bypassed looks identical to one with the gate on until something is reserved outside the
  window, so the demo would otherwise be able to pass for the wrong reason.
- An Instruments trace under the grid poll and during a race, kept as evidence for the Q&A.

**Deliverable:** three scripts that each run twice in a row without intervention.

### Day 10 (Fri 02/10) — Freeze, verify, rehearse

*Modules: all, plus the Definition of Done*

- Code freeze at midday.
- **Build from a clean clone** on a fresh checkout. The Definition of Done says a clean clone
  builds and runs against the backend; a generated project file and any machine-local build
  workaround make that worth proving rather than assuming.
- CI green on the head commit, and the repository shared with the development team. Both are
  Definition of Done items, and both are easy to leave until they are late.
- A full documentation pass, reading the Guardrail/Default compliance matrix line by line. That
  matrix is the document a reviewer scores against, so a stale row in it costs more than a stale
  paragraph anywhere else.
- Two complete demo run-throughs against a stopwatch, in the structure the brief specifies:
  **10 minutes** architecture from the design doc, **20 minutes** live on the simulator covering
  the interface and its state matrix and then the three races, **10 minutes** on security, CI
  and the AI workflow, and **20 minutes** of questions on the trade-offs and what would change
  at production scale.

**Deliverable:** a second run-through that needs no fixes.

---

## Standing rules

- **Never trust a document over the running system.** Anything in the brief or the OpenAPI spec
  is verified against observed behaviour before it is allowed to shape a decision.
- **ADRs are written when the decision is taken**, and a reversed one keeps its reasoning in
  the record rather than being edited away — that is better evidence of judgement than a log
  which only ever shows the answers that survived. One record per decision worth arguing, not
  per mechanism: a log nobody can review in ten minutes does not get reviewed.
- **CI is green on head at the end of every day.** Not a day-10 activity.
- **If a day is lost, cut in this order:** the performance trace, then the second locale beyond
  string extraction, then contention feedback. Never cut the three rehearsals, the clean-clone
  check, certificate pinning, or CI green on the head commit — those are Guardrails or
  Definition of Done items, and the independent weighting means losing one of them costs more
  than losing all three of the cuttable items together.
