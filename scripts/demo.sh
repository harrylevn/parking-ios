#!/usr/bin/env bash
# One-line commands for the live demo's interface segment (docs/final-checkpoint/demo-script.md).
# Each puts one state on the simulator screen, against the real backend unless it says fakes.
#
#   ./demo.sh app [vi]            build if needed, install and launch against the backend
#   ./demo.sh account PLATE [$]   register PLATE (default $100; 0 for "not enough balance")
#   ./demo.sh fill                fill all 80 spaces with other users ("no spaces left")
#   ./demo.sh reset               empty the board and reservations; accounts are kept
#   ./demo.sh unknown KIND        an uncertain outcome, on in-process fakes:
#                                 probablyHeld | ambiguous | noEvidence
#   ./demo.sh countdown           launch with the window an hour ahead: the countdown on screen
#   ./demo.sh freeze | thaw       suspend or resume the backend: the offline state, then recovery
#
# Simulator: DEMO_SIM (default "iPhone 17 Pro", newest runtime). Password for every account
# made here: demo-pass.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIM="${DEMO_SIM:-iPhone 17 Pro}"
API="http://localhost:8080"
PASSWORD="demo-pass"
APP="$ROOT/.build/DerivedData/Build/Products/Debug-iphonesimulator/Parking.app"

sql() { docker exec parking-postgres psql -U postgres -d parking -tAc "$1"; }
token_of() { python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])'; }
backend_up() { curl -sf -o /dev/null "$API/actuator/health" || { echo "Backend is not up: make backend-now" >&2; exit 1; }; }
window_hour() {
  local hour; hour="$(ps -o command= -p "$(lsof -tnP -iTCP:8080 -sTCP:LISTEN | head -1)" | grep -oE 'window-hour=[0-9]+' | cut -d= -f2)"
  echo "${hour:-20}"
}

udid() {
  xcrun simctl list devices available -j | python3 -c "
import json, sys
name = sys.argv[1]
devices = json.load(sys.stdin)['devices']
runtimes = sorted((r for r in devices if 'iOS' in r), key=lambda r: [int(x) for x in r.split('iOS-')[-1].split('-')])
for runtime in reversed(runtimes):
    for device in devices[runtime]:
        if device['name'] == name:
            print(device['udid']); sys.exit()
" "$SIM"
}

install() {
  local device="$1"
  [[ -d "$APP" ]] || make -C "$ROOT" build > /dev/null
  xcrun simctl boot "$device" 2>/dev/null || true
  open -a Simulator
  xcrun simctl terminate "$device" com.vncdc.parking 2>/dev/null || true
  xcrun simctl install "$device" "$APP"
}

account() {  # plate [amount] -> prints the plate
  local plate="$1" amount="${2:-100}" token
  token="$(curl -sf -X POST "$API/auth/register" -H 'Content-Type: application/json' \
    -d "{\"licensePlate\":\"$plate\",\"password\":\"$PASSWORD\"}" | token_of 2>/dev/null)" \
    || token="$(curl -sf -X POST "$API/auth/login" -H 'Content-Type: application/json' \
    -d "{\"licensePlate\":\"$plate\",\"password\":\"$PASSWORD\"}" | token_of 2>/dev/null)" \
    || { echo "$plate exists with another password; pick another plate" >&2; return 1; }  # return: exit would skip a caller's || true inside $(…)
  if [[ "$amount" != 0 ]]; then
    curl -sf -o /dev/null -X POST "$API/wallet/deposit" -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $token" -d "{\"amount\":$amount}"
  fi
  echo "$token"
}

case "${1:-}" in
  app)
    backend_up
    device="$(udid)"; install "$device"
    hour="$(window_hour)"
    args=()
    [[ "${2:-}" == vi ]] && args=(-AppleLanguages "(vi)" -AppleLocale vi_VN)
    SIMCTL_CHILD_PARKING_WINDOW_HOUR="$hour" xcrun simctl launch "$device" com.vncdc.parking ${args[@]+"${args[@]}"} > /dev/null  # bash 3.2: an empty array is "unbound" under set -u
    echo "App on $SIM against the backend, window hour $hour. Password for demo accounts: $PASSWORD"
    ;;
  account)
    backend_up
    [[ -n "${2:-}" ]] || { echo "usage: $0 account TEST-#### [amount]" >&2; exit 2; }
    account "$2" "${3:-100}" > /dev/null
    echo "$2 / $PASSWORD, balance $(sql "SELECT balance FROM users WHERE license_plate='$2';")"
    ;;
  fill)
    backend_up
    # TEST-9### rivals, one space each, until the lot is full.
    n=0
    while (( $(sql "SELECT count(*) FROM reservations WHERE reservation_date = CURRENT_DATE + 1;") < 80 && n < 999 )); do
      token="$(account "$(printf 'TEST-9%03d' "$n")" 20 2>/dev/null || true)"; n=$(( n + 1 ))
      [[ -n "$token" ]] || continue
      curl -s -o /dev/null -X POST "$API/reservations" -H 'Content-Type: application/json' \
        -H "Authorization: Bearer $token" -d '{}'
    done
    echo "Lot: $(sql "SELECT count(*) FROM reservations WHERE reservation_date = CURRENT_DATE + 1;") of 80 taken"
    ;;
  reset)
    docker exec parking-redis redis-cli FLUSHALL > /dev/null
    sql "TRUNCATE reservations, transactions RESTART IDENTITY CASCADE;
         UPDATE spaces SET user_id=NULL, plate_last3=NULL, reserved_date=NULL, version=0;" > /dev/null
    echo "Board empty; accounts kept."
    ;;
  countdown)
    # The app's own window hour, an hour ahead. The backend is untouched, so reservations would
    # still be refused by it; this is for showing the countdown, not for reserving.
    backend_up
    device="$(udid)"; install "$device"
    ahead=$(( $(date +%-H) + 1 ))
    SIMCTL_CHILD_PARKING_WINDOW_HOUR="$ahead" xcrun simctl launch "$device" com.vncdc.parking > /dev/null
    echo "App on $SIM counting down to $ahead:00. Relaunch with: $0 app"
    ;;
  freeze|thaw)
    pid="$(lsof -tnP -iTCP:8080 -sTCP:LISTEN | head -1)"
    [[ -n "$pid" ]] || { echo "Backend is not running" >&2; exit 1; }
    if [[ "$1" == freeze ]]; then
      kill -STOP "$pid"
      echo "Backend suspended: the board goes offline within a poll plus the 10 s timeout. $0 thaw to resume."
    else
      kill -CONT "$pid"
      echo "Backend resumed: the board recovers on the next poll."
    fi
    ;;
  unknown)
    case "${2:-}" in probablyHeld|ambiguous|noEvidence) ;; *) echo "usage: $0 unknown probablyHeld|ambiguous|noEvidence" >&2; exit 2 ;; esac
    device="$(udid)"; install "$device"
    xcrun simctl launch "$device" com.vncdc.parking -UITestMode -UITestSkipReauth -UITestOutcome "$2" > /dev/null
    echo "Fakes, outcome $2: sign in with any plate and password, pick a space, confirm."
    ;;
  *)
    sed -n '2,15p' "$0"; exit 2 ;;
esac
