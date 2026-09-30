# Final checkpoint — speaker notes

What I intend to say, slide by slide; the deck is [`slides.md`](slides.md). Sixty minutes:
10 architecture, 20 live, 10 security, CI and AI, 20 questions. The clock matters more than
completeness: if a part runs long, cut from its end, not from the next part.

---

## Opening — 1 min (inside part A)

The client is done against the brief: every Guardrail met, every Default either kept or
swapped with the swap built. I will spend ten minutes on why it is shaped the way it is, twenty
showing it, ten on what protects the user and the code, and leave twenty for your questions,
which is where the trade-offs get tested.

## Where it landed

The one line to land: *nothing is left neither kept nor replaced.* At week 1, certificate
pinning was a written risk; it is now built and demonstrable. Point at the numbers, but do not
read them: 147 unit tests, 26 UI tests of which 13 run in CI and 13 are live suites the scripts
run against the real backend.

## What changed since week 1

This slide is to show the checkpoint was listened to. Every row there was raised at week 1 and
each has a concrete change behind it. Linger on idempotency: it was a question I put to you, it
was approved, and it changed the architecture more than anything else in week 2.

---

## A. Architecture — 10 min

### The problem, measured

I did not design against the brief; I measured the backend first. 1,000 users, 80 spaces:
92% lose. The backend is correct under load: no duplicates, exactly $800 taken. Two design
consequences follow, and everything else hangs off them: losing is the normal experience, so it
is designed, not an error path; and a lost reply is not a lost race, so the app must never claim
what it cannot prove.

### The shape

Three layers, one composition root, every service a protocol. Worth one sentence each: Domain
imports nothing but Foundation; zero dependencies because every dependency is supply-chain
surface in a banking client; Swift 6 because it cost nothing and turns data races into
compile errors.

### Seven ADRs

Do not read the table. Pick two: ADR-003, because classifying on the HTTP status would have
retried a *closed window* (it is a 429) and signed people out for a wrong password (both 401s);
and ADR-005, because the 6.1-inch guardrail is asserted by a UI test measuring the running app,
after a model-based test passed while the last row was below the fold.

### The hardest problem

This is the one to slow down for. Before: a timeout meant nobody could know if the $10 had gone,
because the server's own retry answer meant two opposite things. After: the client sends a key
per tap, repeats it after a timeout, and the server replays the first outcome. If that still
does not settle it, the app reads back what committed. The board-suffix guessing survives only
for when the server cannot be reached at all. On the backend, the key is written in the same
transaction as the money, so "the key succeeded" and "the $10 moved" cannot disagree.

---

## B. Live demo — 20 min

Follow [`demo-script.md`](demo-script.md) exactly. Narrate *what the user is told and why it is
true*, not which button I am pressing. When a result appears, say what the database says too.

If anything misbehaves: say what happened, show the fallback image, move on. Do not debug live.

---

## C. Security, CI and AI — 10 min

### Security (4 min)

Lead with the finding, not the feature list: when I inspected the release binary, the test
environment, with a Face ID bypass, was compiled into it. The code's own comment said
otherwise. It is fixed and re-verified, and it is the reason I trust `strings` over comments.
Then pinning: pin the key, not the certificate; the CA key as a backup, so the server can rotate
without a release, which the demo showed. Then the two backend defects I could not fix and have
reported: the committed JWT signing key, and the day-long lockout after a crash.

### Testing and CI (3 min)

The point is not the count, it is that the tests that matter are *mutation-checked*: I break
the code they protect and confirm they fail. Two examples: each database fallback in the
idempotency backend, and each check in the pinning evaluator. Mention the trace in one
sentence: idle is about 1% of a core, the worst moment is one frame.

### AI (3 min)

The agreement predates the code: AI-written code clears the same six gates, and there are hard
limits on what may reach an AI tool in a banking context. Then the honest part, and give one
failure fully rather than three in passing: the tap-target fix that did nothing, with a test that
passed, exposed only because I removed the fix and the test still passed. The lesson is the
process, not the tool: a green test is not evidence until you have seen it go red.

---

## D. Questions — 20 min

Prepared answers are in [`qa-prep.md`](qa-prep.md). Two slides to leave up while answering:
*Trade-offs I would defend*, and *Open, and said plainly*. If asked something I do not know,
say so and say how I would find out; the documents usually have the measurement.
