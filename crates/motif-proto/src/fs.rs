//! `fs.*` types. Wire shapes finalized in M1; behavior in M3 / M7.

use serde::{Deserialize, Serialize};

use crate::common::{Sha256Hex, UnixMs};
use crate::git::GitFileStatus;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum FileType {
    File,
    Dir,
    Symlink,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TreeEntry {
    pub name: String,
    #[serde(rename = "type")]
    pub kind: FileType,
    pub size: u64,
    pub mtime: UnixMs,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub git_status: Option<GitFileStatus>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TreeParams {
    pub path: String,
    #[serde(default = "one_u32")]
    pub depth: u32,
    #[serde(default)]
    pub show_hidden: bool,
}
fn one_u32() -> u32 {
    1
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TreeResult {
    pub path: String,
    pub entries: Vec<TreeEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StatParams {
    pub path: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StatResult {
    #[serde(rename = "type")]
    pub kind: FileType,
    pub size: u64,
    pub mtime: UnixMs,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub git_status: Option<GitFileStatus>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReadParams {
    pub path: String,
    #[serde(default = "ten_mb")]
    pub max_bytes: u64,
}
fn ten_mb() -> u64 {
    10_000_000
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReadResult {
    pub content_b64: String,
    pub sha256: Sha256Hex,
    pub truncated: bool,
    pub binary: bool,
    /// MIME type guess from file extension + magic bytes (M7+).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mime: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WriteParams {
    pub path: String,
    pub content_b64: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expected_sha256: Option<Sha256Hex>,
    #[serde(default)]
    pub force: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WriteResult {
    pub sha256: Sha256Hex,
}

