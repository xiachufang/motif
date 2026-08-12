#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
GHOSTTY_DIR="${GHOSTTY_SOURCE_DIR:-$REPO_ROOT/apps/flutter/ghostty}"
ZIG_BIN="${ZIG:-zig}"

if [[ "${1:-}" == "--source" ]]; then
  if [[ -z "${2:-}" ]]; then
    echo "error: --source requires a Ghostty source directory" >&2
    exit 2
  fi
  GHOSTTY_DIR="$2"
  shift 2
fi
if [[ "${1:-}" == "--" ]]; then
  shift
fi

"$SCRIPT_DIR/apply_ghostty_patches.sh" "$GHOSTTY_DIR"

cd "$GHOSTTY_DIR"
exec "$ZIG_BIN" build "$@"
