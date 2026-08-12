#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
GHOSTTY_DIR="${1:-$REPO_ROOT/apps/flutter/ghostty}"
PATCH_DIR="$REPO_ROOT/patches/ghostty"

if [[ ! -f "$GHOSTTY_DIR/build.zig" ]]; then
  echo "error: Ghostty source is missing at $GHOSTTY_DIR; initialize submodules" >&2
  exit 1
fi

shopt -s nullglob
patches=("$PATCH_DIR"/*.patch)
if (( ${#patches[@]} == 0 )); then
  echo "error: no Ghostty patches found under $PATCH_DIR" >&2
  exit 1
fi

for patch in "${patches[@]}"; do
  name="$(basename "$patch")"

  # Reverse-check first makes the operation idempotent for incremental builds.
  if git -C "$GHOSTTY_DIR" apply --reverse --check "$patch" >/dev/null 2>&1; then
    echo "[ghostty] Patch already applied: $name"
    continue
  fi

  if ! git -C "$GHOSTTY_DIR" apply --check "$patch"; then
    echo "error: Ghostty patch does not apply cleanly: $name" >&2
    echo "error: update the patch for the pinned Ghostty revision before building" >&2
    exit 1
  fi

  # Another concurrent build may apply it between check and apply. Accept that
  # only when the complete reverse check succeeds afterwards.
  if git -C "$GHOSTTY_DIR" apply "$patch"; then
    echo "[ghostty] Applied patch: $name"
  elif git -C "$GHOSTTY_DIR" apply --reverse --check "$patch" >/dev/null 2>&1; then
    echo "[ghostty] Patch applied by concurrent build: $name"
  else
    echo "error: failed to apply Ghostty patch: $name" >&2
    exit 1
  fi
done
