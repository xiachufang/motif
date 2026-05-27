#!/usr/bin/env bash
# Assemble a macOS .app bundle for the menu-bar app (no cargo-tauri needed).
# Builds the binary, generates icon.icns from icons/icon.png, writes
# Info.plist (LSUIElement = menu-bar agent), and ad-hoc signs the result.
#
# Usage: apps/menubar/bundle.sh [release|debug]   (default: release)
set -euo pipefail

cd "$(dirname "$0")"            # apps/menubar
ROOT="$(cd ../.. && pwd)"       # repo root

PROFILE="${1:-release}"
APP_NAME="Motif"
BIN="motif-menubar"
BUNDLE_ID="io.allsunday.motif.menubar"
VERSION="0.1.0"

echo "==> building $BIN ($PROFILE)"
if [ "$PROFILE" = "release" ]; then
  cargo build -p "$BIN" --release
  BIN_PATH="$ROOT/target/release/$BIN"
else
  cargo build -p "$BIN"
  BIN_PATH="$ROOT/target/debug/$BIN"
fi

APP="$ROOT/target/$PROFILE/bundle/$APP_NAME.app"
echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/$BIN"

# icon.icns from the 1024px source.
ICONSET="$(mktemp -d)/icon.iconset"
mkdir -p "$ICONSET"
SRC="$PWD/icons/icon.png"
for sz in 16 32 128 256 512; do
  sips -z "$sz" "$sz" "$SRC" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
  sips -z "$((sz * 2))" "$((sz * 2))" "$SRC" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/icon.icns"
rm -rf "$(dirname "$ICONSET")"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$BIN</string>
  <key>CFBundleIconFile</key><string>icon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc sign so macOS caches the icon and trusts the bundle identity locally.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "==> done: $APP"
