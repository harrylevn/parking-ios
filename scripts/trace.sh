#!/usr/bin/env bash
# An Instruments trace of the app on the board, first idle under the 5-second poll and then
# while 150 other users race for the 80 spaces (plan, day 9: evidence for the Q&A). Needs the
# backend up with the window open, as `make rehearse` or `make backend-now` leaves it.

set -euo pipefail
trap 'echo "trace.sh failed at line $LINENO: $BASH_COMMAND" >&2' ERR

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIM="${REHEARSAL_SIM:-iPhone 17 Pro}"
OUT="$ROOT/.build/trace"
API="http://localhost:8080"
PASSWORD="rehearsal-pass"
RIVALS="${TRACE_RIVALS:-150}"
RECORD_SECONDS=40
mkdir -p "$OUT"

say() { printf '\n==> %s\n' "$*"; }
sql() { docker exec parking-postgres psql -U postgres -d parking -tAc "$1"; }
token_of() { python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])'; }

curl -sf -o /dev/null "$API/actuator/health" || { echo "backend is not up: run make backend-now" >&2; exit 1; }
HOUR="$(ps -o command= -p "$(lsof -tnP -iTCP:8080 -sTCP:LISTEN | head -1)" | grep -oE 'window-hour=[0-9]+' | cut -d= -f2)"
HOUR="${HOUR:-$(date +%-H)}"

say "reset, and $RIVALS funded rivals plus the demo account"
docker exec parking-redis redis-cli FLUSHALL >/dev/null
sql "TRUNCATE reservations, transactions RESTART IDENTITY CASCADE;
     UPDATE spaces SET user_id=NULL, plate_last3=NULL, reserved_date=NULL, version=0;" >/dev/null
# TEST-8### accounts. They persist between runs, so an existing one is signed in to rather than
# registered again; one that belongs to another test (the screenshot tests register random
# TEST-#### plates with their own password) is skipped.
account() {  # plate -> token, or nothing
  curl -sf -X POST "$API/auth/register" -H 'Content-Type: application/json' \
      -d "{\"licensePlate\":\"$1\",\"password\":\"$PASSWORD\"}" 2>/dev/null | token_of 2>/dev/null \
    || curl -sf -X POST "$API/auth/login" -H 'Content-Type: application/json' \
      -d "{\"licensePlate\":\"$1\",\"password\":\"$PASSWORD\"}" 2>/dev/null | token_of 2>/dev/null \
    || true
}
: > "$OUT/rivals.tokens"
n=0
while (( $(wc -l < "$OUT/rivals.tokens") < RIVALS && n < 999 )); do
  token="$(account "$(printf 'TEST-8%03d' "$n")")"; n=$(( n + 1 ))
  [[ -n "$token" ]] || continue
  curl -sf -o /dev/null -X POST "$API/wallet/deposit" -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $token" -d '{"amount":20}'
  echo "$token" >> "$OUT/rivals.tokens"
done
n=999
until [[ -n "$(account "$(printf 'TEST-8%03d' "$n")")" ]]; do n=$(( n - 1 )); done
PLATE="$(printf 'TEST-8%03d' "$n")"

UDID="$(xcrun simctl list devices available -j | python3 -c "
import json, sys
name = sys.argv[1]
devices = json.load(sys.stdin)['devices']
runtimes = sorted((r for r in devices if 'iOS' in r), key=lambda r: [int(x) for x in r.split('iOS-')[-1].split('-')])
for runtime in reversed(runtimes):
    for device in devices[runtime]:
        if device['name'] == name:
            print(device['udid']); sys.exit()
" "$SIM")"

say "app on the board ($SIM)"
TEST_RUNNER_REHEARSAL=trace TEST_RUNNER_REHEARSAL_PLATE="$PLATE" TEST_RUNNER_REHEARSAL_PASSWORD="$PASSWORD" \
TEST_RUNNER_REHEARSAL_WINDOW_HOUR="$HOUR" TEST_RUNNER_REHEARSAL_TRACE_SECONDS=$(( RECORD_SECONDS + 15 )) \
  xcodebuild -project "$ROOT/Parking.xcodeproj" -scheme Parking -destination "id=$UDID" \
    -derivedDataPath "$ROOT/.build/DerivedData" \
    -only-testing:ParkingUITests/RehearsalUITests/testSitOnTheBoardForATrace test > "$OUT/driver.log" 2>&1 &
driver=$!

# Let the sign-in finish, so the trace is of the board and not of the login screen.
until grep -q 'Waiting 20.0s for "space.12" Button to exist' "$OUT/driver.log" 2>/dev/null; do
  kill -0 "$driver" 2>/dev/null || { echo "the UI test driver stopped early; see $OUT/driver.log" >&2; exit 1; }
  sleep 0.5
done
sleep 4
# Found now, after sign-in: the test relaunches the app, so a process seen earlier may be gone.
pid="$(xcrun simctl spawn "$UDID" launchctl list 2>/dev/null | awk '/UIKitApplication:com\.vncdc\.parking\[/ && $1 != "-" {print $1}' | tail -1)"
[[ -n "$pid" ]] || { echo "the app is not running" >&2; exit 1; }

TRACE="$OUT/board-$(date +%Y%m%d-%H%M%S).trace"
say "recording $RECORD_SECONDS s: idle on the poll, then the race at +20 s"
xcrun xctrace record --template 'Time Profiler' --device "$UDID" --attach "$pid" \
  --time-limit "${RECORD_SECONDS}s" --output "$TRACE" > "$OUT/xctrace.log" 2>&1 &
recorder=$!
sleep 20
say "race: $RIVALS rivals reserve at once"
# TOKEN, not {}: -I replaces every occurrence, and the JSON body is itself "{}". -S because
# macOS xargs caps a replacement at 255 bytes, and a JWT is about 600.
xargs -P 50 -S 4096 -I TOKEN curl -s -o /dev/null -X POST "$API/reservations" -H 'Content-Type: application/json' \
  -H "Authorization: Bearer TOKEN" -d '{}' < "$OUT/rivals.tokens" || true  # losers are the point
echo "    $(sql "SELECT count(*) FROM reservations;") reservations made"
wait "$recorder" || true
wait "$driver" || true
say "trace: $TRACE"
