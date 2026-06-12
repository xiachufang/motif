#!/bin/sh

# Xcode Cloud post-build hook: package the Developer ID-signed Motif.app as a
# .dmg, notarize + staple it, and publish it to a GitHub Release.
#
# Runs AFTER `xcodebuild archive` (and after the workflow's Developer ID
# distribution preparation, which is what signs the app). Unlike the Run Script
# build phase, this hook HAS network access.
#
# Notarization is done here, in-script, with `xcrun notarytool` — Xcode Cloud's
# own Notarize post-action runs AFTER this script and offers no way to get the
# stapled binary back out, so we do it ourselves: notarize the .dmg, then
# `stapler staple` it so it verifies offline and launches on a fresh Mac with no
# Gatekeeper prompt. We do NOT modify the .app after signing (Apple Silicon
# requires the signature stay intact); we only staple the enclosing .dmg.
#
# Division of labour (see ci_post_clone.sh sibling for the build-time half):
#   - Xcode Cloud's Developer ID distribution action signs the app and exposes
#     it via CI_DEVELOPER_ID_SIGNED_APP_PATH. We cannot sign here: the script
#     environment has zero valid codesign identities.
#   - We package the .dmg, notarize + staple it, and upload the GitHub Release.
#
# Required workflow Secret environment variables (set in Xcode Cloud, masked):
#   GH_TOKEN            fine-grained PAT, contents:write on xiachufang/motif
# Notarization (App Store Connect API key — all three, or notarization is
# skipped and we fall back to publishing an un-notarized build):
#   ASC_KEY_ID          the key's 10-char Key ID
#   ASC_ISSUER_ID       the issuer UUID
#   ASC_KEY_P8_BASE64   base64 of the AuthKey_XXXX.p8 (so it survives as one env
#                       line); decoded back to a file at runtime
#
# Only publishes for tag builds (CI_TAG set); other runs are a no-op.

set -e

APP_NAME="Motif"
REPO="xiachufang/motif"

# --- Guard: tag-only -------------------------------------------------------
if [ -z "$CI_TAG" ]; then
  echo "ci_post_xcodebuild: CI_TAG not set; not a tag build, skipping release."
  exit 0
fi
echo "ci_post_xcodebuild: publishing release for tag $CI_TAG"

# --- Locate the Developer ID-signed app ------------------------------------
# Populated only when the workflow has a Developer ID distribution preparation.
# If it's empty the archive is adhoc-signed, which won't reliably launch on
# Apple Silicon even after stripping quarantine, so we can't publish a usable
# build. That's a workflow-config prerequisite, NOT a build failure: the archive
# itself already succeeded, so skip the release with a loud warning and let the
# build stay green. Add a Developer ID distribution preparation to the workflow's
# Archive action to enable publishing.
if [ -z "$CI_DEVELOPER_ID_SIGNED_APP_PATH" ]; then
  echo "WARNING: CI_DEVELOPER_ID_SIGNED_APP_PATH is empty; skipping release for $CI_TAG." >&2
  echo "         The archive is not Developer ID-signed (no Developer ID" >&2
  echo "         distribution preparation on the workflow's Archive action), so" >&2
  echo "         there is no notarizable/launchable app to publish. Add that" >&2
  echo "         preparation in Xcode Cloud to enable tag releases." >&2
  exit 0
fi
APP_PATH="$CI_DEVELOPER_ID_SIGNED_APP_PATH/$APP_NAME.app"
if [ ! -d "$APP_PATH" ]; then
  echo "ERROR: $APP_PATH not found." >&2
  ls -la "$CI_DEVELOPER_ID_SIGNED_APP_PATH" >&2 || true
  exit 1
fi

WORK="${CI_DERIVED_DATA_PATH:-/Volumes/workspace}/release"
rm -rf "$WORK" && mkdir -p "$WORK"

# --- Build the .dmg (drag-to-Applications layout) --------------------------
DMG="$WORK/$APP_NAME-$CI_TAG.dmg"
STAGE="$WORK/dmg"
mkdir -p "$STAGE"
cp -R "$APP_PATH" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" \
  -ov -format UDZO "$DMG"

# --- Notarize + staple the .dmg --------------------------------------------
# notarytool accepts .dmg directly. The .app inside is already Developer ID-
# signed (by the workflow's distribution prep), which notarization requires.
# --wait blocks until Apple finishes and exits non-zero if the build is
# rejected, so a bad notarization fails the release loudly. If the API-key
# secrets aren't configured, skip notarization and fall back to publishing an
# un-notarized (signed) build with the one-time un-quarantine note.
NOTARIZED=0
if [ -n "$ASC_KEY_ID" ] && [ -n "$ASC_ISSUER_ID" ] && [ -n "$ASC_KEY_P8_BASE64" ]; then
  KEY_P8="$WORK/asc_key.p8"
  printf '%s' "$ASC_KEY_P8_BASE64" | base64 --decode > "$KEY_P8"
  echo "ci_post_xcodebuild: submitting $DMG to notarytool (this blocks until done)..."
  xcrun notarytool submit "$DMG" \
    --key "$KEY_P8" \
    --key-id "$ASC_KEY_ID" \
    --issuer "$ASC_ISSUER_ID" \
    --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  rm -f "$KEY_P8"
  NOTARIZED=1
  echo "ci_post_xcodebuild: notarized + stapled $DMG"
else
  echo "WARNING: notarization secrets (ASC_KEY_ID/ASC_ISSUER_ID/ASC_KEY_P8_BASE64)" >&2
  echo "         not all set; publishing an un-notarized (signed) build." >&2
fi

# --- Release notes ---------------------------------------------------------
NOTES="$WORK/notes.md"
if [ "$NOTARIZED" -eq 1 ]; then
  cat > "$NOTES" <<EOF
## 安装

下载 \`$APP_NAME-$CI_TAG.dmg\`，打开后把 **$APP_NAME** 拖到 Applications，双击即可打开。

> 该构建经 Developer ID 签名并已 Apple 公证（notarized + stapled），无需额外步骤。
EOF
else
  cat > "$NOTES" <<EOF
## 安装

1. 下载 \`$APP_NAME-$CI_TAG.dmg\`，打开后把 **$APP_NAME** 拖到 Applications。
2. 首次打开如果提示「无法验证开发者 / 无法打开」，在终端执行一次：
   \`\`\`sh
   xattr -dr com.apple.quarantine /Applications/$APP_NAME.app
   \`\`\`
   之后正常双击打开即可。

> 该构建经 Developer ID 签名但未公证，上述步骤仅首次需要。
EOF
fi

# --- Publish to GitHub Release ---------------------------------------------
command -v gh >/dev/null 2>&1 || brew install gh
export GH_TOKEN
if gh release view "$CI_TAG" --repo "$REPO" >/dev/null 2>&1; then
  gh release upload "$CI_TAG" "$DMG" --repo "$REPO" --clobber
else
  gh release create "$CI_TAG" "$DMG" \
    --repo "$REPO" --title "$CI_TAG" --notes-file "$NOTES"
fi

echo "ci_post_xcodebuild: published $DMG to $REPO release $CI_TAG"
exit 0
