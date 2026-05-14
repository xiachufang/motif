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

function __motif_emit_si
    printf '\e]777;%s\a' (string join ';' -- $argv)
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
    __motif_emit_si E (__motif_hex "$cmd")
    __motif_emit_si C
    set -g __motif_in_cmd 1
end

function __motif_postexec --on-event fish_postexec
    set -l last $status
    __motif_emit_si D $last
    set -e __motif_in_cmd
end

function __motif_prompt_start
    __motif_emit_si A
    __motif_emit_si P "Cwd=file://"(hostname)"$PWD"
    __motif_emit_si P "Context="(__motif_hex (__motif_build_context_json))
end

function __motif_prompt_end
    __motif_emit_si B
end

function __motif_fish_has_mode_prompt
    functions fish_mode_prompt | string match -rvq '^ *(#|function |end$|$)'
end

function __motif_fish_has_right_prompt
    functions fish_right_prompt | string match -rvq '^ *(#|function |end$|$)'
end

function __motif_install_prompt_wrappers
    if functions --query fish_prompt
        functions --copy fish_prompt __motif_fish_prompt
    else
        function __motif_fish_prompt
            echo -n (whoami)@(prompt_hostname) (prompt_pwd) '~> '
        end
    end

    set -l has_mode 0
    if __motif_fish_has_mode_prompt
        set has_mode 1
        functions --copy fish_mode_prompt __motif_fish_mode_prompt
    end

    set -l has_right 0
    if __motif_fish_has_right_prompt
        set has_right 1
        functions --copy fish_right_prompt __motif_fish_right_prompt
    end

    if test "$has_mode" = 1
        function fish_mode_prompt
            __motif_prompt_start
            __motif_fish_mode_prompt
        end
    end

    if test "$has_right" = 1
        if test "$has_mode" = 1
            function fish_prompt
                __motif_fish_prompt
            end
        else
            function fish_prompt
                __motif_prompt_start
                __motif_fish_prompt
            end
        end
        function fish_right_prompt
            __motif_fish_right_prompt
            __motif_prompt_end
        end
    else
        if test "$has_mode" = 1
            function fish_prompt
                __motif_fish_prompt
                __motif_prompt_end
            end
        else
            function fish_prompt
                __motif_prompt_start
                __motif_fish_prompt
                __motif_prompt_end
            end
        end
    end
end

# fish doesn't have a chpwd hook by name, but PWD is a tracked variable
# — emitting the private Cwd property on every PWD change gives clients
# prompt-independent cwd updates.
function __motif_pwd --on-variable PWD
    __motif_emit_si P "Cwd=file://"(hostname)"$PWD"
end

__motif_install_prompt_wrappers
