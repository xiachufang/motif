//! Per-PTY block state machine. Consumes shell-integration OSC markers
//! produced by the bootstrap scripts and emits high-level
//! [`ShellEvent`]s. The reader loop in `pty.rs` turns those into
//! `Event::Pty*` broadcasts and appends finished blocks to the
//! [`BlockStore`](super::block_store::BlockStore).
//!
//! See `docs/shell-integration.md` §4 for the transition table this
//! mirrors.

use std::path::PathBuf;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use motif_proto::common::BlockId;
use motif_proto::pty::{OutputScope, ShellContext, ShellKind};
use motif_proto::terminal_query::QueryKind;
use ulid::Ulid;

/// Per-segment in-memory cap. Each of `prompt`, `command`, `output` is
/// independently capped at this many bytes; overflow drops the tail and
/// sets the corresponding `*_truncated` flag.
pub const SEGMENT_MAX_BYTES: usize = 1024 * 1024;

#[derive(Debug)]
pub enum BlockState {
    /// PTY just spawned; haven't seen any OSC 133 yet.
    Unknown,

    /// Got `133;A`. Shell is rendering its prompt; bytes after this
    /// boundary are appended to `prompt_buf`.
    AtPrompt {
        block_id:           BlockId,
        prompt_buf:         Vec<u8>,
        prompt_truncated:   bool,
        cwd:                PathBuf,
        started_at:         SystemTime,
    },

    /// Got `133;B`. User is typing; bytes after this boundary are
    /// appended to `command_buf`.
    Composing {
        block_id:           BlockId,
        prompt_buf:         Vec<u8>,
        prompt_truncated:   bool,
        command_buf:        Vec<u8>,
        command_truncated:  bool,
        cwd:                PathBuf,
        started_at:         SystemTime,
    },

    /// Got `133;C`. Command is executing; bytes are appended to `output`.
    Running {
        block_id:           BlockId,
        cmd:                String,        // OSC 7770
        cwd:                PathBuf,
        started_at:         SystemTime,
        prompt:             Vec<u8>,
        prompt_truncated:   bool,
        command:            Vec<u8>,
        command_truncated:  bool,
        output:             Vec<u8>,
        output_truncated:   bool,
    },
}

#[derive(Debug)]
pub enum ShellEvent {
    /// First successful OSC 133, or 5s timeout (kind = Unknown).
    Bootstrapped,
    /// Emitted on every OSC 133;A. `block_id` is the id allocated for
    /// this prompt cycle — same as the previous `PromptStarted` for a
    /// pure redraw, new for a fresh cycle.
    PromptStarted { block_id: BlockId },
    /// Emitted on the AtPrompt → Composing transition (OSC 133;B).
    PromptEnded { block_id: BlockId },
    CommandStarted {
        id:         BlockId,
        text:       String,
        cwd:        PathBuf,
        started_at: u64,
    },
    /// Carries the full block — the reader loop publishes the
    /// `command_finished` notification and writes the block into the
    /// [`BlockStore`](super::block_store::BlockStore).
    CommandFinished {
        id:                BlockId,
        cmd:               String,
        cwd:               PathBuf,
        started_at:        u64,
        finished_at:       u64,
        exit:              Option<i32>,
        prompt:            Vec<u8>,
        prompt_truncated:  bool,
        command:           Vec<u8>,
        command_truncated: bool,
        output:            Vec<u8>,
        output_truncated:  bool,
    },
    Context    { ctx: ShellContext },
    /// OSC 7 said cwd changed. Reader loop dedupes against
    /// `Pty::last_cwd` before emitting `pty.cwd_changed`.
    CwdChanged { cwd: PathBuf },
}

#[derive(Debug)]
pub struct ShellState {
    pub kind: ShellKind,
    pub state: BlockState,
    pub spawned_at: Instant,
    /// Latches true once we've emitted `Bootstrapped`.
    pub bootstrap_announced: bool,
    /// Tracked separately because OSC 7 fires outside any block too.
    pub current_cwd: Option<PathBuf>,
    /// `7770` always arrives just before `133;C`. Stash text and
    /// consume it on the next `133;C` so a missing 7770 doesn't block
    /// the transition.
    pending_cmd: Option<String>,
}

impl ShellState {
    pub fn new(kind: ShellKind, spawned_at: Instant, initial_cwd: Option<PathBuf>) -> Self {
        Self {
            kind,
            state: BlockState::Unknown,
            spawned_at,
            bootstrap_announced: false,
            current_cwd: initial_cwd,
            pending_cmd: None,
        }
    }

    /// Block id of the currently-active prompt cycle, if any. Used by
    /// the reader loop to tag every `Event::PtyOutput`.
    pub fn active_block_id(&self) -> Option<&BlockId> {
        match &self.state {
            BlockState::Unknown                       => None,
            BlockState::AtPrompt   { block_id, .. }
            | BlockState::Composing { block_id, .. }
            | BlockState::Running   { block_id, .. } => Some(block_id),
        }
    }

    /// `OutputScope` for the current state. `Unknown` reports
    /// `Passthrough` so housekeeping bytes (pre-bootstrap banners,
    /// between-block window-title sets / mode toggles, or shells with
    /// integration disabled) are visibly distinct from real prompt-zone
    /// bytes — and so client-side routing can fast-path them away from
    /// any block-segment buffers.
    pub fn active_scope(&self) -> OutputScope {
        match &self.state {
            BlockState::Unknown           => OutputScope::Passthrough,
            BlockState::AtPrompt { .. }   => OutputScope::Prompt,
            BlockState::Composing { .. }  => OutputScope::Command,
            BlockState::Running   { .. }  => OutputScope::Output,
        }
    }

    /// Append passthrough bytes to whichever segment buffer is active
    /// for the current state. Caller is responsible for separately
    /// broadcasting `Event::PtyOutput` with the matching scope/block_id.
    pub fn record_output(&mut self, bytes: &[u8]) {
        match &mut self.state {
            BlockState::Unknown => {}
            BlockState::AtPrompt { prompt_buf, prompt_truncated, .. } => {
                append_capped(prompt_buf, prompt_truncated, bytes);
            }
            BlockState::Composing { command_buf, command_truncated, .. } => {
                append_capped(command_buf, command_truncated, bytes);
            }
            BlockState::Running { output, output_truncated, .. } => {
                append_capped(output, output_truncated, bytes);
            }
        }
    }

    /// Drive the state machine on a single OSC marker. Returns the
    /// `ShellEvent`s the reader loop should dispatch.
    pub fn on_osc(&mut self, q: &QueryKind) -> Vec<ShellEvent> {
        let mut out = Vec::new();
        let now = unix_now_ms();
        match q {
            QueryKind::Osc133PromptStart => {
                self.first_osc_seen(&mut out);
                let cwd = self.current_cwd.clone().unwrap_or_else(|| PathBuf::from("/"));
                let prev = std::mem::replace(&mut self.state, BlockState::Unknown);
                let new_id = match prev {
                    // Pure redraw — keep the same block_id, just reset
                    // the prompt buffer.
                    BlockState::AtPrompt { block_id, cwd: c, started_at, .. } => {
                        self.state = BlockState::AtPrompt {
                            block_id:         block_id.clone(),
                            prompt_buf:       Vec::new(),
                            prompt_truncated: false,
                            cwd:              c,
                            started_at,
                        };
                        block_id
                    }
                    // Composing → 133;A: also a redraw. fish (and any
                    // shell that calls `repaint` after typing/binding
                    // events) re-emits A→…→B on every keystroke without
                    // running anything. Keep the same block_id and reset
                    // prompt_buf; command_buf is dropped because the
                    // upcoming B→… cycle will re-stream the live cmdline
                    // bytes. Empty Enter falls through here too — no
                    // command actually ran, so emitting nothing is the
                    // right outcome.
                    //
                    // Why: Composing → A used to synthesize an empty
                    // CommandStarted+CommandFinished pair, which made
                    // fish redraws spam empty blocks into the UI.
                    BlockState::Composing { block_id, cwd: c, started_at, .. } => {
                        self.state = BlockState::AtPrompt {
                            block_id:         block_id.clone(),
                            prompt_buf:       Vec::new(),
                            prompt_truncated: false,
                            cwd:              c,
                            started_at,
                        };
                        block_id
                    }
                    // Force-finalize a Running block (SIGINT scenario).
                    BlockState::Running {
                        block_id, cmd, cwd: c, started_at,
                        prompt, prompt_truncated,
                        command, command_truncated,
                        output, output_truncated,
                    } => {
                        out.push(ShellEvent::CommandFinished {
                            id:                block_id,
                            cmd,
                            cwd:               c,
                            started_at:        system_time_to_ms(started_at),
                            finished_at:       now,
                            exit:              None,
                            prompt,
                            prompt_truncated,
                            command,
                            command_truncated,
                            output,
                            output_truncated,
                        });
                        let new_id = Ulid::new().to_string();
                        self.state = BlockState::AtPrompt {
                            block_id:         new_id.clone(),
                            prompt_buf:       Vec::new(),
                            prompt_truncated: false,
                            cwd:              cwd.clone(),
                            started_at:       SystemTime::now(),
                        };
                        new_id
                    }
                    BlockState::Unknown => {
                        let new_id = Ulid::new().to_string();
                        self.state = BlockState::AtPrompt {
                            block_id:         new_id.clone(),
                            prompt_buf:       Vec::new(),
                            prompt_truncated: false,
                            cwd:              cwd.clone(),
                            started_at:       SystemTime::now(),
                        };
                        new_id
                    }
                };
                out.push(ShellEvent::PromptStarted { block_id: new_id });
            }
            QueryKind::Osc133PromptEnd => {
                self.first_osc_seen(&mut out);
                let prev = std::mem::replace(&mut self.state, BlockState::Unknown);
                if let BlockState::AtPrompt {
                    block_id, prompt_buf, prompt_truncated, cwd, started_at,
                } = prev {
                    out.push(ShellEvent::PromptEnded { block_id: block_id.clone() });
                    self.state = BlockState::Composing {
                        block_id,
                        prompt_buf,
                        prompt_truncated,
                        command_buf:       Vec::new(),
                        command_truncated: false,
                        cwd,
                        started_at,
                    };
                } else {
                    self.state = prev;
                }
            }
            QueryKind::Osc7770Cmd { text } => {
                self.first_osc_seen(&mut out);
                self.pending_cmd = Some(text.clone());
            }
            QueryKind::Osc133CmdStart { cmdline_url } => {
                self.first_osc_seen(&mut out);
                let prev = std::mem::replace(&mut self.state, BlockState::Unknown);
                match prev {
                    BlockState::Composing {
                        block_id, prompt_buf, prompt_truncated,
                        command_buf, command_truncated,
                        cwd, started_at: _at_prompt,
                    } => {
                        // `cmdline_url` is fish 4.x's authoritative
                        // commandline (written next to its native 133;C
                        // BEFORE the `fish_preexec` event fires — see
                        // fish-shell `reader/reader.rs:858-862`). Our
                        // bootstrap's OSC 7770 fallback fires inside the
                        // event handler, which means it lands AFTER this
                        // transition and would otherwise leak into the
                        // next cycle. Prefer cmdline_url when present;
                        // fall back to pending_cmd for shells without
                        // native cmdline_url support (bash/zsh + our
                        // bootstrap, where 7770 lands before our 133;C).
                        let cmd = cmdline_url.clone()
                            .or_else(|| self.pending_cmd.take())
                            .unwrap_or_default();
                        // Always clear pending_cmd so a stale value can't
                        // feed the next cycle even if `cmdline_url` was
                        // used here. (Without this, a 7770 emitted by our
                        // bootstrap during this cycle would survive into
                        // the next `Composing → Running` transition.)
                        self.pending_cmd = None;
                        // `started_at` carried in `AtPrompt`/`Composing`
                        // is the *prompt-paint* time. Re-anchor it to NOW
                        // for the Running block so block.duration =
                        // execution time, not (think + execution). Without
                        // this the UI overstates duration by however long
                        // the user sat at the prompt before pressing
                        // Enter — sometimes minutes.
                        let started_at = SystemTime::now();
                        out.push(ShellEvent::CommandStarted {
                            id:         block_id.clone(),
                            text:       cmd.clone(),
                            cwd:        cwd.clone(),
                            started_at: system_time_to_ms(started_at),
                        });
                        self.state = BlockState::Running {
                            block_id,
                            cmd,
                            cwd,
                            started_at,
                            prompt:           prompt_buf,
                            prompt_truncated,
                            command:          command_buf,
                            command_truncated,
                            output:           Vec::new(),
                            output_truncated: false,
                        };
                    }
                    // 133;C while not Composing — restore prior state.
                    // (fish 4.x emits 133;C twice per cycle: native first
                    // with cmdline_url, then our bootstrap's bare 133;C
                    // from inside fish_preexec. The second one lands on
                    // Running and goes idempotent here.)
                    other => { self.state = other; }
                }
            }
            QueryKind::Osc133CmdEnd { exit } => {
                self.first_osc_seen(&mut out);
                // Belt-and-suspenders: any pending OSC 7770 left here
                // (e.g. our bootstrap fired 7770 mid-cycle but native
                // 133;C had already consumed cmdline_url) must not leak
                // across the block boundary into the next cycle's
                // `Composing → Running` transition.
                self.pending_cmd = None;
                let prev = std::mem::replace(&mut self.state, BlockState::Unknown);
                match prev {
                    BlockState::Running {
                        block_id, cmd, cwd, started_at,
                        prompt, prompt_truncated,
                        command, command_truncated,
                        output, output_truncated,
                    } => {
                        out.push(ShellEvent::CommandFinished {
                            id:                block_id,
                            cmd,
                            cwd:               cwd.clone(),
                            started_at:        system_time_to_ms(started_at),
                            finished_at:       now,
                            exit:              *exit,
                            prompt,
                            prompt_truncated,
                            command,
                            command_truncated,
                            output,
                            output_truncated,
                        });
                        // Drop back to Unknown so any housekeeping bytes
                        // between this 133;D and the next 133;A (fish's
                        // window-title `OSC 0`, bracketed-paste mode-set,
                        // etc.) flow as `block_id=null, scope=prompt`
                        // instead of being tagged with a pre-allocated
                        // id that has no `prompt_started` yet. The next
                        // 133;A goes through the `Unknown → AtPrompt`
                        // branch above, allocating a fresh id and
                        // broadcasting `PromptStarted` *before* any
                        // bytes reference it. `bootstrap_announced`
                        // stays latched, so `Bootstrapped` doesn't
                        // re-fire.
                        self.state = BlockState::Unknown;
                    }
                    other => { self.state = other; }
                }
            }
            QueryKind::Osc7771Context { ctx } => {
                self.first_osc_seen(&mut out);
                out.push(ShellEvent::Context { ctx: ctx.clone() });
            }
            QueryKind::Osc7Cwd { path } => {
                self.first_osc_seen(&mut out);
                if self.current_cwd.as_ref() != Some(path) {
                    self.current_cwd = Some(path.clone());
                    out.push(ShellEvent::CwdChanged { cwd: path.clone() });
                }
            }
            // Capability queries belong to a different code path; ignore.
            _ => {}
        }
        out
    }

    /// Called once we know the PTY is exiting. Force-finalizes any
    /// in-flight Running block so its output isn't lost. AtPrompt /
    /// Composing blocks are dropped (no committed command).
    pub fn on_exit(&mut self) -> Option<ShellEvent> {
        let now = unix_now_ms();
        let prev = std::mem::replace(&mut self.state, BlockState::Unknown);
        match prev {
            BlockState::Running {
                block_id, cmd, cwd, started_at,
                prompt, prompt_truncated,
                command, command_truncated,
                output, output_truncated,
            } => Some(ShellEvent::CommandFinished {
                id:                block_id,
                cmd,
                cwd,
                started_at:        system_time_to_ms(started_at),
                finished_at:       now,
                exit:              None,
                prompt,
                prompt_truncated,
                command,
                command_truncated,
                output,
                output_truncated,
            }),
            _ => None,
        }
    }

    /// Called by the bootstrap-timeout task. If we still haven't seen a
    /// 133 marker after 5s, declare the shell unknown so clients stop
    /// waiting for block events that aren't coming.
    pub fn note_bootstrap_timeout(&mut self) -> Option<ShellEvent> {
        if !self.bootstrap_announced && matches!(self.state, BlockState::Unknown) {
            self.bootstrap_announced = true;
            self.kind = ShellKind::Unknown;
            return Some(ShellEvent::Bootstrapped);
        }
        None
    }

    fn first_osc_seen(&mut self, out: &mut Vec<ShellEvent>) {
        if !self.bootstrap_announced {
            self.bootstrap_announced = true;
            out.push(ShellEvent::Bootstrapped);
        }
    }
}

fn append_capped(buf: &mut Vec<u8>, truncated: &mut bool, bytes: &[u8]) {
    if *truncated { return; }
    let remaining = SEGMENT_MAX_BYTES.saturating_sub(buf.len());
    if bytes.len() > remaining {
        buf.extend_from_slice(&bytes[..remaining]);
        *truncated = true;
    } else {
        buf.extend_from_slice(bytes);
    }
}

fn unix_now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

fn system_time_to_ms(t: SystemTime) -> u64 {
    t.duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn new_state() -> ShellState {
        ShellState::new(ShellKind::Bash, Instant::now(), Some(PathBuf::from("/tmp")))
    }

    #[test]
    fn bootstrap_announced_on_first_marker() {
        let mut s = new_state();
        let evs = s.on_osc(&QueryKind::Osc133PromptStart);
        assert!(matches!(evs[0], ShellEvent::Bootstrapped));
        let evs = s.on_osc(&QueryKind::Osc133PromptEnd);
        assert!(!evs.iter().any(|e| matches!(e, ShellEvent::Bootstrapped)));
    }

    #[test]
    fn happy_path_command_lifecycle_keeps_block_id() {
        let mut s = new_state();
        s.on_osc(&QueryKind::Osc133PromptStart);
        let id_after_a = s.active_block_id().cloned().expect("AtPrompt has id");
        s.record_output(b"$ ");
        s.on_osc(&QueryKind::Osc133PromptEnd);
        assert_eq!(s.active_block_id(), Some(&id_after_a), "B keeps id");
        s.record_output(b"echo hi");
        s.on_osc(&QueryKind::Osc7770Cmd { text: "echo hi".into() });
        let evs = s.on_osc(&QueryKind::Osc133CmdStart { cmdline_url: None });
        let cs = evs.iter().find_map(|e| match e {
            ShellEvent::CommandStarted { id, text, .. } => Some((id.clone(), text.clone())),
            _ => None,
        }).expect("CommandStarted");
        assert_eq!(cs.0, id_after_a, "C keeps id");
        assert_eq!(cs.1, "echo hi");
        s.record_output(b"hi\n");
        let evs = s.on_osc(&QueryKind::Osc133CmdEnd { exit: Some(0) });
        let f = evs.iter().find_map(|e| match e {
            ShellEvent::CommandFinished { id, exit, prompt, command, output, .. } =>
                Some((id.clone(), *exit, prompt.clone(), command.clone(), output.clone())),
            _ => None,
        }).expect("CommandFinished");
        assert_eq!(f.0, id_after_a);
        assert_eq!(f.1, Some(0));
        assert_eq!(f.2, b"$ ");
        assert_eq!(f.3, b"echo hi");
        assert_eq!(f.4, b"hi\n");
        // After 133;D the state machine drops to Unknown so housekeeping
        // bytes (window-title set, mode toggles) before the next prompt
        // flow as block_id=null. The next 133;A allocates a fresh id and
        // broadcasts PromptStarted before any bytes can reference it.
        assert!(s.active_block_id().is_none(), "no block id between 133;D and next 133;A");
        s.record_output(b"\x1b]0;title\x07"); // housekeeping byte; not buffered (Unknown drops it).
        let evs = s.on_osc(&QueryKind::Osc133PromptStart);
        let id_next = evs.iter().find_map(|e| match e {
            ShellEvent::PromptStarted { block_id } => Some(block_id.clone()),
            _ => None,
        }).expect("PromptStarted after 133;D → Unknown → 133;A");
        assert_ne!(id_next, id_after_a, "next prompt cycle gets a fresh id");
        assert_eq!(s.active_block_id(), Some(&id_next));
    }

    #[test]
    fn fish_prompt_redraw_keeps_id() {
        let mut s = new_state();
        s.on_osc(&QueryKind::Osc133PromptStart);
        let id_first = s.active_block_id().cloned().unwrap();
        s.record_output(b"old prompt");
        // Redraw — id should not change, prompt buffer should reset.
        let evs = s.on_osc(&QueryKind::Osc133PromptStart);
        let ps_id = evs.iter().find_map(|e| match e {
            ShellEvent::PromptStarted { block_id } => Some(block_id.clone()),
            _ => None,
        }).expect("PromptStarted");
        assert_eq!(ps_id, id_first, "redraw must keep block_id");
        s.record_output(b"new prompt");
        s.on_osc(&QueryKind::Osc133PromptEnd);
        s.on_osc(&QueryKind::Osc7770Cmd { text: "x".into() });
        s.on_osc(&QueryKind::Osc133CmdStart { cmdline_url: None });
        let evs = s.on_osc(&QueryKind::Osc133CmdEnd { exit: Some(0) });
        let prompt = evs.iter().find_map(|e| match e {
            ShellEvent::CommandFinished { prompt, .. } => Some(prompt.clone()),
            _ => None,
        }).expect("CommandFinished");
        // Redraw cleared "old prompt" before "new prompt" was recorded.
        assert_eq!(prompt, b"new prompt");
    }

    #[test]
    fn composing_to_prompt_start_is_redraw_no_synthesis() {
        // fish 4.x emits A→…→B→A→…→B on every keystroke (autosuggestion /
        // syntax-highlight repaint). The Composing → 133;A edge must NOT
        // synthesize a CommandStarted/CommandFinished pair — otherwise
        // every keystroke would spawn an empty block in the UI. The
        // (rare) "Enter on empty cmdline" case also lands here and
        // correctly produces no block (nothing actually ran).
        let mut s = new_state();
        s.on_osc(&QueryKind::Osc133PromptStart);
        let id_first = s.active_block_id().cloned().unwrap();
        s.record_output(b"$ ");
        s.on_osc(&QueryKind::Osc133PromptEnd);
        s.record_output(b"partial-typed");
        assert!(matches!(s.state, BlockState::Composing { .. }));

        let evs = s.on_osc(&QueryKind::Osc133PromptStart);
        assert!(
            !evs.iter().any(|e| matches!(e, ShellEvent::CommandStarted { .. })),
            "redraw must not synthesize CommandStarted"
        );
        assert!(
            !evs.iter().any(|e| matches!(e, ShellEvent::CommandFinished { .. })),
            "redraw must not synthesize CommandFinished"
        );
        let ps = evs.iter().find_map(|e| match e {
            ShellEvent::PromptStarted { block_id } => Some(block_id.clone()),
            _ => None,
        }).expect("PromptStarted");
        assert_eq!(ps, id_first, "redraw keeps the same block_id");
        assert_eq!(s.active_block_id(), Some(&id_first));

        // After the redraw the shell repaints PS1 + the typed cmdline,
        // then drops B again. The freshly-recorded prompt bytes must
        // reach the eventual CommandFinished.prompt without the prior
        // cycle's content leaking through.
        s.record_output(b"$ ");
        s.on_osc(&QueryKind::Osc133PromptEnd);
        s.record_output(b"echo hi");
        s.on_osc(&QueryKind::Osc7770Cmd { text: "echo hi".into() });
        s.on_osc(&QueryKind::Osc133CmdStart { cmdline_url: None });
        let evs = s.on_osc(&QueryKind::Osc133CmdEnd { exit: Some(0) });
        let (id, prompt, command) = evs.iter().find_map(|e| match e {
            ShellEvent::CommandFinished { id, prompt, command, .. } =>
                Some((id.clone(), prompt.clone(), command.clone())),
            _ => None,
        }).expect("CommandFinished");
        assert_eq!(id, id_first, "real command keeps the same id across the redraw");
        assert_eq!(prompt, b"$ ", "prompt_buf was reset on redraw");
        assert_eq!(command, b"echo hi", "command_buf was reset on redraw");
    }

    #[test]
    fn ctrl_c_running_force_finalizes_and_allocates_new_id() {
        let mut s = new_state();
        s.on_osc(&QueryKind::Osc133PromptStart);
        s.on_osc(&QueryKind::Osc133PromptEnd);
        s.on_osc(&QueryKind::Osc7770Cmd { text: "sleep 30".into() });
        s.on_osc(&QueryKind::Osc133CmdStart { cmdline_url: None });
        let id_running = s.active_block_id().cloned().unwrap();
        let evs = s.on_osc(&QueryKind::Osc133PromptStart);
        let cf = evs.iter().find_map(|e| match e {
            ShellEvent::CommandFinished { id, exit, .. } => Some((id.clone(), *exit)),
            _ => None,
        }).expect("force-finalized CommandFinished");
        assert_eq!(cf.0, id_running);
        assert_eq!(cf.1, None);
        let id_after = s.active_block_id().cloned().unwrap();
        assert_ne!(id_after, id_running);
    }

    #[test]
    fn output_truncates_at_per_segment_cap() {
        let mut s = new_state();
        s.on_osc(&QueryKind::Osc133PromptStart);
        s.on_osc(&QueryKind::Osc133PromptEnd);
        s.on_osc(&QueryKind::Osc7770Cmd { text: "noisy".into() });
        s.on_osc(&QueryKind::Osc133CmdStart { cmdline_url: None });
        let big = vec![b'x'; SEGMENT_MAX_BYTES + 500_000];
        s.record_output(&big);
        let evs = s.on_osc(&QueryKind::Osc133CmdEnd { exit: Some(0) });
        let (output, truncated) = evs.iter().find_map(|e| match e {
            ShellEvent::CommandFinished { output, output_truncated, .. } =>
                Some((output.clone(), *output_truncated)),
            _ => None,
        }).unwrap();
        assert_eq!(output.len(), SEGMENT_MAX_BYTES);
        assert!(truncated);
    }

    #[test]
    fn cwd_change_dedupes() {
        let mut s = new_state();
        s.on_osc(&QueryKind::Osc133PromptStart);
        let evs = s.on_osc(&QueryKind::Osc7Cwd { path: "/tmp".into() });
        assert!(!evs.iter().any(|e| matches!(e, ShellEvent::CwdChanged { .. })));
        let evs = s.on_osc(&QueryKind::Osc7Cwd { path: "/other".into() });
        assert!(evs.iter().any(|e| matches!(e, ShellEvent::CwdChanged { .. })));
    }

    #[test]
    fn timeout_marks_unknown_only_when_no_marker_yet() {
        let mut s = new_state();
        let ev = s.note_bootstrap_timeout();
        assert!(ev.is_some());
        assert!(matches!(s.kind, ShellKind::Unknown));
        let ev2 = s.note_bootstrap_timeout();
        assert!(ev2.is_none());

        let mut s2 = new_state();
        s2.on_osc(&QueryKind::Osc133PromptStart);
        let ev3 = s2.note_bootstrap_timeout();
        assert!(ev3.is_none());
    }

    #[test]
    fn record_output_routes_to_correct_segment() {
        let mut s = new_state();
        s.on_osc(&QueryKind::Osc133PromptStart);
        s.record_output(b"PS1");
        s.on_osc(&QueryKind::Osc133PromptEnd);
        s.record_output(b"cmd-typed");
        s.on_osc(&QueryKind::Osc7770Cmd { text: "x".into() });
        s.on_osc(&QueryKind::Osc133CmdStart { cmdline_url: None });
        s.record_output(b"out");
        let evs = s.on_osc(&QueryKind::Osc133CmdEnd { exit: Some(0) });
        let (p, c, o) = evs.iter().find_map(|e| match e {
            ShellEvent::CommandFinished { prompt, command, output, .. } =>
                Some((prompt.clone(), command.clone(), output.clone())),
            _ => None,
        }).unwrap();
        assert_eq!(p, b"PS1");
        assert_eq!(c, b"cmd-typed");
        assert_eq!(o, b"out");
    }

    #[test]
    fn active_block_id_none_until_first_133a() {
        let s = new_state();
        assert!(s.active_block_id().is_none());
    }

    #[test]
    fn cmdline_url_takes_priority_over_pending_cmd() {
        // fish 4.x ordering: native `133;C;cmdline_url=…` fires BEFORE
        // `fish_preexec`, our bootstrap's OSC 7770 fires INSIDE the event
        // (so it lands AFTER native 133;C in the byte stream).
        // cmdline_url must win, otherwise pending_cmd would be empty for
        // the first cycle and stale-from-previous for every cycle after
        // (the off-by-one we hit in production: block N's text === block
        // N-1's command).
        let mut s = new_state();
        s.on_osc(&QueryKind::Osc133PromptStart);
        s.on_osc(&QueryKind::Osc133PromptEnd);
        // Native 133;C arrives first with the authoritative cmd.
        let evs = s.on_osc(&QueryKind::Osc133CmdStart {
            cmdline_url: Some("ls".into()),
        });
        let cs = evs.iter().find_map(|e| match e {
            ShellEvent::CommandStarted { text, .. } => Some(text.clone()),
            _ => None,
        }).expect("CommandStarted");
        assert_eq!(cs, "ls", "cmdline_url is the cmd source");
        // Bootstrap's 7770 + bare 133;C arrive AFTER, while we're already
        // Running. They must be fully idempotent — and crucially, must
        // NOT leave a leftover pending_cmd that the next cycle would
        // mis-attribute.
        s.on_osc(&QueryKind::Osc7770Cmd { text: "ls".into() });
        s.on_osc(&QueryKind::Osc133CmdStart { cmdline_url: None });
        s.on_osc(&QueryKind::Osc133CmdEnd { exit: Some(0) });
        assert!(s.pending_cmd.is_none(), "pending_cmd cleared at 133;D");

        // Next cycle: another fish-style sequence. After 133;D the state
        // machine sits at Unknown; 133;A allocates a fresh id, then 133;B
        // → Composing → 133;C with new cmdline_url. The cmd attached to
        // the new block must come from THIS cycle's cmdline_url, not from
        // any pending_cmd left over from the previous cycle.
        s.on_osc(&QueryKind::Osc133PromptStart);
        s.on_osc(&QueryKind::Osc133PromptEnd);
        let evs = s.on_osc(&QueryKind::Osc133CmdStart {
            cmdline_url: Some("e".into()),
        });
        let cs = evs.iter().find_map(|e| match e {
            ShellEvent::CommandStarted { text, .. } => Some(text.clone()),
            _ => None,
        }).expect("CommandStarted (second cycle)");
        assert_eq!(cs, "e", "second block sees its own cmd, not previous");
    }

    #[test]
    fn started_at_anchored_at_133c_not_133a() {
        // block.started_at must reflect when the command actually started
        // executing (133;C), not when the prompt first painted (133;A).
        // Otherwise duration shown in the UI = think-time + execution,
        // which can be minutes off when the user sat reading the prompt.
        let mut s = new_state();
        s.on_osc(&QueryKind::Osc133PromptStart);
        s.on_osc(&QueryKind::Osc133PromptEnd);
        // Simulate user reading the prompt for a perceptible time before
        // pressing Enter.
        std::thread::sleep(std::time::Duration::from_millis(40));
        let pre_c = system_time_to_ms(SystemTime::now());
        let evs = s.on_osc(&QueryKind::Osc133CmdStart {
            cmdline_url: Some("ls".into()),
        });
        let cs_at = evs.iter().find_map(|e| match e {
            ShellEvent::CommandStarted { started_at, .. } => Some(*started_at),
            _ => None,
        }).expect("CommandStarted");
        assert!(
            cs_at >= pre_c - 5,
            "started_at ({cs_at}) must be at-or-after the 133;C boundary ({pre_c})"
        );
        let evs = s.on_osc(&QueryKind::Osc133CmdEnd { exit: Some(0) });
        let cf_at = evs.iter().find_map(|e| match e {
            ShellEvent::CommandFinished { started_at, .. } => Some(*started_at),
            _ => None,
        }).expect("CommandFinished");
        assert_eq!(cs_at, cf_at, "started_at carries through finalize");
    }

    #[test]
    fn unknown_state_reports_passthrough_scope_in_all_three_subcases() {
        // (1) Pre-bootstrap: state machine starts in Unknown before any
        //     OSC 133 fires (fish welcome banner / SSH MOTD lands here).
        let mut s = new_state();
        assert!(matches!(s.state, BlockState::Unknown));
        assert_eq!(s.active_scope(), OutputScope::Passthrough);

        // (2) Between blocks: a 133;D drops state back to Unknown until
        //     the next 133;A arrives (window-title set, mode toggles).
        s.on_osc(&QueryKind::Osc133PromptStart);
        s.on_osc(&QueryKind::Osc133PromptEnd);
        s.on_osc(&QueryKind::Osc133CmdStart { cmdline_url: Some("ls".into()) });
        s.on_osc(&QueryKind::Osc133CmdEnd { exit: Some(0) });
        assert!(matches!(s.state, BlockState::Unknown));
        assert_eq!(s.active_scope(), OutputScope::Passthrough);

        // (3) Bootstrap-timeout (shell-integration disabled or unsupported
        //     shell): the timeout latches kind=Unknown and the state
        //     stays Unknown forever — every byte is passthrough.
        let mut s2 = ShellState::new(ShellKind::Bash, Instant::now(), None);
        s2.note_bootstrap_timeout();
        assert!(matches!(s2.state, BlockState::Unknown));
        assert_eq!(s2.active_scope(), OutputScope::Passthrough);
    }

    #[test]
    fn no_block_id_between_133d_and_next_133a() {
        // Housekeeping bytes the shell emits after a command finishes but
        // before painting the next prompt — `OSC 0` (window title), mode
        // toggles, etc. — must NOT be tagged with a block_id, because no
        // `prompt_started` has been broadcast yet for the next block.
        // Previously the state machine pre-allocated the next id at 133;D
        // and tagged these bytes with it, leaving the client with
        // `pty.output` events that referenced a block_id it had never
        // heard of.
        let mut s = new_state();
        s.on_osc(&QueryKind::Osc133PromptStart);
        let id_first = s.active_block_id().cloned().unwrap();
        s.on_osc(&QueryKind::Osc133PromptEnd);
        s.on_osc(&QueryKind::Osc133CmdStart { cmdline_url: Some("ls".into()) });
        s.on_osc(&QueryKind::Osc133CmdEnd { exit: Some(0) });

        // Between 133;D and the next 133;A: no active block; scope is
        // Passthrough so housekeeping bytes are visibly distinct from
        // real PS1 paint bytes.
        assert!(s.active_block_id().is_none());
        assert!(matches!(s.state, BlockState::Unknown));
        assert_eq!(s.active_scope(), OutputScope::Passthrough);

        // Next 133;A: fresh id, broadcasts PromptStarted before any bytes
        // can reference it.
        let evs = s.on_osc(&QueryKind::Osc133PromptStart);
        let id_second = evs.iter().find_map(|e| match e {
            ShellEvent::PromptStarted { block_id } => Some(block_id.clone()),
            _ => None,
        }).expect("PromptStarted");
        assert_ne!(id_second, id_first);
        // bootstrap_announced is latched, so the second cycle does NOT
        // re-broadcast Bootstrapped.
        assert!(!evs.iter().any(|e| matches!(e, ShellEvent::Bootstrapped)));
    }

    #[test]
    fn pending_cmd_falls_back_when_cmdline_url_absent() {
        // bash/zsh + our bootstrap: there's no native 133;C; we emit OSC
        // 7770 then bare 133;C from inside preexec. The state machine
        // must still pick up the cmd from pending_cmd in that case.
        let mut s = new_state();
        s.on_osc(&QueryKind::Osc133PromptStart);
        s.on_osc(&QueryKind::Osc133PromptEnd);
        s.on_osc(&QueryKind::Osc7770Cmd { text: "echo hi".into() });
        let evs = s.on_osc(&QueryKind::Osc133CmdStart { cmdline_url: None });
        let cs = evs.iter().find_map(|e| match e {
            ShellEvent::CommandStarted { text, .. } => Some(text.clone()),
            _ => None,
        }).expect("CommandStarted");
        assert_eq!(cs, "echo hi");
    }
}
