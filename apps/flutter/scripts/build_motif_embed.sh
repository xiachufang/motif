#!/usr/bin/env bash
# Build the motif-embed cdylib (a C ABI over motif-server) for the requested
# desktop Flutter target. The Flutter app loads it over dart:ffi to run an
# embedded motifd in-process — the same capability the Tauri menu-bar app has.
# Desktop only (macOS/Linux/Windows); the embedded server isn't built for
# mobile.
#
#   scripts/build_motif_embed.sh --target macos-arm64|linux-arm64|linux-x64|windows-arm64|windows-x64 [--out <path>]
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
cargo_features=()
case "$TARGET" in
  macos-arm64) triple="aarch64-apple-darwin"; artifact="libmotif_embed.dylib"; out_name="libmotif_embed.dylib";;
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

# The Windows App does not expose embedded Tailscale. Build motif-embed without
# its default tailscale-bundled feature so the DLL rejects that configuration
# explicitly and remains independent of Go.
if [[ "$os" == "windows" ]]; then
  cargo_features+=(--no-default-features)

  # Flutter's native-assets runner may omit APPDATA and the Zig cache
  # variables from the hook environment. libghostty-vt-sys invokes Zig from
  # Cargo, which otherwise cannot resolve a global cache directory on Windows.
  export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$REPO_ROOT/.zig-cache/global}"
  export ZIG_LOCAL_CACHE_DIR="${ZIG_LOCAL_CACHE_DIR:-$REPO_ROOT/.zig-cache/local}"
  mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"

  # motif-server links libghostty-vt through libghostty-rs, while Flutter's
  # renderer DLL is built from apps/flutter/ghostty. Force the Rust build to
  # the same checkout so motif_embed.dll and the DLL bundled by the native
  # assets hook agree on the C ABI and struct layouts.
  ghostty_source="$PROJECT_DIR/ghostty"
  if command -v cygpath >/dev/null 2>&1; then
    ghostty_source="$(cygpath -w "$ghostty_source")"
  fi
  export GHOSTTY_SOURCE_DIR="${MOTIF_GHOSTTY_SOURCE_DIR:-$ghostty_source}"
fi

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
  extra_rustflags="-C link-arg=-Wl,-install_name,@rpath/$out_name -C link-arg=-Wl,-rpath,@loader_path -C link-arg=-Wl,-headerpad_max_install_names"
  : "${MACOSX_DEPLOYMENT_TARGET:=${MACOS_MIN_VERSION:-11.0}}"
  : "${SDKROOT:=$(xcrun --sdk macosx --show-sdk-path)}"
  export MACOSX_DEPLOYMENT_TARGET
  export SDKROOT

  command -v pkg-config >/dev/null || { echo "error: pkg-config not on PATH (brew install pkg-config)" >&2; exit 127; }

  # Mixed-prefix macOS environments can run an arm64 Rust toolchain while
  # Zig/Go auto-detect x86_64. Build libghostty-vt with our explicit target and
  # make Cargo pick it up through pkg-config instead of libghostty-vt-sys'
  # auto-detected vendored build.
  ghostty_dir="${MOTIF_GHOSTTY_VT_DIR:-$PROJECT_DIR/build/native/ghostty-vt/macos/$arch}"
  if [[ ! -f "$ghostty_dir/libghostty-vt.dylib" ]]; then
    bash "$PROJECT_DIR/scripts/build_native_deps.sh" \
      --target-os macos \
      --target-arch "$arch" \
      --out-dir "$ghostty_dir" \
      --macos-min-version "$MACOSX_DEPLOYMENT_TARGET"
  fi
  [[ -f "$ghostty_dir/libghostty-vt.dylib" ]] || {
    echo "error: expected libghostty-vt.dylib missing under $ghostty_dir" >&2
    exit 1
  }
  pc_dir="$ghostty_dir/pkgconfig"
  mkdir -p "$pc_dir"
  cat > "$pc_dir/libghostty-vt.pc" <<EOF
prefix=$ghostty_dir
exec_prefix=\${prefix}
libdir=\${prefix}
includedir=$PROJECT_DIR/ghostty/include

Name: libghostty-vt
Description: Ghostty VT engine for Motif
Version: 0.1.0
Libs: -L\${libdir} -lghostty-vt
Cflags: -I\${includedir}
EOF
  export PKG_CONFIG_PATH="$pc_dir${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  export PKG_CONFIG_ALLOW_CROSS=1
  unset GHOSTTY_SOURCE_DIR
  cargo_features+=(--features ghostty-dynamic)

  # libtailscale-sys builds a Go c-archive as part of motif-embed's default
  # features. Force CGO to the same target arch so the final dylib doesn't mix
  # x86_64 objects into an arm64 link (or vice versa).
  clang="$(xcrun --sdk macosx --find clang)"
  case "$arch" in
    arm64) goarch="arm64"; clang_arch="arm64";;
    *) echo "error: unsupported macOS arch '$arch'" >&2; exit 2;;
  esac
  export GOOS=darwin
  export GOARCH="$goarch"
  export CGO_ENABLED=1
  export CC="$clang"
  export CGO_CFLAGS="-arch $clang_arch -isysroot $SDKROOT -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -Wno-unused-parameter ${CGO_CFLAGS:-}"
  export CGO_LDFLAGS="-arch $clang_arch -isysroot $SDKROOT -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET ${CGO_LDFLAGS:-}"
fi

mkdir -p "$(dirname "$OUT")"
echo ">>> building motif-embed ($TARGET → $triple) → $OUT"

(
  cd "$REPO_ROOT"
  cargo_args=(build --release -p motif-embed --target "$triple" "${cargo_features[@]}")
  if [[ -n "$extra_rustflags" ]]; then
    RUSTFLAGS="${RUSTFLAGS:-} $extra_rustflags" cargo "${cargo_args[@]}"
  else
    cargo "${cargo_args[@]}"
  fi
)

built="$REPO_ROOT/target/$triple/release/$artifact"
[[ -f "$built" ]] || { echo "error: expected cargo artifact missing: $built" >&2; exit 1; }
cp -f "$built" "$OUT"

if [[ "$os" == "macos" ]]; then
  cp -f "$ghostty_dir/libghostty-vt.dylib" "$(dirname "$OUT")/libghostty-vt.dylib"
  ln -sf libghostty-vt.dylib "$(dirname "$OUT")/libghostty-vt.0.dylib"
fi

# Keep the Windows runtime dependency next to the manually-built DLL so the
# cross-platform Dart FFI smoke test can open it directly. The Flutter hook also
# emits ghostty-vt.dll as its own native asset; this copy is for manual tests.
if [[ "$os" == "windows" ]]; then
  ghostty_dll=""
  while IFS= read -r -d '' candidate; do
    if [[ -z "$ghostty_dll" || "$candidate" -nt "$ghostty_dll" ]]; then
      ghostty_dll="$candidate"
    fi
  done < <(find "$REPO_ROOT/target/$triple/release/build" -type f -path '*/out/ghostty-install/bin/ghostty-vt.dll' -print0)
  [[ -n "$ghostty_dll" ]] || { echo "error: motif_embed.dll dependency ghostty-vt.dll was not built" >&2; exit 1; }
  cp -f "$ghostty_dll" "$(dirname "$OUT")/ghostty-vt.dll"
fi

echo ">>> built:"
ls -la "$(dirname "$OUT")"
