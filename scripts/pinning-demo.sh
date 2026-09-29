#!/usr/bin/env bash
# The certificate pinning demo: the app against the real backend through the TLS proxy, once
# with the proxy's pin and once with a wrong one. Needs `make backend` (or backend-now) and
# `make tls` running in their own terminals. See docs/security.md.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIM="${PINNING_SIM:-iPhone 17 Pro}"

curl -sf -o /dev/null http://localhost:8080/actuator/health \
  || { echo "backend is not up on :8080: run make backend-now first" >&2; exit 1; }
curl -sf -o /dev/null --cacert "$ROOT/.tls/ca.pem" https://localhost:8443/actuator/health \
  || { echo "TLS proxy is not up on :8443: run make tls first" >&2; exit 1; }

PIN="$("$ROOT/scripts/tls-proxy.sh" pin)"
CA_PIN="$(openssl x509 -in "$ROOT/.tls/ca.pem" -pubkey -noout | openssl pkey -pubin -outform der \
  | openssl dgst -sha256 -binary | openssl enc -base64)"

# The simulator the tests run on must trust the local CA, and xcodebuild picks the newest
# runtime's device for a name, so resolve that same device here rather than trust `booted`.
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
[[ -n "$UDID" ]] || { echo "no simulator named $SIM" >&2; exit 1; }
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl keychain "$UDID" add-root-cert "$ROOT/.tls/ca.pem"
echo "==> $SIM ($UDID) trusts the local CA; pin $PIN"

cd "$ROOT"
TEST_RUNNER_PINNING_DEMO=1 TEST_RUNNER_PINNING_PIN="$PIN" TEST_RUNNER_PINNING_CA_PIN="$CA_PIN" \
  xcodebuild -project Parking.xcodeproj -scheme Parking \
    -destination "id=$UDID" -derivedDataPath .build/DerivedData \
    -resultBundlePath ".build/DerivedData/pinning-demo-$(date +%s).xcresult" \
    -only-testing:ParkingUITests/PinningDemoUITests test
