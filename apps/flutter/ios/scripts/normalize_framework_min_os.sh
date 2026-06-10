#!/bin/sh
#
# Normalize the MinimumOSVersion of every embedded framework to the app's
# deployment target, then re-sign the framework.
#
# Why: the ghostty-vt and tailscale native-asset dylibs are compiled with a
# minos of iOS 17 (ghostty's floor; tailscale gets IOS_MIN_VERSION=17 in CI),
# but Flutter hardcodes `MinimumOSVersion = 13.0` into the generated
# `*.framework/Info.plist` when it wraps a bundled dylib. App Store validation
# then rejects the upload with ITMS-90208 ("does not support the minimum OS
# Version specified in the Info.plist") because the binary's minos is higher
# than the version the plist claims to support.
#
# Setting each framework's MinimumOSVersion to IPHONEOS_DEPLOYMENT_TARGET keeps
# the plist consistent with both the binary (minos <= target) and the host app.
# Modifying Info.plist invalidates the framework's signature, so we re-sign;
# Xcode then re-seals the whole .app in its final CodeSign step.

set -e

FRAMEWORKS_DIR="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
if [ ! -d "$FRAMEWORKS_DIR" ]; then
  echo "normalize_framework_min_os: no Frameworks dir ($FRAMEWORKS_DIR), skipping"
  exit 0
fi

MIN_OS="${IPHONEOS_DEPLOYMENT_TARGET}"
if [ -z "$MIN_OS" ]; then
  echo "normalize_framework_min_os: IPHONEOS_DEPLOYMENT_TARGET unset, skipping"
  exit 0
fi

for fw in "$FRAMEWORKS_DIR"/*.framework; do
  [ -d "$fw" ] || continue
  plist="$fw/Info.plist"
  [ -f "$plist" ] || continue

  cur=$(/usr/libexec/PlistBuddy -c "Print :MinimumOSVersion" "$plist" 2>/dev/null || echo "")
  [ "$cur" = "$MIN_OS" ] && continue

  echo "normalize_framework_min_os: $(basename "$fw") MinimumOSVersion ${cur:-<none>} -> $MIN_OS"
  /usr/libexec/PlistBuddy -c "Set :MinimumOSVersion $MIN_OS" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :MinimumOSVersion string $MIN_OS" "$plist"

  # Re-sign so the edited Info.plist is covered. EXPANDED_CODE_SIGN_IDENTITY is
  # set for signed (device/archive) builds; "-" ad-hoc for simulator/unsigned.
  identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
  /usr/bin/codesign --force --sign "$identity" \
    ${OTHER_CODE_SIGN_FLAGS:-} \
    --preserve-metadata=identifier,entitlements,flags \
    "$fw"
done
