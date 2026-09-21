# Runbook

Everything needed to go from a clean machine to a running demo.

## 1. Prerequisites

```bash
brew install openjdk@21 maven colima docker docker-compose k6 xcodegen swiftlint
```

Xcode 26.3 or later. Colima rather than Docker Desktop, which requires a paid licence at
companies over 250 employees.

## 2. Backend

The backend lives on the **`master`** branch. A plain `git clone` lands on `main`, which
contains a LICENSE and nothing else.

```bash
git clone -b master https://github.com/trint218/parking-reservation.git
```

Then, from the repository root:

```bash
./scripts/backend-up.sh        # gate ON, window 20:00 — the demo configuration
./scripts/backend-up.sh 15     # gate ON, window shifted to 15:00 — for testing
./scripts/backend-up.sh off    # gate bypassed — the shipped default
```

The script starts colima, brings up Postgres and Redis, waits for health, and runs the API.

Three things the upstream documentation gets wrong, all verified:

1. `backend/docker-compose.yml` starts **only** Postgres and Redis. There is no API service.
   The API needs a local JDK 21 and Maven.
2. The README's `./mvnw spring-boot:run` is stale — **no Maven wrapper exists** in the
   repository. Use `mvn`.
3. `mvn spring-boot:run -Dapp.reservation.bypass-time-check=false`, the form the project
   brief gives, **does not enable the time gate**: `spring-boot:run` forks a JVM that does
   not inherit Maven's `-D` properties. It must be passed via
   `-Dspring-boot.run.jvmArguments`. See `docs/defects.md` D1.

Allow ~75 s for the first cold build (mostly Maven resolving dependencies, not a hang) and
3–4 s for warm restarts.

Verify:

```bash
curl -s localhost:8080/actuator/health     # {"status":"UP"}
```

## 3. Reset to a clean grid

```bash
docker exec parking-redis redis-cli FLUSHALL
docker exec parking-postgres psql -U postgres -d parking -c \
  "TRUNCATE reservations, transactions RESTART IDENTITY CASCADE; \
   UPDATE spaces SET user_id=NULL, plate_last3=NULL, reserved_date=NULL, version=0;"
```

Add `DELETE FROM users;` to drop accounts too.

## 4. App

```bash
make project     # regenerate Parking.xcodeproj from project.yml
make build
make test        # unit tests
make uitest      # UI tests (run against in-process fakes, backend not required)
make lint        # SwiftLint, must be zero violations
make ci          # everything CI runs
```

`Parking.xcodeproj` is generated and **not committed** — `project.yml` is the source of
truth. Run `make project` after a fresh clone.

To point the app at a shifted window, matching a backend started with
`./backend-up.sh 15`, set `PARKING_WINDOW_HOUR=15` in the scheme's environment variables.

## 5. Load test

k6 is not preinstalled. `tests/load-stress-test.js` defines `options.scenarios`, so
`--vus` and `--duration` on the command line are **ignored**:

```bash
k6 run --env BASE_URL=http://localhost:8080 --env SCENARIO=stress tests/load-stress-test.js
```

`stress` ramps to 1000 VUs. Setup registers 1000 users sequentially first (~75 s).

Two caveats, both in `docs/defects.md` D8: the run reports a crossed `http_req_failed`
threshold even when behaving perfectly (409 is counted as a failure), and it reports green
against a *closed* window. The real pass criterion is `reservation_success == 80`.

## 6. CI

Runs on a self-hosted runner on the Mac mini. GitHub Free grants ~200 macOS minutes a month
and this workflow takes ~6 minutes, so hosted runners would cover roughly 12 runs across the
fortnight — not "CI on every push".

To register the runner: repository → Settings → Actions → Runners → New self-hosted runner
(macOS/arm64), then `./run.sh`. Label it `macOS`.

## 7. Demo checklist

1. Backend up with the gate **on** and the window shifted to the current hour.
2. Clean grid (§3), 1000 synthetic users seeded by a k6 setup run.
3. App on the simulator, `PARKING_WINDOW_HOUR` matching the backend.
4. Rehearsed: a won race, a lost race, and the backend killed mid-reservation
   (`pkill -f spring-boot:run`) — the app must never show a state that is not true.
