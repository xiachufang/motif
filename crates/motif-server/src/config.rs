//! Server-side configuration.

use std::net::SocketAddr;
use std::path::PathBuf;

pub use motif_net::TailscaleListenConfig;

#[derive(Debug, Clone)]
pub struct ServerConfig {
    /// TCP listen address. `None` to disable the TCP backend (e.g.
    /// tailscale-only deployments).
    pub listen: Option<SocketAddr>,
    /// Embedded-Tailscale listener. Independently optional from `listen`;
    /// at least one must be set.
    pub tailscale: Option<TailscaleListenConfig>,
    /// Bearer token expected on HTTP RPC and WS upgrades. `None` disables
    /// auth — only allowed when no public TCP surface is exposed (loopback or
    /// tailscale-only); see `validate`.
    pub token: Option<String>,
    pub cert: Option<PathBuf>,
    pub key: Option<PathBuf>,
}

impl ServerConfig {
    /// Reject misconfigurations:
    /// - At least one of `listen` / `tailscale` must be set.
    /// - `--cert` and `--key` must come together.
    /// - Token-less mode is rejected on non-loopback TCP (no auth on a
    ///   network-reachable port is never what the operator means).
    ///   Loopback or tailscale-only is fine: tailnet membership is the
    ///   auth boundary.
    ///
    /// Note: we used to also require TLS for non-loopback TCP. That was
    /// removed by user request — operators terminating TLS at an
    /// upstream proxy (or running on a trusted segment) shouldn't be
    /// forced to wire cert/key through motifd itself. The token guard
    /// below remains as the actual auth boundary.
    pub fn validate(&self) -> anyhow::Result<()> {
        if self.listen.is_none() && self.tailscale.is_none() {
            anyhow::bail!("must specify at least one of --listen / --tailscale-hostname");
        }
        if let Some(addr) = self.listen {
            let is_loopback = addr.ip().is_loopback();
            if !is_loopback && self.token.is_none() {
                anyhow::bail!(
                    "refusing to listen on non-loopback address {} without --token-file \
                     (anyone reachable on the network could attach otherwise)",
                    addr
                );
            }
        }
        if self.cert.is_some() != self.key.is_some() {
            anyhow::bail!("--cert and --key must be specified together");
        }
        Ok(())
    }

    pub(crate) fn to_listen_config(&self) -> motif_net::ListenConfig {
        motif_net::ListenConfig {
            tcp: self.listen,
            tailscale: self.tailscale.clone(),
        }
    }
}
