# Shared settings for the demo scripts. Source it, do not run it.
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"
# Capacitor 8 needs JDK 21; Android Studio ships one.
if [ -z "${JAVA_HOME:-}" ] || ! "$JAVA_HOME/bin/java" -version 2>&1 | grep -q '"21'; then
  export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
fi
DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_ID=com.hfps.fieldaudit
AUDIT_ID=AUD-2026-0418
BACKOFFICE_PORT="${BACKOFFICE_PORT:-8791}"
# iOS simulator (scripts/ios-*.sh). SIM_DEVICE is a device name from
# `xcrun simctl list devices`; SIM_UDID picks one device exactly.
SIM_DEVICE="${SIM_DEVICE:-iPhone 17 Pro}"
ios_sim_udid() {
  if [ -n "${SIM_UDID:-}" ]; then echo "$SIM_UDID"; return; fi
  # Prefer a booted device with that name, then the newest runtime that has one.
  xcrun simctl list devices available -j | python3 -c '
import json, sys
name = sys.argv[1]
devs = []
for rt, ds in json.load(sys.stdin)["devices"].items():
    for d in ds:
        if d["name"] == name:
            devs.append((d["state"] == "Booted", rt, d["udid"]))
devs.sort(reverse=True)
print(devs[0][2] if devs else "")' "$SIM_DEVICE"
}
