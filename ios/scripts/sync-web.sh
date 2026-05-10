#!/usr/bin/env bash
# Sync motif-web build output into Motif/Resources/web so Xcode bundles it.
# Run before xcodegen / build. Idempotent.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
IOS_DIR="$(cd -- "$SCRIPT_DIR/.." &> /dev/null && pwd)"
REPO_ROOT="$(cd -- "$IOS_DIR/.." &> /dev/null && pwd)"

SRC="$REPO_ROOT/crates/motif-web/static"
DST="$IOS_DIR/Motif/Resources/web"

if [[ ! -d "$SRC" ]]; then
    echo "error: web bundle not found at $SRC" >&2
    echo "       did you run 'pnpm --dir web build' first?" >&2
    exit 1
fi

mkdir -p "$DST"
rsync -a --delete --exclude='.DS_Store' "$SRC/" "$DST/"

count=$(find "$DST" -type f | wc -l | tr -d ' ')
echo "sync-web: copied $count files from $SRC -> $DST"
