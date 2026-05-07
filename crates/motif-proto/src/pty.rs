//! `pty.*` types. Wire shapes finalized in M1; behavior implemented in M2.

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::common::{PtyId, UnixMs};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PtyInfo {
    pub id:         PtyId,
    pub cmd:        String,
    pub cwd:        PathBuf,
    pub cols:       u16,
    pub rows:       u16,
    pub alive:      bool,
    pub created_at: UnixMs,
    /// Best-effort name of the foreground process inside this PTY (e.g.
    /// "zsh", "vim", "cargo"). Populated by the server's foreground-process
    /// watcher; `None` until the first poll resolves it (or if the OS won't
    /// tell us).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fg_name:    Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PtyCreateParams {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cmd:  Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd:  Option<PathBuf>,
    #[serde(default)]
    pub env:  Vec<(String, String)>,
    pub cols: u16,
    pub rows: u16,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PtyCreateResult {
    pub info: PtyInfo,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PtyListResult {
    pub ptys: Vec<PtyInfo>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PtyWriteParams {
    pub pty_id:   PtyId,
    pub data_b64: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PtyResizeParams {
    pub pty_id: PtyId,
    pub cols:   u16,
    pub rows:   u16,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PtyKillParams {
    pub pty_id: PtyId,
}
