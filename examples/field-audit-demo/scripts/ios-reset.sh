#!/usr/bin/env bash
# Return the simulator app to "audit not synced yet": stop it, drop the plugin
# queue database, its settings, the WebView storage and the delivered
# notifications. Photos stay.
set -euo pipefail
source "$(dirname "$0")/env.sh"
UDID=$(ios_sim_udid)
xcrun simctl terminate "$UDID" "$APP_ID" 2>/dev/null || true
DATA=$(xcrun simctl get_app_container "$UDID" "$APP_ID" data)
rm -f "$DATA/Library/Application Support/bg_sync.db"*
rm -rf "$DATA/Library/WebKit" "$DATA/Library/Caches"
xcrun simctl spawn "$UDID" defaults delete "$APP_ID" >/dev/null 2>&1 || true
echo "Simulator reset ($APP_ID on $UDID)"
