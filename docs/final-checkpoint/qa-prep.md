# Questions — prepared answers

Part D: twenty minutes on the trade-offs and on what changes at production scale. Short answers
first, with where the evidence lives. Where the honest answer is "not done", it says so.

---

## The reservation path

**Why pessimistic, when the brief permits optimistic UI?**
Measured: 80 of 1,000 win. An optimistic cell would be wrong 92% of the time, so rollback would
be the normal experience, a space shown as yours and then taken away. Against a p95 of 248 ms the
wait costs almost nothing. Optimistic updates are used where contention does not apply. (ADR-002,
`design.md` §4)

**Why a 3-second timeout?**
It is a correctness setting, not a performance one. p99 is 368 ms and the worst observed 867 ms,
so 3 s is several times the tail. Every spurious timeout used to manufacture an unknown outcome;
with the idempotency key it now costs a repeat, not an unknown. (ADR-002)

**Why four repeats a second apart, not exponential backoff?**
Four sends cover the realistic cases (a lost reply, a request still queued) within about
15 seconds, which the elapsed timer keeps legible. At this scale, fixed spacing is fine. **At
production scale I would add jitter**: a thousand clients timing out together would otherwise
repeat together. That is a real gap to name, not a hidden one. (ADR-007)

**Is it still one tap, one attempt, if the app repeats the request?**
Yes, because the repeats carry the tap's Idempotency-Key: the server answers them with the first
request's outcome instead of running a second attempt. Against a backend without keys the app
turns repeats off (`PARKING_IDEMPOTENCY_KEYS=0`), because there a repeat could be a real second
attempt. (ADR-007)

**What if the app is killed mid-request?**
The key lives in memory for the tap, so it is gone. On relaunch the board shows the user's space
if the reservation committed, but it infers that from the plate suffix rather than reading back
with `GET /reservations/me`. **Calling the read-back on launch is the obvious next step;** it is
not built.

**Why does "Reserve any space" win more often?**
The server takes the first free row with `SELECT … FOR UPDATE SKIP LOCKED`, stepping over rows
another request holds. Naming a space locks exactly one row, and losing that lock is a loss.
(`design.md` §5.3)

**How do you know two simultaneous taps cannot both win?**
Tested at two levels. The API: two requests released from a barrier a median 32 µs apart, 20 of
20 trials with exactly one winner and one debit, and the winner split 12–8 between the two
threads (10–10 on an earlier run): no clear edge either way. The app: two simulators tapping 1 ms apart; one "is
yours", one "someone was faster", and the database agrees.
(`make concurrent`)

---

## Time, polling and scale

**Why not trust the phone's clock?**
Anyone can change it. The countdown uses the HTTP `Date` header anchored to a monotonic clock,
and warns when the device is more than 30 s off. It claims no sub-second precision, because the
header has none. (ADR-004)

**Why polling rather than WebSockets or SSE?**
The backend offers neither. The 5 s poll is matched to the server's 5 s cache and costs about 1%
of a core on the phone; an unchanged board does no view work. The worst moment, all 80 cells
changing in one poll, is a 25 ms burst. (ADR-004, `performance.md`)

**What changes at 100,000 users?**
- **Push, not polls.** At 1,000 clients the poll is already 200 requests a second of overhead.
- **Jittered retries**, as above.
- **Backend:** the D11 guard fix (a crash should not lock users out for a day), the counter
  reconciled from the database on start-up, and horizontal scaling of the API. The FIFO queue is
  in Redis, so it already survives more than one instance.
- **Observability:** outcome rates (won, lost, unknown) and pin failures as metrics, because a
  spike in "unknown" or in pin failures is the first sign of trouble.

**What would you do differently next time?**
Measure the backend before designing, which I did, but also read its crash paths before
building on them: D11 was only found by a rehearsal that killed it.

---

## Security

**Why this Keychain accessibility class?**
`WhenUnlockedThisDeviceOnly`: the token is unreadable while the device is locked, is never in a
backup, and does not migrate to a new phone. The cost is signing in again after a device
migration, which is the right trade for a banking context. (ADR-006)

**Why Face ID on every attempt, even though it slows the user in the race?**
The prompt is evidence of consent to *this* payment, and it names the amount. A grace period
would make it evidence of nothing. The race-time cost is real and disclosed. (ADR-006)

**Why pin the public key, and what if the pin is wrong in production?**
The key survives certificate renewal; only a rotation needs a new pin. A wrong pin locks users
out until a new release, which is why there is a backup pin on the CA's key, demonstrated
surviving a rotation. Production would ship at least two backups from different keys and monitor
each pin's expiry. Pins are never taken from remote config: whoever controls that could replace
them. (`security.md`)

**The app allows plain HTTP. Isn't that a hole?**
Only in debug builds, to `localhost` and `.local` names. A release build refuses any non-HTTPS
request before sending it, and ignores any server address a debug build reads. (`security.md`)

**What did the security check find?**
The UI-test environment, with an always-yes Face ID, was compiled into release builds: a bypass
behind one launch argument. Fixed and re-verified in the binary. In the backend: the JWT signing
key is committed (D10), so anyone with the repository can mint a session for any user.

---

## Quality and process

**The flaky UI test: is that a bug in the app?**
Not established. On the iOS 26.3 simulator the first tap on a space sometimes never reaches the
app; logging proved the re-tap is what lands. It never happened on iOS 26.0, and a layout change
during the press was ruled out. The test re-taps only while the space is still unselected, so it
cannot pass for the wrong reason. On 30/09 it hit the login screen's "Create an account" link
once, so it is not specific to the board; that tap is left unguarded so the problem stays
visible. It has not been seen on a real device.

**How much of this did AI write, and how do you know it is right?**
Much of the drafting. The agreement makes AI code clear the same gates as mine, and the important
tests are mutation-checked. The record of where it failed is in `ai-workflow.md`. For measurement
I propose a per-commit trailer (drafted / reviewed / none) correlated with defect escape and
review round-trips, never a per-person leaderboard. (`CLAUDE.md`)

**Why no dependencies: not even Alamofire, or TCA?**
None would save more than a few dozen lines, and in a banking client every dependency is
supply-chain surface to audit and update. `URLSession`, `Security`, `CryptoKit` and
`LocalAuthentication` cover everything. (ADR-001) The one exception is fastlane, and it is
build tooling, never linked into the app; the snapshot tests were written without a library
for the same reason.

**Is the accessibility claim real?**
Apple's audit, in light, dark and the largest text size, runs in CI and fails on anything not
explicitly accepted with a reason. It found real failures: outcome sheets unreadable at large
sizes, every dark-mode button below contrast. **Not done: a spoken VoiceOver pass by a person.**
(`accessibility.md`)

**Is the Vietnamese right?**
Machine-drafted and consistent, not yet reviewed by a native speaker. A CI check fails if any key
lacks a translation, so it cannot silently rot.

**Did you change the backend? The brief says it is read-only.**
Once, with your agreement: the idempotency change, on a branch, with 23 integration tests. It is
on a local branch because the account has no push access upstream. Everything else found in the
backend is reported, not patched. (`defects.md`)
