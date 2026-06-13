//! Server-side configuration.

use std::net::SocketAddr;

pub use motif_net::{RzvListenConfig, TailscaleListenConfig};

#[derive(Debug, Clone)]
pub struct ServerConfig {
    /// TCP listen address. `None` to disable the TCP backend (e.g.
    /// tailscale-only deployments).
    pub listen: Option<SocketAddr>,
    /// Embedded-Tailscale listener. Independently optional from `listen`;
    /// at least one must be set.
    pub tailscale: Option<TailscaleListenConfig>,
    /// Rendezvous-relay accept backend. motifd parks `accept` waiters at the
    /// relay so clients can reach it without direct connectivity. Like
    /// tailscale, it's a private surface (relay-mediated), so it satisfies the
    /// "at least one listener" requirement and needs no public-port auth guard.
    pub rendezvous: Option<RzvListenConfig>,
    /// Bearer token expected on HTTP RPC and WS upgrades. `None` disables
    /// auth — only allowed when no public TCP surface is exposed (loopback or
    /// tailscale-only); see `validate`.
    pub token: Option<String>,
    /// Explicit opt-out of the token-less non-loopback guard in `validate`.
    /// When set, a network-reachable TCP port without auth is permitted (with
    /// a loud startup warning). Off by default; operators must consciously
    /// enable it.
    pub allow_insecure_no_auth: bool,
    /// Push-relay base URL. When set, Claude Code hook notifications arriving
    /// on the local hook socket are forwarded here (encrypted) for APNs
    /// delivery. `None` disables push entirely. motifd never holds the APNs
    /// signing key — only this relay URL.
    pub push_relay_url: Option<String>,
}

impl ServerConfig {
    /// Reject misconfigurations:
    /// - At least one of `listen` / `tailscale` must be set.
    /// - Token-less mode is rejected on non-loopback TCP (no auth on a
    ///   network-reachable port is never what the operator means), unless
    ///   `allow_insecure_no_auth` is set as an explicit override.
    ///   Loopback or tailscale-only is fine: tailnet membership is the
    ///   auth boundary.
    ///
    /// motifd itself never terminates TLS: operators expose it on loopback /
    /// a trusted segment / the tailnet, and terminate TLS at an upstream
    /// proxy if they need it. The token guard below is the auth boundary.
    pub fn validate(&self) -> anyhow::Result<()> {
        if self.listen.is_none() && self.tailscale.is_none() && self.rendezvous.is_none() {
            anyhow::bail!(
                "must specify at least one of --listen / --tailscale-hostname / --rzv-relay"
            );
        }
        if let Some(addr) = self.listen {
            let is_loopback = addr.ip().is_loopback();
            if !is_loopback && self.token.is_none() {
                if self.allow_insecure_no_auth {
                    tracing::warn!(
                        %addr,
                        "listening on non-loopback address with auth DISABLED \
                         (--insecure-no-auth): anyone reachable on the network can attach"
                    );
                } else {
                    anyhow::bail!(
                        "refusing to listen on non-loopback address {} without --token-file \
                         (anyone reachable on the network could attach otherwise; \
                         pass --insecure-no-auth to override)",
                        addr
                    );
                }
            }
        }
        Ok(())
    }

    pub(crate) fn to_listen_config(&self) -> motif_net::ListenConfig {
        motif_net::ListenConfig {
            tcp: self.listen,
            tailscale: self.tailscale.clone(),
            rendezvous: self.rendezvous.clone(),
        }
    }
}
