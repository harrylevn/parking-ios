#!/usr/bin/env bash
# The day-9 rehearsals, end to end and unattended: the gate proved on, then a won race, a lost
# race, and the backend killed mid-reservation. Each drives the real app against the real
# backend (RehearsalUITests) and then checks the database agrees with what the app said.
#
#   ./rehearse.sh            one round
#   ./rehearse.sh 2          two rounds back to back, as the plan requires
#
# It owns the backend while it runs: whatever is on :8080 is stopped, and the backend is
# started from ../parking-reservation, which must be on feature/reservation-idempotency,
# the branch the app is built against. Postgres and Redis are reset before every scenario.
# Accounts are synthetic, registered fresh each time as TEST-7xxx.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${PARKING_BACKEND:-$ROOT/../parking-reservation}"
ROUNDS="${1:-1}"
SIM="${REHEARSAL_SIM:-iPhone 17 Pro}"
OUT="$ROOT/.build/rehearsal"
PASSWORD="rehearsal-pass"
API="http://localhost:8080"
mkdir -p "$OUT"

say() { printf '\n==> %s\n' "$*"; }
fail() { printf '\nREHEARSAL FAILED: %s\n' "$*" >&2; exit 1; }
sql() { docker exec -i parking-postgres psql -U postgres -d parking -tAc "$1"; }

# --- backend -------------------------------------------------------------------------------

stop_backend() {
  pkill -f spring-boot:run 2>/dev/null || true
  for pid in $(lsof -tnP -iTCP:8080 -sTCP:LISTEN 2>/dev/null); do kill "$pid" 2>/dev/null || true; done
  for _ in $(seq 1 30); do lsof -tnP -iTCP:8080 -sTCP:LISTEN >/dev/null 2>&1 || return 0; sleep 1; done
  fail "the backend on :8080 would not stop"
}

start_backend() {
  local hour="$1"
  stop_backend
  "$ROOT/scripts/backend-up.sh" "$hour" > "$OUT/backend-$hour.log" 2>&1 &
  disown  # killing it is part of the rehearsal; bash need not announce it
  for _ in $(seq 1 120); do
    curl -sf -o /dev/null "$API/actuator/health" && return 0
    sleep 1
  done
  fail "the backend did not come up; see $OUT/backend-$hour.log"
}

reset() {
  docker exec parking-redis redis-cli FLUSHALL >/dev/null
  sql "TRUNCATE reservations, transactions RESTART IDENTITY CASCADE;
       UPDATE spaces SET user_id=NULL, plate_last3=NULL, reserved_date=NULL, version=0;" >/dev/null
}

# --- accounts ------------------------------------------------------------------------------

new_plate() {  # a TEST-7### plate not already registered: users survive the per-scenario reset
  local plate
  while :; do
    plate="$(printf 'TEST-7%03d' $(( RANDOM % 1000 )))"
    [[ "$(sql "SELECT count(*) FROM users WHERE license_plate='$plate';")" == 0 ]] && break
  done
  echo "$plate"
}

register() {  # plate -> token
  curl -sf -X POST "$API/auth/register" -H 'Content-Type: application/json' \
    -d "{\"licensePlate\":\"$1\",\"password\":\"$PASSWORD\"}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])'
}

fund() {  # token amount
  curl -sf -o /dev/null -X POST "$API/wallet/deposit" -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $1" -d "{\"amount\":$2}"
}

balance_of() { sql "SELECT balance FROM users WHERE license_plate='$1';"; }
bookings_of() { sql "SELECT count(*) FROM reservations r JOIN users u ON u.id=r.user_id WHERE u.license_plate='$1';"; }
holder_of_space() { sql "SELECT u.license_plate FROM spaces s JOIN users u ON u.id=s.user_id WHERE s.space_number=12;"; }

# --- the app -------------------------------------------------------------------------------

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
[[ -n "$UDID" ]] || fail "no simulator named $SIM"

run_app() {  # scenario test [extra env assignments...]
  local scenario="$1" test="$2"; shift 2
  env TEST_RUNNER_REHEARSAL="$scenario" TEST_RUNNER_REHEARSAL_PLATE="$PLATE" \
      TEST_RUNNER_REHEARSAL_PASSWORD="$PASSWORD" TEST_RUNNER_REHEARSAL_WINDOW_HOUR="$HOUR" "$@" \
    xcodebuild -project "$ROOT/Parking.xcodeproj" -scheme Parking -destination "id=$UDID" \
      -derivedDataPath "$ROOT/.build/DerivedData" \
      -resultBundlePath "$OUT/$scenario-$(date +%s).xcresult" \
      -only-testing:"ParkingUITests/RehearsalUITests/$test" test > "$OUT/$scenario.log" 2>&1
}

# --- rehearsals ----------------------------------------------------------------------------

gate_check() {
  # The window hour is read at start-up, so the gate is proved on a backend started with the
  # window an hour ahead, and the scenarios then run on one started with it open. A backend
  # with the gate bypassed looks identical until something is reserved outside the window.
  local ahead=$(( $(date +%-H) + 1 ))
  say "gate: a reservation outside the window must be refused (window-hour $ahead)"
  start_backend "$ahead"
  reset
  local token; token="$(register "$(new_plate)")"
  local reply; reply="$(curl -s -w ' %{http_code}' -X POST "$API/reservations" \
    -H 'Content-Type: application/json' -H "Authorization: Bearer $token" -d '{}')"
  [[ "$reply" == *'"code":"WINDOW_CLOSED"'*' 429' ]] || fail "gate check: expected 429 WINDOW_CLOSED, got: $reply"
  echo "    429 WINDOW_CLOSED: the gate is on"
  HOUR="$(date +%-H)"
  say "backend with the window open (window-hour $HOUR)"
  start_backend "$HOUR"
}

won() {
  say "won race"
  reset
  PLATE="$(new_plate)"; fund "$(register "$PLATE")" 100
  run_app won testWonRace || fail "won: the app did not show the win (see $OUT/won.log)"
  [[ "$(bookings_of "$PLATE")" == 1 && "$(holder_of_space)" == "$PLATE" ]] \
    || fail "won: the database does not show $PLATE holding space 12"
  [[ "$(balance_of "$PLATE")" == 90.00 ]] || fail "won: balance is $(balance_of "$PLATE"), expected 90.00"
  echo "    app: \"Space 12 is yours\"; database: $PLATE holds space 12, balance 90.00"
}

lost() {
  say "lost race"
  reset
  PLATE="$(new_plate)"; fund "$(register "$PLATE")" 100
  local rival; rival="$(new_plate)"
  while [[ "$rival" == "$PLATE" ]]; do rival="$(new_plate)"; done
  local rival_token; rival_token="$(register "$rival")"; fund "$rival_token" 100
  run_app lost testLostRace TEST_RUNNER_REHEARSAL_RIVAL_TOKEN="$rival_token" \
    || fail "lost: the app did not show the loss (see $OUT/lost.log)"
  [[ "$(holder_of_space)" == "$rival" ]] || fail "lost: space 12 is not the rival's"
  [[ "$(bookings_of "$PLATE")" == 0 && "$(balance_of "$PLATE")" == 100.00 ]] \
    || fail "lost: $PLATE was booked or charged"
  echo "    app: \"Someone was faster\"; database: space 12 is $rival's, $PLATE uncharged at 100.00"
}

killed() {
  say "backend killed mid-reservation"
  reset
  PLATE="$(new_plate)"; fund "$(register "$PLATE")" 100
  local id; id="$(sql "SELECT id FROM users WHERE license_plate='$PLATE';")"

  # Hold this user's row, so the reservation blocks inside its database transaction: the
  # request is genuinely in flight on the server when the backend dies.
  # No -i: in the background, an interactive exec gets no stdin and exits at once, taking the
  # lock with it, and the reservation then simply succeeds.
  docker exec parking-postgres psql -U postgres -d parking -qc \
    "BEGIN; SELECT id FROM users WHERE id=$id FOR UPDATE; SELECT pg_sleep(90); COMMIT;" \
    > /dev/null 2>&1 &
  local holder=$!

  run_app killed testBackendKilledMidReservation &
  local app=$!

  local waited=0
  # Hibernate's pessimistic lock is FOR NO KEY UPDATE, not FOR UPDATE: matching the latter
  # never fired, and the app gave up on its own before the backend was killed.
  until [[ "$(sql "SELECT count(*) FROM pg_stat_activity WHERE wait_event_type='Lock' AND query ILIKE '%from users%for no key update%';")" != 0 ]]; do
    kill -0 "$app" 2>/dev/null || fail "killed: the app finished before its reservation reached the lock (see $OUT/killed.log)"
    sleep 0.2; waited=$(( waited + 1 ))
    (( waited < 600 )) || { kill "$app" "$holder" 2>/dev/null; fail "killed: the reservation never reached the database"; }
  done
  pkill -9 -f 'spring-boot|com.parking.ParkingApplication' 2>/dev/null || true
  for pid in $(lsof -tnP -iTCP:8080 -sTCP:LISTEN 2>/dev/null); do kill -9 "$pid"; done
  echo "    the reservation was waiting in the database; backend killed with SIGKILL"
  sql "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE query LIKE '%pg_sleep(90)%' AND pid <> pg_backend_pid();" >/dev/null
  wait "$holder" 2>/dev/null || true

  wait "$app" || fail "killed: the app did not show the uncertain outcome (see $OUT/killed.log)"
  echo "    app: \"Still checking\", the connection dropped"

  start_backend "$HOUR"
  [[ "$(bookings_of "$PLATE")" == 0 && "$(balance_of "$PLATE")" == 100.00 ]] \
    || fail "killed: $PLATE was booked or charged, so the sheet's promise was untrue"
  echo "    database after restart: nothing booked, balance 100.00, as the sheet said"

  # What a crash leaves in Redis: does this user's per-day guard survive it?
  local token; token="$(curl -sf -X POST "$API/auth/login" -H 'Content-Type: application/json' \
    -d "{\"licensePlate\":\"$PLATE\",\"password\":\"$PASSWORD\"}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')"
  local after; after="$(curl -s -X POST "$API/reservations" -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $token" -d '{}' | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("code") or "OK space %s" % d.get("spaceNumber"))')"
  echo "    a fresh reservation by $PLATE after the restart: $after"
}

say "backend branch: $(git -C "$REPO" branch --show-current)"
[[ "$(git -C "$REPO" branch --show-current)" == feature/reservation-idempotency ]] \
  || fail "check out feature/reservation-idempotency in $REPO (or run the app with PARKING_IDEMPOTENCY_KEYS=0)"

for round in $(seq 1 "$ROUNDS"); do
  say "round $round of $ROUNDS"
  gate_check
  won
  lost
  killed
done
say "all rehearsals passed, $ROUNDS round(s)"
