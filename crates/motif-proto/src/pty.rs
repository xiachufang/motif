//! `pty.*` types. Wire shapes finalized in M1; behavior implemented in M2.

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::common::{BlockId, PtyId, UnixMs};

// ── v2 shell-integration types ──

/// Which shell motifd successfully bootstrapped on a given PTY. `Unknown`
/// means we either couldn't detect the shell or the user disabled the
/// integration; clients should fall back to v1 PTY behavior.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ShellKind {
    Bash,
    Zsh,
    Fish,
    Unknown,
}

/// Cheap-to-compute prompt context emitted by the shell's precmd hook.
/// All fields are optional; expensive ones (kube context, aws profile,
/// `node --version`) are deliberately out of scope to avoid slowing the
/// prompt. Add fields here as needed — the wire format treats them as
/// optional, so old clients keep working.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ShellContext {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub branch: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub head: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub venv: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conda: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub node: Option<String>,
}

/// Which segment of a block a chunk of bytes belongs to. See
/// `docs/rpc.md` §6 for the lifecycle that produces these segments.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum OutputScope {
    /// Bytes that don't belong to any block segment: shell hasn't been
    /// bootstrapped yet (pre-first-`777;A` welcome banner / MOTD), the
    /// previous block has finished and the next prompt hasn't started
    /// (between `777;D` and the next `777;A` — fish's window-title /
    /// mode-toggle housekeeping), or shell-integration is disabled
    /// entirely. `block_id` is always `null` for these. Frontend treats
    /// them as raw passthrough (FloatTerm only, no `BlockTerm` routing).
    Passthrough,
    /// `777;A..777;B` — shell-rendered PS1.
    Prompt,
    /// `777;B..777;C` — user-typed command echo (syntax highlight,
    /// autosuggest, PS2 continuation).
    Command,
    /// `777;C..777;D` — command stdout/stderr.
    Output,
}

/// One entry in `pty.list_blocks`. The full segment bytes are fetched
/// separately via `pty.get_block_output(block_id)`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BlockSummary {
    pub id: BlockId,
    pub cwd: PathBuf,
    /// Logical command text from the shell-integration explicit command marker. Empty string for synthesized
    /// blocks (bare-Enter or Ctrl-C cancel).
    pub cmd: String,
    pub started_at: UnixMs,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub finished_at: Option<UnixMs>,
    /// `None` for force-finalized blocks (e.g. SIGINT). `Some(0)` for
    /// synthesized empty-command blocks.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exit_code: Option<i32>,

    pub prompt_size: u64,
    pub prompt_truncated: bool,
    pub command_size: u64,
    pub command_truncated: bool,
    pub output_size: u64,
    pub output_truncated: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ListBlocksParams {
    pub pty_id: PtyId,
    /// Return blocks with id < `before`, sorted descending. None → most
    /// recent `limit` blocks.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub before: Option<BlockId>,
    pub limit: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ListBlocksResult {
    pub blocks: Vec<BlockSummary>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GetBlockOutputParams {
    pub pty_id: PtyId,
    pub block_id: BlockId,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GetBlockOutputResult {
    #[serde(rename = "prompt_b64", with = "crate::wire::bytes_base64_or_native")]
    pub prompt: Vec<u8>,
    pub prompt_truncated: bool,
    #[serde(rename = "command_b64", with = "crate::wire::bytes_base64_or_native")]
    pub command: Vec<u8>,
    pub command_truncated: bool,
    #[serde(rename = "output_b64", with = "crate::wire::bytes_base64_or_native")]
    pub output: Vec<u8>,
    pub output_truncated: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PtyInfo {
    pub id: PtyId,
    pub cmd: String,
    pub cwd: PathBuf,
    pub cols: u16,
    pub rows: u16,
    pub alive: bool,
    pub created_at: UnixMs,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PtyCreateParams {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cmd: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<PathBuf>,
    #[serde(default)]
    pub env: Vec<(String, String)>,
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
pub struct PtyResizeParams {
    pub pty_id: PtyId,
    pub cols: u16,
    pub rows: u16,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PtyKillParams {
    pub pty_id: PtyId,
}
