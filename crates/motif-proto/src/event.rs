//! Server → client push events. Encoded as JSON-RPC notifications.
//!
//! Each variant carries a monotonically increasing `seq`. Clients can pass the
//! last known seq in `session.attach` to request replay of buffered events.

use serde::{Deserialize, Serialize};

use crate::common::{ClientId, PtyId, Seq, UnixMs};
use crate::pty::PtyInfo;
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
        seq:      Seq,
    },

    #[serde(rename = "pty.resize")]
    PtyResize { pty_id: PtyId, cols: u16, rows: u16, seq: Seq },

    #[serde(rename = "pty.created")]
    PtyCreated { info: PtyInfo, seq: Seq },

    #[serde(rename = "pty.exited")]
    PtyExited { pty_id: PtyId, exit_code: Option<i32>, seq: Seq },

    /// Foreground process state of a PTY changed: cwd, program name, or
    /// both. Server polls /proc/<pid>/cwd + /comm (Linux) or proc_pidinfo +
    /// proc_pidpath (macOS) at a low frequency and emits this when a
    /// transition is observed. Clients use cwd to scope file tree / git
    /// diff, and the name to label tabs.
    ///
    /// `name` is always present on the wire — `null` explicitly means
    /// "no foreground program known". (Don't skip-serialize: clients need
    /// to distinguish "name cleared" from "name unchanged".)
    #[serde(rename = "pty.fg_changed")]
    PtyFgChanged {
        pty_id: PtyId,
        cwd:    std::path::PathBuf,
        #[serde(default)]
        name:   Option<String>,
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
}

impl Event {
    pub fn seq(&self) -> Seq {
        match self {
            Self::TreeChanged   { seq, .. } => *seq,
            Self::PtyOutput     { seq, .. } => *seq,
            Self::PtyResize     { seq, .. } => *seq,
            Self::PtyCreated    { seq, .. } => *seq,
            Self::PtyExited     { seq, .. } => *seq,
            Self::PtyFgChanged  { seq, .. } => *seq,
            Self::GitChanged    { seq, .. } => *seq,
            Self::ClientJoined  { seq, .. } => *seq,
            Self::ClientLeft    { seq, .. } => *seq,
            Self::ViewOpened    { seq, .. } => *seq,
            Self::ViewClosed    { seq, .. } => *seq,
            Self::ViewActiveChanged { seq, .. } => *seq,
            Self::ViewMoved         { seq, .. } => *seq,
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
