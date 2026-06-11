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

# Install Flutter artifacts for macOS.
flutter precache --macos

# Install Flutter dependencies.
flutter pub get

# Generate the ephemeral Xcode config + SPM package + FlutterInputs/Outputs.xcfilelist.
# `flutter pub get` alone does NOT create these (they live in macos/Flutter/ephemeral,
# which is gitignored), so `xcodebuild archive` would fail with
# "Unable to load contents of file list: .../FlutterInputs.xcfilelist".
flutter build macos --config-only --release

# Warm zig's global package cache for the ghostty native build. During
# `xcodebuild archive`, the Flutter "Run Script" phase compiles libghostty-vt
# via zig, which fetches deps from deps.files.ghostty.org. Xcode Cloud blocks
# network egress during the build action, so that fetch fails with
# "TlsInitializationFailed". Fetch the whole dep tree here (network is available
# in post-clone) into ~/.cache/zig; the in-build zig run is then a cache hit.
( cd ghostty && zig build --fetch=all )

# Install Rust and prebuild the motif-embed cdylib. The native-assets hook
# compiles it via cargo during the build phase, but Xcode Cloud has no Rust
# toolchain and no network there ("cargo not on PATH" / crate fetch would fail).
# Build it here into build/native/motif/macos/<arch>/ — the exact path the hook
# scans first (hook/build.dart) — so the in-build hook finds it prebuilt and
# skips cargo entirely. rust-toolchain.toml (repo root) pins the channel.
export RUSTUP_HOME="$HOME/.rustup" CARGO_HOME="$HOME/.cargo"
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
  | sh -s -- -y --no-modify-path --default-toolchain 1.95
. "$CARGO_HOME/env"
rustup target add aarch64-apple-darwin x86_64-apple-darwin

# Release archives are universal (arm64 + x86_64); prebuild both slices.
bash scripts/build_motif_embed.sh --target macos-arm64
bash scripts/build_motif_embed.sh --target macos-x64

exit 0
