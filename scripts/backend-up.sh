#!/usr/bin/env bash
# Bring the parking-reservation backend up from nothing. Feeds docs/runbook.md.
#
#   ./backend-up.sh            gate ON, window 20:00 (demo config)
#   ./backend-up.sh 15         gate ON, window shifted to 15:00 (testing)
#   ./backend-up.sh off        gate BYPASSED (shipped default - race code is untested here)
#
# NOTE: -Dapp.reservation.bypass-time-check=false on the mvn command line, as the
# project brief writes it, does NOT reach the application. spring-boot:run forks a
# separate JVM that does not inherit Maven's system properties, so the gate stays
# bypassed and every reservation silently succeeds. It must be passed through
# -Dspring-boot.run.jvmArguments (below) or -Dspring-boot.run.arguments.

set -euo pipefail

REPO="${PARKING_BACKEND:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/parking-reservation}"
export JAVA_HOME="/opt/homebrew/opt/openjdk@21"
export PATH="$JAVA_HOME/bin:/opt/homebrew/bin:$PATH"

case "${1:-20}" in
  off) APP_ARGS="-Dapp.reservation.bypass-time-check=true" ;;
  *)   APP_ARGS="-Dapp.reservation.bypass-time-check=false -Dapp.reservation.window-hour=${1:-20}" ;;
esac

echo "==> container runtime"
colima status >/dev/null 2>&1 || colima start --cpu 4 --memory 6 --disk 40

echo "==> postgres + redis (compose defines no API service)"
docker compose -f "$REPO/backend/docker-compose.yml" up -d

echo "==> waiting for health"
until [ "$(docker inspect -f '{{.State.Health.Status}}' parking-postgres 2>/dev/null)" = healthy ] \
   && [ "$(docker inspect -f '{{.State.Health.Status}}' parking-redis    2>/dev/null)" = healthy ]; do
  sleep 2
done

echo "==> API on :8080 with $APP_ARGS"
cd "$REPO/backend"
exec mvn spring-boot:run -Dspring-boot.run.jvmArguments="$APP_ARGS"
