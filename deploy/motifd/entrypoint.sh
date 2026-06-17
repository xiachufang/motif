#!/usr/bin/env bash
set -euo pipefail

listen="${MOTIFD_LISTEN:-0.0.0.0:7777}"
token_file="${MOTIFD_TOKEN_FILE:-}"
token="${MOTIFD_TOKEN:-}"
log="${MOTIFD_LOG:-info}"
rpc_log="${MOTIFD_RPC_LOG:-}"
push_relay_url="${MOTIFD_PUSH_RELAY_URL:-}"

args=(--log "$log")

if [[ -n "$listen" && "$listen" != "off" && "$listen" != "none" ]]; then
    args+=(--listen "$listen")
fi

tmp_token_file=""
cleanup() {
    if [[ -n "$tmp_token_file" && -f "$tmp_token_file" ]]; then
        rm -f "$tmp_token_file"
    fi
}
trap cleanup EXIT

if [[ -n "$token_file" ]]; then
    args+=(--token-file "$token_file")
elif [[ -n "$token" ]]; then
    tmp_token_file="$(mktemp /tmp/motifd-token.XXXXXX)"
    chmod 0600 "$tmp_token_file"
    printf '%s\n' "$token" > "$tmp_token_file"
    args+=(--token-file "$tmp_token_file")
fi

if [[ "${MOTIFD_INSECURE_NO_AUTH:-}" == "1" || "${MOTIFD_INSECURE_NO_AUTH:-}" == "true" ]]; then
    args+=(--insecure-no-auth)
fi

if [[ -n "$rpc_log" ]]; then
    args+=(--rpc-log "$rpc_log")
fi

if [[ -n "$push_relay_url" ]]; then
    args+=(--push-relay-url "$push_relay_url")
fi

if [[ "${MOTIFD_TAILSCALE:-}" == "1" || "${MOTIFD_TAILSCALE:-}" == "true" ]]; then
    args+=(--tailscale)
    [[ -n "${MOTIFD_TAILSCALE_HOSTNAME:-}" ]] && args+=(--tailscale-hostname "$MOTIFD_TAILSCALE_HOSTNAME")
    [[ -n "${MOTIFD_TAILSCALE_STATE_DIR:-}" ]] && args+=(--tailscale-state-dir "$MOTIFD_TAILSCALE_STATE_DIR")
    [[ -n "${MOTIFD_TAILSCALE_PORT:-}" ]] && args+=(--tailscale-port "$MOTIFD_TAILSCALE_PORT")
    [[ -n "${MOTIFD_TAILSCALE_AUTHKEY:-}" ]] && args+=(--tailscale-authkey "$MOTIFD_TAILSCALE_AUTHKEY")
    [[ -n "${MOTIFD_TAILSCALE_CONTROL_URL:-}" ]] && args+=(--tailscale-control-url "$MOTIFD_TAILSCALE_CONTROL_URL")
    if [[ "${MOTIFD_TAILSCALE_EPHEMERAL:-}" == "1" || "${MOTIFD_TAILSCALE_EPHEMERAL:-}" == "true" ]]; then
        args+=(--tailscale-ephemeral)
    fi
fi

if [[ -n "${MOTIFD_RZV_RELAY:-}" ]]; then
    args+=(--rzv-relay "$MOTIFD_RZV_RELAY")
    [[ -n "${MOTIFD_RZV_PSK:-}" ]] && args+=(--rzv-psk "$MOTIFD_RZV_PSK")
    [[ -n "${MOTIFD_RZV_PSK_FILE:-}" ]] && args+=(--rzv-psk-file "$MOTIFD_RZV_PSK_FILE")
    [[ -n "${MOTIFD_RZV_POOL:-}" ]] && args+=(--rzv-pool "$MOTIFD_RZV_POOL")
    if [[ "${MOTIFD_RZV_NO_TLS:-}" == "1" || "${MOTIFD_RZV_NO_TLS:-}" == "true" ]]; then
        args+=(--rzv-no-tls)
    fi
fi

if [[ "$#" -gt 0 ]]; then
    exec "$@"
fi

exec motifd "${args[@]}"
