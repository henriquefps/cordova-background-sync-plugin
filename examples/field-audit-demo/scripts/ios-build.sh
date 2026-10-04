#!/usr/bin/env bash
# Build the web bundle, sync it into the iOS project (pod install) and build the
# simulator app with xcodebuild. The app talks to the backoffice on
# VITE_SERVER_URL, by default http://localhost:$BACKOFFICE_PORT, which the
# simulator reaches directly because it shares the Mac's network.
# VITE_TEST_CONTROL=1 builds the variant that tests/ios drives remotely.
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$DEMO_DIR/app"
[ -d node_modules ] || npm install
VITE_SERVER_URL="${VITE_SERVER_URL:-http://localhost:$BACKOFFICE_PORT}" npx vite build
npx cap sync ios
xcodebuild -quiet \
  -workspace ios/App/App.xcworkspace -scheme App -configuration Debug \
  -sdk iphonesimulator -destination "platform=iOS Simulator,id=$(ios_sim_udid)" \
  -derivedDataPath ios/DerivedData build
echo "App: $DEMO_DIR/app/ios/DerivedData/Build/Products/Debug-iphonesimulator/App.app"
