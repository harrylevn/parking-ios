# An honest account of AI on this project

Required by 6.5: where AI helped and where it failed me. Written as the fortnight goes, not
reconstructed at the end. The working agreement it runs under is in `CLAUDE.md`.

## Where it helped

**Reconnaissance was the biggest win.** Reading an unfamiliar Spring Boot codebase — Redis Lua
scripts, a FIFO queue, batch gating, `SELECT FOR UPDATE SKIP LOCKED` — and extracting the
handful of facts that change the client design would have taken me most of a day. It took
about an hour, and it found things I would not have gone looking for: that idempotency is
derived server-side from `(userId, date)`, that `/spaces` is Redis-cached at a 5-second TTL,
that the reservation window has no upper bound.

**Boilerplate with a known shape.** DTOs, the Keychain wrapper, test fixtures, the adaptive
colour tokens. Work where I know exactly what I want and typing it is the only cost.

**Writing tests I had thought of but would have skipped.** The suffix-collision case in
`ReservationCoordinatorTests` is the clearest example: I had reasoned about the collision in
the design, and the test that pins it existed within a minute of asking. The cost of a test
dropping from five minutes to thirty seconds changes which tests get written.

**Documentation drafts.** Every document here was drafted with assistance and then rewritten.
The draft is a good skeleton and a bad final answer — it reliably states what the code does
and just as reliably misses why.

**A scripted run found what the tests could not.** The first time `/run-demo` launched the
app against a backend shifted to an 11:00 window, the login screen said "Opens at 20:00".
`ReservationWindow` carries a comment saying the hour is configuration and never a hardcoded
20, and everything behind the login screen followed it. The subtitle in `LoginView` was a
string literal. Forty-five unit tests passed, because none of them had a reason to read that
sentence. What caught it was the screenshot the skill takes at the end, compared against the
hour it had just passed in. That is the same lesson as the three SwiftUI bugs below, arriving
from the other direction: a check that looks at the running app keeps finding things that
reading the code does not, so it is worth making that check cheap enough to run every time.

## Where it failed me

**It followed the brief's wrong instruction without noticing.** The brief says to run the
backend with `-Dapp.reservation.bypass-time-check=false`. That flag does nothing, because
`spring-boot:run` forks a JVM that does not inherit Maven's `-D`. Following the instruction
produced a backend with the time gate silently off. What caught it was not reading the
command more carefully — it was *checking the claim*: attempting a reservation at 15:45
against a 20:00 window and getting HTTP 200. Nothing surfaces a wrong assumption like
exercising it.

**It got the guardrail table backwards.** Section 6.3 puts "all 80 spaces legible on a
6.1-inch screen" in the Guardrail column and "44pt minimum touch targets" in the Default
column. I read it the other way round and built a board that scrolled — protecting the
negotiable requirement at the expense of the non-negotiable one, and writing a confident
paragraph in `docs/design.md` defending the wrong trade-off.

The cause is mundane and worth knowing: the PDF's two-column table flattens into a single
text stream on extraction, so column membership is guesswork unless you check coordinates.
The fix was to re-extract with x positions and split on them. **Confident prose over a
misread source is the characteristic failure mode**, and it is not self-correcting — it took
a direct challenge to surface, after which a second audit found three further gaps
(no deposit amount field, no view-model tests, this file missing).

**It wrote three real bugs that looked completely reasonable.** A card's hairline overlay
above its content, swallowing every touch inside it. A 1 Hz clock update writing identical
values to `@Published` properties, invalidating the screen sixty times a minute at rest. Two
`.sheet` modifiers on one view, where SwiftUI silently ignores the second. Every one compiled,
passed the unit tests, and read as idiomatic SwiftUI. All three were found by driving the UI,
not by reading it.

**It over-trusted its own test harness.** When the UI test could not tap a grid cell, the
early hypotheses were all about XCUITest flakiness — and the honest answer was that the app
genuinely could not be tapped. Roughly forty minutes went into blaming the tooling before
checking the simpler explanation. The correct instinct with a failing test is to assume the
test is right.

**It theorised six times before looking at the evidence it already had.** A UI test that was
green locally failed on CI. The first fix was wrong, and so were the next five: reduce motion,
clock seeding, dismissing the prompt after login, `textContentType(nil)`, a single retry,
waiting for the sheet to vanish. Each was plausible, each was a guess, and each cost a CI run.

The actual cause needed no theory at all. The test had been capturing a screenshot into the
`.xcresult` on every failure from the start; opening it showed iOS's "Save Password?" sheet
sitting over the board. It swallowed taps **twice** — once appearing, once animating away —
and the retry guard I had written returned one tap too early.

Two things worth keeping from that. Green locally can mean the environment, not the code: it
passed on my machine only because I had switched Reduce Motion on by hand, months earlier, for
something unrelated. And the rule now in `docs/runbook.md` — *open the `.xcresult` attachment
before forming a hypothesis* — exists because six plausible explanations cost more than one
look at a screenshot that was already on disk.

**It stated a cost it had never measured.** The record that is now ADR-001 deferred Swift 6
language mode on the reasoning that the migration would make every future change a
language-mode question.
That sounded like engineering judgement and was a guess. When it was finally tested, the
project built and passed all 45 tests under Swift 6 with no source changes at all. The
reasoning was not wrong so much as unverified, and an unverified reason presented in the
confident register of an ADR is hard to distinguish from a real one.

**It tested a clock at the exact edge of its threshold.** The day-6 tests for the count's
age asserted exactly 10 s and exactly 15 s against `ServerClock`, which extrapolates from a
monotonic anchor. The anchor moves by microseconds between readings, so one assertion failed
on the first run (14 against 15) and another would have flipped at random. Both now assert
well inside the boundary, or accept a range, with a comment saying why. It also took the
start of the in-flight timer from the server clock while SwiftUI's timer text counts against
the device clock. That would have shown any clock skew as elapsed time, and it was caught by
reading the diff, not by a test.

**The test-mutation check was worth running.** Switching each new day-6 behaviour off in turn
made its test fail. The tests that still passed were the ones checking the opposite case, as
they should. The first attempt at the check silently proved nothing: the edit left code after
a `return`, warnings are errors here, and the build failed without printing a single test
result. A test run with no output is not a pass.

**A person using the app found what neither of us looked for.** At 20:00 the board showed
space 1 as booked and nothing new opened up. The app and the backend were on different
opening hours (20 and 11), and a booking made at 15:08 was the only sign of it. The app
detects the mismatch in one direction only, and this was the other one. It came from a
person watching the countdown on a real clock, not from any test.

**It read the cache's TTL and not its eviction.** The day-1 reading of the backend found that
`/spaces` is cached for 5 seconds, and "polling faster cannot see anything newer" followed
from it into an ADR, the design doc, the slides and two code comments. It was true only at
rest: `ReservationService` clears that cache in the `finally` of every attempt, so during the
race, which is when the claim was being used, it was false. The decision survived. The
reason did not, and the replacement is a better one: a faster poll mid-race is a Postgres
read per client per interval. It was caught on the day-6 recheck by reading the backend
source against the docs, which is the standing rule, applied late.

**It drafted the one file the agreement says it does not.** `CLAUDE.md` keeps the
reconciliation in `ReservationCoordinator` off the list of things AI writes here. For ADR-007 I
asked for the backend idempotency change and the client side in one go, and the coordinator
rewrite came back as part of it. I reviewed it line by line on 29/09 and changed nothing. That
review came after the commit had been pushed to `main`, which is the wrong order for the rule
it exists to serve. This entry keeps the exception on the record rather than quietly absorbing
it.

**The backend's own tests had never run.** Before any idempotency code was written, all nine
existing integration tests errored before an assertion: a modifying query outside a
transaction, a mock JWT that skipped the app's converter, and two tests expecting a status the
app has never returned. Testcontainers also could not reach Colima until the Docker API version
was forced. None of that was visible from reading the code, and building on an unrun suite
would have meant new tests with nothing proven underneath them.

**The mutation check caught what green could not.** Switching off each of the backend's two
database fallbacks, and failure recording, made exactly its own test fail. That is the evidence
the fallbacks are tested, as opposed to merely exercised.

**A flaky UI test nearly got blamed on the change.** After the client change the UI suite
failed, and on a different test each run. Stashing the change and running the baseline twice
showed the same failure on `main`: the tap on a board space sometimes does not
register. It predates ADR-007 and is still open.

**It wrote a fix that did nothing, and a test that could not tell.** For the header's 34pt
buttons it wrote a modifier to grow their touch target to 44pt without moving the layout, and a
test that tapped just outside the drawn edge. The test passed. The mutation check, removing the
modifier, passed too. Probing found that iOS already accepts taps up to 10pt outside those
buttons, so the modifier was deleted and the test kept as a guard at the distance that matters.
Without the mutation check, both would have shipped: plausible code, a green test, and neither
doing anything.

**The audit's summary was not the finding.** It reported clipped text on sheets that looked
fine, and was right for the wrong reason: the clipping was the board behind the sheet, cut by
its edge. It also passed contrast on buttons that computing the ratios showed at 1.7:1. The
screenshots and the arithmetic were what made its output usable.

**A comment said the bypass was compiled out; the binary said otherwise.** `AppEnvironment`
stated that the Face ID override could not be triggered on a shipped build, and for the one
launch argument it guarded, that was true. The UI-test environment behind a second argument
was not guarded, and it carried an always-yes re-authenticator into release builds. Reading the
code agreed with the comment. Running `strings` on the release binary did not.

**The rehearsal script was wrong three times, and only running it showed which way.** A
background `docker exec -i` dropped its database lock at once; Hibernate locks with `FOR NO KEY
UPDATE`, which a pattern written for `FOR UPDATE` never matched; macOS `xargs -I` caps a
replacement at 255 bytes, which silently discards a 600-byte JWT. Each looked right on review.
Each failed in a way that would have made a rehearsal pass for the wrong reason, or not run.

**The first Instruments trace measured the test, not the app.** Idle, it showed 75 ms of CPU a
second, almost none of it in the app's code: the UI test driver was polling the accessibility
tree, and the app was answering. Asked why the number was high, the plausible answers were all
about the app. The answer was in which frames were named.

**A test helper signed in as accounts it did not own.** The screenshot suite made a fresh
account on a random `TEST-####` plate and returned the plate even when registration failed. The
demo scripts had left 964 of the 9,000 plates taken, so about one run in three signed in with the
wrong password, and the field the app clears afterwards made it look like lost keystrokes. The
first failure was put down to the known simulator flake; the second, with the same screenshot,
could not be. The helper now retries with a new plate and throws rather than return one it
does not own. It was plausible code, and it failed quietly.

**A snapshot test depended on a setting it did not own.** The two largest-text snapshots render
in a real window, added because `ImageRenderer` drew a scroll view blank. A real window takes the
simulator's appearance; `ImageRenderer` never did, and nobody, the AI included, asked what else
the switch brought with it. It stayed green for two days, then failed three pushes in a row
with 99.9% of pixels changed, on commits that touched only documentation. The simulator CI uses
had been left in dark mode; how is not proven. The window is now pinned to light, the failure
was reproduced on the dark simulator before the fix, and both appearances pass after it. The
lesson is the one the clean-clone check was for: a test that passes only in the state of this
machine is checking the machine.

## Tooling in the repository

`.claude/` holds the Claude Code configuration, and it is committed deliberately. The
settings deny reads of secrets files, so the privacy limits in `CLAUDE.md` are enforced by
the tool rather than left to memory. Three skills turn existing process into commands:
`/gate` runs the merge gates, `/ai-log` drafts entries for this file, and `/run-demo` starts
the app against a backend whose window hour matches it. None of them writes production code.

## What I take from it

The division that worked: **AI for breadth, me for judgement**. It reads more code than I can
and drafts faster than I can type. It cannot be relied on to notice that a requirement was
misread, because the misreading and the confident defence of it come from the same place.

Everything AI-assisted that survived into this repository has an argument attached, and I can
give that argument without the file open. Where I could not, the code was rewritten or
deleted. That is not a process I follow because the brief asks for it; it is the only way the
speed is worth having.

The gates in `CLAUDE.md` exist because of the failures above, not in spite of them. Three
bugs invisible to unit tests is the argument for the UI test. A misread requirement defended
in prose is the argument for checking claims against the running system rather than against
the document that describes it.
