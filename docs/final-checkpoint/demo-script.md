# Live demo — 20 minutes

Part B of the final checkpoint. Every step is one command, and every step has a fallback image
in [`images/`](images/) in case something on the day refuses. The rule for the day: **if a step
fails, say so, show the fallback, and move on.** Debugging live costs more than the step is worth.

Accounts made by `scripts/demo.sh` all use the password **`demo-pass`**. Plates are synthetic
(`TEST-####`).

---

## Pre-flight — 30 minutes before

Three terminals, all in the `parking-ios` repository.

| Terminal | Command | Leave it |
|---|---|---|
| 1 | `make backend-now` (backend on `feature/reservation-idempotency`) | Running |
| 2 | `make tls` (the TLS proxy, for the pinning step) | Running |
| 3 | Everything below | Yours |

Then, in terminal 3:

```bash
make lint && make test                   # green before anything is shown
xcrun simctl boot "iPhone 17 Pro"; xcrun simctl boot "iPhone 17 Pro Max"; open -a Simulator
xcodebuild -project Parking.xcodeproj -scheme Parking -derivedDataPath .build/DerivedData \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' build-for-testing   # warm build
./scripts/demo.sh reset
./scripts/demo.sh account TEST-6101          # funded, $100: the main demo account
./scripts/demo.sh account TEST-6102 0        # $0: "not enough balance"
```

- Arrange the two Simulator windows side by side; set the Pro Max to Vietnamese beforehand if
  you want the two-language shot (Settings › General › Language & Region).
- Check CI is green on head: `gh run list --limit 1`.
- If `TEST-6101` is taken by another test's account, `demo.sh` says so; pick another plate.

---

## 1. The board, and the 20:00 moment — 3 min

```bash
./scripts/demo.sh countdown        # the app thinks the window opens next hour
```

Sign in as `TEST-6101` / `demo-pass`. Point at:

- **The countdown** derives from the server's `Date` header, not the phone's clock. Change the
  phone's time and it does not move (ADR-004).
- In the last minute the copy changes to *"Pick a space · opens in"*: a space can be picked
  early, but nothing is sent until the window opens **and** you tap.

```bash
./scripts/demo.sh app              # now against the open window
```

- **All 80 spaces on a 6.1-inch screen** at 44 pt targets, no scrolling: measured off the running
  app by a UI test, in English and Vietnamese.
- *"80 free at last check"*: the count says it is the last poll's, not live.
- Optional: `./scripts/demo.sh app vi` for Vietnamese; dark mode with
  `xcrun simctl ui booted appearance dark`.

Fallback: `images/board-vietnamese.png`, `../screenshots/08-countdown.png`.

---

## 2. The state matrix — 5 min

Still signed in as `TEST-6101`.

| State | How | Point at |
|---|---|---|
| **Win** | Tap *Reserve any space · $10* | Receipt: space, $10, queue position, settle time. (The simulator has no passcode, so re-authentication has nothing to check and passes; a device prompts) |
| **No balance** | Sign out; sign in as `TEST-6102` | The bar says *Add funds to reserve*; nothing is sent |
| **Lot full** | `./scripts/demo.sh fill` | Board fills within a poll; bar says *No spaces left*, disabled |
| **Offline** | `./scripts/demo.sh freeze`, wait ~15 s, then `./scripts/demo.sh thaw` | The board hides rather than show spaces that may be wrong; recovers on its own |
| **Unknown ×3** | `./scripts/demo.sh unknown probablyHeld` (then `ambiguous`, `noEvidence`) | Three different honest sheets, each saying where the $10 stands |

Say for the unknowns: *with the idempotency change these are now rare, only when the server
cannot be reached at all; so they are shown on fakes rather than by breaking the network.*

`./scripts/demo.sh reset` afterwards.

Fallback: `images/race-killed.png` (the no-evidence sheet over the offline board).

---

## 3. The races, verified against the database — 6 min

```bash
make rehearse            # about four minutes; takes over :8080 and restarts it
```

Terminal 1's backend stops when this starts: the rehearsal runs its own, with the window
opened on the current hour. That is expected; leave terminal 1 as it is.

Narrate while it runs; each step prints what the app said and what the database confirms.

1. **Gate:** the backend is started with the window an hour ahead and a reservation must get
   `429 WINDOW_CLOSED`: proof the gate is on, not bypassed.
2. **Won:** *"Space 12 is yours"*; database: booked, balance 90.00.
3. **Lost:** the test selects space 12, a rival books it through the API, then the user
   confirms: exactly the gap the 5 s poll leaves at 20:00. *"Someone was faster"*, uncharged.
4. **Killed:** a database lock holds the reservation inside the server, the backend gets
   `SIGKILL`; the app says *"Still checking"*; after restart nothing was booked or charged.

Mention the last line it prints: a fresh reservation by the same user after the restart gets
`DUPLICATE_REQUEST` — backend defect D11, found by this rehearsal.

Fallback: `images/race-won.png`, `images/race-lost.png`, `images/race-killed.png`.

---

## 4. Two users, one space, the same instant — 4 min

```bash
TRIALS=5 make concurrent
```

1. **API:** two users released from a barrier microseconds apart, five trials; always one winner.
2. **App:** both simulators sign in, select space 12, and tap Confirm together about 90 s after
   launch. Watch the two windows: one *"is yours"*, one *"someone was faster"*, and the loser's
   board shows the winner's plate on space 12. The script prints how far apart the taps
   landed (0 ms on the last run) and that the database agrees.

Fallback: `images/concurrent-won.png`, `images/concurrent-lost.png`.

---

## 5. A wrong certificate pin — 2 min

```bash
make pinning-demo        # needs terminal 2's make tls
```

Three cases through the real TLS proxy: the right pin reaches the backend (its own "incorrect
password" comes back); a wrong pin is refused in the handshake, and the proxy's access log
shows no request at all; a stale pin plus the CA's backup pin still connects, as after a
key rotation.

Fallback: `images/pinning-refused.png`.

---

## If time allows — the real iPhone

`make device-config`, then Run in Xcode onto the phone (or `make device`), and mirror it with
QuickTime (File › New Movie Recording, choose the iPhone as the camera). On a device Face ID is
real: the deposit and each reservation prompt, and the prompt names the amount.

---

## After the demo

`./scripts/demo.sh reset`. The rehearsals leave the backend on the current hour with the gate
on; that is the state to leave it in for questions.
