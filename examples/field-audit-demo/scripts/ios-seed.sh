#!/usr/bin/env bash
# Boot the simulator, install the app and copy the seeded audit photos into
# its Documents dir (Capacitor's Directory.Data on iOS). The simulator's app
# container is a plain folder on the Mac, so this is a file copy.
set -euo pipefail
source "$(dirname "$0")/env.sh"
APP="$DEMO_DIR/app/ios/DerivedData/Build/Products/Debug-iphonesimulator/App.app"
SEED="$DEMO_DIR/seed/out"
[ -d "$SEED/photos" ] || { echo "Run seed/generate_audit.py first"; exit 1; }
[ -d "$APP" ] || { echo "Run scripts/ios-build.sh first"; exit 1; }
UDID=$(ios_sim_udid)
[ -n "$UDID" ] || { echo "No simulator named '$SIM_DEVICE'"; exit 1; }
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
open -a Simulator --args -CurrentDeviceUDID "$UDID"
xcrun simctl install "$UDID" "$APP"
DATA=$(xcrun simctl get_app_container "$UDID" "$APP_ID" data)
DEST="$DATA/Documents/audits/$AUDIT_ID"
rm -rf "$DEST" && mkdir -p "$DEST"
cp -R "$SEED/photos" "$SEED/thumbs" "$DEST/"
n=$(ls "$DEST/photos" | wc -l | tr -d ' ')
size=$(du -sk "$DEST/photos" | awk '{print $1}')
echo "Simulator $UDID has $n photos ($((size / 1024)) MiB) for $AUDIT_ID"
