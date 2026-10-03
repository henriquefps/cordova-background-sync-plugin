#!/usr/bin/env bash
# Install the app and copy the seeded audit photos into its private files dir.
# Photos go through /data/local/tmp because files pushed straight into
# Android/data belong to the shell user and the app cannot read them.
set -euo pipefail
source "$(dirname "$0")/env.sh"
APK="$DEMO_DIR/app/android/app/build/outputs/apk/debug/app-debug.apk"
SEED="$DEMO_DIR/seed/out"
[ -d "$SEED/photos" ] || { echo "Run seed/generate_audit.py first"; exit 1; }
adb wait-for-device
adb install -r "$APK" >/dev/null
adb shell pm grant "$APP_ID" android.permission.POST_NOTIFICATIONS || true
adb shell mkdir -p /data/local/tmp/fieldaudit
adb push "$SEED/photos" "$SEED/thumbs" /data/local/tmp/fieldaudit/ | tail -1
adb shell chmod -R 755 /data/local/tmp/fieldaudit
adb shell "run-as $APP_ID rm -rf files/audits/$AUDIT_ID && run-as $APP_ID mkdir -p files/audits/$AUDIT_ID"
adb shell "run-as $APP_ID cp -r /data/local/tmp/fieldaudit/photos /data/local/tmp/fieldaudit/thumbs files/audits/$AUDIT_ID/"
n=$(adb shell "run-as $APP_ID ls files/audits/$AUDIT_ID/photos" | wc -l | tr -d ' ')
size=$(adb shell "run-as $APP_ID du -sk files/audits/$AUDIT_ID/photos" | awk '{print $1}')
echo "Device has $n photos ($((size / 1024)) MiB) for $AUDIT_ID"
