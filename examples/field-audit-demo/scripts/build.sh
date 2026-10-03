#!/usr/bin/env bash
# Build the web bundle, sync it into the Android project and assemble the debug APK.
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$DEMO_DIR/app"
[ -d node_modules ] || npm install
npx vite build
npx cap sync android
cd android
[ -f local.properties ] || echo "sdk.dir=$ANDROID_HOME" > local.properties
./gradlew assembleDebug
echo "APK: $DEMO_DIR/app/android/app/build/outputs/apk/debug/app-debug.apk"
