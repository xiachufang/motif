#!/bin/sh

# Xcode Cloud post-build hook: package the signed Motif.app as a .dmg and publish
# it to a GitHub Release. No notarization (see note below).
#
# Runs AFTER `xcodebuild archive` (and after the workflow's Developer ID
# distribution preparation, which exposes the exported app). Unlike the Run
# Script build phase, this hook HAS network access.
#
# We do NOT notarize. The team has no Developer ID Application certificate, so
# Xcode Cloud's "Developer ID" export is actually ad-hoc signed (TeamIdentifier
# not set, CodeDirectory flags=0x2) — which notarization rejects ("not signed
# with a valid Developer ID certificate", "no secure timestamp", "hardened
# runtime not enabled"). Ad-hoc is fine for side-loaded distribution on Apple
# Silicon as long as the user clears the quarantine flag once after download:
#     xattr -dr com.apple.quarantine /Applications/Motif.app
# then it launches normally. Do NOT modify the bundle after signing. The release
# notes below spell this out for whoever downloads.
#
# To switch to real notarized distribution later: the Account Holder creates a
# Developer ID Application certificate, enable ENABLE_HARDENED_RUNTIME in the
# Runner target, then notarize+staple the .dmg here with `xcrun notarytool`.
#
# Division of labour (see ci_post_clone.sh sibling for the build-time half):
#   - Xcode Cloud's distribution preparation exports the app and exposes it via
#     CI_DEVELOPER_ID_SIGNED_APP_PATH. We cannot sign here: the script
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

# --- Locate the exported app -----------------------------------------------
# Populated only when the workflow has a distribution preparation on the Archive
# action. If it's empty there's nothing to package: that's a workflow-config
# prerequisite, NOT a build failure (the archive itself already succeeded), so
# skip the release with a loud warning and let the build stay green.
if [ -z "$CI_DEVELOPER_ID_SIGNED_APP_PATH" ]; then
  echo "WARNING: CI_DEVELOPER_ID_SIGNED_APP_PATH is empty; skipping release for $CI_TAG." >&2
  echo "         No distribution preparation on the workflow's Archive action, so" >&2
  echo "         there is no exported app to publish. Add one in Xcode Cloud to" >&2
  echo "         enable tag releases." >&2
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

> 该构建为 ad-hoc 签名、未公证，上述步骤仅首次需要。
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
