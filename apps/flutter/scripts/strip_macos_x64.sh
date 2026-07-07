#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: strip_macos_x64.sh <Motif.app> [--resign] [--entitlements <plist>]

Removes x86_64 slices from Mach-O files in a macOS app bundle. If --resign is
set, nested frameworks are ad-hoc re-signed first, then the app bundle.
EOF
}

APP_PATH=""
RESIGN=0
ENTITLEMENTS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --resign)
      RESIGN=1
      shift
      ;;
    --entitlements)
      [[ -n "${2:-}" ]] || { echo "error: --entitlements needs a path" >&2; exit 2; }
      ENTITLEMENTS="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "error: unknown option '$1'" >&2
      usage >&2
      exit 2
      ;;
    *)
      [[ -z "$APP_PATH" ]] || { echo "error: unexpected argument '$1'" >&2; exit 2; }
      APP_PATH="$1"
      shift
      ;;
  esac
done

[[ -n "$APP_PATH" ]] || { usage >&2; exit 2; }
[[ -d "$APP_PATH" ]] || { echo "error: app bundle not found: $APP_PATH" >&2; exit 1; }

command -v lipo >/dev/null || { echo "error: lipo not on PATH" >&2; exit 127; }
if [[ "$RESIGN" == "1" ]]; then
  command -v codesign >/dev/null || { echo "error: codesign not on PATH" >&2; exit 127; }
  if [[ -n "$ENTITLEMENTS" && ! -f "$ENTITLEMENTS" ]]; then
    echo "error: entitlements file not found: $ENTITLEMENTS" >&2
    exit 1
  fi
fi

stripped=0
while IFS= read -r -d '' file; do
  archs="$(lipo -archs "$file" 2>/dev/null || true)"
  [[ -n "$archs" ]] || continue
  case " $archs " in
    *" x86_64 "*)
      case " $archs " in
        *" arm64 "*) ;;
        *)
          echo "error: $file has x86_64 but no arm64 slice ($archs)" >&2
          exit 1
          ;;
      esac
      mode="$(stat -f '%Lp' "$file")"
      tmp="$file.strip.$$"
      lipo "$file" -remove x86_64 -output "$tmp"
      chmod "$mode" "$tmp"
      mv "$tmp" "$file"
      stripped=$((stripped + 1))
      echo "stripped x86_64: $file"
      ;;
  esac
done < <(find "$APP_PATH" -type f -print0)

if [[ "$RESIGN" == "1" ]]; then
  frameworks_dir="$APP_PATH/Contents/Frameworks"
  if [[ -d "$frameworks_dir" ]]; then
    while IFS= read -r -d '' framework; do
      codesign --force --sign - --timestamp=none "$framework"
    done < <(find "$frameworks_dir" -maxdepth 1 -type d -name '*.framework' -print0)
  fi

  sign_args=(--force --sign - --timestamp=none)
  if [[ -n "$ENTITLEMENTS" ]]; then
    sign_args+=(--entitlements "$ENTITLEMENTS")
  fi
  codesign "${sign_args[@]}" "$APP_PATH"
fi

echo "strip_macos_x64: removed x86_64 from $stripped file(s)"
