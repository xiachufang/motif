#!/bin/sh

# Fail this script if any subcommand fails.
set -e

brew install zig@0.15 go

# The default execution directory of this script is the ci_scripts directory.
cd $CI_PRIMARY_REPOSITORY_PATH/apps/flutter # change working directory to the root of your cloned repo.

# Install Flutter using git.
git clone https://github.com/flutter/flutter.git --depth 1 -b stable $HOME/flutter
export PATH="$PATH:$HOME/flutter/bin:/opt/homebrew/opt/zig@0.15/bin"
export LDFLAGS="-L/opt/homebrew/opt/zig@0.15/lib"

# Install Flutter artifacts for iOS.
flutter precache --ios

# Install Flutter dependencies.
flutter pub get

# Generate the ephemeral Xcode config + SPM package + FlutterInputs/Outputs.xcfilelist.
# `flutter pub get` alone does NOT create these (they live in ios/Flutter/ephemeral,
# which is gitignored), so `xcodebuild archive` would fail with
# "Unable to load contents of file list: .../FlutterInputs.xcfilelist".
flutter build ios --config-only --no-codesign --release

# Warm zig's global package cache for the ghostty native build. During
# `xcodebuild archive`, the Flutter "Run Script" phase compiles libghostty-vt
# via zig, which fetches deps from deps.files.ghostty.org. zig's TLS stack can't
# initialize in the sandboxed Run Script phase ("TlsInitializationFailed"), so
# fetch the whole dep tree here into ~/.cache/zig; the in-build zig run is then a
# cache hit and needs no network.
( cd ghostty && zig build --fetch=all )

# Prebuild libtailscale for iOS device (Go c-archive wrapped into a dylib). The
# hook otherwise clones tailscale/libtailscale and runs `make` in the sandboxed
# build phase; do it here into build/native/tailscale/iphoneos/ (a hook scan
# path) so the in-build hook finds it prebuilt. `go` is installed above.
# iOS doesn't use motif-embed (desktop-only) or cargo, so no Rust needed here.
bash scripts/build_tailscale.sh --target ios

exit 0
