#!/usr/bin/env bash
# 一个终端跑 motifd / vite，两路输出由 foreman 合并并加色彩前缀。
# Rust 端用 cargo-watch 监听对应 crate 自动重启；vite 自带 HMR。
# 实际进程定义在 Procfile.dev 里。
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEV_STATE_DIR="${ROOT_DIR}/.motif-dev"
TOKEN_FILE="${DEV_STATE_DIR}/token.txt"

export MOTIFD_HOST="${MOTIFD_HOST:-127.0.0.1}"
export MOTIFD_PORT="${MOTIFD_PORT:-7777}"
export MOTIFD_LISTEN="${MOTIFD_LISTEN:-${MOTIFD_HOST}:${MOTIFD_PORT}}"
export WEB_HOST="${WEB_HOST:-127.0.0.1}"
export VITE_PORT="${VITE_PORT:-5173}"
export TOKEN_FILE

if ! command -v cargo-watch >/dev/null 2>&1; then
  echo "缺少 cargo-watch，请先安装：cargo install cargo-watch" >&2
  exit 1
fi
if ! command -v foreman >/dev/null 2>&1; then
  echo "缺少 foreman，请先安装：gem install foreman 或 brew install foreman" >&2
  exit 1
fi
if ! command -v pnpm >/dev/null 2>&1; then
  echo "缺少 pnpm，请先安装：npm install -g pnpm" >&2
  exit 1
fi

mkdir -p "$DEV_STATE_DIR"
if [[ ! -s "$TOKEN_FILE" ]]; then
  printf '%s\n' "motif-dev-token" >"$TOKEN_FILE"
fi

# motifd RPC 帧日志：默认写到项目根的 motif-rpc.log（已 gitignore），
# 调试 wire protocol 时直接 `tail -f motif-rpc.log` 即可。
export MOTIFD_RPC_LOG="${MOTIFD_RPC_LOG:-${ROOT_DIR}/motif-rpc.log}"

cat <<EOF
motifd:    http://${MOTIFD_LISTEN}             (cargo watch 自动重启)
vite dev:  http://${WEB_HOST}:${VITE_PORT}     (pnpm dev，API/WS 直连 motifd)
token:     $(cat "$TOKEN_FILE")  (${TOKEN_FILE})
按 Ctrl-C 一起停。
EOF

cd "$ROOT_DIR"
# foreman 自己处理子进程组清理和按行加前缀，省掉旧脚本里的 cleanup / run_labeled / drain_tty。
exec foreman start -f Procfile.dev
