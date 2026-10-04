#!/usr/bin/env bash
# Return the device to "audit not synced yet": stop the app, cancel its work,
# drop the plugin queue, WorkManager state and WebView storage. Photos stay.
set -euo pipefail
source "$(dirname "$0")/env.sh"
adb shell cmd connectivity airplane-mode disable >/dev/null 2>&1 || true
adb shell svc wifi enable || true
adb shell svc data enable || true
adb shell am force-stop "$APP_ID"
adb shell "run-as $APP_ID rm -rf databases shared_prefs no_backup app_webview/Default/Local\ Storage"
adb shell cmd notification cancel_all "$APP_ID" >/dev/null 2>&1 || adb shell service call notification 1 >/dev/null 2>&1 || true
echo "Device reset ($APP_ID)"
