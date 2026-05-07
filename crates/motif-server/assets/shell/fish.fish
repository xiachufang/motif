# Motif shell integration — fish bootstrap.
# Sourced via `fish --init-command "source <this>"` at PTY spawn.
#
# `$MOTIF_BOOTSTRAPPED` is set by motifd at spawn time so user code
# can detect "I'm in a motif PTY"; the `__motif_loaded` global is the
# double-source guard.

if set -q __motif_loaded
    exit 0
end
set -g __motif_loaded 1

# ── helpers ──────────────────────────────────────────────────────────

function __motif_hex
    LC_ALL=C printf '%s' $argv[1] | od -An -v -tx1 | tr -d ' \n'
end

function __motif_emit_osc
    printf '\e]%s;%s\a' $argv[1] $argv[2]
end

function __motif_json_escape
    set -l s $argv[1]
    set s (string replace -a '\\' '\\\\' -- $s)
    set s (string replace -a '"'  '\\"'  -- $s)
    set s (string replace -a \n   '\\n'  -- $s)
    printf '%s' $s
end

function __motif_build_context_json
    set -l parts
    if command -q git
        set -l branch (git symbolic-ref --short HEAD 2>/dev/null)
        if test -n "$branch"
            set -a parts "\"branch\":\""(__motif_json_escape "$branch")"\""
        end
        set -l head (git rev-parse --short HEAD 2>/dev/null)
        if test -n "$head"
            set -a parts "\"head\":\""(__motif_json_escape "$head")"\""
        end
    end
    if test -n "$VIRTUAL_ENV"
        set -a parts "\"venv\":\""(__motif_json_escape (basename $VIRTUAL_ENV))"\""
    end
    if test -n "$CONDA_DEFAULT_ENV"
        set -a parts "\"conda\":\""(__motif_json_escape "$CONDA_DEFAULT_ENV")"\""
    end
    printf '{%s}' (string join , -- $parts)
end

# ── motif hooks ─────────────────────────────────────────────────────

# fish has no precmd/preexec arrays the way bash/zsh do — it dispatches
# named events instead. fish_postexec carries last $status as $argv, but
# we read $status directly inside the handler since it's set on entry.

function __motif_preexec --on-event fish_preexec
    set -l cmd "$argv[1]"
    __motif_emit_osc 7770 (__motif_hex "$cmd")
    printf '\e]133;C\a'
    set -g __motif_in_cmd 1
end

function __motif_postexec --on-event fish_postexec
    set -l last $status
    printf '\e]133;D;%s\a' $last
    set -e __motif_in_cmd
end

function __motif_prompt --on-event fish_prompt
    printf '\e]133;A\a'
    __motif_emit_osc 7    "file://"(hostname)"$PWD"
    __motif_emit_osc 7771 (__motif_hex (__motif_build_context_json))
    printf '\e]133;B\a'
end

# fish doesn't have a chpwd hook by name, but PWD is a tracked variable
# — emitting OSC 7 on every PWD change gives motifd's BlockState the
# same precision OSC 7 buys for bash/zsh.
function __motif_pwd --on-variable PWD
    __motif_emit_osc 7 "file://"(hostname)"$PWD"
end
