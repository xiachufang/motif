# Motif shell integration — zsh bootstrap. Loaded as $ZDOTDIR/.zshrc when
# motifd spawns the PTY. Sources the user's real .zshrc first so their
# prompt + aliases land before our hooks register.
#
# `$MOTIF_BOOTSTRAPPED` is set by motifd at spawn time so user code
# can detect "I'm in a motif PTY"; we use `__motif_loaded` for the
# double-source guard.

[[ -n "$__motif_loaded" ]] && return
__motif_loaded=1

# ── helpers ──────────────────────────────────────────────────────────

__motif_hex() {
    LC_ALL=C printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n'
}

__motif_emit_osc() {
    printf '\e]%s;%s\a' "$1" "$2"
}

__motif_json_escape() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\t'/\\t}
    printf '%s' "$s"
}

__motif_build_context_json() {
    local first=1 out="{"
    __append() {
        [[ -z "$2" ]] && return
        local val
        val=$(__motif_json_escape "$2")
        if [[ -n "$first" ]]; then first=; else out+=","; fi
        out+="\"$1\":\"$val\""
    }
    if command -v git >/dev/null 2>&1; then
        __append branch "$(git symbolic-ref --short HEAD 2>/dev/null)"
        __append head   "$(git rev-parse --short HEAD 2>/dev/null)"
    fi
    [[ -n "$VIRTUAL_ENV" ]]       && __append venv  "${VIRTUAL_ENV:t}"
    [[ -n "$CONDA_DEFAULT_ENV" ]] && __append conda "$CONDA_DEFAULT_ENV"
    out+="}"
    printf '%s' "$out"
}

# ── motif hooks ─────────────────────────────────────────────────────

__motif_precmd() {
    local last_exit=$?
    if [[ -n "$__motif_in_cmd" ]]; then
        printf '\e]133;D;%s\a' "$last_exit"
        unset __motif_in_cmd
    fi
    printf '\e]133;A\a'
    __motif_emit_osc 7    "file://${HOST}${PWD}"
    __motif_emit_osc 7771 "$(__motif_hex "$(__motif_build_context_json)")"
    printf '\e]133;B\a'
}

__motif_preexec() {
    local cmd=$1
    __motif_emit_osc 7770 "$(__motif_hex "$cmd")"
    printf '\e]133;C\a'
    __motif_in_cmd=1
}

# ── source user .zshrc, then register hooks ──────────────────────────

# motifd points $ZDOTDIR at its tmpdir. To reach the user's real .zshrc
# we restore $HOME (or whatever the original ZDOTDIR was) for that one
# source call, then leave ZDOTDIR pointing back at us so a later interactive
# `exec zsh` finds the same wrapped state.
__motif_user_zdotdir=${MOTIF_USER_ZDOTDIR:-$HOME}
if [[ -n "$__motif_user_zdotdir" && -f "$__motif_user_zdotdir/.zshrc" ]]; then
    ZDOTDIR=$__motif_user_zdotdir source "$__motif_user_zdotdir/.zshrc"
fi

autoload -Uz add-zsh-hook
add-zsh-hook precmd  __motif_precmd
add-zsh-hook preexec __motif_preexec
