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

LISTEN="${MOTIFD_LISTEN:-0.0.0.0:8080}"
# Public address testers reach. The pairing link's cert pin is tied to the
# self-signed identity persisted under $XDG_DATA_HOME/motifd — run-review.sh
# bind-mounts a persistent dir there so the pin (and psk) survive restarts.
ADVERTISE_HOST="${MOTIFD_ADVERTISE_HOST:-}"

# A network --listen now auto-encrypts (self-signed TLS, the client pins the
# cert) and authenticates with the psk-derived bearer — no token file, no
# upstream TLS terminator. motifd auto-generates+persists the psk (or pass a
# fixed one via MOTIFD_PSK) and prints a `motif://pair` link/QR on startup;
# paste it into the App Store review notes. --advertise-host makes that link
# carry the public address rather than the container's internal NIC IP.
PSK_ARG=()
[ -n "${MOTIFD_PSK:-}" ] && PSK_ARG=(--psk "$MOTIFD_PSK")
ADV_ARG=()
[ -n "$ADVERTISE_HOST" ] && ADV_ARG=(--advertise-host "$ADVERTISE_HOST")
exec motifd --listen "$LISTEN" "${PSK_ARG[@]}" "${ADV_ARG[@]}"
