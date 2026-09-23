---
name: gate
description: Run the six pre-merge quality gates from CLAUDE.md against the current change and report pass/fail per gate. Use before committing, before opening a PR, or when asked "is this ready to merge".
---

# Pre-merge gate

Check the current change against the six gates in `CLAUDE.md`. Report; do not fix. A gate
that fails is information for the author, and silently patching it hides the thing the gate
exists to surface.

## Scope

- No argument: uncommitted work plus everything on this branch not on `main`
  (`git diff main...HEAD` and `git diff HEAD`).
- An argument (a commit, a range, a branch): diff that instead.

If the diff is empty, say so and stop.

## Steps

1. **Gate 1 — lint.** `make lint`. Must be zero violations. Then look at the *added* lines
   in the diff for `swiftlint:disable`: each must carry a reason on the same line, after the
   rule name. A bare `// swiftlint:disable:next force_unwrapping` fails.
2. **Gates 3 and 4 — build and force operations.** `make test` builds with warnings as
   errors under `-strict-concurrency=complete`, so a clean test run covers gate 3. Gate 4 is
   enforced by lint at error severity; restate the lint result here rather than re-checking.
3. **Gate 2 — tests.** Same `make test` run (timeout 10 minutes); it must be green. Then
   judge, don't just count: for each changed file under `Sources/Domain`, `Sources/Data` or
   `Sources/Features` that adds or changes logic, is there a matching change under
   `Tests/UnitTests`? For each new test, would it fail against an empty implementation? If
   a test only asserts that a fake returned what the fake was told to return, say so.
4. **Gate 5 — fakes only.** In added test lines, flag `localhost`, `:8080`,
   `URLSession.shared`, or `AppEnvironment.live`. Any of them means a test needs the backend.
5. **Gate 6 — comments say why.** List non-obvious additions (retry counts, timeouts,
   ordering constraints, `@MainActor` placement, `Task.detached`, suppressed errors) that
   carry no comment explaining the reason. Also flag comments that only restate the code.
   This one is judgement: phrase each item as a question for the author, not a verdict.
6. **Privacy check (not a numbered gate, same weight).** In added lines, flag any licence
   plate not of the form `TEST-####`, anything shaped like a token, key or bearer header,
   and any real-looking name or email in fixtures.

## Report

One table, then the details for anything that is not a pass:

| Gate | Result | Note |
|---|---|---|
| 1 Lint | PASS / FAIL | … |
| 2 Tests | PASS / FAIL / CHECK | … |
| 3 Zero warnings | PASS / FAIL | … |
| 4 No force ops | PASS / FAIL | … |
| 5 Fakes only | PASS / FAIL | … |
| 6 Why-comments | PASS / CHECK | … |
| Privacy | PASS / FAIL | … |

`CHECK` means a judgement call the author has to make. Do not mark it `PASS` to make the
table look clean. Quote the failing output verbatim, trimmed to the relevant lines.

Finish with a one-line verdict: *ready to merge*, or *not ready: <the blocking gates>*.
