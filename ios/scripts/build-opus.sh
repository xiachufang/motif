#!/usr/bin/env bash
# Build libopus as Opus.xcframework for iOS device + simulator.
#
# Output: ios/vendor/Opus.xcframework
#
# Approach: download source tarball, drive Opus's CMake config for each
# iOS slice, lipo the sim slices, then xcodebuild -create-xcframework.

set -euo pipefail

OPUS_VERSION="${OPUS_VERSION:-1.5.2}"
IOS_TARGET="${IOS_TARGET:-18.0}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
IOS_DIR="$(cd -- "$SCRIPT_DIR/.." &> /dev/null && pwd)"
VENDOR_DIR="$IOS_DIR/vendor"
SRC_DIR="$VENDOR_DIR/opus"
BUILD_ROOT="$VENDOR_DIR/opus-build"

mkdir -p "$VENDOR_DIR"

if [[ ! -d "$SRC_DIR" ]]; then
    echo ">>> cloning opus tag v$OPUS_VERSION"
    git clone --depth=1 --branch "v$OPUS_VERSION" \
        https://github.com/xiph/opus.git "$SRC_DIR"
fi

build_slice() {
    local sysroot=$1   # iphoneos | iphonesimulator
    local arch=$2      # arm64 | x86_64
    local out="$BUILD_ROOT/$sysroot-$arch"

    if [[ -f "$out/libopus.a" ]]; then
        echo ">>> $sysroot-$arch already built (skip)"
        return
    fi

    rm -rf "$out"
    mkdir -p "$out"

    echo ">>> building opus for $sysroot-$arch"
    cmake -S "$SRC_DIR" -B "$out" \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_ARCHITECTURES="$arch" \
        -DCMAKE_OSX_SYSROOT="$sysroot" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_TARGET" \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF \
        -DOPUS_BUILD_PROGRAMS=OFF \
        -DOPUS_BUILD_TESTING=OFF \
        -DOPUS_INSTALL_PKG_CONFIG_MODULE=OFF \
        -DOPUS_INSTALL_CMAKE_CONFIG_MODULE=OFF \
        > "$out/cmake-config.log" 2>&1
    cmake --build "$out" --config Release --parallel \
        > "$out/cmake-build.log" 2>&1
}

build_slice iphoneos          arm64
build_slice iphonesimulator   arm64
build_slice iphonesimulator   x86_64

# lipo simulator slices.
SIM_LIPO="$BUILD_ROOT/sim-lipo"
mkdir -p "$SIM_LIPO"
lipo -create \
    "$BUILD_ROOT/iphonesimulator-arm64/libopus.a" \
    "$BUILD_ROOT/iphonesimulator-x86_64/libopus.a" \
    -output "$SIM_LIPO/libopus.a"

# Stage headers + module.modulemap for each xcframework slice.
stage_slice() {
    local libfile=$1
    local outdir=$2
    rm -rf "$outdir"
    mkdir -p "$outdir/Headers"
    cp "$libfile" "$outdir/libopus.a"
    cp "$SRC_DIR/include/opus.h"          "$outdir/Headers/"
    cp "$SRC_DIR/include/opus_defines.h"  "$outdir/Headers/"
    cp "$SRC_DIR/include/opus_types.h"    "$outdir/Headers/"
    cp "$SRC_DIR/include/opus_multistream.h" "$outdir/Headers/" 2>/dev/null || true
    cat > "$outdir/Headers/module.modulemap" <<'EOF'
module COpus {
    umbrella header "opus.h"
    export *
    module * { export * }
}
EOF
}

stage_slice "$BUILD_ROOT/iphoneos-arm64/libopus.a" "$BUILD_ROOT/stage-ios"
stage_slice "$SIM_LIPO/libopus.a" "$BUILD_ROOT/stage-sim"

XCFW="$VENDOR_DIR/Opus.xcframework"
rm -rf "$XCFW"
xcodebuild -create-xcframework \
    -library "$BUILD_ROOT/stage-ios/libopus.a" \
        -headers "$BUILD_ROOT/stage-ios/Headers" \
    -library "$BUILD_ROOT/stage-sim/libopus.a" \
        -headers "$BUILD_ROOT/stage-sim/Headers" \
    -output "$XCFW"

echo ">>> done: $XCFW"
ls -la "$XCFW"
