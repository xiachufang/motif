#!/bin/sh
# Motif — Claude Code / Codex notification hook.
#
# Installed explicitly from the Motif desktop app. The agent invokes this from
# its user-level hook config, but the environment gates below make it inert in
# every terminal except a Motif-owned PTY with a live hook-ingress endpoint.
#
# Constraints: must NOT write /dev/tty or emit escape sequences (Claude Code
# forbids it), must be non-blocking, and must always exit 0 so a hiccup here
# never disrupts the Claude session.

[ "${MOTIF_BOOTSTRAPPED:-}" = "1" ] || exit 0
[ "${TERM_PROGRAM:-}" = "motif" ] || exit 0
[ -n "${MOTIF_SESSION_ID:-}" ] || exit 0
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
