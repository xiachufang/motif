#!/usr/bin/env bash
#
# run-review.sh — launch a hardened, throwaway motifd for App Review.
#
# Threat model: the motif://pair link (its psk) is handed to Apple (and written
# in review notes), so treat it as public for the review window. Anyone with it
# gets a real shell + file read "anywhere the process can reach". This script's
# whole job is to make that survivable:
#
#   * non-root, all capabilities dropped, no-new-privileges, read-only rootfs
#   * pids / memory / cpu caps so a fork bomb or miner can't take the box down
#   * an isolated docker network with egress firewalling: the container CANNOT
#     reach the cloud metadata endpoint (169.254.169.254) or any RFC1918 LAN
#     address, so a holder can't steal cloud credentials or pivot inside
#     your VPS. Public internet stays reachable (toggle with --egress none).
#   * optional gVisor (runsc) runtime for kernel-level syscall isolation —
#     used automatically if installed.
#   * the container and its network are torn down on exit.
#
# A network listener terminates its own TLS (self-signed; the client pins the
# cert) and authenticates with a psk-derived bearer — no reverse proxy or tunnel
# needed. motifd prints a motif://pair link this script surfaces for the notes.
#
# Usage:
#   deploy/review/run-review.sh [--build] [--egress restricted|none] [--port N]
#                  [--bind ADDR] [--advertise HOST] [--image NAME] [--workspace-size SIZE]
#
#   --build            docker build the image first (from repo root)
#   --egress none      drop ALL container egress (default: restricted = block
#                      metadata + RFC1918 only, allow public internet)
#   --port N           host port to publish + listen on (default 8080)
#   --bind ADDR        host interface to publish on (default 127.0.0.1). Use
#                      0.0.0.0 for direct public exposure (open the port in your
#                      firewall/security group yourself). The connection is
#                      TLS-encrypted and the client pins the cert.
#   --advertise HOST   host put in the pairing link (default: bind addr, or the
#                      detected public IP for a 0.0.0.0 bind)
#   --image NAME       image tag (default motifd:review)
#   --workspace-size   tmpfs size for /home/demo/work (default 128m)
#
set -euo pipefail

# ---- config ---------------------------------------------------------------
IMAGE="motifd:review"
PORT=8080
BIND="127.0.0.1"         # host interface to publish on; 0.0.0.0 = public
ADVERTISE=""             # host put in the motif://pair link (default: BIND or
                         # detected public IP). The cert is pinned, so this is
                         # just where the client dials, not a trust anchor.
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
        --advertise) ADVERTISE="${2:?}"; shift ;;
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

# ---- advertise host -------------------------------------------------------
# Where the client dials, embedded in the printed motif://pair link. motifd
# inside the container only knows its internal NIC IP, so we tell it the real
# reachable host. Default: the bind interface, or (for a public 0.0.0.0 bind)
# the detected public IP. The cert is pinned in the link, so a wrong host just
# fails to connect — it is not a trust anchor. No bearer token to manage now:
# motifd auto-generates a psk and prints it inside the link.
if [ -z "$ADVERTISE" ]; then
    case "$BIND" in
        0.0.0.0|"") ADVERTISE="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)" ;;
        *) ADVERTISE="$BIND" ;;
    esac
fi
[ -z "$ADVERTISE" ] && ADVERTISE="<this-host-public-ip-or-domain>"

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
    `# Publish PORT:PORT (not :8080) and listen on PORT inside, so the port in` \
    `# the advertised motif://pair link matches what the client dials.` \
    -p "${BIND}:${PORT}:${PORT}" \
    -e "MOTIFD_LISTEN=0.0.0.0:${PORT}" \
    -e "MOTIFD_ADVERTISE_HOST=${ADVERTISE}" \
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
    "$IMAGE" >/dev/null

# /home/demo is a fresh tmpfs, so the entrypoint reseeds /home/demo/work from
# the image's /opt/demo-seed on start (see entrypoint.sh).

sleep 1
if ! docker ps --format '{{.Names}}' | grep -qx "$CTR_NAME"; then
    echo "container exited immediately — logs:" >&2
    docker logs "$CTR_NAME" 2>&1 | tail -20 >&2 || true
    exit 1
fi

[ "$DO_TUNNEL" -eq 1 ] && echo "==> note: --tunnel is no longer needed; motifd now terminates TLS itself (pinned cert)." >&2

# ---- pairing link ---------------------------------------------------------
# motifd prints a `motif://pair?...` link (+ a QR) on startup. Capture it.
PAIR_LINK=""
for _ in $(seq 1 15); do
    PAIR_LINK="$(docker logs "$CTR_NAME" 2>&1 | grep -oE 'motif://pair[^[:space:]]+' | head -1 || true)"
    [ -n "$PAIR_LINK" ] && break
    sleep 1
done

# ---- summary --------------------------------------------------------------
cat >&2 <<EOF

────────────────────────────────────────────────────────────────────
  motifd review server is up — encrypted (self-signed TLS, client pins the
  cert) and authenticated (psk-derived bearer). No token, no upstream proxy.

  listen:       ${BIND}:${PORT}   (advertised host: ${ADVERTISE})
EOF
if [ -n "$PAIR_LINK" ]; then
cat >&2 <<EOF

  ── paste into App Store review notes ──
  This app is a client for a self-hosted dev server (motifd). To test, open
  this link on the device (or scan the QR in the logs) to add the server:

    ${PAIR_LINK}

  Then connect, open a terminal, browse files, and view the git diff. The
  server is a sandbox; no account is needed.
EOF
else
cat >&2 <<EOF

  (could not capture the pairing link — run 'docker logs ${CTR_NAME}' and look
   for the 'motif://pair?...' line / QR.)
EOF
fi
cat >&2 <<EOF

  exposure:     for a public reviewer, --bind 0.0.0.0 and open ${PORT}/tcp in
                your firewall/security group. The 'pk' in the link pins the
                cert; the 'psk' is the access credential.
  pin note:     the cert pin is tied to motifd's identity under \$XDG_DATA_HOME.
                This ephemeral container regenerates it each start, so the link
                is valid for THIS run. A persistent server should mount a stable
                data dir (XDG_DATA_HOME) so the pin + psk survive restarts.
  workspace:    /home/demo/work (seeded git repo, tmpfs — wiped on exit)
  Ctrl-C to stop and tear everything down (container, network, fw rules).
────────────────────────────────────────────────────────────────────
EOF

# ---- wait -----------------------------------------------------------------
echo "==> following container logs (Ctrl-C to stop) ..." >&2
docker logs -f "$CTR_NAME" 2>&1 || true
