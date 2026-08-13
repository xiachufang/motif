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
GHOSTTY_DIR="$(cd "$GHOSTTY_DIR" && pwd -P)"

shopt -s nullglob
patches=("$PATCH_DIR"/*.patch)
if (( ${#patches[@]} == 0 )); then
  echo "error: no Ghostty patches found under $PATCH_DIR" >&2
  exit 1
fi

if git_dir="$(git -C "$GHOSTTY_DIR" rev-parse --absolute-git-dir 2>/dev/null)"; then
  patch_backend=git
  # Normalize the path through Bash before using mkdir as a cross-process
  # mutex. Git for Windows may otherwise spell the same directory differently
  # depending on the caller's working directory and drive-path representation.
  git_dir="$(cd "$git_dir" && pwd -P)"
  patch_lock="$git_dir/motif-patch.lock"
elif command -v patch >/dev/null 2>&1; then
  # Docker build contexts contain the submodule sources but not the parent
  # repository's .git/modules metadata. The copied submodule .git file points
  # at that missing metadata, so git apply cannot operate there.
  patch_backend=patch
  patch_lock="$GHOSTTY_DIR/.motif-patch.lock"
else
  echo "error: Ghostty patches require git metadata or the patch command" >&2
  exit 1
fi
patch_state_dir="$(dirname "$patch_lock")/motif-patch-state"

# Flutter native-asset hooks may invoke this script concurrently. Applying a
# multi-file patch is not atomic, so serialize the check/apply sequence to keep
# another process from observing a partially patched source tree.
lock_attempt=0
until mkdir "$patch_lock" 2>/dev/null; do
  lock_attempt=$((lock_attempt + 1))
  if (( lock_attempt >= 600 )); then
    echo "error: timed out waiting for Ghostty patch lock: $patch_lock" >&2
    exit 1
  fi
  sleep 0.1
done
cleanup_patch_lock() {
  rmdir "$patch_lock" 2>/dev/null || true
}
trap cleanup_patch_lock EXIT INT TERM
mkdir -p "$patch_state_dir"

patch_state() {
  local patch="$1"
  local relative

  cksum "$patch"
  while IFS= read -r relative; do
    [[ "$relative" == "/dev/null" ]] && continue
    cksum "$GHOSTTY_DIR/$relative"
  done < <(sed -n 's#^+++ b/##p' "$patch")
}

record_patch_state() {
  local patch="$1"
  local state_file="$2"
  patch_state "$patch" > "$state_file"
}

for patch in "${patches[@]}"; do
  name="$(basename "$patch")"
  state_file="$patch_state_dir/$name.state"

  # Git for Windows can fail a reverse apply check after another native-asset
  # hook has already patched the shared checkout. Record the exact checksums of
  # the patch and every affected file so later serialized invocations can
  # recognize the completed state without relying on Git's line-ending logic.
  if [[ -f "$state_file" ]] && cmp -s "$state_file" <(patch_state "$patch"); then
    echo "[ghostty] Patch state verified: $name"
    continue
  fi

  if [[ "$patch_backend" == git ]]; then
    # Reverse-check first makes the operation idempotent for incremental builds.
    if git -C "$GHOSTTY_DIR" apply --reverse --check "$patch" >/dev/null 2>&1; then
      record_patch_state "$patch" "$state_file"
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
      record_patch_state "$patch" "$state_file"
      echo "[ghostty] Applied patch: $name"
    elif git -C "$GHOSTTY_DIR" apply --reverse --check "$patch" >/dev/null 2>&1; then
      record_patch_state "$patch" "$state_file"
      echo "[ghostty] Patch applied by concurrent build: $name"
    else
      echo "error: failed to apply Ghostty patch: $name" >&2
      exit 1
    fi
  elif patch --batch --silent --dry-run --forward -p1 -d "$GHOSTTY_DIR" < "$patch" >/dev/null 2>&1; then
    if patch --batch --silent --forward -p1 -d "$GHOSTTY_DIR" < "$patch"; then
      record_patch_state "$patch" "$state_file"
      echo "[ghostty] Applied patch without Git metadata: $name"
    elif patch --batch --silent --dry-run --reverse -p1 -d "$GHOSTTY_DIR" < "$patch" >/dev/null 2>&1; then
      record_patch_state "$patch" "$state_file"
      echo "[ghostty] Patch applied by concurrent build: $name"
    else
      echo "error: failed to apply Ghostty patch: $name" >&2
      exit 1
    fi
  elif patch --batch --silent --dry-run --reverse -p1 -d "$GHOSTTY_DIR" < "$patch" >/dev/null 2>&1; then
    record_patch_state "$patch" "$state_file"
    echo "[ghostty] Patch already applied: $name"
  else
    echo "error: Ghostty patch does not apply cleanly: $name" >&2
    echo "error: update the patch for the pinned Ghostty revision before building" >&2
    exit 1
  fi
done
