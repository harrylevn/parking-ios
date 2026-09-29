# Defect report

Two different things are recorded here, and they go to different places:

* **Section A — errors in the project brief itself.** Instructions from VNCDC that do not do
  what they say. These are not backend defects and cannot be "worked around in the client";
  they need correcting at source.
* **Section B — backend defects.** The backend is read-only per the brief's guardrail, with
  one exception the reviewer agreed on 28/09: D4, idempotency, fixed on the backend branch
  `feature/reservation-idempotency`, which is local and not pushed. Nothing else was patched. Each item records what was
  observed, how to reproduce it, and how the client works around it.

Backend under test: `trint218/parking-reservation`, branch `master`, commit `f27120c`.
Verified 2026-09-21 against a local run (Spring Boot 3.3.4, Java 21, Postgres 15, Redis 7).

---

# Section A — errors in the project brief

## D1 — The flag form the brief gives does not enable the time gate

**Severity: high.** Following the documented instruction produces the opposite of the
intended configuration, with no error.

**Source.** The project brief, section 4 *Constraints and ground rules → Environment*
(page 2): "Run the backend with `-Dapp.reservation.bypass-time-check=false`." The same flag
is referenced again in the section 3 guardrails ("Run the backend with its time gate on") and
in the 6.2 guardrail ("Demo runs with `app.reservation.bypass-time-check=false`").

This command form appears **only in the brief**. The backend repository never suggests it:
`bypass-time-check` appears there solely as a YAML property in `application-dev.yml`,
`application-prod.yml` and `application-test.yml`. So this is an error in VNCDC's own
instructions, not a backend defect — which is why it sits in Section A.

Passed as written, the gate stays **bypassed**: `spring-boot:run` forks a separate JVM, and a
forked process does not inherit the parent's `-D` system properties.

**Evidence.** Both forms run back to back on 2026-09-22 at 09:51 and 09:52, same
`window-hour=20`, same request:

| Form | Maven JVM | Application JVM | `POST /reservations` |
|---|---|---|---|
| `-Dapp.reservation.bypass-time-check=false` | carries the flags | **no `-D` flags at all** | **HTTP 200**, reservation created |
| `-Dspring-boot.run.jvmArguments="…"` | — | **carries both flags** | **HTTP 429 `WINDOW_CLOSED`** |

The process tree shows the mechanism directly — the application JVM is a *child* of the
Maven JVM, and the properties never cross:

```
pid 94779  java … Launcher -Dapp.reservation.bypass-time-check=false -Dapp.reservation.window-hour=20
pid 94807  java … com.parking.ParkingApplication          <- child, no -D flags
```

Either of these works, because the plugin puts them on the forked JVM's command line:
```
mvn spring-boot:run -Dspring-boot.run.jvmArguments="-Dapp.reservation.bypass-time-check=false"
mvn spring-boot:run -Dspring-boot.run.arguments="--app.reservation.bypass-time-check=false"
```

**Impact.** It fails silently and in the *permissive* direction: no warning, no log line, the
application starts normally and every reservation succeeds. That is indistinguishable from
correct behaviour until you attempt a reservation outside the window and expect a rejection.
Anyone following the brief believes the 20:00 gate is active while it is off, so all race
handling appears to work and is in fact never exercised — which is precisely the outcome the
brief's own section 3 warns against.

**Verification one-liner.** Outside the window, with the gate on, this must print `429`:
```
curl -s -o /dev/null -w '%{http_code}\n' -X POST localhost:8080/reservations \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{}'
```

**Workaround.** `scripts/backend-up.sh` uses the working form. The demo asserts a
`WINDOW_CLOSED` response before the race is shown, so a misconfigured backend fails loudly
rather than silently passing.

---

# Section B — backend defects

## D2 — `WINDOW_CLOSED` is returned as HTTP 429

A closed reservation window returns `429 Too Many Requests`:
```json
{"status":429,"error":"Too Many Requests","code":"WINDOW_CLOSED", ...}
```
429 conventionally means rate limiting, and both `URLSession` and most HTTP middleware treat
it as a retry-with-backoff signal. Retrying a closed window is useless — it opens on a clock,
not on backoff — and at 20:00 scale it is a self-inflicted thundering herd. `403` or `409`
would carry the correct semantics.

**Workaround.** The client classifies on the `code` field and never on HTTP status;
`APIError.isSafelyRetryable` returns `false` for `windowClosed` despite the 429.
Covered by `ErrorDecodingTests.testWindowClosedArrivesAs429AndIsNotRetryable`.

---

## D3 — Two different 401 shapes, undocumented in the contract

| Trigger | Status | Body | Header |
|---|---|---|---|
| missing / malformed / expired token | 401 | empty, `Content-Length: 0` | `WWW-Authenticate: Bearer` |
| wrong password on `/auth/login` | 401 | full JSON, `code: AUTH_FAILED` | none |

The first is produced by the Spring Security filter chain, which runs before
`GlobalExceptionHandler` (a `@RestControllerAdvice`) and so never reaches it.

**Correction to an earlier version of this document:** I previously wrote that the brief
documents only one of these shapes. That is wrong — section 6.2 describes both, accurately
and in detail, including `AUTH_FAILED` in the JSON list and the bare 401's empty body and
`WWW-Authenticate: Bearer` header. The gap is in the backend's `openapi.yml`, which documents
neither (see D6), and in the reference web client, which conflates them. The brief got this
right and I misread it.

**Impact.** A client that decodes every 401 as JSON throws on the empty body. A client that
treats every 401 as an expired session signs the user out when they merely mistype a password
— which is exactly what the reference web client in `frontend/` does
(`src/services/api.ts` clears storage and redirects on any 401).

**Workaround.** `HTTPClient.decodeFailure` branches on body emptiness, not status, and
`APIError.requiresReauthentication` is true only for the bare 401. Covered by
`ErrorDecodingTests.testBare401…` and `…testAuthFailed401…`.

---

## D4 — No idempotency key, and no way to reconcile a lost response

`ReservationRequest` exposes only `preferredSpaceNumber`. Idempotency is derived
**server-side** from `(userId, date)` in `RedisLockService.checkAndSetIdempotency`, and
`ReservationService.reserve` clears that key in its `finally` block on failure.

Consequently, after a network timeout the client cannot determine what happened:
- retrying returns `DUPLICATE_REQUEST`, which means *either* "still in flight" *or*
  "already succeeded";
- there is **no `GET /reservations`** endpoint to ask;
- the only reconciliation surface is `GET /spaces`, matched on `plateLast3` — three
  characters, so two plates can collide and the client cannot tell which space is its own.

**Suggested fix.** Accept a client-supplied `Idempotency-Key` header and return the original
response for a repeat, or expose `GET /reservations/me`.

**Workaround, as first built.** `ReservationCoordinator` issues exactly one attempt per tap,
never retries a timed-out reservation, reconciles against the grid, and reports
`ReservationOutcome.unknown` when it cannot prove the result — rather than guessing. Covered
by `ReservationCoordinatorTests`.

**Fixed on the backend branch** (reviewer-approved exception to the read-only rule). Both
suggested fixes were built: an optional `Idempotency-Key` whose repeats replay the first
outcome, and `GET /reservations/me`. The client now repeats a tap's key after a timeout and
reads back what committed; the grid reconciliation remains only as the fallback when the
read-back cannot be reached, which also covers running against `master`. See ADR-007 and
`ReservationRetryTests`.

---

## D5 — No time endpoint, and the window's time zone is undiscoverable

The 20:00 gate is evaluated with `LocalTime.now()` in the **JVM default time zone**, while
`spring.jackson.time-zone` is pinned to `Asia/Bangkok`. Nothing in the API exposes either the
server's current time or its zone, yet the brief requires a countdown derived from server
time rather than the device clock.

The gate is also hour-granularity with **no upper bound**: `now.getHour() < windowHour`. The
window therefore runs from the top of the hour until midnight, when
`LocalDate.now().plusDays(1)` rolls over and it shuts.

**Suggested fix.** A `GET /time` returning the server instant, the configured window hour and
the zone.

**Workaround.** `ServerClock` anchors the HTTP `Date` response header against a
`ContinuousClock` and extrapolates, so the countdown survives device clock tampering; the
zone and hour are configuration. Note `Date` has one-second granularity and includes one
network leg of latency, so the countdown does not claim sub-second precision.

---

## D6 — Contract gaps in `openapi.yml`

- `ErrorResponse` appears nowhere in `components.schemas`; only 200 responses are documented,
  so every error shape the client must handle is undocumented.
- The semantics of `DUPLICATE_REQUEST` vs `ALREADY_QUEUED` vs `ALREADY_RESERVED` are unstated.
- `GET /wallet/balance` is typed as a free-form `additionalProperties: number` map rather than
  a named schema, so the key name is not part of the contract. The client reads it
  defensively.
- `GET /spaces` requires authentication but the document does not say so.
- The README Quick Start references `./mvnw`, which does not exist in the repository.

---

## D7 — `ALREADY_RESERVED` is unreachable on the normal path

`ALREADY_RESERVED` is thrown in `ReservationTransactionService` off the
`uk_user_date` unique constraint, but the Redis idempotency check at step 3 fires first for
the same user, so a second attempt always yields `DUPLICATE_REQUEST` instead. Confirmed
empirically — it could not be triggered through the API.

It can therefore only surface when Redis and Postgres disagree (Redis flushed or evicted
while the row survives). That makes it *more* trustworthy than `DUPLICATE_REQUEST`, not less:
it is the only unambiguous "you already hold a reservation".

**Workaround.** The client trusts `ALREADY_RESERVED` without reconciling and reconciles on
`DUPLICATE_REQUEST`. With an Idempotency-Key, `ALREADY_RESERVED` is never this tap's own row, which the
backend replays as a success instead, so it means an earlier tap holds the space. Covered by
`ReservationCoordinatorTests.testAlreadyReservedIsTrustedWithoutReconciliation`.

---

## D8 — The repo's own k6 stress test cannot pass, and passes when it should not

Two separate problems in `tests/load-stress-test.js`:

1. It counts HTTP 409 as a failed request, so `http_req_failed` crosses its `rate<0.01`
   threshold the moment the 81st user arrives. A 1000-VU run on 2026-09-21 reported
   `rate=99.53%` and `** THRESHOLD CROSSED **` while behaving perfectly — every business
   invariant held and `reservation_server_errors` was 0.
2. It classifies 429 as "rate limited — expected under high load" and counts it as neither an
   error nor a failed check. Since 429 is `WINDOW_CLOSED` here (see D2), a run against a
   closed gate reports **green with zero reservations**. Combined with D1, it is possible to
   run the suite, see it pass, and have exercised nothing.

**Workaround.** Treat `reservation_success == 80` as the pass criterion. Recorded because
the brief requires defects be reported rather than worked around silently.

---

## D9 — `GET /spaces` contradicts itself: free spaces arrive carrying a plate

`SpaceService.fetchAndCacheSpaces` computes the two fields against different dates:

```java
LocalDate tomorrow = LocalDate.now().plusDays(1);
.available(space.getReservedDate() == null || !space.getReservedDate().equals(tomorrow))
.plateLast3(space.getPlateLast3())   // ← no date filter
```

`available` is correctly scoped to tomorrow. `plateLast3` is returned from the row whatever
date it holds, and the `spaces` table has a single `reserved_date` column that is never
cleared once that date passes — there is no check-out, no expiry job, and no nightly reset.
So every space whose booking is in the past arrives **`available: true` with a stranger's
plate attached**, and the two fields flatly contradict each other.

**Reproduce** (after the backend has been used on any earlier day):

```
curl -s localhost:8080/spaces -H "Authorization: Bearer $TOKEN" \
  | python3 -c "import sys,json;d=json.load(sys.stdin);\
print(sum(1 for s in d['spaces'] if s['available'] and s.get('plateLast3')),'contradictory of',len(d['spaces']))"
```

Observed 2026-09-28: **15 of 80**, with `reserved_date` values of 2026-09-24, -25 and -26
still in the table. Space 4 was among them.

**Impact.** Two, and the second is the one that matters:

1. *Cosmetic but decisive.* A board that prints the plate is telling the user the space is
   taken while the same payload says it is free. This is what the week-1 checkpoint saw and
   reported as "the dashboard books tomorrow but still shows spaces booked today".
2. *Correctness.* `plateLast3` is the **only** reconciliation surface after a timed-out
   reservation (D4), matched on three characters across 80 cells. Stale plates enlarge the
   population that can collide with our own suffix on the one path that decides whether the
   user believes they were charged.

**Workaround.** `ParkingSpace.init` drops `plateLast3` whenever `isAvailable` is true, so the
contradiction is resolved once at the type rather than at each reader, and no view or
reconciliation path can observe it. Covered by `ParkingSpaceTests`.

**The fix belongs server-side.** Filtering the plate by the same date as the flag is a
one-line change; the durable fix is a check-out or expiry that clears `reserved_date` and
`plate_last3` once the day has passed, which is what the "single `reserved_date` column"
design is missing. The client cannot distinguish a stale plate from a current one by
inspection — it infers it only from the `available` flag it is contradicting.

---

## D10 — The JWT signing key is committed to the repository

`backend/src/main/resources/keys/` holds the RSA private key the backend signs session tokens
with, and `terraform-minimal/` holds a copy. Both have been there since the first commit
(`ff91cb1`). The default profile (`application.yml`) and the dev profile sign with that
committed key; only the prod profile reads one from a file path.

**Impact.** Anyone with read access to the repository can mint a valid token for any user id,
and with it sign in as that user and spend their balance on reservations. Nothing on the
server tells a minted token from a real one. Here the data is synthetic and the backend local,
so it harms nobody; the defect is in what the repository makes possible for any deployment
that forgets the prod profile.

**Suggested fix.** Remove the keys from the repository and from its history, rotate the key
pair, and have every profile load the signing key from a secret store or an injected path,
failing to start without one rather than falling back to a bundled key.

**Client impact.** None to work around: the client only stores and presents the token. Found
during the day-8 secrets check (`docs/security.md`). Not fixed, since the backend is read-only
apart from the agreed idempotency change.

---

## Appendix — measured behaviour, 1000-VU stress run

Clean database, `FLUSHALL`ed Redis, gate on with the window open. 2026-09-21.

| Measure | Value |
|---|---|
| reservations created | 80 |
| distinct spaces / distinct users | 80 / 80 |
| duplicate space rows, duplicate (user, date) rows | 0, 0 |
| money taken | 800.00 = 80 × 10.00 exactly |
| users with balance ≠ 100 − paid | 0 |
| 5xx, EOF errors, exhausted retries | 0, 0, 0 |
| reservation p95 / p99 / max | 248 ms / 368 ms / 867 ms |
| sustained throughput | ~2,967 req/s |

The concurrency design is correct under load. These numbers set the client's timeout budget
(see `APIConfiguration.reservationTimeout`) and are the evidence behind the design doc's
claim that 92% of users lose the race.
