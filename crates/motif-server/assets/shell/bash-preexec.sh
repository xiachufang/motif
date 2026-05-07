# Motif's own minimal preexec/precmd hook system for bash. Inspired by
# rcaloras/bash-preexec (MIT) but trimmed to what motif's bootstrap
# needs. Provides:
#   preexec_functions[]  fns called *before* each interactive command;
#                        each receives the literal command text as $1.
#   precmd_functions[]   fns called *before* each prompt renders; each
#                        receives the previous command's $? as $1.
#
# Limitations vs upstream: no nested-trap chaining; relies on motif's
# bootstrap being the sole PROMPT_COMMAND owner inside the wrapped rc.

[[ -n "$__motif_preexec_loaded" ]] && return 0
__motif_preexec_loaded=1

declare -a preexec_functions=()
declare -a precmd_functions=()

# Capture whatever PROMPT_COMMAND the user's rcfile already set so we can
# invoke it before our own dispatcher (preserves themes / completions).
__motif_chained_pc="$PROMPT_COMMAND"

# Set right before the prompt renders, cleared by the DEBUG trap on the
# first command that follows. Lets us tell user commands apart from
# subshell expansions inside PROMPT_COMMAND itself.
__motif_at_prompt=1

__motif_dispatch_preexec() {
    local cmd="$1" fn
    for fn in "${preexec_functions[@]}"; do
        "$fn" "$cmd"
    done
}

__motif_dispatch_precmd() {
    # Save $? from the last interactive command — anything we run below
    # will clobber it, so capture immediately on entry.
    local last_exit=$?
    [[ -n "$__motif_chained_pc" ]] && eval "$__motif_chained_pc"
    local fn
    for fn in "${precmd_functions[@]}"; do
        "$fn" "$last_exit"
    done
    __motif_at_prompt=1
}

__motif_debug_trap() {
    # Skip our own dispatchers + chained PROMPT_COMMAND content. We only
    # want the *first* BASH_COMMAND after the prompt was drawn.
    local cmd="$BASH_COMMAND"
    case "$cmd" in
        __motif_dispatch_*|__motif_debug_trap) return ;;
    esac
    [[ -z "$__motif_at_prompt" ]] && return
    __motif_at_prompt=
    __motif_dispatch_preexec "$cmd"
}

trap '__motif_debug_trap' DEBUG
PROMPT_COMMAND='__motif_dispatch_precmd'
