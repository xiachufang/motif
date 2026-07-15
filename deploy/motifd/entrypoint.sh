#!/usr/bin/env bash
set -euo pipefail

listen="${MOTIFD_LISTEN:-0.0.0.0:7777}"
log="${MOTIFD_LOG:-info}"
rpc_log="${MOTIFD_RPC_LOG:-}"
push_relay_url="${MOTIFD_PUSH_RELAY_URL:-}"

args=(--log "$log")

if [[ -n "$listen" && "$listen" != "off" && "$listen" != "none" ]]; then
    args+=(--listen "$listen")
fi

# A non-loopback --listen is auto-encrypted (self-signed TLS, the client pins
# the cert) and authenticated (psk-derived bearer); motifd prints a motif://pair
# link/QR carrying its psk + pin. Pass a fixed psk for a stable link across
# restarts (the TLS identity persists under the data dir — bind-mount it too).
[[ -n "${MOTIFD_PSK:-}" ]] && args+=(--psk "$MOTIFD_PSK")
[[ -n "${MOTIFD_PSK_FILE:-}" ]] && args+=(--psk-file "$MOTIFD_PSK_FILE")
# Host(s) put in the direct pairing QR for a public/NAT server (default: all
# local NIC IPs). Comma-separate multiple.
[[ -n "${MOTIFD_ADVERTISE_HOST:-}" ]] && args+=(--advertise-host "$MOTIFD_ADVERTISE_HOST")

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
    [[ -n "${MOTIFD_RZV_JWT_FILE:-}" ]] && args+=(--rzv-jwt-file "$MOTIFD_RZV_JWT_FILE")
    [[ -n "${MOTIFD_RZV_POOL:-}" ]] && args+=(--rzv-pool "$MOTIFD_RZV_POOL")
fi

if [[ "$#" -gt 0 ]]; then
    exec "$@"
fi

exec motifd "${args[@]}"
