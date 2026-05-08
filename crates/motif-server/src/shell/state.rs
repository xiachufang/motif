//! Per-PTY block state machine. Consumes shell-integration OSC markers
//! produced by the bootstrap scripts and emits high-level
//! [`ShellEvent`]s. The reader loop in `pty.rs` then turns those into
//! `Event::Pty*` broadcasts and appends finished blocks to the
//! [`BlockStore`](super::block_store::BlockStore).
//!
//! See `docs/shell-integration.md` §6 for the transition table this
//! mirrors.

use std::path::PathBuf;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use motif_proto::common::BlockId;
use motif_proto::pty::{ShellContext, ShellKind};
use motif_proto::terminal_query::QueryKind;
use ulid::Ulid;

/// Per-block in-memory output cap. Anything past this is dropped from
/// the recording (still streamed live via `Event::PtyOutput`); the
/// finished block carries `output_truncated: true`.
pub const SINGLE_BLOCK_MAX_BYTES: usize = 1024 * 1024;

#[derive(Debug)]
pub enum BlockState {
    /// PTY just spawned; haven't seen any OSC 133 yet. May be a shell
    /// motifd doesn't recognize, or may be still booting.
    Unknown,
    /// Got `133;A`. Shell is rendering its prompt.
    AtPrompt,
    /// Got `133;B`. User is typing.
    Composing,
    /// Got `133;C` (or `7770` then `133;C`). Command is executing.
    Running {
        block_id:   BlockId,
        cmd:        String,
        cwd:        PathBuf,
        started_at: SystemTime,
        output:     Vec<u8>,
        truncated:  bool,
    },
}

#[derive(Debug)]
pub enum ShellEvent {
    /// First successful OSC 133, or 5s timeout (kind = Unknown).
    Bootstrapped,
    /// Emitted on every OSC 133;A — including fish's prompt redraws for
    /// autosuggest / syntax highlighting. Clients reset their PS1
    /// renderer here so each prompt paints on a fresh grid.
    PromptStarted,
    /// Emitted on the AtPrompt → Composing transition (OSC 133;B).
    /// Pure prompt redraws don't fire this — only the first 133;B after
    /// 133;A does, since the state is already past AtPrompt for redraws
    /// where the shell skips re-emitting B.
    PromptEnded,
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
        id:               BlockId,
        cmd:              String,
        cwd:              PathBuf,
        started_at:       u64,
        finished_at:      u64,
        exit:             Option<i32>,
        output:           Vec<u8>,
        output_truncated: bool,
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
    /// Latches true once we've emitted `Bootstrapped` (either after
    /// the first 133 marker or after the 5s timeout).
    pub bootstrap_announced: bool,
    /// Tracked separately from `BlockState::Running { cwd }` because
    /// OSC 7 fires outside any block too.
    pub current_cwd: Option<PathBuf>,
    /// `7770` always arrives just before `133;C`. We stash the text
    /// and consume it on the next `CmdStart` so a missing 7770
    /// doesn't block the transition (cmd would just be empty).
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

    /// Block id of the currently-running command, if any. Used by the
    /// reader loop to tag `Event::PtyOutput`.
    pub fn block_id_in_progress(&self) -> Option<&BlockId> {
        match &self.state {
            BlockState::Running { block_id, .. } => Some(block_id),
            _ => None,
        }
    }

    /// Append to the in-flight block's recorded output (if any).
    /// Truncates at `SINGLE_BLOCK_MAX_BYTES`.
    pub fn record_output(&mut self, bytes: &[u8]) {
        if let BlockState::Running { output, truncated, .. } = &mut self.state {
            if *truncated { return; }
            let remaining = SINGLE_BLOCK_MAX_BYTES.saturating_sub(output.len());
            if bytes.len() > remaining {
                output.extend_from_slice(&bytes[..remaining]);
                *truncated = true;
            } else {
                output.extend_from_slice(bytes);
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
                // Force-finalize a stranded Running block if the shell
                // re-rendered the prompt without sending 133;D (e.g.
                // SIGINT killed the command and bash skipped postcmd).
                if let Some(ev) = self.finalize_running(None, now) {
                    out.push(ev);
                } else if matches!(self.state, BlockState::Composing) {
                    // Bare Enter on an empty prompt: shells skip
                    // preexec/postexec, so 133;C/D never fire. Synthesize
                    // a degenerate Started+Finished pair so the client
                    // gets a block delimiter (FloatTerm clears, stack
                    // gains an empty card).
                    let id  = Ulid::new().to_string();
                    let cwd = self.current_cwd.clone().unwrap_or_else(|| PathBuf::from("/"));
                    let cmd = self.pending_cmd.take().unwrap_or_default();
                    out.push(ShellEvent::CommandStarted {
                        id: id.clone(), text: cmd.clone(), cwd: cwd.clone(), started_at: now,
                    });
                    out.push(ShellEvent::CommandFinished {
                        id, cmd, cwd,
                        started_at: now, finished_at: now,
                        exit: Some(0),
                        output: Vec::new(),
                        output_truncated: false,
                    });
                }
                self.state = BlockState::AtPrompt;
                // Boundary signal for clients: reset their PS1 renderer
                // and start collecting fresh prompt-zone bytes. Emitted
                // after Bootstrapped / force-finalize / synthesize-empty
                // so clients see those state changes before the new
                // prompt edge.
                out.push(ShellEvent::PromptStarted);
            }
            QueryKind::Osc133PromptEnd => {
                self.first_osc_seen(&mut out);
                if matches!(self.state, BlockState::AtPrompt) {
                    self.state = BlockState::Composing;
                    out.push(ShellEvent::PromptEnded);
                }
            }
            QueryKind::Osc7770Cmd { text } => {
                self.first_osc_seen(&mut out);
                self.pending_cmd = Some(text.clone());
            }
            QueryKind::Osc133CmdStart => {
                self.first_osc_seen(&mut out);
                if matches!(self.state, BlockState::Composing | BlockState::AtPrompt) {
                    let id = Ulid::new().to_string();
                    let cmd = self.pending_cmd.take().unwrap_or_default();
                    let cwd = self.current_cwd.clone().unwrap_or_else(|| PathBuf::from("/"));
                    let started = SystemTime::now();
                    self.state = BlockState::Running {
                        block_id:  id.clone(),
                        cmd:       cmd.clone(),
                        cwd:       cwd.clone(),
                        started_at: started,
                        output:    Vec::new(),
                        truncated: false,
                    };
                    out.push(ShellEvent::CommandStarted {
                        id, text: cmd, cwd, started_at: now,
                    });
                }
                // Idempotent on a second 133;C — keep the existing
                // Running block. Some shells emit C twice on retried
                // input.
            }
            QueryKind::Osc133CmdEnd { exit } => {
                self.first_osc_seen(&mut out);
                if let Some(ev) = self.finalize_running(*exit, now) {
                    out.push(ev);
                }
                self.state = BlockState::AtPrompt;
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
    /// in-flight block so its output isn't lost from the BlockStore.
    pub fn on_exit(&mut self) -> Option<ShellEvent> {
        let ev = self.finalize_running(None, unix_now_ms());
        self.state = BlockState::Unknown;
        ev
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

    fn finalize_running(&mut self, exit: Option<i32>, finished_at: u64) -> Option<ShellEvent> {
        let prev = std::mem::replace(&mut self.state, BlockState::Unknown);
        match prev {
            BlockState::Running { block_id, cmd, cwd, started_at, output, truncated } => {
                Some(ShellEvent::CommandFinished {
                    id: block_id,
                    cmd,
                    cwd,
                    started_at: system_time_to_ms(started_at),
                    finished_at,
                    exit,
                    output,
                    output_truncated: truncated,
                })
            }
            other => { self.state = other; None }
        }
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
        // Second marker doesn't re-announce.
        let evs = s.on_osc(&QueryKind::Osc133PromptEnd);
        assert!(!evs.iter().any(|e| matches!(e, ShellEvent::Bootstrapped)));
    }

    #[test]
    fn happy_path_command_lifecycle() {
        let mut s = new_state();
        s.on_osc(&QueryKind::Osc133PromptStart);
        s.on_osc(&QueryKind::Osc133PromptEnd);
        s.on_osc(&QueryKind::Osc7770Cmd { text: "echo hi".into() });
        let evs = s.on_osc(&QueryKind::Osc133CmdStart);
        let cs = evs.iter().find_map(|e| match e {
            ShellEvent::CommandStarted { text, id, .. } => Some((text.clone(), id.clone())),
            _ => None,
        }).expect("expected CommandStarted");
        assert_eq!(cs.0, "echo hi");
        assert!(matches!(s.state, BlockState::Running { .. }));
        // record some output bytes — should accumulate in the block.
        s.record_output(b"hi\n");
        let evs = s.on_osc(&QueryKind::Osc133CmdEnd { exit: Some(0) });
        let finished = evs.iter().find_map(|e| match e {
            ShellEvent::CommandFinished { id, exit, output, output_truncated, .. } =>
                Some((id.clone(), *exit, output.clone(), *output_truncated)),
            _ => None,
        }).expect("expected CommandFinished");
        assert_eq!(finished.0, cs.1);
        assert_eq!(finished.1, Some(0));
        assert_eq!(finished.2, b"hi\n");
        assert!(!finished.3);
        assert!(matches!(s.state, BlockState::AtPrompt));
    }

    #[test]
    fn empty_enter_synthesizes_block() {
        // Composing → 133;A (no 133;C in between) means user pressed
        // Enter on an empty line. Shells skip preexec/postexec entirely,
        // so we synthesize a degenerate block as a delimiter.
        let mut s = new_state();
        s.on_osc(&QueryKind::Osc133PromptStart);
        s.on_osc(&QueryKind::Osc133PromptEnd);
        assert!(matches!(s.state, BlockState::Composing));
        // Fresh 133;A from Composing → synthesize Started + Finished.
        let evs = s.on_osc(&QueryKind::Osc133PromptStart);
        let started = evs.iter().find_map(|e| match e {
            ShellEvent::CommandStarted { id, text, .. } => Some((id.clone(), text.clone())),
            _ => None,
        }).expect("expected CommandStarted");
        let finished = evs.iter().find_map(|e| match e {
            ShellEvent::CommandFinished { id, cmd, exit, output, output_truncated, .. } =>
                Some((id.clone(), cmd.clone(), *exit, output.clone(), *output_truncated)),
            _ => None,
        }).expect("expected CommandFinished");
        // Same id ties the pair together, both empty.
        assert_eq!(started.0, finished.0);
        assert!(started.1.is_empty());
        assert!(finished.1.is_empty());
        assert_eq!(finished.2, Some(0));
        assert!(finished.3.is_empty());
        assert!(!finished.4);
        assert!(matches!(s.state, BlockState::AtPrompt));
    }

    #[test]
    fn empty_enter_does_not_synthesize_from_at_prompt() {
        // After a real command finishes (133;D moves us to AtPrompt),
        // the next 133;A from a re-rendered prompt must NOT synthesize
        // an extra empty block — there's no "user pressed Enter" event
        // here, just the shell's own prompt cycle.
        let mut s = new_state();
        s.on_osc(&QueryKind::Osc133PromptStart);
        s.on_osc(&QueryKind::Osc133PromptEnd);
        s.on_osc(&QueryKind::Osc7770Cmd { text: "echo hi".into() });
        s.on_osc(&QueryKind::Osc133CmdStart);
        s.on_osc(&QueryKind::Osc133CmdEnd { exit: Some(0) });
        assert!(matches!(s.state, BlockState::AtPrompt));
        let evs = s.on_osc(&QueryKind::Osc133PromptStart);
        assert!(!evs.iter().any(|e| matches!(e, ShellEvent::CommandStarted { .. })));
        assert!(!evs.iter().any(|e| matches!(e, ShellEvent::CommandFinished { .. })));
    }

    #[test]
    fn ctrl_c_then_new_prompt_force_finalizes_block() {
        // Real shells sometimes emit `133;A` (new prompt) directly
        // after a SIGINT'd command without a `133;D`. The state
        // machine has to synthesize a CommandFinished so the BlockStore
        // doesn't lose the partial output.
        let mut s = new_state();
        s.on_osc(&QueryKind::Osc133PromptStart);
        s.on_osc(&QueryKind::Osc133PromptEnd);
        s.on_osc(&QueryKind::Osc7770Cmd { text: "sleep 30".into() });
        s.on_osc(&QueryKind::Osc133CmdStart);
        assert!(matches!(s.state, BlockState::Running { .. }));
        // Fresh 133;A while still running → finalize + AtPrompt.
        let evs = s.on_osc(&QueryKind::Osc133PromptStart);
        assert!(evs.iter().any(|e| matches!(
            e,
            ShellEvent::CommandFinished { exit: None, .. }
        )));
        assert!(matches!(s.state, BlockState::AtPrompt));
    }

    #[test]
    fn output_truncates_at_per_block_cap() {
        let mut s = new_state();
        s.on_osc(&QueryKind::Osc133PromptStart);
        s.on_osc(&QueryKind::Osc133PromptEnd);
        s.on_osc(&QueryKind::Osc7770Cmd { text: "noisy".into() });
        s.on_osc(&QueryKind::Osc133CmdStart);
        // Push 1.5 MiB → cap at 1 MiB.
        let big = vec![b'x'; 1024 * 1024 + 500_000];
        s.record_output(&big);
        let evs = s.on_osc(&QueryKind::Osc133CmdEnd { exit: Some(0) });
        let (output, truncated) = evs.iter().find_map(|e| match e {
            ShellEvent::CommandFinished { output, output_truncated, .. } =>
                Some((output.clone(), *output_truncated)),
            _ => None,
        }).unwrap();
        assert_eq!(output.len(), SINGLE_BLOCK_MAX_BYTES);
        assert!(truncated);
    }

    #[test]
    fn cwd_change_dedupes() {
        let mut s = new_state();
        s.on_osc(&QueryKind::Osc133PromptStart);
        // Same as initial /tmp → no event.
        let evs = s.on_osc(&QueryKind::Osc7Cwd { path: "/tmp".into() });
        assert!(!evs.iter().any(|e| matches!(e, ShellEvent::CwdChanged { .. })));
        // Different → emits.
        let evs = s.on_osc(&QueryKind::Osc7Cwd { path: "/other".into() });
        assert!(evs.iter().any(|e| matches!(e, ShellEvent::CwdChanged { .. })));
    }

    #[test]
    fn prompt_started_fires_on_every_133a_including_redraws() {
        // fish re-emits 133;A on every prompt redraw (autosuggest /
        // syntax highlight). Each one must yield a PromptStarted so
        // the client resets its PS1 renderer.
        let mut s = new_state();
        let evs = s.on_osc(&QueryKind::Osc133PromptStart);
        assert!(evs.iter().any(|e| matches!(e, ShellEvent::PromptStarted)));
        // Second 133;A while AtPrompt → still PromptStarted, no other side effects.
        let evs = s.on_osc(&QueryKind::Osc133PromptStart);
        assert!(evs.iter().any(|e| matches!(e, ShellEvent::PromptStarted)));
        assert!(!evs.iter().any(|e| matches!(e, ShellEvent::CommandStarted { .. })));
        assert!(!evs.iter().any(|e| matches!(e, ShellEvent::CommandFinished { .. })));
    }

    #[test]
    fn prompt_ended_only_on_at_prompt_to_composing_transition() {
        let mut s = new_state();
        s.on_osc(&QueryKind::Osc133PromptStart);
        let evs = s.on_osc(&QueryKind::Osc133PromptEnd);
        assert!(evs.iter().any(|e| matches!(e, ShellEvent::PromptEnded)));
        // A second 133;B while already Composing must NOT re-fire.
        let evs = s.on_osc(&QueryKind::Osc133PromptEnd);
        assert!(!evs.iter().any(|e| matches!(e, ShellEvent::PromptEnded)));
    }

    #[test]
    fn prompt_started_after_finalize_orders_after_command_finished() {
        // Ctrl-C path: Running → 133;A force-finalizes the block AND
        // emits PromptStarted. CommandFinished must come before
        // PromptStarted so clients commit the block before resetting
        // their PS1 renderer.
        let mut s = new_state();
        s.on_osc(&QueryKind::Osc133PromptStart);
        s.on_osc(&QueryKind::Osc133PromptEnd);
        s.on_osc(&QueryKind::Osc7770Cmd { text: "sleep 30".into() });
        s.on_osc(&QueryKind::Osc133CmdStart);
        let evs = s.on_osc(&QueryKind::Osc133PromptStart);
        let cf_idx = evs.iter().position(|e| matches!(e, ShellEvent::CommandFinished { .. }));
        let ps_idx = evs.iter().position(|e| matches!(e, ShellEvent::PromptStarted));
        assert!(cf_idx.is_some() && ps_idx.is_some());
        assert!(cf_idx.unwrap() < ps_idx.unwrap());
    }

    #[test]
    fn empty_enter_orders_command_pair_before_prompt_started() {
        // Composing → 133;A: synthesize CommandStarted+CommandFinished
        // pair, then PromptStarted last. Same ordering principle as the
        // Ctrl-C path.
        let mut s = new_state();
        s.on_osc(&QueryKind::Osc133PromptStart);
        s.on_osc(&QueryKind::Osc133PromptEnd);
        let evs = s.on_osc(&QueryKind::Osc133PromptStart);
        let cs_idx = evs.iter().position(|e| matches!(e, ShellEvent::CommandStarted { .. }));
        let cf_idx = evs.iter().position(|e| matches!(e, ShellEvent::CommandFinished { .. }));
        let ps_idx = evs.iter().position(|e| matches!(e, ShellEvent::PromptStarted));
        assert!(cs_idx.is_some() && cf_idx.is_some() && ps_idx.is_some());
        assert!(cs_idx.unwrap() < cf_idx.unwrap());
        assert!(cf_idx.unwrap() < ps_idx.unwrap());
    }

    #[test]
    fn timeout_marks_unknown_only_when_no_marker_yet() {
        let mut s = new_state();
        let ev = s.note_bootstrap_timeout();
        assert!(ev.is_some());
        assert!(matches!(s.kind, ShellKind::Unknown));
        // Second timeout call is a no-op.
        let ev2 = s.note_bootstrap_timeout();
        assert!(ev2.is_none());

        // Fresh state that already saw a marker → timeout no-ops.
        let mut s2 = new_state();
        s2.on_osc(&QueryKind::Osc133PromptStart);
        let ev3 = s2.note_bootstrap_timeout();
        assert!(ev3.is_none());
    }
}
