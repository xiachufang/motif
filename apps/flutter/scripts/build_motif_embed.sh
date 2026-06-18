#!/usr/bin/env bash
# Build the motif-embed cdylib (a C ABI over motif-server) for the requested
# desktop Flutter target. The Flutter app loads it over dart:ffi to run an
# embedded motifd in-process — the same capability the Tauri menu-bar app has.
# Desktop only (macOS/Linux/Windows); the embedded server isn't built for
# mobile.
#
#   scripts/build_motif_embed.sh --target macos-arm64|macos-x64|linux-arm64|linux-x64|windows-arm64|windows-x64 [--out <path>]
#
# Requires the Rust toolchain (cargo) with the matching target installed
# (`rustup target add <triple>`). Host-arch builds work out of the box.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"          # apps/flutter
REPO_ROOT="$(cd "$PROJECT_DIR/../.." && pwd)"   # workspace root (Cargo.toml lives here)

OUT=""
TARGET=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="$2"; shift 2;;
    --target) TARGET="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

command -v cargo >/dev/null || { echo "error: cargo not on PATH" >&2; exit 127; }
[[ -n "$TARGET" ]] || { echo "error: --target is required" >&2; exit 2; }

# Map the Flutter target name → (cargo triple, artifact filename, output ext).
# cargo names a cdylib `libmotif_embed.{dylib,so}` on unix and `motif_embed.dll`
# on windows.
triple=""; artifact=""; out_name=""
extra_rustflags=""
case "$TARGET" in
  macos-arm64) triple="aarch64-apple-darwin"; artifact="libmotif_embed.dylib"; out_name="libmotif_embed.dylib";;
  macos-x64)   triple="x86_64-apple-darwin";  artifact="libmotif_embed.dylib"; out_name="libmotif_embed.dylib";;
  linux-arm64) triple="aarch64-unknown-linux-gnu"; artifact="libmotif_embed.so"; out_name="libmotif_embed.so";;
  linux-x64)   triple="x86_64-unknown-linux-gnu";  artifact="libmotif_embed.so"; out_name="libmotif_embed.so";;
  windows-arm64) triple="aarch64-pc-windows-msvc"; artifact="motif_embed.dll"; out_name="motif_embed.dll";;
  windows-x64)   triple="x86_64-pc-windows-msvc";  artifact="motif_embed.dll"; out_name="motif_embed.dll";;
  *) echo "error: unknown/unsupported --target '$TARGET' (desktop only)" >&2; exit 2;;
esac

# Default output path under apps/flutter/build/ — the layout the hook scans.
case "$TARGET" in
  macos-*) os="macos";;
  linux-*) os="linux";;
  windows-*) os="windows";;
esac
arch="${TARGET##*-}"
OUT="${OUT:-$PROJECT_DIR/build/native/motif/$os/$arch/$out_name}"

# On macOS, point the dylib's install name at @rpath so it resolves once the
# native-asset bundler copies it into the app's Frameworks (mirrors how the
# libtailscale dylib is wrapped).
if [[ "$os" == "macos" ]]; then
  # `-headerpad_max_install_names` reserves space in the Mach-O load commands so
  # the native-asset bundler can rewrite this dylib's dependency install names
  # (libghostty-vt / libtailscale / objective_c) to their absolute
  # `.dart_tool/lib/...` paths. Without it, deep checkout paths (e.g. a git
  # worktree under `.claude/worktrees/`) overflow the pad and install_name_tool
  # fails with "larger updated load commands do not fit".
  extra_rustflags="-C link-arg=-Wl,-install_name,@rpath/$out_name -C link-arg=-Wl,-headerpad_max_install_names"
  : "${MACOSX_DEPLOYMENT_TARGET:=${MACOS_MIN_VERSION:-11.0}}"
  : "${SDKROOT:=$(xcrun --sdk macosx --show-sdk-path)}"
  export MACOSX_DEPLOYMENT_TARGET
  export SDKROOT
fi

mkdir -p "$(dirname "$OUT")"
echo ">>> building motif-embed ($TARGET → $triple) → $OUT"

(
  cd "$REPO_ROOT"
  if [[ -n "$extra_rustflags" ]]; then
    RUSTFLAGS="${RUSTFLAGS:-} $extra_rustflags" cargo build --release -p motif-embed --target "$triple"
  else
    cargo build --release -p motif-embed --target "$triple"
  fi
)

built="$REPO_ROOT/target/$triple/release/$artifact"
[[ -f "$built" ]] || { echo "error: expected cargo artifact missing: $built" >&2; exit 1; }
cp -f "$built" "$OUT"
echo ">>> built:"
ls -la "$OUT"
