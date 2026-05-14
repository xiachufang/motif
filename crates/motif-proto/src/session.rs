//! `session.*` request/response types.

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::common::{ClientId, Seq, SessionId, UnixMs};
use crate::pty::PtyInfo;
use crate::view::{ViewId, ViewInfo};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionInfo {
    pub id: SessionId,
    pub name: String,
    pub workdir: PathBuf,
    pub created_at: UnixMs,
    pub client_count: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClientInfo {
    pub id: ClientId,
    pub since: UnixMs,
}

// ────────────────────────────────────────────────────── session.list

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ListParams {}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ListResult {
    pub sessions: Vec<SessionInfo>,
}

// ────────────────────────────────────────────────────── session.create

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateParams {
    pub name: String,
    pub workdir: PathBuf,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateResult {
    pub session: SessionInfo,
}

// ────────────────────────────────────────────────────── session.attach

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AttachParams {
    pub name: String,
    /// Optional: last sequence the client already has, server replays from
    /// `last_seq + 1` if still in ring buffer; otherwise sends `session.resync`
    /// (resync support is a v1.5+ feature).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_seq: Option<Seq>,

    /// Optional: the client terminal's foreground colour, in the rgb portion
    /// of an OSC 10 reply (e.g. `"e6e6/e6e6/e6e6"`). When supplied, server
    /// answers OSC 10 queries from the shell with this value rather than a
    /// hardcoded default — so theme-aware prompts (starship, oh-my-posh)
    /// pick a colour scheme that actually matches the user's terminal.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub term_fg: Option<String>,
    /// Optional: the client terminal's background colour, same encoding as
    /// `term_fg`. Used to answer OSC 11 queries.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub term_bg: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AttachResult {
    pub session: SessionInfo,
    pub client_id: ClientId,
    pub clients: Vec<ClientInfo>,
    pub ptys: Vec<PtyInfo>,
    pub views: Vec<ViewInfo>,
    pub active_view: Option<ViewId>,
    pub last_seq: Seq,
}

// ────────────────────────────────────────────────────── session.detach

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct DetachParams {}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct DetachResult {}

// ────────────────────────────────────────────────────── session.destroy

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DestroyParams {
    pub name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct DestroyResult {}
