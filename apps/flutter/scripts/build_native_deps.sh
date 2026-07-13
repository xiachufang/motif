#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

TARGET_OS="macos"
TARGET_ARCH=""
OUT_DIR=""
FRAMEWORKS_DEST=""
MACOS_MIN_VERSION="10.15"
IOS_SDK="iphoneos"
IOS_MIN_VERSION="17.0"
# `zig build` defaults to Debug. That is unusably slow for a terminal engine:
# a Codex synchronized-redraw stream that ReleaseFast parses in milliseconds
# can pin a core continuously in Debug. Native assets are bundled into the app
# even for Flutter debug/profile runs, so default the engine itself to the same
# optimized mode used by Cargo release builds. Keep an environment override for
# targeted native debugging.
GHOSTTY_OPTIMIZE="${GHOSTTY_OPTIMIZE:-ReleaseFast}"

case "$GHOSTTY_OPTIMIZE" in
  Debug|ReleaseSafe|ReleaseSmall|ReleaseFast) ;;
  *)
    echo "error: invalid GHOSTTY_OPTIMIZE '$GHOSTTY_OPTIMIZE' (expected Debug|ReleaseSafe|ReleaseSmall|ReleaseFast)" >&2
    exit 2
    ;;
esac

if [[ -n "${ZIG:-}" && -x "$ZIG" ]]; then
  export PATH="$(dirname "$ZIG"):$PATH"
elif [[ -x "/opt/homebrew/opt/zig@0.15/bin/zig" ]]; then
  export PATH="/opt/homebrew/opt/zig@0.15/bin:$PATH"
fi

print_usage() {
  cat <<'EOF'
Usage: build_native_deps.sh [options] [legacy_frameworks_dest]

Options:
  --target-os <os>             Target OS (currently only: macos)
  --target-arch <arch>         Target architecture (arm64 or x64)
  --out-dir <path>             Output directory for produced libraries
  --frameworks-dest <path>     Optional destination to mirror built dylibs
  --macos-min-version <ver>    Minimum macOS deployment version (default: 10.15)
  -h, --help                   Show this help message

Defaults:
  --target-os macos
  --target-arch host architecture
  --out-dir build/native/macos

The optional positional argument is kept for backward compatibility and maps to
--frameworks-dest.

Environment:
  GHOSTTY_OPTIMIZE             Zig optimization mode for libghostty-vt
                               (default: ReleaseFast; Debug is diagnostic only)
EOF
}

require_value() {
  local flag="$1"
  local value="${2:-}"
  if [[ -z "$value" ]]; then
    echo "error: missing value for $flag" >&2
    exit 2
  fi
}

map_host_arch() {
  case "$(uname -m)" in
    arm64) echo "arm64" ;;
    x86_64) echo "x64" ;;
    *)
      echo "error: unsupported host architecture '$(uname -m)'" >&2
      exit 2
      ;;
  esac
}

zig_arch() {
  local arch="$1"
  case "$arch" in
    arm64) echo "aarch64" ;;
    x64) echo "x86_64" ;;
    *)
      echo "error: unsupported target arch '$arch'" >&2
      exit 2
      ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-os)
      require_value "$1" "${2:-}"
      TARGET_OS="$2"
      shift 2
      ;;
    --target-arch)
      require_value "$1" "${2:-}"
      TARGET_ARCH="$2"
      shift 2
      ;;
    --out-dir)
      require_value "$1" "${2:-}"
      OUT_DIR="$2"
      shift 2
      ;;
    --frameworks-dest)
      require_value "$1" "${2:-}"
      FRAMEWORKS_DEST="$2"
      shift 2
      ;;
    --macos-min-version)
      require_value "$1" "${2:-}"
      MACOS_MIN_VERSION="$2"
      shift 2
      ;;
    --ios-sdk)
      require_value "$1" "${2:-}"
      IOS_SDK="$2"
      shift 2
      ;;
    --ios-min-version)
      require_value "$1" "${2:-}"
      IOS_MIN_VERSION="$2"
      shift 2
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    -* )
      echo "error: unknown option '$1'" >&2
      print_usage >&2
      exit 2
      ;;
    *)
      if [[ -n "$FRAMEWORKS_DEST" ]]; then
        echo "error: unexpected positional argument '$1'" >&2
        print_usage >&2
        exit 2
      fi
      FRAMEWORKS_DEST="$1"
      shift
      ;;
  esac
done

if [[ -z "$TARGET_ARCH" ]]; then
  TARGET_ARCH="$(map_host_arch)"
fi

if [[ -z "$OUT_DIR" ]]; then
  OUT_DIR="$PROJECT_DIR/build/native/$TARGET_OS"
fi

require_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "error: required command '$cmd' is not available on PATH" >&2
    exit 127
  fi
}

require_command zig
# xcrun is macOS-only. The Linux/Windows/Android paths drive Zig directly and
# never shell out to it, so requiring it there would wrongly fail the build
# (e.g. on CI Linux/Windows runners with no Xcode).
if [[ "$TARGET_OS" == "macos" || "$TARGET_OS" == "ios" ]]; then
  require_command xcrun
fi

# Zig 0.15.2's self-hosted Mach-O linker can't parse libSystem.tbd from very new
# macOS SDKs (e.g. 26.x), which makes even the build runner fail to link. If the
# active SDK is unparseable and an older CLT SDK (15.x) is present, shim `xcrun`
# so Zig auto-detects the older macOS SDK. iOS SDK queries pass through. This is
# a no-op on machines whose default SDK Zig already handles.
maybe_pin_macos_sdk() {
  # Probe: can zig link a trivial native program?
  local probe="${TMPDIR:-/tmp}/zig_sdk_probe_$$"
  mkdir -p "$probe"
  printf 'pub fn main() void {}\n' > "$probe/p.zig"
  if zig build-exe "$probe/p.zig" -femit-bin="$probe/p" >/dev/null 2>&1; then
    rm -rf "$probe"
    return 0  # native linking already works
  fi
  # Find the newest MacOSX15*.sdk under Command Line Tools.
  local clt="/Library/Developer/CommandLineTools/SDKs"
  local fallback
  fallback="$(ls -d "$clt"/MacOSX15*.sdk 2>/dev/null | sort -V | tail -n1)"
  if [[ -z "$fallback" || ! -d "$fallback" ]]; then
    rm -rf "$probe"
    return 0  # nothing to pin; let zig fail loudly later
  fi
  local shimdir="$probe/shim"
  mkdir -p "$shimdir"
  cat > "$shimdir/xcrun" <<EOF
#!/bin/bash
real=/usr/bin/xcrun
for a in "\$@"; do
  if [[ "\$a" == "--show-sdk-path" ]]; then
    case "\$*" in
      *iphoneos*|*iphonesimulator*) exec "\$real" "\$@";;
      *) echo "$fallback"; exit 0;;
    esac
  fi
done
exec "\$real" "\$@"
EOF
  chmod +x "$shimdir/xcrun"
  export PATH="$shimdir:$PATH"
  echo "[native] pinned macOS SDK for Zig → $fallback (active SDK unparseable by Zig 0.15.2)"
}
# Only relevant to macOS/iOS builds (the shim probes the macOS SDK via xcrun).
if [[ "$TARGET_OS" == "macos" || "$TARGET_OS" == "ios" ]]; then
  maybe_pin_macos_sdk
fi

if [[ "$TARGET_OS" != "macos" && "$TARGET_OS" != "ios" && "$TARGET_OS" != "linux" && "$TARGET_OS" != "windows" && "$TARGET_OS" != "android" ]]; then
  echo "error: unsupported target OS '$TARGET_OS' (expected macos|ios|linux|windows|android)" >&2
  exit 2
fi

mkdir -p "$OUT_DIR"

# Windows: Flutter's native-assets runner spawns this hook with a sanitized
# environment that can drop ZIG_GLOBAL_CACHE_DIR and APPDATA, leaving zig unable
# to resolve its global cache ("error: unable to resolve zig cache directory:
# AppDataDirUnavailable"). Give zig a project-local cache as a fallback (only
# when the env didn't already provide one, so CI cache restore still wins).
if [[ "$TARGET_OS" == "windows" ]]; then
  export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$PROJECT_DIR/.zig-cache/global}"
  export ZIG_LOCAL_CACHE_DIR="${ZIG_LOCAL_CACHE_DIR:-$PROJECT_DIR/.zig-cache/local}"
  mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"
fi

# ─────────────────────────── Android (.so) ───────────────────────────
# Requires the Android NDK (ghostty's simdutf dep links bionic libc/headers).
# Set ANDROID_NDK_HOME (or ANDROID_HOME with an ndk/ subdir). pty is a stub
# (Motif uses a remote PTY).
if [[ "$TARGET_OS" == "android" ]]; then
  case "$TARGET_ARCH" in
    arm64) ztriple="aarch64-linux-android" ;;
    x64)   ztriple="x86_64-linux-android" ;;
    arm)   ztriple="arm-linux-androideabi" ;;
    *) echo "error: unsupported android arch '$TARGET_ARCH'" >&2; exit 2 ;;
  esac
  if [[ -z "${ANDROID_NDK_HOME:-}" && -d "${ANDROID_HOME:-}/ndk" ]]; then
    ANDROID_NDK_HOME="$(ls -d "${ANDROID_HOME}/ndk"/*/ 2>/dev/null | sort -V | tail -n1)"
    export ANDROID_NDK_HOME
  fi
  echo "[native] Building libghostty-vt.so for $ztriple (NDK=${ANDROID_NDK_HOME:-<unset>})"
  ( cd "$PROJECT_DIR/ghostty" && zig build -Demit-lib-vt=true -Dtarget="$ztriple" -Doptimize="$GHOSTTY_OPTIMIZE" )
  so_src="$(ls -t "$PROJECT_DIR/ghostty/zig-out/lib"/libghostty-vt.so.*.*.* 2>/dev/null | head -n1)"
  if [[ -z "$so_src" || ! -f "$so_src" ]]; then
    echo "error: missing libghostty-vt.so for $ztriple" >&2; exit 1
  fi
  cp -f "$so_src" "$OUT_DIR/libghostty-vt.so"

  echo "[native] Built Android artifact:"
  ls -la "$OUT_DIR/libghostty-vt.so"
  exit 0
fi

# ─────────────────────────── Windows (.dll) ───────────────────────────
# libghostty-vt builds as a PE DLL. Motif uses a remote PTY, so no local pty lib.
if [[ "$TARGET_OS" == "windows" ]]; then
  zarch="$(zig_arch "${TARGET_ARCH:-x64}")"
  ztriple="$zarch-windows-gnu"

  echo "[native] Building ghostty-vt.dll for $ztriple"
  ( cd "$PROJECT_DIR/ghostty" && zig build -Demit-lib-vt=true -Dtarget="$ztriple" -Doptimize="$GHOSTTY_OPTIMIZE" )
  dll_src="$PROJECT_DIR/ghostty/zig-out/bin/ghostty-vt.dll"
  if [[ ! -f "$dll_src" ]]; then
    echo "error: missing ghostty-vt.dll for $ztriple" >&2; exit 1
  fi
  cp -f "$dll_src" "$OUT_DIR/ghostty-vt.dll"

  echo "[native] Built Windows artifact:"
  ls -la "$OUT_DIR/ghostty-vt.dll"
  exit 0
fi

# ─────────────────────────── Linux (.so) ───────────────────────────
# libghostty-vt cross-compiles cleanly to ELF.
if [[ "$TARGET_OS" == "linux" ]]; then
  if [[ "$TARGET_ARCH" != "arm64" && "$TARGET_ARCH" != "x64" ]]; then
    echo "error: unsupported linux arch '$TARGET_ARCH'" >&2; exit 2
  fi
  zarch="$(zig_arch "$TARGET_ARCH")"
  ztriple="$zarch-linux-gnu"

  echo "[native] Building libghostty-vt.so for $ztriple"
  ( cd "$PROJECT_DIR/ghostty" && zig build -Demit-lib-vt=true -Dtarget="$ztriple" -Doptimize="$GHOSTTY_OPTIMIZE" )
  so_src="$(ls -t "$PROJECT_DIR/ghostty/zig-out/lib"/libghostty-vt.so.*.*.* 2>/dev/null | head -n1)"
  if [[ -z "$so_src" || ! -f "$so_src" ]]; then
    echo "error: missing libghostty-vt.so for $ztriple" >&2; exit 1
  fi
  cp -f "$so_src" "$OUT_DIR/libghostty-vt.so"

  echo "[native] Built Linux artifact:"
  ls -la "$OUT_DIR/libghostty-vt.so"
  exit 0
fi

# ─────────────────────────── iOS (dynamic) ───────────────────────────
# Ghostty's direct iOS dylib emit path is unreliable for arm64-ios, so source
# the lib-vt archive slice and wrap it into a single-arch dylib. The hook emits
# only that dylib as a DynamicLoadingBundled code asset.
if [[ "$TARGET_OS" == "ios" ]]; then
  if [[ "$TARGET_ARCH" != "arm64" && "$TARGET_ARCH" != "x64" ]]; then
    echo "error: unsupported iOS arch '$TARGET_ARCH'" >&2
    exit 2
  fi
  if [[ "$IOS_SDK" == "iphonesimulator" ]]; then
    clang_sdk="iphonesimulator"
    clang_arch="$(if [[ "$TARGET_ARCH" == "arm64" ]]; then echo arm64; else echo x86_64; fi)"
    min_flag="-mios-simulator-version-min=$IOS_MIN_VERSION"
  else
    clang_sdk="iphoneos"
    clang_arch="arm64"
    min_flag="-miphoneos-version-min=$IOS_MIN_VERSION"
  fi

  # Source the libghostty-vt archive for this arch+sdk:
  #   - arm64 (device + sim): the dylib emit fails for arm64-ios, so take the
  #     archive slice from the lib-vt xcframework.
  #   - x86_64 simulator: build the archive directly (no xcframework slice).
  if [[ "$TARGET_ARCH" == "x64" ]]; then
    echo "[native] Building libghostty-vt archive for x86_64-ios-simulator"
    ( cd "$PROJECT_DIR/ghostty" && zig build -Demit-lib-vt=true -Dtarget=x86_64-ios-simulator -Doptimize="$GHOSTTY_OPTIMIZE" )
    slice_lib="$PROJECT_DIR/ghostty/zig-out/lib/libghostty-vt.a"
  else
    echo "[native] Building libghostty-vt xcframework via zig (for arm64 iOS slice)"
    ( cd "$PROJECT_DIR/ghostty" && zig build -Demit-lib-vt=true -Demit-xcframework=true -Doptimize="$GHOSTTY_OPTIMIZE" )
    xcf="$PROJECT_DIR/ghostty/zig-out/lib/ghostty-vt.xcframework"
    slice_dir="$(if [[ "$IOS_SDK" == "iphonesimulator" ]]; then echo "$xcf/ios-arm64-simulator"; else echo "$xcf/ios-arm64"; fi)"
    slice_lib="$(ls "$slice_dir"/libghostty-vt*.a 2>/dev/null | head -n1)"
  fi
  if [[ -z "$slice_lib" || ! -f "$slice_lib" ]]; then
    echo "error: missing iOS ghostty-vt archive for $TARGET_ARCH/$IOS_SDK" >&2
    exit 1
  fi
  rm -f "$OUT_DIR/libghostty-vt.a"

  ios_sdk_path="$(xcrun --sdk "$clang_sdk" --show-sdk-path)"

  # Wrap the archive into a single-arch dynamic library with -all_load.
  echo "[native] Wrapping libghostty-vt archive into a dylib (-all_load, arch=$clang_arch)"
  xcrun --sdk "$clang_sdk" clang -dynamiclib -arch "$clang_arch" -isysroot "$ios_sdk_path" \
    "$min_flag" -Wl,-all_load "$slice_lib" \
    -o "$OUT_DIR/libghostty-vt.dylib" \
    -install_name @rpath/libghostty-vt.dylib \
    -lc++ -framework Foundation

  echo "[native] Built iOS artifact:"
  ls -la "$OUT_DIR/libghostty-vt.dylib"
  exit 0
fi

# ─────────────────────────── macOS (dynamic) ───────────────────────────
if [[ "$TARGET_ARCH" != "arm64" && "$TARGET_ARCH" != "x64" ]]; then
  echo "error: unsupported target arch '$TARGET_ARCH' (expected arm64 or x64)" >&2
  exit 2
fi

ghostty_target="$(zig_arch "$TARGET_ARCH")-macos"
macos_sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
if [[ -z "$macos_sdk_path" || ! -d "$macos_sdk_path" ]]; then
  echo "error: could not determine macOS SDK path via xcrun" >&2
  exit 1
fi

echo "[native] Building libghostty-vt via zig (target=$ghostty_target, optimize=$GHOSTTY_OPTIMIZE)"
(
  cd "$PROJECT_DIR/ghostty"
  zig build -Demit-lib-vt=true -Dtarget="$ghostty_target" -Doptimize="$GHOSTTY_OPTIMIZE"
)

ghostty_lib_dir="$PROJECT_DIR/ghostty/zig-out/lib"
ghostty_versioned_name="$(basename "$(ls -t "$ghostty_lib_dir"/libghostty-vt.*.*.*.dylib 2>/dev/null | head -n1)")"
if [[ -z "$ghostty_versioned_name" ]]; then
  echo "error: could not locate versioned libghostty-vt dylib under $ghostty_lib_dir" >&2
  exit 1
fi

ghostty_versioned="$ghostty_lib_dir/$ghostty_versioned_name"

cp -f "$ghostty_versioned" "$OUT_DIR/$ghostty_versioned_name"
cp -f "$ghostty_versioned" "$OUT_DIR/libghostty-vt.dylib"
ln -sf libghostty-vt.dylib "$OUT_DIR/libghostty-vt.0.dylib"

if [[ -n "$FRAMEWORKS_DEST" ]]; then
  echo "[native] Syncing dylibs to app Frameworks: $FRAMEWORKS_DEST"
  mkdir -p "$FRAMEWORKS_DEST"

  cp -f "$OUT_DIR/$ghostty_versioned_name" "$FRAMEWORKS_DEST/$ghostty_versioned_name"
  cp -f "$OUT_DIR/libghostty-vt.dylib" "$FRAMEWORKS_DEST/libghostty-vt.dylib"
  ln -sf libghostty-vt.dylib "$FRAMEWORKS_DEST/libghostty-vt.0.dylib"
fi

echo "[native] Built artifacts:"
ls -la "$OUT_DIR"/libghostty-vt*
