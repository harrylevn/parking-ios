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

## 6. CI — self-hosted runner

CI on every push is a **guardrail** (6.4). It is not achievable on GitHub's hosted macOS
runners: the free tier grants ~2,000 minutes a month but bills macOS at **10×**, so ~200
effective macOS minutes, and this workflow takes ~6 minutes. That is about 12 runs for the
whole fortnight. A self-hosted runner is the only way the guardrail is met, which is why the brief puts it in
the Default column as the expected answer.

### 6.1 Conditions that must hold before registering

**Repository**

| # | Condition | Why |
|---|---|---|
| 1 | The repo exists on GitHub and this clone has a remote | Nothing to register a runner against otherwise. `git remote -v` is currently empty |
| 2 | The repo is **private** | Guardrail 6.5, and a hard security requirement: see 6.2 |
| 3 | You have **admin** on the repo | Settings → Actions → Runners is admin-only |
| 4 | `gh` is authenticated with `repo` scope | `gh auth status` — used to mint the registration token |

**Machine**

| # | Condition | Why |
|---|---|---|
| 5 | macOS on arm64 | Runner package is `osx-arm64`. This machine: MacBook Pro M4, 16 GB, macOS 26.5.1, arm64 — **not** the Mac mini the brief assumes, which changes nothing except that 16 GB is tight (see 6.6) |
| 6 | Xcode installed, selected and licensed | `xcode-select -p`; `sudo xcodebuild -license accept` once |
| 7 | An iOS simulator runtime is installed | The workflow runs UI tests on `iPhone 17 Pro`; `xcrun simctl list runtimes` |
| 8 | `xcodegen`, `swiftlint` and `git` on the runner's PATH | The project is generated, not committed. Homebrew's `/opt/homebrew/bin` must be on PATH for the runner's shell, which does **not** inherit your interactive profile |
| 9 | The runner is installed **outside** `~/Documents` or any cloud-synced folder | Sync extended attributes break iOS code signing — `Command CodeSign failed`. Use `~/actions-runner`; its `_work/` checkout inherits the location |
| 10 | ~20 GB free | DerivedData plus simulator runtimes. Measured: 219 GB free — met |
| 10b | **The Mac does not idle-sleep** | Measured on this machine: `sleep 1` on **both** battery and AC, i.e. it sleeps after one idle minute. A runner cannot survive that — jobs are suspended mid-build and the run eventually fails or hangs. Fix before registering: `sudo pmset -c sleep 0` (AC only, leaves battery behaviour alone) |
| 11 | Installed as a launchd service (`svc.sh`) | Otherwise the runner dies with the terminal and CI stops silently between pushes |

**Not required:** the backend. Unit and UI tests run against in-process fakes, and
`ScreenshotTests` is skipped unless `SCREENSHOTS=1`. CI never needs Postgres, Redis or the API.

**No secrets are needed.** `make archive` passes `CODE_SIGNING_ALLOWED=NO`, so there is no
certificate, provisioning profile or App Store credential anywhere in the pipeline — which is
what keeps guardrail 6.5 ("no secrets, keys or credentialled endpoints in the repo") true of
CI as well as of the app.

### 6.2 Security conditions — read before running this on your own machine

A self-hosted runner executes whatever the workflow says, as your user, on your Mac. That is
fine here and would not be fine everywhere:

- **The repo must stay private.** GitHub's own guidance is that self-hosted runners should not
  be used with public repositories: anyone can open a pull request from a fork, and on a
  public repo that can run their code on your machine. Making this repo public later without
  removing the runner would be the single most dangerous change available.
- **The runner has your user's access** — Keychain, SSH keys, the filesystem. For a personal
  probation project that is an accepted risk. In production I would run it as a dedicated
  macOS user with no Keychain items and no SSH keys, or in an ephemeral VM.
- **Job code is not sandboxed between runs.** The workspace persists, so a compromised
  dependency could linger. There are no third-party dependencies in this project, which
  narrows that surface to approximately zero.

### 6.3 Registering it

```bash
# 1. Create the private repo and push (one-off, from the repo root)
gh repo create parking-ios --private --source=. --remote=origin --push

# 2. Download the runner, outside any cloud-synced folder
mkdir -p ~/actions-runner && cd ~/actions-runner
curl -o actions-runner-osx-arm64.tar.gz -L \
  https://github.com/actions/runner/releases/latest/download/actions-runner-osx-arm64-<version>.tar.gz
tar xzf actions-runner-osx-arm64.tar.gz

# 3. Mint a registration token and configure.
#    Labels must include macOS — .github/workflows/ci.yml targets [self-hosted, macOS].
TOKEN=$(gh api -X POST repos/<owner>/parking-ios/actions/runners/registration-token --jq .token)
./config.sh --url https://github.com/<owner>/parking-ios --token "$TOKEN" \
            --labels macOS --unattended

# 4. Install as a service so it survives logout and reboot
./svc.sh install && ./svc.sh start && ./svc.sh status
```

The registration token is short-lived (one hour) and is not a secret worth keeping.

### 6.4 Verifying it actually works

Registration is not the same as CI passing. Confirm all four:

```bash
gh api repos/<owner>/parking-ios/actions/runners --jq '.runners[] | {name, status, busy}'
git commit --allow-empty -m "ci: verify runner" && git push
gh run watch
gh run view --log-failed     # if it fails
```

The first run is the one that finds PATH problems: `xcodegen: command not found` means
condition 8 is unmet, and `Command CodeSign failed` means condition 9 is.

### 6.6 Resource contention on a 16 GB machine

The runner shares the machine with everything else. During this project, running colima
(6 GB), Xcode, two simulators and a Vite dev server at once was enough for macOS to start
killing processes. A CI run that boots a simulator while you are also building in Xcode will
be slow and can fail on memory.

Practical mitigations, in order of preference: stop colima when the backend is not needed
(`colima stop`), keep the workflow to one simulator, and do not run CI and a local build
simultaneously. The `concurrency` group in the workflow already cancels superseded runs, so
rapid pushes do not stack.

### 6.5 If the runner cannot be registered

The guardrail is CI on every push, not a self-hosted runner specifically. If registration is
blocked — no admin rights, corporate device management — the fallback is a hosted macOS
runner with the workflow trimmed to lint plus unit tests (~2 minutes), pushing the UI tests
and archive to a nightly schedule. That fits the free tier and keeps *something* on every
push. It is a worse answer and should be argued for explicitly, not slipped in.

## 7. Demo checklist

1. Backend up with the gate **on** and the window shifted to the current hour.
2. Clean grid (§3), 1000 synthetic users seeded by a k6 setup run.
3. App on the simulator, `PARKING_WINDOW_HOUR` matching the backend.
4. Rehearsed: a won race, a lost race, and the backend killed mid-reservation
   (`pkill -f spring-boot:run`) — the app must never show a state that is not true.
