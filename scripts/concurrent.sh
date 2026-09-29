#!/usr/bin/env bash
# Two users confirming the same space at the same time, checked two ways:
#
#   1. The API, precisely: scripts/concurrent-reserve.py releases both reservations from a
#      barrier, microseconds apart, for many trials.
#   2. The app, for real: two simulators, each signed in as a different user with space 12
#      selected, tap Confirm at an agreed instant (RehearsalUITests.testConfirmAtTheSameMoment).
#      One app must say the space is yours, the other that someone was faster, and the
#      database must agree.
#
#   ./concurrent.sh [trials]      default 20 API trials, then one two-device run
#
# Needs the backend up with the reservation window open (make backend-now). Unlike the
# rehearsals it does not take the backend over; Postgres and Redis are reset between runs.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRIALS="${1:-20}"
SIM_A="${CONCURRENT_SIM_A:-iPhone 17 Pro}"
SIM_B="${CONCURRENT_SIM_B:-iPhone 17 Pro Max}"
OUT="$ROOT/.build/concurrent"
API="http://localhost:8080"
PASSWORD="concurrent-pass"
LEAD_SECONDS=90
# How long each device keeps its result on screen before XCTest closes the app.
HOLD_SECONDS="${CONCURRENT_HOLD_SECONDS:-30}"
mkdir -p "$OUT"

say() { printf '\n==> %s\n' "$*"; }
fail() { printf '\nCONCURRENT CHECK FAILED: %s\n' "$*" >&2; exit 1; }
sql() { docker exec parking-postgres psql -U postgres -d parking -tAc "$1"; }
token_of() { python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])'; }

curl -sf -o /dev/null "$API/actuator/health" || fail "the backend is not up: make backend-now"
HOUR="$(ps -o command= -p "$(lsof -tnP -iTCP:8080 -sTCP:LISTEN | head -1)" | grep -oE 'window-hour=[0-9]+' | cut -d= -f2)"
HOUR="${HOUR:-20}"

say "API: $TRIALS trials of two users released together"
python3 "$ROOT/scripts/concurrent-reserve.py" "$TRIALS"

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
" "$1"
}
UDID_A="$(udid "$SIM_A")"; UDID_B="$(udid "$SIM_B")"
[[ -n "$UDID_A" && -n "$UDID_B" ]] || fail "need simulators named $SIM_A and $SIM_B"
xcrun simctl boot "$UDID_A" 2>/dev/null || true
xcrun simctl boot "$UDID_B" 2>/dev/null || true
# Both devices on screen, so the race can be watched.
open -a Simulator

say "app: building once for both simulators"
xcodebuild -project "$ROOT/Parking.xcodeproj" -scheme Parking -derivedDataPath "$ROOT/.build/DerivedData" \
  -destination "id=$UDID_A" -destination "id=$UDID_B" build-for-testing > "$OUT/build.log" 2>&1 \
  || fail "build failed; see $OUT/build.log"

docker exec parking-redis redis-cli FLUSHALL >/dev/null
sql "TRUNCATE reservations, transactions RESTART IDENTITY CASCADE;
     UPDATE spaces SET user_id=NULL, plate_last3=NULL, reserved_date=NULL, version=0;" >/dev/null
account() {  # a fresh TEST-5### account with $100 -> its plate
  local plate
  while :; do
    plate="$(printf 'TEST-5%03d' $(( RANDOM % 1000 )))"
    [[ "$(sql "SELECT count(*) FROM users WHERE license_plate='$plate';")" == 0 ]] && break
  done
  local token; token="$(curl -sf -X POST "$API/auth/register" -H 'Content-Type: application/json' \
    -d "{\"licensePlate\":\"$plate\",\"password\":\"$PASSWORD\"}" | token_of)"
  curl -sf -o /dev/null -X POST "$API/wallet/deposit" -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $token" -d '{"amount":100}'
  echo "$plate"
}
PLATE_A="$(account)"; PLATE_B="$(account)"
while [[ "$PLATE_B" == "$PLATE_A" ]]; do PLATE_B="$(account)"; done

TAP_AT=$(( $(date +%s) + LEAD_SECONDS ))
say "app: $PLATE_A on $SIM_A and $PLATE_B on $SIM_B confirm space 12 at $(date -r "$TAP_AT" '+%H:%M:%S')"
echo "    watch the two Simulator windows; each result stays on screen for ${HOLD_SECONDS} s"

run_device() {  # udid plate log
  TEST_RUNNER_REHEARSAL=concurrent TEST_RUNNER_REHEARSAL_PLATE="$2" TEST_RUNNER_REHEARSAL_PASSWORD="$PASSWORD" \
  TEST_RUNNER_REHEARSAL_WINDOW_HOUR="$HOUR" TEST_RUNNER_REHEARSAL_TAP_AT="$TAP_AT" \
  TEST_RUNNER_REHEARSAL_HOLD_SECONDS="$HOLD_SECONDS" \
    xcodebuild -project "$ROOT/Parking.xcodeproj" -scheme Parking -derivedDataPath "$ROOT/.build/DerivedData" \
      -destination "id=$1" -resultBundlePath "$OUT/$2-$(date +%s).xcresult" \
      -only-testing:ParkingUITests/RehearsalUITests/testConfirmAtTheSameMoment \
      test-without-building > "$3" 2>&1
}
run_device "$UDID_A" "$PLATE_A" "$OUT/device-a.log" & a=$!
run_device "$UDID_B" "$PLATE_B" "$OUT/device-b.log" & b=$!
status=0
wait "$a" || status=1
wait "$b" || status=1

line_a="$(grep -o 'CONCURRENT outcome=[a-z]* tapStarted=[0-9.]* tapReturned=[0-9.]*' "$OUT/device-a.log" | head -1 || true)"
line_b="$(grep -o 'CONCURRENT outcome=[a-z]* tapStarted=[0-9.]* tapReturned=[0-9.]*' "$OUT/device-b.log" | head -1 || true)"
[[ -n "$line_a" && -n "$line_b" ]] || fail "a device did not report (see $OUT/device-a.log and device-b.log)"
(( status == 0 )) || fail "a device's test failed (see $OUT/device-*.log)"

python3 - "$line_a" "$line_b" "$PLATE_A" "$PLATE_B" <<'EOF'
import sys
def parse(line):
    fields = dict(part.split("=") for part in line.split()[1:])
    return fields["outcome"], float(fields["tapStarted"]), float(fields["tapReturned"])
(oa, sa, ra), (ob, sb, rb) = parse(sys.argv[1]), parse(sys.argv[2])
print(f"    {sys.argv[3]}: {oa:4s} tap {sa:.3f}-{ra:.3f}")
print(f"    {sys.argv[4]}: {ob:4s} tap {sb:.3f}-{rb:.3f}")
print(f"    the two taps started {abs(sa - sb) * 1000:.0f} ms apart and returned {abs(ra - rb) * 1000:.0f} ms apart")
EOF

outcome() { grep -o 'outcome=[a-z]*' <<< "$1" | cut -d= -f2; }
oa="$(outcome "$line_a")"; ob="$(outcome "$line_b")"
[[ "$oa$ob" == "wonlost" || "$oa$ob" == "lostwon" ]] || fail "expected one win and one loss, got $oa and $ob"
winner="$PLATE_A"; loser="$PLATE_B"
[[ "$oa" == lost ]] && { winner="$PLATE_B"; loser="$PLATE_A"; }
holder="$(sql "SELECT u.license_plate FROM spaces s JOIN users u ON u.id=s.user_id WHERE s.space_number=12;")"
[[ "$holder" == "$winner" ]] || fail "the app said $winner won, but the database says space 12 is ${holder:-nobody}'s"
[[ "$(sql "SELECT count(*) FROM reservations;")" == 1 ]] || fail "more than one reservation was made"
[[ "$(sql "SELECT balance FROM users WHERE license_plate='$winner';")" == 90.00 ]] || fail "the winner was not charged exactly \$10"
[[ "$(sql "SELECT balance FROM users WHERE license_plate='$loser';")" == 100.00 ]] || fail "the loser was charged"
echo "    database: space 12 is $winner's, one reservation, $winner 90.00, $loser 100.00"

# Each device's result, as a PNG, for slides and the record.
SHOTS="$OUT/screens-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$SHOTS"
for plate in "$PLATE_A" "$PLATE_B"; do
  bundle="$(ls -td "$OUT/$plate"-*.xcresult | head -1)"
  python3 "$ROOT/scripts/export-screenshots.py" "$bundle" "$SHOTS" "$plate" concurrent- | sed 's/^/    screenshot: /'
done

say "passed: one winner, one \"someone was faster\", and the database agrees with both apps"
