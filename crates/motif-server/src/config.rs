//! Server-side configuration.

use std::net::SocketAddr;
use std::path::PathBuf;

pub use motif_net::TailscaleListenConfig;

#[derive(Debug, Clone)]
pub struct ServerConfig {
    /// TCP listen address. `None` to disable the TCP backend (e.g.
    /// tailscale-only deployments).
    pub listen:    Option<SocketAddr>,
    /// Embedded-Tailscale listener. Independently optional from `listen`;
    /// at least one must be set.
    pub tailscale: Option<TailscaleListenConfig>,
    pub token:     String,
    pub cert:      Option<PathBuf>,
    pub key:       Option<PathBuf>,
}

impl ServerConfig {
    /// Reject misconfigurations:
    /// - At least one of `listen` / `tailscale` must be set.
    /// - Non-loopback TCP requires TLS (defense in depth).
    /// - `--cert` and `--key` must come together.
    pub fn validate(&self) -> anyhow::Result<()> {
        if self.listen.is_none() && self.tailscale.is_none() {
            anyhow::bail!("must specify at least one of --listen / --tailscale-hostname");
        }
        if let Some(addr) = self.listen {
            let is_loopback = addr.ip().is_loopback();
            let has_tls     = self.cert.is_some() && self.key.is_some();
            if !is_loopback && !has_tls {
                anyhow::bail!(
                    "refusing to listen on non-loopback address {} without --cert/--key",
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
            tcp:       self.listen,
            tailscale: self.tailscale.clone(),
        }
    }
}
