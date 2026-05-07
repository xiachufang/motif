#!/usr/bin/env bash
set -euo pipefail

CONFIG_NAME="${1:-motif-dev}"
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEV_STATE_DIR="${ROOT_DIR}/.motif-dev"
TOKEN_FILE="${DEV_STATE_DIR}/token.txt"
DEV_SESSION_NAME="${MOTIF_DEV_SESSION_NAME:-dev}"
MOTIFD_HOST="${MOTIFD_HOST:-127.0.0.1}"
MOTIFD_PORT="${MOTIFD_PORT:-7777}"
MOTIFD_LISTEN="${MOTIFD_LISTEN:-${MOTIFD_HOST}:${MOTIFD_PORT}}"
WEB_HOST="${WEB_HOST:-127.0.0.1}"
WEB_PORT="${WEB_PORT:-8080}"
WEB_LISTEN="${WEB_LISTEN:-${WEB_HOST}:${WEB_PORT}}"
MOTIFD_URL="${MOTIFD_URL:-ws://${MOTIFD_HOST}:${MOTIFD_PORT}/}"
VITE_DIR="${VITE_DIR:-${ROOT_DIR}/web}"
VITE_PKG_MANAGER="${VITE_PKG_MANAGER:-pnpm}"
VITE_PORT="${VITE_PORT:-5173}"

WARP_DIR="${HOME}/.warp/launch_configurations"
WARP_CONFIG="${WARP_DIR}/${CONFIG_NAME}.yaml"

if ! command -v open >/dev/null 2>&1; then
  echo "需要 macOS 的 open 命令来启动 Warp。"
  exit 1
fi

build_run_cmd() {
  local bin_name="$1"
  local cargo_pkg="$2"
  local args="$3"
  if command -v "$bin_name" >/dev/null 2>&1; then
    printf '%s %s' "$bin_name" "$args"
  else
    printf 'cargo run -p %s --bin %s -- %s' "$cargo_pkg" "$bin_name" "$args"
  fi
}

mkdir -p "$DEV_STATE_DIR"
if [[ ! -s "$TOKEN_FILE" ]]; then
  printf '%s\n' "motif-dev-token" >"$TOKEN_FILE"
fi

MOTIFD_RUN_CMD="$(build_run_cmd motifd motif-server "--listen $MOTIFD_LISTEN --token-file \"$TOKEN_FILE\"")"
MOTIF_WEB_RUN_CMD="$(build_run_cmd motif-web motif-web "--listen $WEB_LISTEN --motifd-url \"$MOTIFD_URL\" --motifd-token-file \"$TOKEN_FILE\" --browser-token-file \"$TOKEN_FILE\"")"
MOTIF_TUI_BASE_CMD="$(build_run_cmd motif-tui motif-tui "")"

# /dev/tcp 是 bash 内建，所以 TUI 的等待循环用 bash -lc 包一层。
MOTIF_TUI_RUN_CMD="bash -lc 'export MOTIF_TOKEN_FILE=\"$TOKEN_FILE\"; until (echo > /dev/tcp/$MOTIFD_HOST/$MOTIFD_PORT) >/dev/null 2>&1; do sleep 0.2; done; $MOTIF_TUI_BASE_CMD new \"$MOTIFD_URL\" --name \"$DEV_SESSION_NAME\" --workdir \"$ROOT_DIR\" >/dev/null 2>&1 || true; exec $MOTIF_TUI_BASE_CMD attach \"$MOTIFD_URL\" --session \"$DEV_SESSION_NAME\"'"

# vite dev 不依赖 motif-web 进程启动顺序（只在收到请求时才 proxy），直接起即可。
# 用 bash -lc 走登录 shell，保证 pnpm/node 的 PATH（fnm、~/Library/pnpm 之类）
# 都被加载；纯 exec 在 Warp 里有时会因为 PATH 不全直接挂掉。
VITE_RUN_CMD="bash -lc 'cd \"$VITE_DIR\" && exec $VITE_PKG_MANAGER dev'"

mkdir -p "$WARP_DIR"

# Warp launch config 用 YAML 单引号串：内部单引号需要写成 ''。
# 注意：bash 替换里反斜杠不是转义符，`\'\'` 会被当成字面 4 个字符；
# 所以替换串必须是纯 `''`（两个单引号）。
yaml_quote() {
  local s="$1"
  local sq="'"
  s="${s//$sq/$sq$sq}"
  printf "'%s'" "$s"
}

cat >"$WARP_CONFIG" <<EOF
---
name: $CONFIG_NAME
windows:
  - tabs:
      - title: motif-dev
        layout:
          split_direction: horizontal
          panes:
            - split_direction: vertical
              panes:
                - cwd: $(yaml_quote "$ROOT_DIR")
                  commands:
                    - exec: $(yaml_quote "$MOTIFD_RUN_CMD")
                - cwd: $(yaml_quote "$ROOT_DIR")
                  commands:
                    - exec: $(yaml_quote "$MOTIF_WEB_RUN_CMD")
            - split_direction: vertical
              panes:
                - cwd: $(yaml_quote "$VITE_DIR")
                  commands:
                    - exec: $(yaml_quote "$VITE_RUN_CMD")
                - cwd: $(yaml_quote "$ROOT_DIR")
                  commands:
                    - exec: $(yaml_quote "$MOTIF_TUI_RUN_CMD")
        is_active: true
EOF

echo "已写入 Warp launch config: $WARP_CONFIG"
open "warp://launch/$CONFIG_NAME"

cat <<EOF

Warp launch config: $CONFIG_NAME
已启动: motifd / motif-web / vite / motif-tui
motifd:     ws://$MOTIFD_LISTEN/ws
motif-web:  http://$WEB_LISTEN          (生产形态：内嵌前端)
vite dev:   http://$WEB_HOST:$VITE_PORT  (开发形态：HMR，proxy /ws,/blob -> motif-web)
token file: $TOKEN_FILE
说明: Warp 各 pane 相互独立，关掉一个不会联动关其它，需要自己管理。
EOF
