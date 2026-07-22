#!/bin/sh
# Motif — Claude Code notify hook.
#
# Provisioned automatically (zero user config) via a generated `--settings`
# file that the motif `claude` wrapper passes to Claude Code. Claude runs this
# on Notification/Stop hooks, handing us the hook JSON on stdin. We forward it
# to motifd's local hook socket, which fans it out to live clients and (if a
# push relay is configured) to iOS via encrypted APNs.
#
# Constraints: must NOT write /dev/tty or emit escape sequences (Claude Code
# forbids it), must be non-blocking, and must always exit 0 so a hiccup here
# never disrupts the Claude session.

command -v curl >/dev/null 2>&1 || exit 0

if [ -n "$MOTIF_HOOK_SOCK" ]; then
  cat | curl -s --max-time 3 \
    --unix-socket "$MOTIF_HOOK_SOCK" \
    -H "X-Motif-Session: ${MOTIF_SESSION_NAME:-}" \
    -H "X-Motif-Pty: ${MOTIF_SESSION_ID:-}" \
    -H "Content-Type: application/json" \
    --data-binary @- \
    http://localhost/hook >/dev/null 2>&1
elif [ -n "$MOTIF_HOOK_URL" ] && [ -n "$MOTIF_HOOK_TOKEN" ]; then
  cat | curl -s --max-time 3 \
    -H "X-Motif-Session: ${MOTIF_SESSION_NAME:-}" \
    -H "X-Motif-Pty: ${MOTIF_SESSION_ID:-}" \
    -H "X-Motif-Hook-Token: $MOTIF_HOOK_TOKEN" \
    -H "Content-Type: application/json" \
    --data-binary @- \
    "$MOTIF_HOOK_URL" >/dev/null 2>&1
fi

exit 0
