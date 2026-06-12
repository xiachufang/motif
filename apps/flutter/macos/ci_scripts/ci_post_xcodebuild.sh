#!/bin/sh

# Xcode Cloud post-build hook: package the Developer ID-signed Motif.app as a
# .dmg and publish it to a GitHub Release. No notarization (see note below).
#
# Runs AFTER `xcodebuild archive` (and after the workflow's Developer ID
# distribution preparation, which is what signs the app). Unlike the Run Script
# build phase, this hook HAS network access.
#
# We do NOT notarize. The app is Developer ID-signed, so on a fresh Mac
# Gatekeeper will refuse the first launch ("Apple could not verify..."). Users
# strip the quarantine flag once after download:
#     xattr -dr com.apple.quarantine /Applications/Motif.app
# then it launches normally. The signature itself stays valid (Apple Silicon
# requires that), so do NOT modify the bundle after signing. The release notes
# below spell this out for whoever downloads.
#
# Division of labour (see ci_post_clone.sh sibling for the build-time half):
#   - Xcode Cloud's Developer ID distribution action signs the app and exposes
#     it via CI_DEVELOPER_ID_SIGNED_APP_PATH. We cannot sign here: the script
#     environment has zero valid codesign identities.
#   - We package the .dmg and upload the GitHub Release.
#
# Required workflow Secret environment variable (set in Xcode Cloud, masked):
#   GH_TOKEN   fine-grained PAT, contents:write on xiachufang/motif
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

# --- Release notes (with the un-quarantine instructions) -------------------
NOTES="$WORK/notes.md"
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
