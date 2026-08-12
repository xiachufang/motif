//! Server-scoped Codex service control and thread-workspace types.

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::session::SessionInfo;

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct StatusParams {}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StatusResult {
    pub running: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct StartParams {}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct StopParams {}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct RestartParams {}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LifecycleResult {
    pub running: bool,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub closed_sessions: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EnsureWorkspaceParams {
    pub thread_id: String,
    pub cwd: PathBuf,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EnsureWorkspaceResult {
    pub session: SessionInfo,
}
