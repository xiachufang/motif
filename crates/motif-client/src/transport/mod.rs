//! Connection transports for `motif-tui`. Direct WS is the default; SSH
//! tunnel is opt-in via `--via ssh://...`.

pub mod ssh;

use std::time::Duration;

use anyhow::Context;

use crate::client::Client;
use ssh::SshTunnel;

/// Resolved connection target. Owns any spawned tunnel resources for the life
/// of the connection.
pub struct Connected {
    pub client:  Client,
    pub _tunnel: Option<SshTunnel>,
}

/// Connect using whatever transport is implied by `via`. If `via` is `None`,
/// connect directly to `url`.
pub async fn connect(
    url:   &str,
    token: &str,
    via:   Option<&str>,
    remote_port: Option<u16>,
) -> anyhow::Result<Connected> {
    if let Some(via) = via {
        if let Some(rest) = via.strip_prefix("ssh://") {
            return connect_ssh(rest, token, remote_port).await;
        }
        if via == "direct" {
            // explicit direct
        } else {
            anyhow::bail!("unsupported --via scheme: {via} (expected ssh://… or direct)");
        }
    }
    let client = Client::connect(url, token).await
        .with_context(|| format!("connecting to {url}"))?;
    Ok(Connected { client, _tunnel: None })
}

async fn connect_ssh(
    target:      &str,
    token:       &str,
    remote_port: Option<u16>,
) -> anyhow::Result<Connected> {
    let port = remote_port.unwrap_or(7777);
    let tunnel = SshTunnel::open(target, port).await?;
    // Allow a brief warm-up; SshTunnel::open polls but lower bound to be safe.
    tokio::time::sleep(Duration::from_millis(50)).await;
    let local_url = tunnel.local_ws_url();
    let client = Client::connect(&local_url, token).await
        .with_context(|| format!("connecting via ssh tunnel to {local_url}"))?;
    Ok(Connected { client, _tunnel: Some(tunnel) })
}
