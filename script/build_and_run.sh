#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
case "$MODE" in
  run|--verify|--debug|--profile|--logs|--telemetry) ;;
  *) echo "Usage: $0 [--verify|--debug|--profile|--logs|--telemetry]" >&2; exit 2 ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR/apps/flutter"
export GOTOOLCHAIN="${GOTOOLCHAIN:-go1.25.5}"
BUILD_MODE="debug"
BUILD_CONFIGURATION="Debug"
if [[ "$MODE" == --profile ]]; then
  BUILD_MODE="profile"
  BUILD_CONFIGURATION="Profile"
fi
flutter build macos "--$BUILD_MODE" -t lib/main_desktop.dart
if [[ "$BUILD_MODE" == profile ]]; then
  APP_BUNDLE="$PWD/build/macos/Build/Products/$BUILD_CONFIGURATION/Motif.app"
else
  APP_BUNDLE="$PWD/build/macos/Build/Products/$BUILD_CONFIGURATION/Motif Desktop Debug.app"
fi
APP_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_BUNDLE/Contents/Info.plist")"

# Keep the running server available while compiling, then replace the app.
for process_name in "Motif Desktop Debug" "Motif"; do
  pkill -TERM -x "$process_name" || true
  for ((attempt = 0; attempt < 50; attempt++)); do
    if ! pgrep -x "$process_name" >/dev/null; then break; fi
    sleep 0.1
  done
  if pgrep -x "$process_name" >/dev/null; then
    echo "$process_name has not exited; refusing to start a duplicate server." >&2
    exit 1
  fi
done

if [[ "$MODE" == --debug ]]; then
  exec lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_EXECUTABLE"
fi
if [[ -n "${MOTIF_PREVIEW_LOCALE:-}" ]]; then
  /usr/bin/open -n "$APP_BUNDLE" --args -AppleLanguages "(${MOTIF_PREVIEW_LOCALE})" -AppleLocale "$MOTIF_PREVIEW_LOCALE"
else
  /usr/bin/open -n "$APP_BUNDLE"
fi
case "$MODE" in
  --verify|--profile)
    sleep 2
    pgrep -x "$APP_EXECUTABLE" >/dev/null
    ;;
  --logs|--telemetry)
    exec /usr/bin/log stream --info --style compact --predicate "process == \"$APP_EXECUTABLE\""
    ;;
esac
