#!/usr/bin/env bash
# Build libtailscale (Tailscale's C API over Go tsnet) as a dynamic library for
# the requested Flutter target platform. Requires Go + CGO.
#
#   scripts/build_tailscale.sh [--src <libtailscale-dir>] [--target host|macos-arm64|linux-arm64|linux-x64|windows-arm64|windows-x64|android-arm|android-arm64|android-x64|ios|ios-sim|ios-sim-arm64|ios-sim-x64] [--out <path>]
#
# If --src is omitted, clones tailscale/libtailscale into build/libtailscale.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

SRC=""
OUT=""
TARGET="host"   # host | macos-* | linux-* | windows-* | android-* | ios | ios-sim*
REPO="${LIBTAILSCALE_REPO:-https://github.com/tailscale/libtailscale.git}"
REF="${LIBTAILSCALE_REF:-main}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --src) SRC="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --target) TARGET="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

command -v go >/dev/null || { echo "error: go not on PATH" >&2; exit 127; }

if [[ -z "$SRC" ]]; then
  SRC="$PROJECT_DIR/build/libtailscale"
  if [[ ! -d "$SRC/.git" ]]; then
    echo ">>> cloning libtailscale ($REF)"
    git clone --depth 1 --branch "$REF" "$REPO" "$SRC"
  fi
fi

# Cross-build env for Android (needs ANDROID_NDK_HOME); host build otherwise.
GOOS_ENV=(); CC_ENV=""; CGO_CFLAGS_ENV=""; CGO_LDFLAGS_ENV=""; GO_BUILD_EXTRA=(); ext=""
case "$TARGET" in
  host)
    case "$(uname -s)" in
      Darwin) ext="dylib";;
      Linux)  ext="so";;
      *) echo "error: unsupported host $(uname -s)" >&2; exit 2;;
    esac
    OUT="${OUT:-$PROJECT_DIR/build/native/tailscale/libtailscale.$ext}";;
  macos-arm64)
    command -v xcrun >/dev/null || { echo "error: xcrun not on PATH" >&2; exit 127; }
    arch="${TARGET#macos-}"
    goarch="arm64"
    clang_arch="arm64"
    sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
    clang="$(xcrun --sdk macosx --find clang)"
    min="${MACOSX_DEPLOYMENT_TARGET:-${MACOS_MIN_VERSION:-11.0}}"
    GOOS_ENV=(GOOS=darwin "GOARCH=$goarch")
    CC_ENV="$clang"
    CGO_CFLAGS_ENV="-arch $clang_arch -isysroot $sdk_path -mmacosx-version-min=$min"
    CGO_LDFLAGS_ENV="$CGO_CFLAGS_ENV"
    GO_BUILD_EXTRA=(-ldflags=-extldflags=-Wl,-headerpad_max_install_names)
    ext="dylib"
    OUT="${OUT:-$PROJECT_DIR/build/native/tailscale/macos/$arch/libtailscale.dylib}";;
  linux-arm64|linux-x64)
    arch="${TARGET#linux-}"
    if [[ "$arch" == "arm64" ]]; then goarch="arm64"; else goarch="amd64"; fi
    GOOS_ENV=(GOOS=linux "GOARCH=$goarch"); ext="so"
    OUT="${OUT:-$PROJECT_DIR/build/native/tailscale/linux/$arch/libtailscale.so}";;
  windows-arm64|windows-x64)
    arch="${TARGET#windows-}"
    if [[ "$arch" == "arm64" ]]; then
      goarch="arm64"; cc_default="aarch64-w64-mingw32-gcc";
    else
      goarch="amd64"; cc_default="x86_64-w64-mingw32-gcc";
    fi
    cc="${CC:-}"
    if [[ -z "$cc" ]]; then
      cc="$(command -v "$cc_default" 2>/dev/null || true)"
    fi
    [[ -n "$cc" ]] || { echo "error: set CC or install $cc_default for windows CGO builds" >&2; exit 127; }
    GOOS_ENV=(GOOS=windows "GOARCH=$goarch"); CC_ENV="$cc"; ext="dll"
    OUT="${OUT:-$PROJECT_DIR/build/native/tailscale/windows/$arch/libtailscale.dll}";;
  android-arm|android-arm64|android-x64)
    if [[ -z "${ANDROID_NDK_HOME:-}" && -d "${ANDROID_HOME:-}/ndk" ]]; then
      ANDROID_NDK_HOME="$(ls -d "${ANDROID_HOME}/ndk"/*/ 2>/dev/null | sort -V | tail -n1)"
      export ANDROID_NDK_HOME
    fi
    : "${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME for android builds}"
    arch="${TARGET#android-}"
    if [[ "$arch" == "arm64" ]]; then
      goarch="arm64"; cc_prefix="aarch64-linux-android29";
    elif [[ "$arch" == "arm" ]]; then
      goarch="arm"; GOOS_ENV+=(GOARM=7); cc_prefix="armv7a-linux-androideabi29";
    else
      goarch="amd64"; cc_prefix="x86_64-linux-android29";
    fi
    cc="$(ls "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/*/bin/"${cc_prefix}-clang" 2>/dev/null | head -n1)"
    [[ -x "$cc" ]] || { echo "error: NDK clang not found ($cc_prefix)" >&2; exit 1; }
    GOOS_ENV=(GOOS=android "GOARCH=$goarch" "${GOOS_ENV[@]}"); CC_ENV="$cc"; ext="so"
    OUT="${OUT:-$PROJECT_DIR/build/native/tailscale/android/$arch/libtailscale.so}";;
  ios|ios-sim|ios-sim-arm64|ios-sim-x64)
    # libtailscale ships iOS as a Go c-archive. Wrap that archive into a
    # dynamic library so all Motif platforms load Tailscale dynamically.
    command -v xcrun >/dev/null || { echo "error: xcrun not on PATH" >&2; exit 127; }
    make_tgt=$([[ "$TARGET" == "ios" ]] && echo c-archive-ios || echo c-archive-ios-sim)
    echo ">>> building libtailscale iOS archive ($make_tgt)"
    ( cd "$SRC" && make "$make_tgt" )
    min="${IOS_MIN_VERSION:-17.0}"
    if [[ "$TARGET" == "ios" ]]; then
      a="libtailscale_ios.a"
      sdk="iphoneos"
      triple="arm64-apple-ios$min"
      OUT="${OUT:-$PROJECT_DIR/build/native/tailscale/$sdk/libtailscale.dylib}"
    else
      sim_arch="${TARGET#ios-sim-}"
      [[ "$sim_arch" == "$TARGET" ]] && sim_arch="arm64"
      if [[ "$sim_arch" == "x64" ]]; then
        a="libtailscale_ios_sim_x86_64.a"
        triple="x86_64-apple-ios$min-simulator"
      else
        a="libtailscale_ios_sim_arm64.a"
        triple="arm64-apple-ios$min-simulator"
      fi
      sdk="iphonesimulator"
      OUT="${OUT:-$PROJECT_DIR/build/native/tailscale/$sdk/$sim_arch/libtailscale.dylib}"
    fi
    mkdir -p "$(dirname "$OUT")"
    sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
    echo ">>> wrapping $a → $OUT"
    xcrun --sdk "$sdk" clang \
      -target "$triple" \
      -isysroot "$sdk_path" \
      -dynamiclib \
      -Wl,-all_load "$SRC/$a" \
      -framework CoreFoundation \
      -framework Security \
      -o "$OUT" \
      -install_name @rpath/libtailscale.dylib
    cp -f "$SRC/${a%.a}.h" "$(dirname "$OUT")/libtailscale.h" 2>/dev/null || true
    echo ">>> built: $OUT"; ls -la "$OUT"; exit 0;;
  *) echo "error: unknown --target '$TARGET'" >&2; exit 2;;
esac

mkdir -p "$(dirname "$OUT")"
echo ">>> building libtailscale ($TARGET) → $OUT"
if [[ -n "$CC_ENV" ]]; then
  ( cd "$SRC" && env CGO_ENABLED=1 "${GOOS_ENV[@]}" CC="$CC_ENV" CGO_CFLAGS="$CGO_CFLAGS_ENV" CGO_LDFLAGS="$CGO_LDFLAGS_ENV" go build -buildmode=c-shared "${GO_BUILD_EXTRA[@]}" -o "$OUT" . )
else
  ( cd "$SRC" && env CGO_ENABLED=1 "${GOOS_ENV[@]}" go build -buildmode=c-shared "${GO_BUILD_EXTRA[@]}" -o "$OUT" . )
fi
# Emit the generated header next to the lib.
cp -f "${OUT%.*}.h" "$(dirname "$OUT")/libtailscale.h" 2>/dev/null || true
echo ">>> built:"
ls -la "$OUT"
