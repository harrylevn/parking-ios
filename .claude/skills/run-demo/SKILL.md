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
  `git -C <that path> branch --show-current` is `master`. If it is `main`, stop and tell the
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

```bash
make build
xcrun simctl boot "iPhone 17 Pro" 2>/dev/null || true   # already booted is fine
open -a Simulator
xcrun simctl install booted .build/DerivedData/Build/Products/Debug-iphonesimulator/Parking.app
SIMCTL_CHILD_PARKING_WINDOW_HOUR=<hour> xcrun simctl launch --terminate-running-process booted com.vncdc.parking
```

`SIMCTL_CHILD_` passes the variable into the app's environment. That makes
`AppEnvironment.live` read the same hour the backend was given, without editing the scheme.

Do not pass `-UITestMode` or `-UITestSkipReauth`. They swap in fakes and stand down Face ID,
and the point of this skill is the real stack.

## 3. Confirm

Take `xcrun simctl io booted screenshot <scratchpad>/run-demo.png` and read it. Report:
- backend state (gate on, window hour)
- the hour passed to the app
- what the screen shows

## Data

Accounts and plates are synthetic: plates are `TEST-####`. If a login or registration is
needed, invent one in that form. Never type anything resembling real customer data.
