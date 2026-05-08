#!/usr/bin/env bash
# 一个终端跑 motifd / motif-web / vite，三路输出混在一起。
# Rust 端用 cargo-watch 监听对应 crate 自动重启；vite 自带 HMR，启动后不动。
set -euo pipefail
# 开 monitor mode，让下面 `( ... ) &` 的每个子 shell 自成进程组，
# cleanup 才能用 `kill -- -PGID` 把 cargo watch / pnpm 整组带走。
set -m

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEV_STATE_DIR="${ROOT_DIR}/.motif-dev"
TOKEN_FILE="${DEV_STATE_DIR}/token.txt"

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

if ! command -v cargo-watch >/dev/null 2>&1; then
  echo "缺少 cargo-watch，请先安装：cargo install cargo-watch" >&2
  exit 1
fi

mkdir -p "$DEV_STATE_DIR"
if [[ ! -s "$TOKEN_FILE" ]]; then
  printf '%s\n' "motif-dev-token" >"$TOKEN_FILE"
fi

# motifd RPC 帧日志：默认写到项目根的 motif-rpc.log（已 gitignore），
# 调试 wire protocol 时直接 `tail -f motif-rpc.log` 即可。
export MOTIFD_RPC_LOG="${MOTIFD_RPC_LOG:-${ROOT_DIR}/motif-rpc.log}"

# 给每路输出加彩色前缀。
# - stdbuf -oL 让 cargo / pnpm 在管道里也按行 flush。
# - tr '\r' '\n' 把 cargo / vite 进度条的原地刷新（CR）切成多行，
#   否则按行 prefix 时整段会被压成一根巨长的空白。
# - awk + fflush() 跨 BSD / GNU 都能稳定按行加前缀。
run_labeled() {
  local label="$1" color="$2"; shift 2
  local prefix
  printf -v prefix '\033[1;%sm[%-6s]\033[0m ' "$color" "$label"
  local STDBUF=""
  if command -v stdbuf >/dev/null 2>&1; then STDBUF="stdbuf -oL"; fi
  $STDBUF "$@" 2>&1 \
    | $STDBUF tr '\r' '\n' \
    | awk -v p="$prefix" '{ print p $0; fflush() }'
}

pids=()
cleanup() {
  trap - INT TERM EXIT
  for pid in "${pids[@]}"; do
    # 整组干掉，避免 cargo watch 留下子进程
    kill -- -"$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
}
trap cleanup INT TERM EXIT

# motifd：watch motif-server + 共享 crate
( cd "$ROOT_DIR" && \
  run_labeled motifd 36 cargo watch \
    -w crates/motif-server -w crates/motif-proto -w crates/motif-tailscale \
    -x "run -q -p motif-server --bin motifd -- --listen $MOTIFD_LISTEN --token-file $TOKEN_FILE" \
) &
pids+=($!)

# motif-web：watch motif-web + 共享 crate
( cd "$ROOT_DIR" && \
  run_labeled web 33 cargo watch \
    -w crates/motif-web -w crates/motif-proto \
    -x "run -q -p motif-web --bin motif-web -- --listen $WEB_LISTEN --motifd-url $MOTIFD_URL --motifd-token-file $TOKEN_FILE --browser-token-file $TOKEN_FILE" \
) &
pids+=($!)

# vite：常驻，HMR 自己处理
( cd "$VITE_DIR" && \
  run_labeled vite 35 "$VITE_PKG_MANAGER" dev --host "$WEB_HOST" --port "$VITE_PORT" \
) &
pids+=($!)

cat <<EOF
motifd:    ws://${MOTIFD_LISTEN}/ws    (cargo watch 自动重启)
motif-web: http://${WEB_LISTEN}        (cargo watch 自动重启)
vite dev:  http://${WEB_HOST}:${VITE_PORT}      (HMR；proxy /ws,/blob -> motif-web)
token:     ${TOKEN_FILE}
按 Ctrl-C 一起停。
EOF

wait
