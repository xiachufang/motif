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
# prefetch into ~/.cache/zig here; the in-build zig run is then a cache hit and
# needs no network.
#
# Fetch the *needed* set for the libghostty-vt build (-Demit-lib-vt --fetch), NOT
# --fetch=all. --fetch=all force-pulls the entire lazy dep tree, including the
# Linux/GUI Wayland deps (e.g. wayland_protocols from gitlab.freedesktop.org,
# which the runner can't resolve — "UnknownHostName"). lib-vt's build graph never
# references those, so needed-mode resolves them away. The archive runs the same
# `zig build -Demit-lib-vt=true` (see scripts/build_native_deps.sh), so this
# caches exactly the dep set it will need.
#
# Retry the fetch: individual deps from deps.files.ghostty.org intermittently
# throw TlsInitializationFailed (a flaky handshake, not a network block — most
# deps in the same run succeed). Successfully-fetched deps are cached, so each
# pass only refetches the missing ones. Without this, one bad handshake fails the
# whole archive.
( cd ghostty
  n=0
  until zig build -Demit-lib-vt=true --fetch; do
    n=$((n + 1))
    if [ "$n" -ge 5 ]; then
      echo "zig fetch still failing after $n attempts; giving up" >&2
      exit 1
    fi
    echo "zig fetch attempt $n hit a transient error; retrying in 5s..." >&2
    sleep 5
  done )

# Prebuild libtailscale for iOS device (Go c-archive wrapped into a dylib). The
# hook otherwise clones tailscale/libtailscale and runs `make` in the sandboxed
# build phase; do it here into build/native/tailscale/iphoneos/ (a hook scan
# path) so the in-build hook finds it prebuilt. `go` is installed above.
# iOS doesn't use motif-embed (desktop-only) or cargo, so no Rust needed here.
bash scripts/build_tailscale.sh --target ios

exit 0
