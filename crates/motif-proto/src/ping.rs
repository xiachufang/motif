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
///
/// The `rzv_direct_*` fields are an optional LAN-direct hint: when a
/// rendezvous-mode server also exposes a plaintext, non-loopback `--listen`
/// port, it advertises that port plus its non-loopback NIC addresses here so a
/// same-LAN client can probe and upgrade off the relay. Both are omitted from
/// the wire when empty.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PingInfo {
    pub service: String,
    pub version: String,
    /// Plaintext direct port a same-LAN client can dial, or `None` when no
    /// direct listener is configured.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rzv_direct_port: Option<u16>,
    /// motifd's non-loopback NIC addresses (IPv4/IPv6 literals) to try at
    /// `rzv_direct_port`. Empty unless a direct port is configured.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub rzv_direct_addrs: Vec<String>,
}

impl PingInfo {
    /// `true` when `service` matches the frozen motif-server magic string —
    /// the one check a probe needs to confirm it's talking to a motif-server.
    pub fn is_motif_server(&self) -> bool {
        self.service == PING_SERVICE
    }
}
