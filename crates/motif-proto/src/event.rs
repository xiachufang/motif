//! Server → client push events. Encoded as JSON-RPC notifications.
//!
//! Each variant carries a monotonically increasing `seq`. Clients can pass the
//! last known seq in `session.attach` to request replay of buffered events.

use serde::{Deserialize, Serialize};

use crate::common::{BlockId, ClientId, PtyId, Seq, UnixMs};
use crate::pty::{PtyInfo, ShellContext, ShellKind};
use crate::view::{ViewId, ViewInfo};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "method", content = "params")]
pub enum Event {
    #[serde(rename = "tree.changed")]
    TreeChanged { paths: Vec<String>, seq: Seq },

    #[serde(rename = "pty.output")]
    PtyOutput {
        pty_id:   PtyId,
        /// Base64-encoded raw bytes from the pseudo-tty.
        data_b64: String,
        /// v2 shell-integration: when the PTY's BlockState is `Running`,
        /// this carries the active block id so clients can fold output
        /// into the block card. `None` outside a running command (prompt
        /// rendering, idle compose, un-bootstrapped PTY).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        block_id: Option<BlockId>,
        seq:      Seq,
    },

    #[serde(rename = "pty.resize")]
    PtyResize { pty_id: PtyId, cols: u16, rows: u16, seq: Seq },

    #[serde(rename = "pty.created")]
    PtyCreated { info: PtyInfo, seq: Seq },

    #[serde(rename = "pty.exited")]
    PtyExited { pty_id: PtyId, exit_code: Option<i32>, seq: Seq },

    /// The cwd of a PTY's shell process changed. Server polls
    /// /proc/<pid>/cwd (Linux) or proc_pidinfo (macOS) every ~1.5s and
    /// emits this on transitions. Clients use it to scope file tree / git
    /// diff. The v2 shell-integration path (OSC 7 from a precmd hook) emits
    /// the same event but at I/O speed instead of polling cadence.
    #[serde(rename = "pty.cwd_changed")]
    PtyCwdChanged {
        pty_id: PtyId,
        cwd:    std::path::PathBuf,
        seq:    Seq,
    },

    #[serde(rename = "git.changed")]
    GitChanged { seq: Seq },

    #[serde(rename = "client.joined")]
    ClientJoined { client_id: ClientId, since: UnixMs, seq: Seq },

    #[serde(rename = "client.left")]
    ClientLeft { client_id: ClientId, seq: Seq },

    /// A new tab/view appeared in the session. All clients mirror.
    #[serde(rename = "view.opened")]
    ViewOpened { view: ViewInfo, seq: Seq },

    /// A tab/view was closed (by user, or because its PTY exited).
    #[serde(rename = "view.closed")]
    ViewClosed { view_id: ViewId, seq: Seq },

    /// The currently-focused tab changed. `None` means no active tab.
    #[serde(rename = "view.active_changed")]
    ViewActiveChanged { view_id: Option<ViewId>, seq: Seq },

    /// Tabs have been reordered. `order` is the full list of view ids in
    /// their new positions; clients reconcile by sorting their local views
    /// to match.
    #[serde(rename = "view.moved")]
    ViewMoved { order: Vec<ViewId>, seq: Seq },

    // ── v2 shell-integration events ──

    /// First successful OSC 133 sequence observed on this PTY (or 5s
    /// timeout reached → `shell: Unknown`). Lets clients distinguish
    /// "still booting" from "this PTY won't ever produce block events".
    #[serde(rename = "pty.shell_bootstrapped")]
    PtyShellBootstrapped { pty_id: PtyId, shell: ShellKind, seq: Seq },

    /// OSC 133;A observed: shell is (re-)rendering its prompt. Emitted
    /// on every 133;A — fish redraws the prompt for autosuggest /
    /// syntax highlighting and each redraw is its own `prompt_started`.
    /// Clients use this as the boundary to clear their PS1 renderer so
    /// the next prompt paints on a fresh grid.
    #[serde(rename = "pty.prompt_started")]
    PtyPromptStarted { pty_id: PtyId, seq: Seq },

    /// OSC 133;B observed: prompt is done, user is now composing input.
    /// Only emitted on the AtPrompt → Composing transition (not on
    /// pure redraws), so clients can use it to freeze the PS1 + user
    /// input row for the eventual BlockCard header.
    #[serde(rename = "pty.prompt_ended")]
    PtyPromptEnded { pty_id: PtyId, seq: Seq },

    /// User pressed Enter; shell is about to run a command. Allocates a
    /// `block_id` that subsequent `pty.output` events carry.
    #[serde(rename = "pty.command_started")]
    PtyCommandStarted {
        pty_id:     PtyId,
        block_id:   BlockId,
        text:       String,
        cwd:        std::path::PathBuf,
        started_at: UnixMs,
        seq:        Seq,
    },

    /// Command finished. `exit_code = None` when the block was force-
    /// finalized (e.g., shell sent a fresh prompt without `133;D`).
    #[serde(rename = "pty.command_finished")]
    PtyCommandFinished {
        pty_id:      PtyId,
        block_id:    BlockId,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        exit_code:   Option<i32>,
        finished_at: UnixMs,
        seq:         Seq,
    },

    /// Cheap prompt context (git branch, venv, etc.) refreshed on every
    /// precmd. Sent at most once per prompt; clients render as status-bar
    /// chips.
    #[serde(rename = "pty.shell_context")]
    PtyShellContext { pty_id: PtyId, ctx: ShellContext, seq: Seq },

    /// Catch-all so older clients can ignore newly added variants without
    /// the JSON-RPC parse failing. Required because we use `tag = "method"`
    /// — without this, an unknown method string aborts deserialization.
    #[serde(other)]
    Unknown,
}

impl Event {
    /// Sequence number for this event. `Unknown` (forward-compat fallback)
    /// has no seq on the wire — return 0 so callers can still total-order
    /// known events without crashing on an unknown one.
    pub fn seq(&self) -> Seq {
        match self {
            Self::TreeChanged    { seq, .. } => *seq,
            Self::PtyOutput      { seq, .. } => *seq,
            Self::PtyResize      { seq, .. } => *seq,
            Self::PtyCreated     { seq, .. } => *seq,
            Self::PtyExited      { seq, .. } => *seq,
            Self::PtyCwdChanged  { seq, .. } => *seq,
            Self::GitChanged     { seq, .. } => *seq,
            Self::ClientJoined   { seq, .. } => *seq,
            Self::ClientLeft     { seq, .. } => *seq,
            Self::ViewOpened     { seq, .. } => *seq,
            Self::ViewClosed     { seq, .. } => *seq,
            Self::ViewActiveChanged   { seq, .. } => *seq,
            Self::ViewMoved           { seq, .. } => *seq,
            Self::PtyShellBootstrapped { seq, .. } => *seq,
            Self::PtyPromptStarted     { seq, .. } => *seq,
            Self::PtyPromptEnded       { seq, .. } => *seq,
            Self::PtyCommandStarted    { seq, .. } => *seq,
            Self::PtyCommandFinished   { seq, .. } => *seq,
            Self::PtyShellContext      { seq, .. } => *seq,
            Self::Unknown => 0,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn client_joined_round_trip() {
        let e = Event::ClientJoined {
            client_id: "01H".into(),
            since:     1700000000000,
            seq:       42,
        };
        let s = serde_json::to_string(&e).unwrap();
        assert!(s.contains("\"method\":\"client.joined\""));
        let back: Event = serde_json::from_str(&s).unwrap();
        assert_eq!(back.seq(), 42);
        match back {
            Event::ClientJoined { client_id, .. } => assert_eq!(client_id, "01H"),
            _ => panic!(),
        }
    }
}
