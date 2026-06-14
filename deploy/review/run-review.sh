#!/usr/bin/env bash
#
# run-review.sh — launch a hardened, throwaway motifd for App Review.
#
# Threat model: the bearer token is handed to Apple (and written in review
# notes), so treat it as public for the review window. Anyone with it gets a
# real shell + file read "anywhere the process can reach". This script's whole
# job is to make that survivable:
#
#   * non-root, all capabilities dropped, no-new-privileges, read-only rootfs
#   * pids / memory / cpu caps so a fork bomb or miner can't take the box down
#   * an isolated docker network with egress firewalling: the container CANNOT
#     reach the cloud metadata endpoint (169.254.169.254) or any RFC1918 LAN
#     address, so a token holder can't steal cloud credentials or pivot inside
#     your VPS. Public internet stays reachable (toggle with --egress none).
#   * optional gVisor (runsc) runtime for kernel-level syscall isolation —
#     used automatically if installed.
#   * the token is random per run and shredded on exit; the container and its
#     network are torn down on exit.
#
# motifd does not terminate TLS. Front it with `cloudflared tunnel` (or your
# reverse proxy) for a trusted wss:// URL the iOS app can use. Pass --tunnel to
# have this script start cloudflared for you.
#
# Usage:
#   deploy/review/run-review.sh [--build] [--tunnel] [--egress restricted|none]
#                               [--port N] [--image NAME] [--workspace-size SIZE]
#
#   --build            docker build the image first (from repo root)
#   --tunnel           start `cloudflared tunnel --url http://127.0.0.1:PORT`
#   --egress none      drop ALL container egress (default: restricted = block
#                      metadata + RFC1918 only, allow public internet)
#   --port N           host port to publish (default 8080)
#   --bind ADDR        host interface to publish on (default 127.0.0.1). Use
#                      0.0.0.0 for direct public exposure (open the port in your
#                      firewall/security group yourself; the bearer token is the
#                      only auth, and motifd speaks plaintext ws:// — fine only
#                      if the client allows non-TLS, e.g. an iOS ATS exception).
#   --image NAME       image tag (default motifd:review)
#   --workspace-size   tmpfs size for /home/demo/work (default 128m)
#
set -euo pipefail

# ---- config ---------------------------------------------------------------
IMAGE="motifd:review"
PORT=8080
BIND="127.0.0.1"         # host interface to publish on; 0.0.0.0 = public
EGRESS="restricted"      # restricted | none
WORKSPACE_SIZE="128m"
DO_BUILD=0
DO_TUNNEL=0
NET_SUBNET="172.31.244.0/24"   # private, unlikely to collide; used in fw rules
NET_NAME="motif-review-net"
CTR_NAME="motifd-review"

while [ $# -gt 0 ]; do
    case "$1" in
        --build) DO_BUILD=1 ;;
        --tunnel) DO_TUNNEL=1 ;;
        --egress) EGRESS="${2:?}"; shift ;;
        --port) PORT="${2:?}"; shift ;;
        --bind) BIND="${2:?}"; shift ;;
        --image) IMAGE="${2:?}"; shift ;;
        --workspace-size) WORKSPACE_SIZE="${2:?}"; shift ;;
        -h|--help) sed -n '2,42p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done

case "$EGRESS" in restricted|none) ;; *) echo "--egress must be restricted|none" >&2; exit 2 ;; esac
command -v docker >/dev/null || { echo "docker not found" >&2; exit 1; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# ---- root / iptables capability check -------------------------------------
# Egress firewalling edits the DOCKER-USER chain, which needs root + iptables.
SUDO=""
if [ "$(id -u)" -ne 0 ]; then SUDO="sudo"; fi
HAVE_IPTABLES=1
command -v iptables >/dev/null || HAVE_IPTABLES=0
if [ "$HAVE_IPTABLES" -eq 0 ]; then
    echo "WARNING: iptables not found — cannot firewall container egress." >&2
    echo "         The container could reach your LAN / cloud metadata. Install" >&2
    echo "         iptables, or only run this on a host with nothing else on it." >&2
    if [ "$EGRESS" = "none" ]; then echo "--egress none requires iptables." >&2; exit 1; fi
fi

# ---- token ----------------------------------------------------------------
TOKEN_DIR="$(mktemp -d)"
TOKEN_FILE="$TOKEN_DIR/motifd_token"
umask 077
if command -v openssl >/dev/null; then
    openssl rand -hex 32 > "$TOKEN_FILE"
else
    head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$TOKEN_FILE"
fi
TOKEN="$(cat "$TOKEN_FILE")"
# The container runs as uid 10001 and bind-mounts this file read-only. On Linux
# a bind mount preserves host ownership/perms, so a 0600 file (umask above) is
# unreadable by the container user — motifd then exits with "token-file:
# Permission denied". Make the file world-readable; it still sits inside the
# 0700 mktemp dir, so no other host user can reach it.
chmod 0644 "$TOKEN_FILE"

# ---- cleanup --------------------------------------------------------------
FW_RULES=()           # exact rule specs we inserted, for precise removal
TUNNEL_PID=""
cleanup() {
    set +e
    [ -n "$TUNNEL_PID" ] && kill "$TUNNEL_PID" 2>/dev/null
    docker rm -f "$CTR_NAME" >/dev/null 2>&1
    # remove firewall rules we added (reverse order)
    for ((i=${#FW_RULES[@]}-1; i>=0; i--)); do
        $SUDO iptables -D ${FW_RULES[$i]} 2>/dev/null
    done
    docker network rm "$NET_NAME" >/dev/null 2>&1
    # shred the token
    command -v shred >/dev/null && shred -u "$TOKEN_FILE" 2>/dev/null || rm -f "$TOKEN_FILE"
    rm -rf "$TOKEN_DIR"
    echo "cleaned up." >&2
}
trap cleanup EXIT INT TERM

# ---- build (optional) -----------------------------------------------------
if [ "$DO_BUILD" -eq 1 ]; then
    echo "==> building $IMAGE ..." >&2
    docker build -f "$REPO_ROOT/deploy/review/Dockerfile" -t "$IMAGE" "$REPO_ROOT"
fi
docker image inspect "$IMAGE" >/dev/null 2>&1 || {
    echo "image '$IMAGE' not found — run with --build first." >&2; exit 1; }

# ---- isolated network -----------------------------------------------------
docker network rm "$NET_NAME" >/dev/null 2>&1 || true
docker network create --subnet "$NET_SUBNET" "$NET_NAME" >/dev/null
echo "==> network $NET_NAME ($NET_SUBNET)" >&2

# ---- egress firewall (DOCKER-USER) ----------------------------------------
# DOCKER-USER is evaluated for forwarded container traffic before Docker's own
# accepts. Rules match on -s (the container subnet) so return traffic and the
# loopback-published port are unaffected.
add_rule() {  # add_rule <rule-spec-without-table>
    $SUDO iptables -I $1
    FW_RULES+=("$1")
}
if [ "$HAVE_IPTABLES" -eq 1 ]; then
    # Always: block cloud metadata + link-local, regardless of egress mode.
    add_rule "DOCKER-USER -s $NET_SUBNET -d 169.254.0.0/16 -j DROP"
    if [ "$EGRESS" = "restricted" ]; then
        # Block private ranges (LAN pivot / host services / other containers),
        # allow everything else (public internet) out.
        add_rule "DOCKER-USER -s $NET_SUBNET -d 10.0.0.0/8 -j DROP"
        add_rule "DOCKER-USER -s $NET_SUBNET -d 172.16.0.0/12 -j DROP"
        add_rule "DOCKER-USER -s $NET_SUBNET -d 192.168.0.0/16 -j DROP"
        add_rule "DOCKER-USER -s $NET_SUBNET -d 100.64.0.0/10 -j DROP"
        echo "==> egress: restricted (metadata + RFC1918 blocked, internet allowed)" >&2
    else
        # none: allow only replies to inbound (the published port), drop all
        # new outbound. Insert RETURN first so it sits above the DROP.
        add_rule "DOCKER-USER -s $NET_SUBNET -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN"
        add_rule "DOCKER-USER -s $NET_SUBNET -j DROP"
        echo "==> egress: none (all new outbound dropped)" >&2
    fi
fi

# ---- gVisor (optional) ----------------------------------------------------
RUNTIME_ARGS=()
if docker info --format '{{range .Runtimes}}{{.}} {{end}}' 2>/dev/null | grep -qw runsc \
   || docker info 2>/dev/null | grep -qiw runsc; then
    RUNTIME_ARGS=(--runtime=runsc)
    echo "==> using gVisor runtime (runsc)" >&2
else
    echo "==> gVisor not installed — using runc. For a public shell, installing" >&2
    echo "    gVisor (https://gvisor.dev) adds kernel-level isolation." >&2
fi

# ---- run ------------------------------------------------------------------
echo "==> starting $CTR_NAME ..." >&2
docker run -d --rm \
    --name "$CTR_NAME" \
    "${RUNTIME_ARGS[@]}" \
    --network "$NET_NAME" \
    -p "${BIND}:${PORT}:8080" \
    --user 10001:10001 \
    --cap-drop=ALL \
    --security-opt=no-new-privileges \
    --read-only \
    `# mode=1777: docker tmpfs mountpoints are root-owned and take no uid/gid,` \
    `# so without a world-writable sticky mode the non-root (uid 10001) process` \
    `# can't create its HOME/workspace and the container exits on start.` \
    --tmpfs /tmp:rw,noexec,nosuid,nodev,size=32m \
    --tmpfs "/home/demo:rw,nosuid,nodev,mode=1777,size=${WORKSPACE_SIZE}" \
    --tmpfs /run:rw,noexec,nosuid,nodev,mode=1777,size=4m \
    --pids-limit=256 \
    --memory=512m --memory-swap=512m \
    --cpus=1 \
    --mount "type=bind,source=${TOKEN_FILE},target=/run/secrets/motifd_token,readonly" \
    "$IMAGE" >/dev/null

# /home/demo is a fresh tmpfs, so the entrypoint reseeds /home/demo/work from
# the image's /opt/demo-seed on start (see entrypoint.sh).

sleep 1
if ! docker ps --format '{{.Names}}' | grep -qx "$CTR_NAME"; then
    echo "container exited immediately — logs:" >&2
    docker logs "$CTR_NAME" 2>&1 | tail -20 >&2 || true
    exit 1
fi

# ---- optional tunnel ------------------------------------------------------
PUBLIC_URL=""
if [ "$DO_TUNNEL" -eq 1 ]; then
    command -v cloudflared >/dev/null || { echo "cloudflared not found (install it or drop --tunnel)" >&2; }
    if command -v cloudflared >/dev/null; then
        TLOG="$TOKEN_DIR/cloudflared.log"
        cloudflared tunnel --url "http://127.0.0.1:${PORT}" >"$TLOG" 2>&1 &
        TUNNEL_PID=$!
        echo "==> cloudflared starting, waiting for URL ..." >&2
        for _ in $(seq 1 30); do
            PUBLIC_URL="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$TLOG" | head -1 || true)"
            [ -n "$PUBLIC_URL" ] && break
            sleep 1
        done
    fi
fi

# ---- summary --------------------------------------------------------------
WSS_HOST="${PUBLIC_URL#https://}"
cat >&2 <<EOF

────────────────────────────────────────────────────────────────────
  motifd review server is up.

  token:        $TOKEN
  local:        ws://${BIND}:${PORT}
EOF
if [ -n "$PUBLIC_URL" ]; then
cat >&2 <<EOF
  public:       $PUBLIC_URL
  iOS connect:  wss://${WSS_HOST}        token above

  ── paste into App Store review notes ──
  This app is a client for a self-hosted dev server (motifd). To test:
    Server URL:  wss://${WSS_HOST}
    Token:       $TOKEN
  Add the server in the app, connect, open a terminal, browse files,
  and view the git diff. The server is a sandbox; no account is needed.
EOF
elif [ "$BIND" != "127.0.0.1" ] && [ "$BIND" != "localhost" ]; then
# Direct public exposure, plaintext ws:// (no TLS). Best-effort public IP.
PUB_IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
HOST_HINT="${PUB_IP:-<this-host-public-ip-or-domain>}"
cat >&2 <<EOF
  exposure:     direct, plaintext ws:// — open port ${PORT}/tcp in your
                firewall/security group. The bearer token is the only auth.
  connect:      ws://${HOST_HINT}:${PORT}        token above

  ── paste into App Store review notes (requires the app's ATS to allow ws://) ──
  This app is a client for a self-hosted dev server (motifd). To test:
    Server URL:  ws://${HOST_HINT}:${PORT}
    Token:       $TOKEN
  Add the server in the app, connect, open a terminal, browse files,
  and view the git diff. The server is a sandbox; no account is needed.
EOF
else
cat >&2 <<EOF
  next:         publish publicly with --bind 0.0.0.0 (plaintext ws://, open the
                port yourself) or front it with TLS via --tunnel / a proxy, then
                give the app the URL + token above.
EOF
fi
cat >&2 <<EOF

  workspace:    /home/demo/work (seeded git repo, tmpfs — wiped on exit)
  Ctrl-C to stop and tear everything down (container, network, fw rules, token).
────────────────────────────────────────────────────────────────────
EOF

# ---- wait -----------------------------------------------------------------
echo "==> following container logs (Ctrl-C to stop) ..." >&2
docker logs -f "$CTR_NAME" 2>&1 || true
