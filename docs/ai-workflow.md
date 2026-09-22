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
