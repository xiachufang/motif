#!/bin/bash
# motifd review-image entrypoint.
#
# The container runs with a read-only rootfs and a writable tmpfs mounted at
# /home/demo/work (see run-review.sh). That tmpfs starts empty on every boot, so
# we seed it from the baked-in read-only /opt/demo-seed before launching motifd.
# This keeps the rootfs immutable while still giving the reviewer an editable git
# repo to poke at.
set -euo pipefail

WORK=/home/demo/work
SEED=/opt/demo-seed

# /home/demo is a fresh tmpfs at runtime, so create the workspace dir and seed
# it from the read-only baked-in copy. Seed only when empty so a restart with a
# persisted volume keeps reviewer edits.
mkdir -p "$WORK"
if [ -z "$(ls -A "$WORK" 2>/dev/null || true)" ]; then
    cp -a "$SEED/." "$WORK/" 2>/dev/null || true
fi

# A writable HOME (tmpfs) means no baked ~/.gitconfig — give git an identity so
# the reviewer can commit in the demo repo, not just read the diff.
if [ ! -s "$HOME/.gitconfig" ]; then
    git config --global user.email "demo@motif.local"
    git config --global user.name  "Motif Demo"
    git config --global --add safe.directory "$WORK"
fi

TOKEN_FILE="${MOTIFD_TOKEN_FILE:-/run/secrets/motifd_token}"
LISTEN="${MOTIFD_LISTEN:-0.0.0.0:8080}"

if [ ! -s "$TOKEN_FILE" ]; then
    echo "entrypoint: token file '$TOKEN_FILE' is missing or empty." >&2
    echo "            run-review.sh should mount it read-only — refusing to start" >&2
    echo "            an auth-less remote shell on a public port." >&2
    exit 1
fi

# No --tailscale, no --insecure-no-auth: a single TCP listener gated by the
# bearer token. TLS is terminated upstream (reverse proxy / cloudflared).
exec motifd --listen "$LISTEN" --token-file "$TOKEN_FILE"
