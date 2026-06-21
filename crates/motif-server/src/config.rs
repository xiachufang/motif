//! Server-side configuration.

use std::net::SocketAddr;
use std::sync::Arc;

pub use motif_net::{RzvListenConfig, TailscaleListenConfig};

use crate::ws::RzvDirectInfo;

#[derive(Clone)]
pub struct ServerConfig {
    /// TCP listen address. `None` to disable the TCP backend (e.g.
    /// tailscale-only deployments).
    pub listen: Option<SocketAddr>,
    /// When set, the `listen` backend terminates TLS with this self-signed
    /// identity (the client pins the cert). motifd sets it for any non-loopback
    /// `listen` (encrypted direct surface); loopback stays plaintext. Shares the
    /// identity used for rzv end-to-end TLS, so the pin matches either path.
    pub listen_tls: Option<Arc<rustls::ServerConfig>>,
    /// Embedded-Tailscale listener. Independently optional from `listen`;
    /// at least one must be set.
    pub tailscale: Option<TailscaleListenConfig>,
    /// Rendezvous-relay accept backend. motifd parks `accept` waiters at the
    /// relay so clients can reach it without direct connectivity.
    pub rendezvous: Option<RzvListenConfig>,
    /// LAN-direct `/ping` advertisement: this host's NIC addresses + the
    /// `listen` port, surfaced so a same-LAN rendezvous client can probe and
    /// upgrade off the relay onto a direct (TLS-pinned) connection. `None` ⇒
    /// `/ping` omits the hint. See `main.rs`.
    pub rzv_direct: Option<Arc<RzvDirectInfo>>,
    /// Bearer token required on HTTP RPC and WS upgrades. motifd sets it to the
    /// psk-derived access bearer (`base64url(rzv::derive_bearer(psk))`) whenever
    /// a `psk` exists (pairing mode); `None` disables auth (loopback / embed /
    /// tailscale-only, where the surface is otherwise gated). Every client —
    /// rzv or direct — derives the same value from the QR's psk and sends it.
    pub token: Option<String>,
    /// Push-relay base URL. When set, Claude Code hook notifications arriving
    /// on the local hook socket are forwarded here (encrypted) for APNs
    /// delivery. `None` disables push entirely. motifd never holds the APNs
    /// signing key — only this relay URL.
    pub push_relay_url: Option<String>,
}

// rustls::ServerConfig isn't Debug; render listen_tls as a presence flag.
impl std::fmt::Debug for ServerConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ServerConfig")
            .field("listen", &self.listen)
            .field("listen_tls", &self.listen_tls.is_some())
            .field("tailscale", &self.tailscale)
            .field("rendezvous", &self.rendezvous)
            .field("rzv_direct", &self.rzv_direct)
            .field("token", &self.token.as_ref().map(|_| "<redacted>"))
            .field("push_relay_url", &self.push_relay_url)
            .finish()
    }
}

impl ServerConfig {
    /// The only structural requirement: at least one listener. Access control is
    /// the psk-derived bearer (`token`) when a psk exists; encryption is TLS
    /// (`listen_tls` / rzv). There is no token-less non-loopback escape hatch —
    /// any network `listen` is set up by `main.rs` with both TLS and a bearer.
    pub fn validate(&self) -> anyhow::Result<()> {
        if self.listen.is_none() && self.tailscale.is_none() && self.rendezvous.is_none() {
            anyhow::bail!(
                "must specify at least one of --listen / --tailscale-hostname / --rzv-relay"
            );
        }
        Ok(())
    }

    pub(crate) fn to_listen_config(&self) -> motif_net::ListenConfig {
        motif_net::ListenConfig {
            tcp: self.listen,
            tcp_tls: self.listen_tls.clone(),
            tailscale: self.tailscale.clone(),
            rendezvous: self.rendezvous.clone(),
        }
    }
}
