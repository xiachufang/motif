use std::net::SocketAddr;
use std::path::PathBuf;

#[derive(Clone)]
pub struct WebConfig {
    pub listen:           SocketAddr,
    pub motifd_url:       String,
    pub motifd_token:     String,
    pub browser_token:    String,
    pub bind_cert:        Option<PathBuf>,
    pub bind_key:         Option<PathBuf>,
}

impl WebConfig {
    pub fn validate(&self) -> anyhow::Result<()> {
        if !self.listen.ip().is_loopback() && self.bind_cert.is_none() {
            anyhow::bail!("non-loopback --listen requires --bind-cert/--bind-key");
        }
        if self.bind_cert.is_some() != self.bind_key.is_some() {
            anyhow::bail!("--bind-cert and --bind-key must be specified together");
        }
        if !(self.motifd_url.starts_with("ws://") || self.motifd_url.starts_with("wss://")) {
            anyhow::bail!("--motifd-url must start with ws:// or wss://");
        }
        Ok(())
    }
}
