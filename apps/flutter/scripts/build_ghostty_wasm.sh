#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(cd "$PROJECT_DIR/../.." && pwd)"
GHOSTTY_DIR="$PROJECT_DIR/ghostty"
OUT_DIR="${GHOSTTY_WASM_OUT_DIR:-$PROJECT_DIR/build/ghostty-wasm}"
ZIG_BIN="${ZIG:-zig}"

if ! command -v "$ZIG_BIN" >/dev/null 2>&1; then
  echo "error: Zig 0.16.0 is required to build Ghostty WebAssembly" >&2
  exit 1
fi

zig_version="$($ZIG_BIN version)"
if [[ "$zig_version" != "0.16.0" ]]; then
  echo "error: Zig $zig_version found, but Ghostty requires Zig 0.16.0" >&2
  exit 1
fi

if [[ ! -f "$GHOSTTY_DIR/build.zig" ]]; then
  echo "error: Ghostty source is missing at $GHOSTTY_DIR; initialize submodules" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
echo "[web] Building Ghostty WASM from $GHOSTTY_DIR"
"$REPO_ROOT/scripts/build_ghostty.sh" --source "$GHOSTTY_DIR" -- \
  -Demit-lib-vt=true \
  -Dtarget=wasm32-freestanding \
  -Doptimize=ReleaseSmall \
  --prefix "$OUT_DIR"

wasm="$OUT_DIR/bin/ghostty-vt.wasm"
if [[ ! -f "$wasm" ]]; then
  echo "error: expected Ghostty WASM artifact is missing at $wasm" >&2
  exit 1
fi

cp -f "$wasm" "$PROJECT_DIR/web/ghostty-vt.wasm"
echo "[web] Installed $PROJECT_DIR/web/ghostty-vt.wasm"
