#!/bin/sh

# Fail this script if any subcommand fails.
set -e

# Retry a flaky command. The Xcode Cloud runner has intermittent outbound
# DNS/TLS failures in the post-clone phase — we've seen "Could not resolve host",
# "TlsInitializationFailed" and "UnknownHostName" (zig deps), etc. These are
# transient, not real errors, but under `set -e` a single blip fails the whole
# archive. Wrap every network step: up to 5 attempts, 5s apart. `until` is exempt
# from `set -e`, so failed attempts don't abort the script; only a final give-up
# (return 1) does.
retry() {
  _n=0
  until "$@"; do
    _n=$((_n + 1))
    if [ "$_n" -ge 5 ]; then
      echo "retry: command still failing after $_n attempts: $*" >&2
      return 1
    fi
    echo "retry: attempt $_n hit a transient error ($*); retrying in 5s..." >&2
    sleep 5
  done
}

retry brew install zig@0.15 go

# The default execution directory of this script is the ci_scripts directory.
# Xcode Cloud checks out the primary repository, but submodules are not
# guaranteed to be populated. The Flutter native-asset hook builds libghostty-vt
# from apps/flutter/ghostty, so initialize that submodule before any build step.
cd "$CI_PRIMARY_REPOSITORY_PATH"
retry git submodule sync --recursive apps/flutter/ghostty
retry git submodule update --init --recursive apps/flutter/ghostty

cd "$CI_PRIMARY_REPOSITORY_PATH/apps/flutter" # change working directory to the root of your cloned repo.

# Install Flutter using git. rm -rf first so a retry after a partial clone starts
# clean (git clone refuses a non-empty target).
retry sh -c 'rm -rf "$HOME/flutter" && git clone https://github.com/flutter/flutter.git --depth 1 -b stable "$HOME/flutter"'
export PATH="$PATH:$HOME/flutter/bin:/opt/homebrew/opt/zig@0.15/bin"
export LDFLAGS="-L/opt/homebrew/opt/zig@0.15/lib"

# Install Flutter artifacts for iOS.
retry flutter precache --ios

# Install Flutter dependencies.
retry flutter pub get

# Generate the ephemeral Xcode config + SPM package + FlutterInputs/Outputs.xcfilelist.
# `flutter pub get` alone does NOT create these (they live in ios/Flutter/ephemeral,
# which is gitignored), so `xcodebuild archive` would fail with
# "Unable to load contents of file list: .../FlutterInputs.xcfilelist".
retry flutter build ios --config-only --no-codesign --release

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
# caches exactly the dep set it will need. Successfully-fetched deps are cached,
# so a retry only refetches the ones that hit a flaky handshake.
retry sh -c 'cd ghostty && zig build -Demit-lib-vt=true --fetch'

# Prebuild libtailscale for iOS device (Go c-archive wrapped into a dylib). The
# hook otherwise clones tailscale/libtailscale and runs `make` in the sandboxed
# build phase; do it here into build/native/tailscale/iphoneos/ (a hook scan
# path) so the in-build hook finds it prebuilt. `go` is installed above.
# iOS doesn't use motif-embed (desktop-only) or cargo, so no Rust needed here.
retry bash scripts/build_tailscale.sh --target ios

exit 0
