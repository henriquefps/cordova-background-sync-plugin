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
