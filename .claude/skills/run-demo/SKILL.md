---
name: run-demo
description: Launch the Parking app in the iOS Simulator against the live local backend, with the reservation gate on and the app's window hour matching the backend's. Use when asked to run, demo, or screenshot the real app.
disable-model-invocation: true
---

# Run the app against the live backend

The easy mistake is a backend and an app that disagree about the window hour. The quiet
mistake is a backend with the gate bypassed, which looks like a working one until someone
reserves outside the window. This sequence prevents both.

## 1. Backend

- Check that the backend is cloned at `${PARKING_BACKEND:-../parking-reservation}` and that
  `git -C <that path> branch --show-current` is `feature/reservation-idempotency`, the branch
  the app is built against (ADR-007). `master` also works, but only with
  `PARKING_IDEMPOTENCY_KEYS=0` in the app's environment. If it is `main`, stop and tell the
  user: `main` holds a LICENSE and nothing else.
- Run `make backend-health`.
  - **Up already:** you cannot tell which window hour it was started with. Ask the user.
  - **Down:** start `make backend-now` with `run_in_background` (it runs in the
    foreground and never exits). Record `date +%-H` as the window hour. Wait for health
    with Monitor, not a sleep loop. The first start takes a minute or two for Maven. If the
    background task exits, read its output and report. Do not retry blindly.
- Never use `make backend-off` unless the user asks for the bypassed gate by name, and say
  that the race code is untested in that mode. Never run `make backend-reset` without
  confirmation, because it truncates the reservations.

## 2. App

Run `make build`, then this as **one** Bash call, because shell variables do not survive
between calls:

```bash
# Resolve one iPhone 17 Pro by UDID, preferring one already booted. The trailing ` \(`
# excludes "iPhone 17 Pro Max".
UUID_RE='[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}'
UDID=$(xcrun simctl list devices booted | grep -E '^ +iPhone 17 Pro \(' | head -1 | grep -oE "$UUID_RE")
[ -n "$UDID" ] || UDID=$(xcrun simctl list devices available | grep -E '^ +iPhone 17 Pro \(' | head -1 | grep -oE "$UUID_RE")
[ -n "$UDID" ] || { echo "no iPhone 17 Pro simulator installed"; exit 1; }
echo "UDID=$UDID"

xcrun simctl boot "$UDID" 2>/dev/null || true   # already booted is fine
open -a Simulator
xcrun simctl install "$UDID" .build/DerivedData/Build/Products/Debug-iphonesimulator/Parking.app
SIMCTL_CHILD_PARKING_WINDOW_HOUR=<hour> xcrun simctl launch --terminate-running-process "$UDID" com.vncdc.parking
sleep 3; xcrun simctl io "$UDID" screenshot <scratchpad>/run-demo.png
```

**Never target `booted`.** When several simulators are booted, which is normal after
`make screenshots` (it boots the iPhone and the iPad), `booted` picks one of them
unpredictably. It has picked the iPad, so the app launched there and the screenshot was of
the wrong device. Every command above uses the same UDID so install, launch and screenshot
all hit the same simulator.

`SIMCTL_CHILD_` passes the variable into the app's environment. That makes
`AppEnvironment.live` read the same hour the backend was given, without editing the scheme.

Do not pass `-UITestMode` or `-UITestSkipReauth`. They swap in fakes and stand down Face ID,
and the point of this skill is the real stack.

## 3. Confirm

Read the screenshot the block above wrote. If it is not phone-shaped (for example
2064×2752 is the iPad), the wrong device was targeted: stop and report it rather than
describing the screen. Report:
- backend state (gate on, window hour)
- the simulator name and UDID the app was launched on
- the hour passed to the app
- what the screen shows

## Data

Accounts and plates are synthetic: plates are `TEST-####`. If a login or registration is
needed, invent one in that form. Never type anything resembling real customer data.
