//! Connection transports. Direct WS is the default; SSH tunnel is opt-in via
//! `--via ssh://...`; `--via tailscale://hostname[:port]` (under the
//! `tailscale` feature) brings up an embedded tsnet client node and dials
//! through the tailnet.

pub mod ssh;

use std::any::Any;
use std::time::Duration;

use anyhow::{anyhow, Context};

use crate::coordinator::Coordinator;
use crate::http::{tcp_factory, StreamFactory};
use ssh::SshTunnel;

/// Resolved connection target. Owns any spawned tunnel resources for the
/// life of the connection. Hold the value in scope until `client` is no
/// longer needed — dropping `ConnectedV2` may tear down a tunnel or tsnet
/// node, which will fail any in-flight RPC.
pub struct ConnectedV2 {
    pub client: Coordinator,
    pub _keepalive: Vec<Box<dyn Any + Send + Sync>>,
}

/// Turn the user-supplied `--host` argument into a URL [`connect_v2`]
/// accepts. The auto-default points at the local loopback so clients
/// can come up with no flags at all when they're sharing a host with
/// motifd.
///
/// - `None`              → `ws://127.0.0.1:7777`
/// - already a full URL  → passed through (must include scheme)
/// - `host:port`         → `ws://host:port`
/// - bare `host`         → `ws://host:7777`
pub fn normalize_target(host: Option<&str>) -> String {
    match host {
        None => "ws://127.0.0.1:7777".to_string(),
        Some(h) if h.contains("://") => h.to_string(),
        Some(h) if h.contains(':') => format!("ws://{h}"),
        Some(h) => format!("ws://{h}:7777"),
    }
}

/// New-protocol connect: returns a [`Coordinator`] that fans RPC over
/// HTTP and PTY/events over independent WebSockets. URL accepts the
/// same `ws://` / `http://` shapes the old transport did — the scheme
/// is internally mapped to `http://` for the HTTP path.
pub async fn connect_v2(
    url: &str,
    token: &str,
    via: Option<&str>,
    remote_port: Option<u16>,
) -> anyhow::Result<ConnectedV2> {
    if let Some(via) = via {
        if let Some(rest) = via.strip_prefix("ssh://") {
            return connect_v2_ssh(rest, token, remote_port).await;
        }
        #[cfg(feature = "tailscale")]
        if let Some(rest) = via.strip_prefix("tailscale://") {
            return connect_v2_tailscale(rest, token).await;
        }
        if via != "direct" {
            anyhow::bail!(
                "unsupported --via scheme: {via} (expected ssh://…, tailscale://…, or direct)"
            );
        }
    }
    let (factory, authority) = factory_for_url(url)?;
    let client = Coordinator::new(factory, authority, token.to_string())?;
    Ok(ConnectedV2 {
        client,
        _keepalive: Vec::new(),
    })
}

fn factory_for_url(url: &str) -> anyhow::Result<(StreamFactory, String)> {
    let parsed = url::Url::parse(url).with_context(|| format!("invalid url: {url}"))?;
    if !matches!(parsed.scheme(), "http" | "https") {
        anyhow::bail!("unsupported URL scheme: {}", parsed.scheme());
    }
    let host = parsed
        .host_str()
        .ok_or_else(|| anyhow!("missing host in {url}"))?;
    let port = parsed.port().unwrap_or(match parsed.scheme() {
        "https" => 443,
        _ => 80,
    });
    let addr = format!("{host}:{port}");
    Ok((tcp_factory(addr.clone()), addr))
}

async fn connect_v2_ssh(
    target: &str,
    token: &str,
    remote_port: Option<u16>,
) -> anyhow::Result<ConnectedV2> {
    let port = remote_port.unwrap_or(7777);
    let tunnel = SshTunnel::open(target, port).await?;
    tokio::time::sleep(Duration::from_millis(50)).await;
    let local_addr = format!("127.0.0.1:{}", tunnel.local_port());
    let factory = tcp_factory(local_addr.clone());
    let client = Coordinator::new(factory, local_addr, token.to_string())?;
    Ok(ConnectedV2 {
        client,
        _keepalive: vec![Box::new(tunnel) as Box<dyn Any + Send + Sync>],
    })
}

#[cfg(feature = "tailscale")]
async fn connect_v2_tailscale(rest: &str, token: &str) -> anyhow::Result<ConnectedV2> {
    use motif_net::motif_tailscale::TsServer;
    use std::sync::Arc;

    let dial_addr = if rest.contains(':') {
        rest.to_string()
    } else {
        format!("{rest}:7777")
    };
    let mut server = TsServer::new(default_client_ts_options()).context("tsnet init")?;
    server.up().await.context("tsnet up")?;
    let server = Arc::new(server);

    // tsnet factory: each dial opens a fresh tsnet socket. Multiple
    // RPCs in flight => multiple parallel sockets, which is the whole
    // point of dropping the single-WS multiplexed transport.
    let dial_addr_for_factory = dial_addr.clone();
    let server_for_factory = server.clone();
    let factory: StreamFactory = std::sync::Arc::new(move || {
        let addr = dial_addr_for_factory.clone();
        let server = server_for_factory.clone();
        Box::pin(async move {
            let s = motif_net::dial(&motif_net::DialTarget::Tailscale {
                addr: addr.clone(),
                server: server.clone(),
            })
            .await
            .with_context(|| format!("tsnet dial {addr}"))?;
            Ok(Box::pin(s) as crate::http::HttpStream)
        })
    });

    let client = Coordinator::new(factory, dial_addr, token.to_string())?;
    Ok(ConnectedV2 {
        client,
        _keepalive: vec![Box::new(server) as Box<dyn Any + Send + Sync>],
    })
}

/// Build a `TsOptions` for a client-side tsnet node.
///
/// State dir defaults to `~/.cache/motif/tsnet`; hostname defaults to
/// `motif-client` (stable, so successive invocations reuse one tailnet
/// device entry rather than littering admin/machines with fresh
/// per-PID names).
///
/// `ephemeral: false` matches what iOS's TailscaleManager does. The
/// `ephemeral=true` path appears to interact badly with tsnet 1.94's
/// internal Loopback() — auth completes, state goes Running, then a
/// /serve-config POST inside Loopback() triggers an EditPrefs
/// `WantRunning=false LoggedOut=true` and the node tears itself down a
/// few ms after coming up. With `ephemeral=false` the node persists,
/// state_dir caches the identity, and re-runs are zero-interaction.
///
/// Env overrides: `MOTIF_TS_{STATE_DIR,HOSTNAME,AUTHKEY,CONTROL_URL,EPHEMERAL}`.
#[cfg(feature = "tailscale")]
pub fn default_client_ts_options() -> motif_net::motif_tailscale::TsOptions {
    motif_net::motif_tailscale::TsOptions {
        hostname: std::env::var("MOTIF_TS_HOSTNAME").unwrap_or_else(|_| "motif-client".to_string()),
        state_dir: std::env::var_os("MOTIF_TS_STATE_DIR")
            .map(std::path::PathBuf::from)
            .unwrap_or_else(default_state_dir),
        authkey: std::env::var("MOTIF_TS_AUTHKEY").ok(),
        control_url: std::env::var("MOTIF_TS_CONTROL_URL").ok(),
        ephemeral: std::env::var("MOTIF_TS_EPHEMERAL")
            .ok()
            .and_then(|v| match v.as_str() {
                "1" | "true" | "yes" => Some(true),
                _ => Some(false),
            })
            .unwrap_or(false),
    }
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
