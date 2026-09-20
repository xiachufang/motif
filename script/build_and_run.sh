#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
case "$MODE" in
  run|--verify|--debug|--logs|--telemetry) ;;
  *) echo "Usage: $0 [--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR/apps/flutter"
export GOTOOLCHAIN="${GOTOOLCHAIN:-go1.25.5}"
flutter build macos --debug -t lib/main_desktop.dart
APP_BUNDLE="$PWD/build/macos/Build/Products/Debug/Motif Desktop Debug.app"
APP_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_BUNDLE/Contents/Info.plist")"

# Keep the running server available while compiling, then replace the app.
pkill -TERM -x "$APP_EXECUTABLE" || true
for ((attempt = 0; attempt < 50; attempt++)); do
  if ! pgrep -x "$APP_EXECUTABLE" >/dev/null; then break; fi
  sleep 0.1
done
if pgrep -x "$APP_EXECUTABLE" >/dev/null; then
  echo "Motif has not exited; refusing to start a duplicate server." >&2
  exit 1
fi

if [[ "$MODE" == --debug ]]; then
  exec lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_EXECUTABLE"
fi
if [[ -n "${MOTIF_PREVIEW_LOCALE:-}" ]]; then
  /usr/bin/open -n "$APP_BUNDLE" --args -AppleLanguages "(${MOTIF_PREVIEW_LOCALE})" -AppleLocale "$MOTIF_PREVIEW_LOCALE"
else
  /usr/bin/open -n "$APP_BUNDLE"
fi
case "$MODE" in
  --verify)
    sleep 2
    pgrep -x "$APP_EXECUTABLE" >/dev/null
    ;;
  --logs|--telemetry)
    exec /usr/bin/log stream --info --style compact --predicate "process == \"$APP_EXECUTABLE\""
    ;;
esac
