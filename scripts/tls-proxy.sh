#!/usr/bin/env bash
# Terminate TLS in front of the plaintext backend, so certificate pinning has something real
# to pin. Feeds docs/security.md and the pinning demo in docs/runbook.md.
#
#   ./tls-proxy.sh          https://localhost:8443 -> http://localhost:8080, in the foreground
#   ./tls-proxy.sh pin      print the SPKI pin of the current certificate and exit
#   ./tls-proxy.sh rotate   replace the key and certificate (the pin changes), then run
#
# The backend stays untouched: it is read-only under the brief, so TLS is terminated by an
# nginx container rather than by Spring Boot.
#
# Keys and certificates live in .tls/, which is gitignored, and are generated on first run: a
# local root CA and a localhost certificate it issues. They are specific to this machine; only
# the pin, a hash of the server's public key, is ever copied anywhere. The CA is added to the
# booted simulator's trusted roots, so the app validates the chain the normal way first and
# checks the pin on top, which is how pinning works against a certificate from a public CA.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TLS="$ROOT/.tls"
CA="$TLS/ca.pem"
CA_KEY="$TLS/ca.key"
KEY="$TLS/localhost.key"
CERT="$TLS/localhost.pem"
CONF="$TLS/nginx.conf"
PORT="${PARKING_TLS_PORT:-8443}"

pin() {
  # SHA-256 of the DER-encoded SubjectPublicKeyInfo, base64: the same value the app computes
  # from the certificate it is handed (SPKIPin.hash).
  openssl x509 -in "$CERT" -pubkey -noout \
    | openssl pkey -pubin -outform der \
    | openssl dgst -sha256 -binary \
    | openssl enc -base64
}

generate_ca() {
  mkdir -p "$TLS"
  chmod 700 "$TLS"
  # A local root, as a public CA would be: trusted by the simulator, never sent by the server.
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "$CA_KEY" -out "$CA" -days 3650 \
    -subj "/CN=Parking local development CA" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
  chmod 600 "$CA_KEY"
  echo "==> generated a local root CA in .tls/"
}

generate_leaf() {
  # P-256 because it is what a current production certificate would use, and the app's SPKI
  # encoding is written for it. A new leaf means a new key, so a new pin: that is rotation.
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "$KEY" -out "$TLS/localhost.csr" -subj "/CN=localhost" 2>/dev/null
  openssl x509 -req -in "$TLS/localhost.csr" -CA "$CA" -CAkey "$CA_KEY" -CAcreateserial \
    -out "$CERT" -days 365 -extfile <(printf '%s\n' \
      "subjectAltName=DNS:localhost,IP:127.0.0.1" \
      "basicConstraints=critical,CA:FALSE" \
      "keyUsage=critical,digitalSignature" \
      "extendedKeyUsage=serverAuth") 2>/dev/null
  rm -f "$TLS/localhost.csr"
  chmod 600 "$KEY"
  echo "==> issued a new localhost certificate"
}

case "${1:-run}" in
  pin)
    [[ -f "$CERT" ]] || { echo "no certificate yet: run make tls first" >&2; exit 1; }
    pin
    exit 0 ;;
  rotate)
    # A new server key under the same CA: still trusted, but the old pin no longer matches.
    rm -f "$KEY" "$CERT" ;;
  run) ;;
  *) echo "usage: $0 [pin|rotate]" >&2; exit 2 ;;
esac

[[ -f "$CA" && -f "$CA_KEY" ]] || generate_ca
[[ -f "$CERT" && -f "$KEY" ]] || generate_leaf

cat > "$CONF" <<EOF
events {}
http {
  server {
    listen 443 ssl;
    server_name localhost;
    ssl_certificate     /etc/nginx/tls/localhost.pem;
    ssl_certificate_key /etc/nginx/tls/localhost.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    location / {
      proxy_pass http://host.docker.internal:8080;
      proxy_set_header Host \$host;
      proxy_pass_request_headers on;
    }
  }
}
EOF

# Every booted simulator, not just one: `simctl ... booted` picks an arbitrary device when
# several are running, which is how a demo ends up refusing a certificate it should trust.
BOOTED=$(xcrun simctl list devices booted 2>/dev/null | grep -oE '[0-9A-F-]{36}' || true)
if [[ -n "$BOOTED" ]]; then
  for device in $BOOTED; do
    xcrun simctl keychain "$device" add-root-cert "$CA" >/dev/null 2>&1 \
      && echo "==> local CA trusted by simulator $device" \
      || echo "==> could not add the local CA to simulator $device"
  done
else
  echo "==> no booted simulator: boot one, then run make tls again to trust the local CA"
fi

echo "==> pin (put this in PARKING_SPKI_PINS in the scheme):"
echo "    $(pin)"
echo "==> https://localhost:$PORT -> http://localhost:8080  (Ctrl+C to stop)"

colima status >/dev/null 2>&1 || colima start --cpu 4 --memory 6 --disk 40
exec docker run --rm --name parking-tls \
  -p "$PORT:443" \
  --add-host=host.docker.internal:host-gateway \
  -v "$TLS/localhost.pem:/etc/nginx/tls/localhost.pem:ro" \
  -v "$TLS/localhost.key:/etc/nginx/tls/localhost.key:ro" \
  -v "$CONF:/etc/nginx/nginx.conf:ro" \
  nginx:alpine
