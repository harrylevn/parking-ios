# AI working agreement

The agreement I would impose on a mobile team in a banking context, and the one this
repository runs under. It exists because AI assistance is expected here and every line it
writes is mine to defend in review.

## The rule everything else follows from

**If I cannot explain it, it does not merge.** Not "I understand roughly what it does" —
I can say why this approach and not the obvious alternative, what breaks if the inputs are
hostile, and which requirement it satisfies. Generated code I cannot defend is worse than
code I wrote badly myself, because it looks reviewed and is not.

In practice this means reading the diff before accepting it, every time, including the
boring parts. The failure mode of AI assistance is not bad code; it is plausible code that
nobody read.

## What AI is good for here, and what it is not

Used it for: boilerplate DTOs and wire types, test scaffolding and fixtures, exploring an
unfamiliar API surface, first drafts of documentation, and mechanical refactors.

Did not delegate: the concurrency model, the error taxonomy, anything touching the Keychain
or authentication, the reconciliation logic in `ReservationCoordinator`, and the decision of
what the UI is allowed to claim is true. These are the parts a reviewer would question, so
they are the parts I need to have reasoned through myself.

The honest account of where it helped and where it failed lives in `docs/ai-workflow.md`,
and is updated as the fortnight goes rather than reconstructed at the end.

## Quality gates AI-written code must clear before merge

Identical to the gates for hand-written code — the point is that origin grants no exemption.

1. `make lint` — SwiftLint at **zero** violations. No inline `swiftlint:disable` without a
   comment saying why, on the same line.
2. `make test` — unit tests green. New logic ships with tests that would fail without it;
   a test that passes against an empty implementation is not a test.
3. Builds with **zero warnings** under `-strict-concurrency=complete`. Warnings are errors
   in `project.yml`, so this is enforced rather than hoped for.
4. No force unwraps, force casts or force tries outside test fixtures — enforced by lint at
   `error` severity.
5. Tests run against fakes. A test that needs the backend running is not a unit test.
6. Every non-obvious decision carries a comment saying *why*, not *what*. If AI produced an
   approach I kept, the rationale is mine and written in my words.

## Data-privacy limits in a banking context

Hard limits on what may reach an AI tool, regardless of convenience:

- **Never**: real customer data of any kind, real licence plates, real account balances or
  transaction records, production credentials, API keys, signing certificates, provisioning
  profiles, or `.env` contents.
- **Never**: production logs or crash reports without scrubbing — they routinely carry
  tokens, device identifiers and PII in payloads.
- **Never**: internal security review findings, penetration test reports, or unremediated
  vulnerability details.
- **Fine**: this repository's own source, synthetic fixtures, public API contracts, and
  error messages from a local backend seeded with invented data.

All test data in this repo is synthetic by construction: plates are `TEST-####`, balances are
placeholders, and the database is seeded locally. Nothing here has a real-world referent.

The general test: *if this appeared in a vendor's training set or a breach disclosure, would
it harm a customer or the bank?* If yes, it does not go in the prompt. When unsure, treat it
as if the answer is yes.

A practical corollary: paste the *shape* of a problem, not the payload. A schema and a
synthetic example get the same quality of help as real records, at none of the risk.

## Conventions

- Swift API Design Guidelines; American spelling in code identifiers, British in prose.
- Comments explain intent and trade-offs. No comments restating the code.
- Commits are scoped and imperative, and explain why in the body when the why is not obvious.
- No dependency without a one-line justification in `docs/design.md`. Currently: none.

## Measuring AI contribution on a mobile repo

A proposal rather than a solved problem, since the obvious metrics are all bad. Lines
generated rewards verbosity; percentage-of-diff rewards accepting slop.

What I would actually track, per PR, as a trailer in the commit:

```
AI-Assisted: drafted | reviewed | none
```

Three values, self-reported, cheap enough that people comply. Then correlate against things
that already get measured: defect escape rate, review round-trips, and time-to-merge.

The question worth answering is not "how much did AI write" but "does AI-assisted code fail
review or production more often than hand-written code in this codebase". If it does not,
loosen the process. If it does, the gates above are the lever, not a ban.

I would resist any per-developer leaderboard. The moment contribution percentage is a
performance metric, it stops measuring anything real.
