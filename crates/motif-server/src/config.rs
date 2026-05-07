//! Server-side configuration.

use std::net::SocketAddr;
use std::path::PathBuf;

#[derive(Debug, Clone)]
pub struct ServerConfig {
    pub listen:     SocketAddr,
    pub token:      String,
    pub cert:       Option<PathBuf>,
    pub key:        Option<PathBuf>,
}

impl ServerConfig {
    /// Reject non-loopback listening without TLS — defense in depth.
    pub fn validate(&self) -> anyhow::Result<()> {
        let is_loopback = self.listen.ip().is_loopback();
        let has_tls     = self.cert.is_some() && self.key.is_some();
        if !is_loopback && !has_tls {
            anyhow::bail!(
                "refusing to listen on non-loopback address {} without --cert/--key",
                self.listen
            );
        }
        if self.cert.is_some() != self.key.is_some() {
            anyhow::bail!("--cert and --key must be specified together");
        }
        Ok(())
    }
}
