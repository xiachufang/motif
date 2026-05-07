//! Protocol-level error codes mapped onto JSON-RPC 2.0 error objects.

use serde::{Deserialize, Serialize};

/// Custom error codes layered on top of JSON-RPC 2.0 reserved range.
///
/// JSON-RPC reserves `-32700..-32000`. We use `-32001` and beyond for
/// motif-specific errors.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[repr(i32)]
#[serde(into = "i32", try_from = "i32")]
pub enum ErrorCode {
    AuthRequired         = -32001,
    PathEscape           = -32002,
    FileTooLarge         = -32003,
    Conflict             = -32004,
    NotAGitRepo          = -32005,
    PtyNotFound          = -32006,
    SessionNotFound      = -32007,
    AlreadyExists        = -32008,
    NotAttached          = -32009,
    PtyLimitReached      = -32010,
    BlobNotFound         = -32011,
    BlobExpired          = -32012,
    BlobLimitReached     = -32013,
    BlobTooLarge         = -32014,
    BlobChecksumMismatch = -32015,
    /// Block id was not found in the PTY's ring buffer (rolled out, or
    /// never existed). Returned by `pty.get_block_output`.
    BlockNotFound        = -32016,
    /// Catch-all for unrecognized internal errors.
    Internal             = -32099,
}

impl From<ErrorCode> for i32 {
    fn from(c: ErrorCode) -> i32 { c as i32 }
}

impl TryFrom<i32> for ErrorCode {
    type Error = i32;
    fn try_from(v: i32) -> Result<Self, i32> {
        Ok(match v {
            -32001 => Self::AuthRequired,
            -32002 => Self::PathEscape,
            -32003 => Self::FileTooLarge,
            -32004 => Self::Conflict,
            -32005 => Self::NotAGitRepo,
            -32006 => Self::PtyNotFound,
            -32007 => Self::SessionNotFound,
            -32008 => Self::AlreadyExists,
            -32009 => Self::NotAttached,
            -32010 => Self::PtyLimitReached,
            -32011 => Self::BlobNotFound,
            -32012 => Self::BlobExpired,
            -32013 => Self::BlobLimitReached,
            -32014 => Self::BlobTooLarge,
            -32015 => Self::BlobChecksumMismatch,
            -32016 => Self::BlockNotFound,
            -32099 => Self::Internal,
            other  => return Err(other),
        })
    }
}

#[derive(Debug, Clone, thiserror::Error, Serialize, Deserialize)]
#[error("{message}")]
pub struct RpcError {
    pub code:    i32,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub data:    Option<serde_json::Value>,
}

impl RpcError {
    pub fn new(code: ErrorCode, message: impl Into<String>) -> Self {
        Self { code: code.into(), message: message.into(), data: None }
    }

    pub fn with_data(mut self, data: serde_json::Value) -> Self {
        self.data = Some(data);
        self
    }

    /// JSON-RPC standard codes.
    pub fn parse_error(msg: impl Into<String>) -> Self      { Self { code: -32700, message: msg.into(), data: None } }
    pub fn invalid_request(msg: impl Into<String>) -> Self  { Self { code: -32600, message: msg.into(), data: None } }
    pub fn method_not_found(method: &str) -> Self           { Self { code: -32601, message: format!("method not found: {method}"), data: None } }
    pub fn invalid_params(msg: impl Into<String>) -> Self   { Self { code: -32602, message: msg.into(), data: None } }
    pub fn internal(msg: impl Into<String>) -> Self         { Self { code: -32603, message: msg.into(), data: None } }
}
