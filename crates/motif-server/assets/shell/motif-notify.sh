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

[ -n "$MOTIF_HOOK_SOCK" ] || exit 0
command -v curl >/dev/null 2>&1 || exit 0

cat | curl -s --max-time 3 \
  --unix-socket "$MOTIF_HOOK_SOCK" \
  -H "X-Motif-Session: ${MOTIF_SESSION_NAME:-}" \
  -H "Content-Type: application/json" \
  --data-binary @- \
  http://localhost/hook >/dev/null 2>&1

exit 0
