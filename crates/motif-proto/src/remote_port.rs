//! `remote_port.*` request/response types.

use serde::{Deserialize, Serialize};

use crate::common::UnixMs;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RemotePortMapping {
    pub id: String,
    pub remote_host: String,
    pub remote_port: u16,
    pub local_scheme: String,
    pub created_at: UnixMs,
}

// ────────────────────────────────────────────────────── remote_port.list

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ListParams {}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ListResult {
    pub mappings: Vec<RemotePortMapping>,
}

// ────────────────────────────────────────────────────── remote_port.add

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AddParams {
    #[serde(default = "default_remote_host")]
    pub remote_host: String,
    pub remote_port: u16,
    #[serde(default = "default_local_scheme")]
    pub local_scheme: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AddResult {
    pub mapping: RemotePortMapping,
}

// ────────────────────────────────────────────────────── remote_port.update

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UpdateParams {
    pub id: String,
    #[serde(default = "default_remote_host")]
    pub remote_host: String,
    pub remote_port: u16,
    #[serde(default = "default_local_scheme")]
    pub local_scheme: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UpdateResult {
    pub mapping: RemotePortMapping,
}

// ────────────────────────────────────────────────────── remote_port.remove

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RemoveParams {
    pub id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct RemoveResult {}

fn default_remote_host() -> String {
    "127.0.0.1".to_string()
}

fn default_local_scheme() -> String {
    "http".to_string()
}
