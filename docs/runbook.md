# Runbook

Everything needed to go from a clean machine to a running demo.

## 1. Prerequisites

```bash
brew install openjdk@21 maven colima docker docker-compose k6 xcodegen swiftlint
```

Xcode 26.3 or later. Colima rather than Docker Desktop, which requires a paid licence at
companies over 250 employees.

## 2. Backend

Clone the backend the app is built against alongside the iOS repo. It is the original backend
plus the key replay and `GET /reservations/me` (ADR-007), published separately because the
GitHub account has no write access to `trint218/parking-reservation`:

```bash
git clone https://github.com/harrylevn/parking-backend.git ../parking-reservation
```

Its JWT signing key was taken out of the repository before publishing (D10), so generate one
before the first start:

```bash
mkdir -p ../parking-reservation/backend/src/main/resources/keys
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
  -out ../parking-reservation/backend/src/main/resources/keys/private_key_pkcs8.pem
```

Leave `PARKING_IDEMPOTENCY_KEYS` unset and repeats are on. Against the original
`trint218/parking-reservation` (`master`; its `main` holds only a LICENSE), which ignores the
`Idempotency-Key` header, put **`PARKING_IDEMPOTENCY_KEYS=0`** in the scheme's environment
variables: there a repeat after a lost reply could be a genuine second attempt, so the setting
turns repeats off and the app falls back to reconciling against the board, as it did before
ADR-007.

Set `PARKING_BACKEND` if the clone lives anywhere else. Then, from the **iOS** repository
root:

```bash
make backend                   # gate ON, window 20:00 — the demo configuration
make backend-now               # gate ON, window = the current hour — open immediately
make backend-off               # gate bypassed — the shipped default
```

These wrap `scripts/backend-up.sh`, which also takes an explicit hour:

```bash
./scripts/backend-up.sh 15     # gate ON, window shifted to 15:00
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

`make backend-reset`, or by hand:

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

To point the app at a shifted window, matching a backend started with `make backend-now` or
`./scripts/backend-up.sh 15`, set `PARKING_WINDOW_HOUR` to the same hour in the scheme's
environment variables. The app and the backend must agree, or the countdown points at a
window the server is not using.

- **Which hour is the backend on?** `make backend-hour`. The backend has no endpoint for it,
  so the target reads the running JVM's arguments, and reports the gate state too.
- **From Xcode:** Edit Scheme → Run → Arguments → Environment Variables. Every `make build`,
  `make test` and `make uitest` regenerates the scheme with `xcodegen`, which **discards
  that setting** — the app then silently falls back to 20:00. Re-check it after any `make`.
- **From the command line:** `SIMCTL_CHILD_PARKING_WINDOW_HOUR=<hour> xcrun simctl launch
  --terminate-running-process <udid> com.vncdc.parking`. A backend restarted on a new hour
  does not reach an app already running; relaunch it.
- **Changing the backend's hour** means restarting the API: it reads the hour once, at
  start-up. Stop it (`Ctrl+C` in its terminal, or `kill $(lsof -tnP -iTCP:8080 -sTCP:LISTEN)`),
  then `./scripts/backend-up.sh <hour>`. Postgres and Redis keep running, so reservations
  survive the restart; `make backend-reset` clears them.
- **Picking an hour to test the countdown:** the window runs from the opening hour until
  midnight, so any hour at or before the current one is already open. To watch T-60s, T-10s
  and the opening, use the *next* hour.
- If they disagree anyway and the app thinks the window is open, the first reservation
  answers `WINDOW_CLOSED` and the app replaces "Reservations are open" with a mismatch
  warning. The opposite case (app counting down, server already open) is not detected yet. Its
  symptom is spaces on the board booked for tomorrow while the app still counts down — which
  can only happen after the server's window has opened. Check `make backend-hour` first.

`make` with no target lists every command.

## 5. Screenshots

```bash
make screenshots        # needs the backend up: make backend-now
```

Runs `ScreenshotTests` against the live backend, exports the attachments from each `.xcresult`
and writes all thirteen files into `docs/screenshots/`.

It is three passes, because a screenshot set needs two appearances and two devices and one
test run is one of each:

| Pass | Device | Appearance | Captures |
|---|---|---|---|
| 1 | iPhone 17 Pro | light | 01–08, 11–12 |
| 2 | iPhone 17 Pro | dark | 09–10 |
| 3 | iPad Pro 13-inch (M5) | light | 13 |

The appearance is set with `xcrun simctl ui <device> appearance dark` rather than forced in
the app with `preferredColorScheme`, so what is captured is the palette the app actually
adopts from the system rather than an override.

The iPad must exist on the **newest** installed runtime, because the destination resolves
`OS:latest`. An iPad Pro 13-inch (M4) is present here but only on 26.0.1, so naming it fails
with "no available devices matched the request".

Three things this wraps, all of which cost time when done by hand:

1. **The environment variable needs a `TEST_RUNNER_` prefix.** `xcodebuild` passes only those
   through to the test-runner process. A plain `SCREENSHOTS=1` leaves the suite skipped — and a
   skipped suite still reports `** TEST SUCCEEDED **`, so it looks like it ran.
2. **The run creates its own account** over HTTP and funds it through the UI. One reservation
   per vehicle per day is a backend invariant, so a fixed plate captures the flow once and then
   never again that day: the board comes back with the space already held and nothing is
   selectable.
3. **Landscape captures are rotated upright before attaching.** `UIImage.size` reports the
   landscape dimensions, but the rotation lives in `imageOrientation` while the backing buffer
   stays portrait, and `XCTAttachment(image:)` writes the buffer and drops the orientation.

The registration screen is captured but not driven. iOS puts its Automatic Strong Password
cover view over any pair of secure fields and nothing the app declares dismisses it, so a test
cannot type a confirmation.

## 6. Load test

k6 is not preinstalled. `tests/load-stress-test.js` defines `options.scenarios`, so
`--vus` and `--duration` on the command line are **ignored**:

`make loadtest`, or by hand from the backend repo:

```bash
k6 run --env BASE_URL=http://localhost:8080 --env SCENARIO=stress tests/load-stress-test.js
```

`stress` ramps to 1000 VUs. Setup registers 1000 users sequentially first (~75 s).

Two caveats, both in `docs/defects.md` D8: the run reports a crossed `http_req_failed`
threshold even when behaving perfectly (409 is counted as a failure), and it reports green
against a *closed* window. The real pass criterion is `reservation_success == 80`.

## 7. CI — self-hosted runner

CI on every push is a **guardrail** (6.4). It is not achievable on GitHub's hosted macOS
runners: the free tier grants ~2,000 minutes a month but bills macOS at **10×**, so ~200
effective macOS minutes, and this workflow takes ~6 minutes. That is about 12 runs for the
whole fortnight. A self-hosted runner is the only way the guardrail is met, which is why the brief puts it in
the Default column as the expected answer.

### 7.1 Conditions that must hold before registering

**Repository**

| # | Condition | Why |
|---|---|---|
| 1 | The repo exists on GitHub and this clone has a remote | Nothing to register a runner against otherwise. `git remote -v` shows it |
| 2 | The repo is **private** | Guardrail 6.5, and a hard security requirement: see 7.2 |
| 3 | You have **admin** on the repo | Settings → Actions → Runners is admin-only |
| 4 | `gh` is authenticated with `repo` scope | `gh auth status` — used to mint the registration token |

**Machine**

| # | Condition | Why |
|---|---|---|
| 5 | macOS on arm64 | Runner package is `osx-arm64`. This machine: MacBook Pro M4, 16 GB, macOS 26.5.1 — the machine the brief calls "your Mac mini". 16 GB is tight; see 7.6 |
| 6 | Xcode installed, selected and licensed | `xcode-select -p`; `sudo xcodebuild -license accept` once |
| 7 | An iOS simulator runtime is installed | The workflow runs UI tests on `iPhone 17 Pro`; `xcrun simctl list runtimes` |
| 8 | `xcodegen`, `swiftlint` and `git` on the runner's PATH | The project is generated, not committed. Homebrew's `/opt/homebrew/bin` must be on PATH for the runner's shell, which does **not** inherit your interactive profile |
| 9 | The runner is installed **outside** `~/Documents` or any cloud-synced folder | Sync extended attributes break iOS code signing — `Command CodeSign failed`. Use `~/actions-runner`; its `_work/` checkout inherits the location |
| 10 | ~20 GB free | DerivedData plus simulator runtimes. Measured: 219 GB free — met |
| 10b | **The Mac does not idle-sleep** | A runner cannot survive idle sleep — jobs are suspended mid-build and the run eventually fails or hangs. This machine shipped at `sleep 1` on both battery and AC, i.e. asleep after one idle minute. Set with `sudo pmset -c sleep 0`, which changes the AC profile only and leaves battery behaviour alone. Verify with `pmset -g custom`. **Needs a real terminal** — `sudo` cannot prompt for a password without a TTY |
| 11 | Installed as a launchd service (`svc.sh`) | Otherwise the runner dies with the terminal and CI stops silently between pushes |

**Not required:** the backend. Unit and UI tests run against in-process fakes, and the live
suites (`ScreenshotTests`, `RehearsalUITests`, `PinningDemoUITests`) skip unless their scripts
enable them. CI never needs Postgres, Redis or the API.

**No secrets are needed.** `make archive` passes `CODE_SIGNING_ALLOWED=NO`, so there is no
certificate, provisioning profile or App Store credential anywhere in the pipeline — which is
what keeps guardrail 6.5 ("no secrets, keys or credentialled endpoints in the repo") true of
CI as well as of the app.

### 7.2 Security conditions — read before running this on your own machine

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
  dependency could linger. The app has no third-party dependencies, and CI never installs
  fastlane's gems, which narrows that surface to approximately zero.

### 7.3 Registering it

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

### 7.4 Verifying it actually works

Registration is not the same as CI passing:

```bash
gh api repos/harrylevn/parking-ios/actions/runners --jq '.runners[] | {name, status, busy}'
git commit --allow-empty -m "ci: verify runner" && git push
gh run watch
```

The first run is what finds the environment problems: `xcodegen: command not found` means
condition 8 is unmet, and `Command CodeSign failed` means condition 9 is. Reading the result
is §7.5.

### 7.5 Reading a CI run

Registration is the one-off part. This is the part you do every day.

**The whole run, in a browser.** Fastest when something is red and you want to see which step:

```bash
gh run list --web          # every run
gh run view --web          # the latest one, click through to per-step logs
```

Or go straight to <https://github.com/harrylevn/parking-ios/actions>.

**From the terminal:**

| Task | Command |
|---|---|
| Last ten runs | `gh run list` |
| One run's summary | `gh run view <id>` |
| **Only the failing step's log** | `gh run view <id> --log-failed` |
| The entire log | `gh run view <id> --log` |
| Follow a run live | `gh run watch` |
| Re-run after a flake | `gh run rerun <id>` |

`--log-failed` is the one worth remembering. A green run produces several thousand lines of
compiler output; it skips all of that and prints the step that broke.

**When a UI test fails, look at the screenshot before theorising.**

The workflow uploads the `.xcresult` bundle as an artifact, and XCTest puts a screenshot of
the screen at the moment of failure inside it. That is not a nicety — it is usually the
fastest path to the cause:

```bash
gh run download <id> -D /tmp/ci
open /tmp/ci/test-results/*.xcresult      # opens in Xcode
```

In Xcode: **Tests** tab → the red test → the attachments underneath it. Both screenshots and
the captured element tree are there.

This is worth insisting on. A UI test that fails only on CI invites guessing, and two
plausible-sounding fixes in a row can both be wrong while the screenshot shows the answer
immediately — in one case here, iOS's "Save Password?" dialog sitting on top of the board
while the element underneath still reported itself hittable.

**A test that passes locally and fails on CI is usually the simulator runtime.**

`name=iPhone 17 Pro` resolves to the **newest installed runtime**, which is not necessarily
the one you have been testing against. The `Tool versions` step logs what is installed. To
reproduce a CI failure locally, run against that runtime explicitly by UDID:

```bash
xcrun simctl list devices available | grep -B1 "iPhone 17 Pro"
xcodebuild -project Parking.xcodeproj -scheme Parking \
  -destination "platform=iOS Simulator,id=<udid>" \
  -derivedDataPath .build/DerivedData -only-testing:ParkingUITests test
```

That turns a remote flake into a local failure, which is the only comfortable place to debug one.

**When the job never starts at all**, the problem is the runner rather than the code:

```bash
# is it online and idle?
gh api repos/harrylevn/parking-ios/actions/runners \
  --jq '.runners[] | "\(.name) status=\(.status) busy=\(.busy)"'

# the service's own log
tail -f ~/Library/Logs/actions.runner.harrylevn-parking-ios.harry-mbp-m4/*.log

# restart it
cd ~/actions-runner && ./svc.sh stop && ./svc.sh start && ./svc.sh status
```

A runner showing `offline` after the Mac has been asleep or rebooted is the usual cause; the
launchd agent restarts it at login, not at boot.

**A run marked failed with no logs at all did not fail — it lost contact with GitHub.**

If `gh run view <id> --log` answers `log not found` and the failing step has no conclusion,
the job did not break: the runner could not report back. The step output was never uploaded,
so the web UI shows nothing either. The truth is in the runner's own diagnostics, which are
written locally regardless:

```bash
grep -nE "HttpRequestException|SocketException|nodename nor servname" \
  ~/actions-runner/_diag/Worker_*.log | tail
```

Seen here once: `nodename nor servname provided, or not known
(results-receiver.actions.githubusercontent.com)` — a transient DNS failure part-way through
a job. The tests themselves had not failed. `gh run rerun <id>` was the whole fix, and the
rerun passed unchanged.

Worth checking before assuming a real failure, because the symptom is indistinguishable from
a broken build in every view except that one log file.

### 7.6 Resource contention on a 16 GB machine

The runner shares the machine with everything else. During this project, running colima
(6 GB), Xcode, two simulators and a Vite dev server at once was enough for macOS to start
killing processes. A CI run that boots a simulator while you are also building in Xcode will
be slow and can fail on memory.

Practical mitigations, in order of preference: stop colima when the backend is not needed
(`colima stop`), keep the workflow to one simulator, and do not run CI and a local build
simultaneously. The `concurrency` group in the workflow already cancels superseded runs, so
rapid pushes do not stack.

### 7.7 If the runner cannot be registered

The guardrail is CI on every push, not a self-hosted runner specifically. If registration is
blocked — no admin rights, corporate device management — the fallback is a hosted macOS
runner with the workflow trimmed to lint plus unit tests (~2 minutes), pushing the UI tests
and archive to a nightly schedule. That fits the free tier and keeps *something* on every
push. It is a worse answer and should be argued for explicitly, not slipped in.

## 8. Demo checklist

1. Backend up with the gate **on** and the window shifted to the current hour.
2. Clean grid (§3), 1000 synthetic users seeded by a k6 setup run.
3. App on the simulator, `PARKING_WINDOW_HOUR` matching what `make backend-hour` reports.
4. Rehearsed: a won race, a lost race, and the backend killed mid-reservation, by
   `ROUNDS=2 make rehearse` (§10) — the app must never show a state that is not true.
5. Certificate pinning (§9): `make tls` running, and `make pinning-demo` green on the day.

## 9. TLS and certificate pinning

The backend is plaintext, so TLS is terminated in front of it for the pinning demo
(`docs/security.md`). Three terminals: the backend, the proxy, and the demo.

```bash
make backend-now          # terminal 1
make tls                  # terminal 2: https://localhost:8443 -> :8080, prints the pin
make pinning-demo         # terminal 3: the app through the proxy, three cases
```

The first `make tls` generates a local root CA and a `localhost` certificate in `.tls/`
(gitignored; no key leaves it), trusts the CA on every booted simulator, and prints the pin.
`make pinning-demo` trusts the CA on the simulator it runs on as well, so a freshly erased
simulator needs nothing by hand.

What the three cases show:

| Pins | Result | Why |
|---|---|---|
| The proxy's | The backend's "Incorrect licence plate or password." | Connected and trusted: the password is wrong on purpose |
| A wrong one | "The server's identity couldn't be verified, so nothing was sent." | Refused in the handshake; the proxy's access log shows no request |
| A stale one plus the CA's | Connected | What survives a server key rotation |

To run the app by hand through the proxy, set in the scheme's environment:

```text
PARKING_BASE_URL=https://localhost:8443
PARKING_SPKI_PINS=<the value make tls-pin prints>
```

**Rotation.** `./scripts/tls-proxy.sh rotate` issues a new server key under the same CA. The
old pin stops working; the CA pin does not. Rotate, then put only the old pin in the scheme to
see the lockout a release without a backup pin would suffer.

**If the app refuses a pin you believe is right:** the simulator does not trust the CA. That
fails ordinary validation, and pinning never overrides it. Run `make tls` again with the
simulator booted, or check `xcrun simctl keychain <udid> add-root-cert .tls/ca.pem`. A release
build refuses plaintext and ignores environment pins by design.

## 10. Rehearsals

```bash
ROUNDS=2 make rehearse
```

Unattended, about four minutes a round. It takes over `:8080`: whatever backend is running is
stopped, and the backend is started from `../parking-reservation`, which must carry the
idempotency change (§2); the script refuses to start without it. Each round:

| Step | Drives | Checked against the database |
|---|---|---|
| Gate | A reservation on a backend started with the window an hour ahead | `429 WINDOW_CLOSED`, so the gate is on rather than bypassed |
| Won | `RehearsalUITests.testWonRace`: a funded account reserves space 12 | The account holds space 12; balance 90.00 |
| Lost | The test selects space 12, books it for a rival through the API, then confirms | Space 12 is the rival's; the user is uncharged |
| Killed | A database lock holds the user's row; the backend is SIGKILLed the moment the reservation is seen waiting | After restart: nothing booked, balance unchanged, as the "Still checking" sheet said |

The window hour is read at start-up, which is why the gate is proved on a separate start: a
backend with the gate bypassed looks the same as one with it on until something is reserved
outside the window.

After the killed scenario the script makes one more reservation for the same user and prints
the answer. It is `DUPLICATE_REQUEST`: the crash left that user's guard in Redis for 24 hours
(`docs/defects.md` D11). Redis is reset before every scenario, so the rehearsal is unaffected.

Logs and result bundles, with a screenshot of each outcome, are in `.build/rehearsal/`.

## 11. Two users confirming at the same moment

```bash
TRIALS=20 make concurrent
```

Needs the backend with the window open (`make backend-now`); it does not take the backend over.
Two checks:

1. **The API, precisely.** `scripts/concurrent-reserve.py` releases two users' reservations
   for space 12 from a barrier, within about 40 µs of each other, `TRIALS` times. Every trial
   must end with one winner, one `SPACE_UNAVAILABLE`, one $10 debit and the space held by the
   winner. Then the same for "any space", where both must win different spaces. It also prints
   how often each side won, which shows whether arriving first confers an edge.
2. **The app, for real.** Two simulators (`iPhone 17 Pro` and `iPhone 17 Pro Max`, override
   with `CONCURRENT_SIM_A` / `_B`), each signed in as a different user with space 12 selected,
   tap Confirm at an instant agreed 90 s ahead. One must show the win and the other "Someone
   was faster", and the database must agree. The script prints how far apart the taps
   actually landed.

The Simulator app opens so both devices can be watched; each keeps its result on screen for
30 s (`CONCURRENT_HOLD_SECONDS`). Screenshots of both results are saved to
`.build/concurrent/screens-<time>/`, ready for slides. Outcomes are matched by accessibility
identifier, not wording, so the two simulators may run in different languages. Showing one in
English and one in Vietnamese is a good way to demonstrate the localisation during the same
race.

## 12. Running on a real iPhone

```bash
cp Config/Local.xcconfig.example Config/Local.xcconfig   # once; set DEVELOPMENT_TEAM
make backend-now                                         # its own terminal
make device
```

On a phone, `localhost` is the phone. `make device` builds the app to reach this Mac by its
local network name, `http://<LocalHostName>.local:8080` (`scutil --get LocalHostName`). It
reads the running backend's window hour, writes both into the build, and installs and launches
it on the first connected iPhone (`PARKING_DEVICE=<id>` to pick another).

**Building from Xcode instead.** Run `make device-config` first, then choose the iPhone as
the destination and press Run. Xcode passes nothing on the command line, so the address and
hour come from `Config/Device.xcconfig`, which `make device-config` (and `make device`) writes.
It applies to device builds only, so the simulator stays on `localhost`. Rerun it whenever the
backend restarts at another hour; if Xcode still shows the old value, clean the build folder
(⇧⌘K) once.

Why it is built in rather than set in the scheme: Xcode's scheme environment only applies when
Xcode launches the app. Opened from the home screen, a device build has no scheme, so the
values come from `Info.plist` instead (`LaunchSettings`). That only happens in debug builds;
release builds read neither, and refuse plaintext regardless.

On the phone:

1. **Allow Local Network access** when asked. Every request fails until you do.
2. **Register a synthetic plate** (`TEST-####`). Face ID is real on a device, so the deposit
   and each reservation prompt.

Requirements and what goes wrong:

| Symptom | Cause |
|---|---|
| "Can't reach the server" | The phone cannot reach the Mac. They must share a network: the same Wi-Fi, or the Mac on the phone's Personal Hotspot. Check `curl http://<name>.local:8080/actuator/health` from the Mac |
| "Can't reach the server" from an Xcode build, but `make device` works | `Config/Device.xcconfig` is missing: run `make device-config`, then Run again |
| It worked, then fails after a restart of the backend at another hour | The window hour is built in. Run `make device` (or `make device-config` and Run) again |
| Signing error | `DEVELOPMENT_TEAM` is missing or wrong in `Config/Local.xcconfig` |
| Nothing happens on launch | The phone is locked, or has not trusted this Mac |

The transport exception is `NSAllowsLocalNetworking`, which allows plaintext to `.local` names
only. It is the local-development bypass `docs/security.md` describes, not a general one.

## 13. A signed `.ipa`, fastlane, snapshots and the coverage gate

```bash
make ipa                 # archive, export, verify the signature, install on the iPhone
make ipa NO_INSTALL=1    # the same, without installing
make lane LANE=ipa       # the same .ipa, built by fastlane's gym, in .build/fastlane/
```

Both need `DEVELOPMENT_TEAM` in `Config/Local.xcconfig`, and the backend running for the
address and hour they build in (§12). The `.ipa` is archived from **Debug**, deliberately: a
Release build refuses plaintext and ignores the server address, so it would install and then
reach nothing. `make ipa` prints what it verified — signer, profile and provisioned devices,
version and build number, and the server the build points at.

**fastlane.** Homebrew's Ruby (`brew install ruby`), not the system one; `make lane` puts it on
the path and installs the gems pinned in `Gemfile.lock` into `vendor/bundle` on first use. The
lanes other than `ipa` call the Makefile, so `make lane LANE=ci` and `make ci` run the same
checks.

**Snapshots.** `make test` compares 20 views against the PNGs in
`Tests/UnitTests/__Snapshots__/`, recorded on the iOS 26.3 simulator. After a deliberate visual
change, or a new simulator runtime, run `make snapshots-record` and look at every changed
image in the diff before committing it. A failing snapshot attaches the actual image to the
result bundle.

**Coverage gate.** `make test` ends with `scripts/coverage-gate.py`: Domain 90%, Data 85%,
view models 80%. Overall coverage is printed and not gated, because it counts SwiftUI bodies
the unit tests are not meant to reach. Relax a floor for one run with, for example,
`COVERAGE_FLOOR_DATA=80 make test` — and say why in the commit if it stays relaxed.

