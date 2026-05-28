#!/usr/bin/env bash
# Sync the web build output into Motif/Resources/web so Xcode bundles it.
# Run before xcodegen / build. Idempotent.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
IOS_DIR="$(cd -- "$SCRIPT_DIR/.." &> /dev/null && pwd)"
# `web` is a sibling of `ios` under apps/.
SRC="$(cd -- "$IOS_DIR/../web/dist" &> /dev/null && pwd || true)"
DST="$IOS_DIR/Motif/Resources/web"

if [[ -z "$SRC" || ! -d "$SRC" ]]; then
    echo "error: web bundle not found at $IOS_DIR/../web/dist" >&2
    echo "       did you run 'pnpm --dir apps/web build' first?" >&2
    exit 1
fi

mkdir -p "$DST"
rsync -a --delete --exclude='.DS_Store' "$SRC/" "$DST/"

count=$(find "$DST" -type f | wc -l | tr -d ' ')
echo "sync-web: copied $count files from $SRC -> $DST"
