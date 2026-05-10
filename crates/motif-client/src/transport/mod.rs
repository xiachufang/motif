//! Connection transports. Direct WS is the default; SSH tunnel is opt-in via
//! `--via ssh://...`; `--via tailscale://hostname[:port]` (under the
//! `tailscale` feature) brings up an embedded tsnet client node and dials
//! through the tailnet.

pub mod ssh;

use std::any::Any;
use std::time::Duration;

use anyhow::Context;

use crate::client::Client;
use ssh::SshTunnel;

/// Resolved connection target. Owns any spawned tunnel resources for the life
/// of the connection. Hold the value in scope until the `client` is no longer
/// needed — dropping `Connected` may tear down a tunnel or tsnet node, which
/// will fail any in-flight RPC.
pub struct Connected {
    pub client: Client,
    /// Resources that must outlive the WebSocket connection. SSH tunnel
    /// child processes, embedded tsnet nodes, etc. Type-erased so a single
    /// field works regardless of which transport(s) are stacked. Order
    /// matters: dropped after `client`.
    pub _keepalive: Vec<Box<dyn Any + Send + Sync>>,
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
        #[cfg(feature = "tailscale")]
        if let Some(rest) = via.strip_prefix("tailscale://") {
            return connect_tailscale(rest, url, token).await;
        }
        if via == "direct" {
            // explicit direct
        } else {
            anyhow::bail!(
                "unsupported --via scheme: {via} (expected ssh://…, tailscale://…, or direct)"
            );
        }
    }
    let client = Client::connect(url, token).await
        .with_context(|| format!("connecting to {url}"))?;
    Ok(Connected { client, _keepalive: Vec::new() })
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
    Ok(Connected {
        client,
        _keepalive: vec![Box::new(tunnel) as Box<dyn Any + Send + Sync>],
    })
}

/// Build a `TsOptions` for a client-side tsnet node using the conventional
/// defaults (state dir `~/.cache/motif/tsnet`, per-process hostname so two
/// concurrent client invocations don't collide on the same tailnet device
/// entry, ephemeral so the entry self-removes when the process exits).
/// Env overrides: `MOTIF_TS_{STATE_DIR,HOSTNAME,AUTHKEY,CONTROL_URL}`.
#[cfg(feature = "tailscale")]
pub fn default_client_ts_options() -> motif_net::motif_tailscale::TsOptions {
    motif_net::motif_tailscale::TsOptions {
        hostname: std::env::var("MOTIF_TS_HOSTNAME")
            .unwrap_or_else(|_| format!("motif-client-{}", std::process::id())),
        state_dir: std::env::var_os("MOTIF_TS_STATE_DIR")
            .map(std::path::PathBuf::from)
            .unwrap_or_else(default_state_dir),
        authkey:     std::env::var("MOTIF_TS_AUTHKEY").ok(),
        control_url: std::env::var("MOTIF_TS_CONTROL_URL").ok(),
        ephemeral:   true,
    }
}

#[cfg(feature = "tailscale")]
async fn connect_tailscale(
    rest:  &str,
    url:   &str,
    token: &str,
) -> anyhow::Result<Connected> {
    use std::sync::Arc;
    use motif_net::motif_tailscale::TsServer;

    // `rest` is `hostname[:port]`, e.g. `motifd-laptop:7777`. Default port
    // matches the server's --tailscale-port default.
    let dial_addr = if rest.contains(':') {
        rest.to_string()
    } else {
        format!("{rest}:7777")
    };

    let mut server = TsServer::new(default_client_ts_options()).context("tsnet init")?;
    server.up().await.context("tsnet up")?;
    let server = Arc::new(server);

    let stream = motif_net::dial(&motif_net::DialTarget::Tailscale {
        addr:   dial_addr.clone(),
        server: server.clone(),
    }).await
        .with_context(|| format!("tsnet dial {dial_addr}"))?;

    let client = Client::connect_with_stream(url, token, stream).await
        .with_context(|| format!("ws handshake over tsnet to {dial_addr}"))?;
    Ok(Connected {
        client,
        _keepalive: vec![Box::new(server) as Box<dyn Any + Send + Sync>],
    })
}

#[cfg(feature = "tailscale")]
fn default_state_dir() -> std::path::PathBuf {
    if let Some(home) = std::env::var_os("HOME") {
        let mut p = std::path::PathBuf::from(home);
        p.push(".cache");
        p.push("motif");
        p.push("tsnet");
        p
    } else {
        std::path::PathBuf::from("/tmp/motif-tsnet")
    }
}
