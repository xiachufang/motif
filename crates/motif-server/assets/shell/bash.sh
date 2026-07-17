# Motif shell integration — bash bootstrap.
# Sourced via `bash --rcfile <this>` when motifd spawns the PTY. Sources
# the user's regular interactive rcfile after registering hooks so PS1
# and aliases land first; motif's OSC markers ride on top.
#
# Note: `$MOTIF_BOOTSTRAPPED` is exported by motifd at spawn time as a
# signal to user code ("you're inside a motif PTY"); we use a separate
# `__motif_loaded` to guard against double-sourcing this script.

[[ -n "$__motif_loaded" ]] && return 0
__motif_loaded=1

# ── helpers ───────────────────────────────────────────────────────────

# Hex-encode a string byte-wise. `od` is more portable than printf %02x
# for non-ASCII payloads (printf treats high bytes as signed in some bash
# builds). Performance: ~1ms per ~100B payload, fine for once-per-prompt.
__motif_hex() {
    LC_ALL=C printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n'
}

__motif_emit_si() {
    # Motif private shell-integration protocol:
    # ESC ] 7777 ; sub [ ; payload ] BEL.
    if [[ $# -gt 1 ]]; then
        printf '\e]7777;%s;%s\a' "$1" "$2"
    else
        printf '\e]7777;%s\a' "$1"
    fi
}

__motif_json_escape() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\t'/\\t}
    printf '%s' "$s"
}

# Build the precmd JSON context. Every field is optional; emit only the
# ones we have so far. `branch` / `head` need git, the rest read env vars.
__motif_build_context_json() {
    local first=1 out="{"
    __append() {
        local key=$1 val=$2
        [[ -z "$val" ]] && return
        val=$(__motif_json_escape "$val")
        if [[ -n "$first" ]]; then first=; else out+=","; fi
        out+="\"$key\":\"$val\""
    }
    if command -v git >/dev/null 2>&1; then
        __append branch "$(git symbolic-ref --short HEAD 2>/dev/null)"
        __append head   "$(git rev-parse --short HEAD 2>/dev/null)"
    fi
    [[ -n "$VIRTUAL_ENV" ]]       && __append venv  "$(basename "$VIRTUAL_ENV")"
    [[ -n "$CONDA_DEFAULT_ENV" ]] && __append conda "$CONDA_DEFAULT_ENV"
    out+="}"
    printf '%s' "$out"
}

# ── motif hooks ───────────────────────────────────────────────────────

__motif_precmd() {
    local last_exit=${1:-$?}
    # D for the *previous* command. Skipped on the very first prompt
    # of the session — there's no command to report on yet.
    if [[ -n "$__motif_in_cmd" ]]; then
        __motif_emit_si D "$last_exit"
        unset __motif_in_cmd
    fi
    __motif_emit_si A
    __motif_emit_si P "Cwd=file://${HOSTNAME}${PWD}"
    __motif_emit_si P "Context=$(__motif_hex "$(__motif_build_context_json)")"
    __motif_emit_si B
}

__motif_preexec() {
    local cmd="$1"
    __motif_emit_si E "$(__motif_hex "$cmd")"
    __motif_emit_si C
    __motif_in_cmd=1
}

# Bracketed paste: paste of multi-line text doesn't auto-execute lines as
# soon as a newline is pasted. bash 4+ supports this readline option.
bind 'set enable-bracketed-paste on' 2>/dev/null

# ── source user rc, then register hooks ──────────────────────────────

# We read the user's .bashrc *before* installing the DEBUG trap so any
# PROMPT_COMMAND they configure ends up in __motif_chained_pc rather
# than fighting our dispatcher.
[[ -n "$MOTIF_USER_RC" && -f "$MOTIF_USER_RC" ]] && source "$MOTIF_USER_RC"
[[ -z "$MOTIF_USER_RC" && -f "$HOME/.bashrc"  ]] && source "$HOME/.bashrc"

source "$MOTIF_BOOTSTRAP_DIR/bash-preexec.sh"
preexec_functions+=(__motif_preexec)
precmd_functions+=(__motif_precmd)

# ── Motif: provision Claude Code notify hooks (push only) ────────────
# When motifd has push enabled (MOTIF_HOOK_SOCK set) and generated a
# settings file, transparently pass it to `claude` so Notification/Stop
# hooks fire — without touching the user's ~/.claude/settings.json.
# `command claude` skips this function, so there's no recursion.
if [[ -n "${MOTIF_HOOK_SOCK:-}${MOTIF_HOOK_URL:-}" && -n "$MOTIF_CLAUDE_SETTINGS" ]]; then
    claude() { command claude --settings "$MOTIF_CLAUDE_SETTINGS" "$@"; }
fi

# ── Motif: provision Codex CLI notify hook (push only) ───────────────
# Same idea for Codex: inject a Stop hook via `-c` (ephemeral SessionFlags
# layer) pointing at the shared notify script — without touching the user's
# ~/.codex/config.toml. Codex's own "Hooks need review" UI handles trust.
# `command codex` skips this function, so there's no recursion.
if [[ -n "${MOTIF_HOOK_SOCK:-}${MOTIF_HOOK_URL:-}" && -n "$MOTIF_CODEX_NOTIFY" ]]; then
    codex() {
        command codex -c "hooks.Stop=[{hooks=[{type=\"command\",command=\"$MOTIF_CODEX_NOTIFY\"}]}]" "$@"
    }
fi
