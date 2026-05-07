//! Common type aliases used across the protocol.

use serde::{Deserialize, Serialize};

/// A motif session identifier (ULID, 26 chars in Crockford base32).
pub type SessionId = String;

/// A connected-client identifier (ULID).
pub type ClientId = String;

/// A PTY identifier — server-assigned, e.g. `"sh-1"`, `"sh-2"`.
pub type PtyId = String;

/// A monotonically increasing sequence number on the broadcast event stream.
pub type Seq = u64;

/// A block (one shell command's lifecycle) identifier — ULID text. String
/// rather than u64 to dodge JS `Number` precision after passing through
/// `ts-rs` derived TS types.
pub type BlockId = String;

/// Lower-case hex SHA-256 (64 chars).
pub type Sha256Hex = String;

/// Unix epoch milliseconds.
pub type UnixMs = u64;

/// Wraps a name + ULID pair sometimes returned together.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NamedId {
    pub name: String,
    pub id:   String,
}
