#!/usr/bin/env bash
# A signed .ipa, exported and installed on the connected iPhone (docs/runbook.md §13).
#
#   ./ipa.sh              archive, export, verify the signature, install
#   ./ipa.sh --no-install archive, export and verify only
#
# Archived from the Debug configuration on purpose. A Release build refuses plaintext and
# ignores the server address a debug build reads, so a Release .ipa installs and then cannot
# reach the local backend at all; there is no production server to point it at. Signed for
# development with the team in Config/Local.xcconfig. CI keeps its own unsigned Release archive
# (make archive): signing credentials on a CI runner would be a security question of its own.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/.build/ipa"
ARCHIVE="$OUT/Parking.xcarchive"

# awk, not sed: BSD sed has no \s, and a leading space in the team makes the export look for
# a team that does not exist.
TEAM="$(awk -F= '/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' \
  "$ROOT/Config/Local.xcconfig" 2>/dev/null)"
[[ -n "$TEAM" && "$TEAM" != YOUR_TEAM_ID ]] || {
  echo "Set DEVELOPMENT_TEAM in Config/Local.xcconfig (see Config/Local.xcconfig.example)." >&2
  exit 1
}

# The Mac's address and the backend's hour, into the build (Config/Device.xcconfig).
"$ROOT/scripts/device.sh" --config-only

rm -rf "$OUT"; mkdir -p "$OUT"
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>debugging</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>compileBitcode</key><false/>
  <key>thinning</key><string>&lt;none&gt;</string>
</dict>
</plist>
PLIST

BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD)"
echo "==> archiving (Debug, build $BUILD_NUMBER, team $TEAM)"
xcodebuild -project "$ROOT/Parking.xcodeproj" -scheme Parking -configuration Debug \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" -allowProvisioningUpdates \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" archive > "$OUT/archive.log" 2>&1 \
  || { grep -E "error:" "$OUT/archive.log" | head -5; echo "Archive failed; see $OUT/archive.log" >&2; exit 1; }

echo "==> exporting a development-signed .ipa"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -allowProvisioningUpdates > "$OUT/export.log" 2>&1 \
  || { grep -E "error:" "$OUT/export.log" | head -5; echo "Export failed; see $OUT/export.log" >&2; exit 1; }
IPA="$OUT/Parking.ipa"
[[ -f "$IPA" ]] || { echo "No .ipa produced; see $OUT/export.log" >&2; exit 1; }

echo "==> verifying"
CHECK="$OUT/verify"; rm -rf "$CHECK"; mkdir -p "$CHECK"
unzip -q "$IPA" -d "$CHECK"
APP="$CHECK/Payload/Parking.app"
codesign --verify --deep --strict "$APP"
# To files, not pipes: `codesign … | grep -m1` stops reading at the first match, codesign dies
# of SIGPIPE, and under pipefail the script ended silently here.
codesign -dvv "$APP" > "$CHECK/codesign.txt" 2>&1
AUTHORITY="$(grep '^Authority=' "$CHECK/codesign.txt" | head -1 | cut -d= -f2)"
security cms -D -i "$APP/embedded.mobileprovision" > "$CHECK/profile.plist" 2>/dev/null
PROFILE_NAME="$(plutil -extract Name raw "$CHECK/profile.plist" 2>/dev/null || echo unknown)"
DEVICES="$(plutil -extract ProvisionedDevices raw "$CHECK/profile.plist" 2>/dev/null || echo 0)"
echo "    $(du -h "$IPA" | cut -f1) $IPA"
echo "    signed by: $AUTHORITY"
echo "    profile:   $PROFILE_NAME ($DEVICES provisioned device(s))"
echo "    version:   $(plutil -extract CFBundleShortVersionString raw "$APP/Info.plist") ($(plutil -extract CFBundleVersion raw "$APP/Info.plist"))"
echo "    server:    $(plutil -extract PARKING_BASE_URL raw "$APP/Info.plist")"

[[ "${1:-}" == --no-install ]] && exit 0
DEVICES_JSON="$(mktemp)"
xcrun devicectl list devices --json-output "$DEVICES_JSON" > /dev/null 2>&1 || true
DEVICE="${PARKING_DEVICE:-$(python3 -c '
import json, sys
for device in json.load(open(sys.argv[1]))["result"]["devices"]:
    if (device.get("hardwareProperties", {}).get("deviceType") == "iPhone"
            and device.get("connectionProperties", {}).get("tunnelState") == "connected"):
        print(device["identifier"]); break
' "$DEVICES_JSON")}"
rm -f "$DEVICES_JSON"
[[ -n "$DEVICE" ]] || { echo "No connected iPhone: the .ipa is at $IPA" >&2; exit 0; }
echo "==> installing the .ipa on $DEVICE"
xcrun devicectl device install app --device "$DEVICE" "$IPA" > /dev/null
echo "    installed; open Parking on the phone"
