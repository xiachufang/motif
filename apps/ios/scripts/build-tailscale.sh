#!/usr/bin/env bash
# Build TailscaleKit.xcframework from tailscale/libtailscale.
#
# Output: ios/vendor/TailscaleKit.xcframework
#
# First run takes ~5-10 minutes (Go cross-compile for arm64 device + arm64 sim
# + x86_64 sim, then xcodebuild for each, then lipo + xcframework). Subsequent
# runs reuse the Go build cache.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
IOS_DIR="$(cd -- "$SCRIPT_DIR/.." &> /dev/null && pwd)"
VENDOR_DIR="$IOS_DIR/vendor"
SRC_DIR="$VENDOR_DIR/libtailscale"

REPO_URL="${LIBTAILSCALE_REPO:-https://github.com/tailscale/libtailscale.git}"
REF="${LIBTAILSCALE_REF:-main}"

mkdir -p "$VENDOR_DIR"

if [[ ! -d "$SRC_DIR/.git" ]]; then
    echo ">>> cloning libtailscale ($REF) into $SRC_DIR"
    git clone --depth=1 --branch "$REF" "$REPO_URL" "$SRC_DIR"
else
    echo ">>> updating libtailscale in $SRC_DIR"
    git -C "$SRC_DIR" fetch --depth=1 origin "$REF"
    git -C "$SRC_DIR" checkout FETCH_HEAD
fi

# Lower TailscaleKit's iOS deployment target from 18.1 → 18.0 so the resulting
# xcframework can link into apps that target iOS 18.0. TailscaleKit uses
# AsyncSequence<X, Never> (typed throws), introduced in iOS 18.0, so 18.0 is
# the practical floor. If upstream starts using iOS 18.1-only APIs we'll see
# compile errors here.
TARGET_IOS="${TARGET_IOS:-18.0}"
PROJ="$SRC_DIR/swift/TailscaleKit.xcodeproj/project.pbxproj"
echo ">>> setting TailscaleKit IPHONEOS_DEPLOYMENT_TARGET -> $TARGET_IOS"
# Match any version (digits + dots) and replace.
sed -i.bak -E "s/IPHONEOS_DEPLOYMENT_TARGET = [0-9.]+;/IPHONEOS_DEPLOYMENT_TARGET = $TARGET_IOS;/g" "$PROJ"
rm -f "$PROJ.bak"

# Build sequence per libtailscale's swift/Makefile.
# Note: libtailscale's Makefile uses $(PWD) (not $(CURDIR)) to locate the
# clangwrap-ios.sh CC scripts, so we must cd into the source dir before make
# rather than using `make -C`.
(
    cd "$SRC_DIR"
    echo ">>> building libtailscale_ios.a (arm64 device)"
    make c-archive-ios

    echo ">>> building libtailscale_ios_sim.a (arm64+x86_64 simulator, lipo'd)"
    make c-archive-ios-sim
)

(
    cd "$SRC_DIR/swift"
    echo ">>> building TailscaleKit.xcframework"
    make ios-fat
)

XCFW_SRC="$SRC_DIR/swift/build/Build/Products/Release-iphonefat/TailscaleKit.xcframework"
XCFW_DST="$VENDOR_DIR/TailscaleKit.xcframework"

if [[ ! -d "$XCFW_SRC" ]]; then
    echo "error: expected xcframework not found at $XCFW_SRC" >&2
    exit 1
fi

rm -rf "$XCFW_DST"
cp -R "$XCFW_SRC" "$XCFW_DST"

echo ">>> done: $XCFW_DST"
ls -la "$XCFW_DST"
