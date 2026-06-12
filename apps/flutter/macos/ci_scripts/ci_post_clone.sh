#!/bin/sh

# Fail this script if any subcommand fails.
set -e

# Retry a flaky command. The Xcode Cloud runner has intermittent outbound
# DNS/TLS failures in the post-clone phase — we've seen "Could not resolve host"
# (rustup from static.rust-lang.org), "TlsInitializationFailed" and
# "UnknownHostName" (zig deps), etc. These are transient, not real errors, but
# under `set -e` a single blip fails the whole archive. Wrap every network step:
# up to 5 attempts, 5s apart. `until` is exempt from `set -e`, so failed attempts
# don't abort the script; only a final give-up (return 1) does.
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
cd $CI_PRIMARY_REPOSITORY_PATH/apps/flutter # change working directory to the root of your cloned repo.

# Install Flutter using git. rm -rf first so a retry after a partial clone starts
# clean (git clone refuses a non-empty target).
retry sh -c 'rm -rf "$HOME/flutter" && git clone https://github.com/flutter/flutter.git --depth 1 -b stable "$HOME/flutter"'
export PATH="$PATH:$HOME/flutter/bin:/opt/homebrew/opt/zig@0.15/bin"
export LDFLAGS="-L/opt/homebrew/opt/zig@0.15/lib"

# Install Flutter artifacts for macOS.
retry flutter precache --macos

# Install Flutter dependencies.
retry flutter pub get

# Generate the ephemeral Xcode config + SPM package + FlutterInputs/Outputs.xcfilelist.
# `flutter pub get` alone does NOT create these (they live in macos/Flutter/ephemeral,
# which is gitignored), so `xcodebuild archive` would fail with
# "Unable to load contents of file list: .../FlutterInputs.xcfilelist".
retry flutter build macos --config-only --release

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

# Install Rust and prebuild the motif-embed cdylib. The native-assets hook
# compiles it via cargo during the build phase, but Xcode Cloud has no Rust
# toolchain ("cargo not on PATH"). Build it here into
# build/native/motif/macos/<arch>/ — the exact path the hook scans first
# (hook/build.dart) — so the in-build hook finds it prebuilt and skips cargo
# entirely. rust-toolchain.toml (repo root) pins the channel.
export RUSTUP_HOME="$HOME/.rustup" CARGO_HOME="$HOME/.cargo"
retry sh -c "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path --default-toolchain 1.95"
. "$CARGO_HOME/env"
retry rustup target add aarch64-apple-darwin x86_64-apple-darwin

# Release archives are universal (arm64 + x86_64); prebuild both slices. These
# pull crates/modules from the network, so retry the whole build (cargo/go cache
# what already downloaded).
retry bash scripts/build_motif_embed.sh --target macos-arm64
retry bash scripts/build_motif_embed.sh --target macos-x64

# Prebuild libtailscale (Go c-shared lib). The hook otherwise clones
# tailscale/libtailscale and runs `go build` inside the sandboxed build phase;
# do it here into build/native/tailscale/macos/<arch>/ (the hook's first scan
# path) so the in-build hook finds it prebuilt. `go` is installed above.
retry bash scripts/build_tailscale.sh --target macos-arm64
retry bash scripts/build_tailscale.sh --target macos-x64

exit 0
