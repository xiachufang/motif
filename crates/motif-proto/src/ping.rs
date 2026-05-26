//! `/ping` identity-probe payload — shared by server and clients so the
//! magic `service` string can't drift between the two sides of the wire.

use serde::{Deserialize, Serialize};

/// Stable magic string clients match on to confirm a `motif-server` is
/// answering (vs. some other service on the same host/port). Keep this
/// value frozen across versions — it's an identity probe, not a version
/// check.
pub const PING_SERVICE: &str = "motif-server";

/// Body of `GET /ping`. `service` is always [`PING_SERVICE`]; `version`
/// carries the server build's `CARGO_PKG_VERSION` for diagnostics only.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PingInfo {
    pub service: String,
    pub version: String,
}

impl PingInfo {
    /// `true` when `service` matches the frozen motif-server magic string —
    /// the one check a probe needs to confirm it's talking to a motif-server.
    pub fn is_motif_server(&self) -> bool {
        self.service == PING_SERVICE
    }
}
