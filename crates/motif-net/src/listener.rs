//! Server-side listener. Implements `axum::serve::Listener` so it drops
//! straight into `axum::serve(listener, app)`. With both backends
//! configured, accepts are fanned in concurrently via `tokio::select!`.

use std::future::Future;
use std::io;
use std::net::SocketAddr;
use std::time::Duration;

use tokio::net::TcpListener;

use crate::config::ListenConfig;
use crate::stream::Stream;

#[cfg(feature = "tailscale")]
use crate::config::TailscaleListenConfig;
#[cfg(feature = "tailscale")]
use motif_tailscale::{TsOptions, TsServer};
#[cfg(feature = "tailscale")]
use std::net::{IpAddr, Ipv4Addr};
#[cfg(feature = "tailscale")]
use std::sync::Arc;

pub struct Listener {
    tcp: Option<TcpListener>,
    #[cfg(feature = "tailscale")]
    ts: Option<TsBackend>,
}

#[cfg(feature = "tailscale")]
struct TsBackend {
    /// Held to keep the tsnet node alive for the lifetime of the listener.
    /// The dialer side reuses this same node by cloning the `Arc` if it ever
    /// needs to dial out from the server (currently it doesn't, but the
    /// option exists).
    _server: Arc<TsServer>,
    /// Connections accepted by the dedicated pump task. We pull from this
    /// channel inside `tokio::select!` so axum's accept loop can race the
    /// tsnet backend against the TCP backend without leaking ghost
    /// recvmsg waiters — see the field docs on `_pump` for the bug
    /// motivation.
    rx: tokio::sync::mpsc::Receiver<io::Result<(Stream, SocketAddr)>>,
    /// Cached for `local_addr()` — tsnet has no real socket addr, so we
    /// synthesize `0.0.0.0:<port>` as a stand-in.
    port: u16,
    /// Background task that owns the underlying `TsListener` and pumps
    /// every accept into `rx`. We can't poll `TsListener::accept()`
    /// directly from `tokio::select!` because that future internally
    /// `spawn_blocking`s a `recvmsg` on the libtailscale socketpair —
    /// when the select branch is cancelled (TCP races and wins) the
    /// blocking thread keeps running, and the next select-iteration
    /// spawns *another* one. The kernel can hand the next inbound
    /// connection to any waiter, so abandoned threads accumulate and
    /// silently consume real tsnet connections, leaving axum thinking
    /// nothing arrived. Funnelling accepts through a permanent task
    /// + mpsc means exactly one `recvmsg` is ever outstanding and the
    /// cancellation is on the cancel-safe `rx.recv()` side.
    _pump: tokio::task::JoinHandle<()>,
}

impl Listener {
    pub async fn bind(cfg: &ListenConfig) -> io::Result<Self> {
        cfg.validate().map_err(io::Error::other)?;

        let tcp = match cfg.tcp {
            Some(addr) => Some(
                TcpListener::bind(addr)
                    .await
                    .map_err(|e| io::Error::new(e.kind(), format!("bind {addr}: {e}")))?,
            ),
            None => None,
        };

        #[cfg(feature = "tailscale")]
        let ts = match cfg.tailscale.as_ref() {
            Some(c) => Some(bind_tailscale(c).await?),
            None => None,
        };

        Ok(Self {
            tcp,
            #[cfg(feature = "tailscale")]
            ts,
        })
    }

    /// Human-readable list of bound endpoints, for the startup log. Format
    /// is backend-prefixed (`tcp://...`, `tailscale://hostname:port`) since
    /// the tailscale "address" isn't a `SocketAddr`.
    pub fn bound_addrs(&self) -> Vec<String> {
        let mut out = Vec::new();
        if let Some(t) = &self.tcp {
            if let Ok(a) = t.local_addr() {
                out.push(format!("tcp://{a}"));
            }
        }
        #[cfg(feature = "tailscale")]
        if let Some(_b) = &self.ts {
            // We don't have the hostname back from libtailscale yet; the
            // bind() caller logs it. Future: surface it through TsServer.
            out.push(format!("tailscale://*:{}", _b.port));
        }
        out
    }

    /// The embedded tsnet node, if the tailscale backend is active. Lets an
    /// embedding host (e.g. the menu-bar app) read live tailscale status
    /// (`backend_status`, `list_peers`, `auth_url`) after `bind()` — the
    /// node otherwise stays buried in the listener and is moved into
    /// `axum::serve`. Cheap `Arc` clone; the node's lifetime is still owned
    /// by the listener.
    #[cfg(feature = "tailscale")]
    pub fn tailscale_server(&self) -> Option<Arc<TsServer>> {
        self.ts.as_ref().map(|b| Arc::clone(&b._server))
    }
}

#[cfg(feature = "tailscale")]
async fn bind_tailscale(c: &TailscaleListenConfig) -> io::Result<TsBackend> {
    let opts = TsOptions {
        hostname: c.hostname.clone(),
        state_dir: c.state_dir.clone(),
        authkey: c.authkey.clone(),
        control_url: c.control_url.clone(),
        ephemeral: c.ephemeral,
    };
    let mut server =
        TsServer::new(opts).map_err(|e| io::Error::other(format!("tailscale init: {e}")))?;
    server
        .up()
        .await
        .map_err(|e| io::Error::other(format!("tailscale up: {e}")))?;
    let server = Arc::new(server);
    let inner = server
        .listen(c.port)
        .await
        .map_err(|e| io::Error::other(format!("tailscale listen :{}: {e}", c.port)))?;
    // Periodic backend snapshot — surfaces BackendState transitions and
    // peer-list collapses (e.g. after a Mac sleep/wake). Task ties its
    // lifetime to the Arc via Weak::upgrade, so it self-terminates when
    // the listener drops `_server`.
    let _watcher = Arc::clone(&server).spawn_status_watcher();
    // Permanent accept pump — see `TsBackend::_pump` for the ghost-waiter
    // bug this works around. Bounded buffer pushes backpressure onto
    // libtailscale (i.e. tsnet's accept queue) instead of letting an
    // unbounded number of accepted-but-unread connections pile up here.
    let (tx, rx) = tokio::sync::mpsc::channel::<io::Result<(Stream, SocketAddr)>>(8);
    let pump = tokio::spawn(async move {
        let mut listener = inner;
        loop {
            let res = listener
                .accept()
                .await
                .map(|(s, a)| (Stream::from_tailscale(s), a))
                .map_err(|e| io::Error::other(format!("tailscale accept: {e}")));
            // tx.send only fails when the receiver has been dropped,
            // which means the parent `Listener` (and the whole motifd
            // process most likely) is shutting down. Bail out cleanly.
            if tx.send(res).await.is_err() {
                tracing::debug!("tailscale accept pump: receiver dropped, exiting");
                return;
            }
        }
    });
    Ok(TsBackend {
        _server: server,
        rx,
        port: c.port,
        _pump: pump,
    })
}

impl axum::serve::Listener for Listener {
    type Io = Stream;
    type Addr = SocketAddr;

    fn accept(&mut self) -> impl Future<Output = (Self::Io, Self::Addr)> + Send {
        async move {
            loop {
                // tokio::select! doesn't allow `#[cfg]` on arms, so the body
                // is split by feature. Both branches do the same retry-loop
                // back-off on accept errors.
                #[cfg(feature = "tailscale")]
                let res: io::Result<(Stream, SocketAddr)> = {
                    let Self { tcp, ts } = self;
                    tokio::select! {
                        biased;
                        r = accept_tcp(tcp.as_ref()) => r,
                        r = accept_ts(ts.as_mut())   => r,
                    }
                };
                #[cfg(not(feature = "tailscale"))]
                let res: io::Result<(Stream, SocketAddr)> = {
                    let Self { tcp } = self;
                    accept_tcp(tcp.as_ref()).await
                };

                match res {
                    Ok(pair) => return pair,
                    Err(e) => {
                        tracing::warn!(error = %e, "motif-net: accept failed; retrying");
                        // Same back-off shape as axum's TcpListener impl —
                        // gives the kernel a chance to free fds on EMFILE etc.
                        tokio::time::sleep(Duration::from_millis(50)).await;
                    }
                }
            }
        }
    }

    fn local_addr(&self) -> io::Result<Self::Addr> {
        if let Some(t) = &self.tcp {
            return t.local_addr();
        }
        #[cfg(feature = "tailscale")]
        if let Some(b) = &self.ts {
            // Tailscale has no real SocketAddr; placeholder so axum can log
            // something. The real human-readable name is in `bound_addrs()`.
            return Ok(SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), b.port));
        }
        Err(io::Error::other("Listener has no backends"))
    }
}

async fn accept_tcp(o: Option<&TcpListener>) -> io::Result<(Stream, SocketAddr)> {
    match o {
        Some(t) => {
            let (s, a) = t.accept().await?;
            tracing::info!(peer = %a, transport = "tcp", "motif-net: accept");
            Ok((Stream::from_tcp(s), a))
        }
        None => std::future::pending().await,
    }
}

#[cfg(feature = "tailscale")]
async fn accept_ts(o: Option<&mut TsBackend>) -> io::Result<(Stream, SocketAddr)> {
    match o {
        Some(b) => match b.rx.recv().await {
            Some(Ok((stream, addr))) => {
                tracing::info!(peer = %addr, transport = "tailscale", "motif-net: accept");
                Ok((stream, addr))
            }
            Some(Err(e)) => Err(e),
            None => {
                // Pump exited unexpectedly. Wedge here forever instead of
                // returning Err (which would make the outer loop spin):
                // a healthier motifd should restart the listener at this
                // point, but that's outside motif-net's responsibility.
                std::future::pending().await
            }
        },
        None => std::future::pending().await,
    }
}

/// Newtype around [`SocketAddr`] used as the connect-info payload so
/// handlers can pull the peer addr via `ConnectInfo<PeerAddr>`. We can't
/// `impl Connected<...> for SocketAddr` here — orphan rules reject it
/// since both `SocketAddr` and `IncomingStream` are foreign. Wrapping
/// in a local newtype side-steps that.
///
/// For TCP accepts the addr is the real socket peer; for tailscale
/// accepts the IP is the tsnet peer's tailnet IP and the port is `0`
/// (libtailscale doesn't surface ephemeral ports). Use `transport` from
/// the accept log if you need to disambiguate.
#[derive(Debug, Clone, Copy)]
pub struct PeerAddr(pub SocketAddr);

impl std::fmt::Display for PeerAddr {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.0.fmt(f)
    }
}

impl axum::extract::connect_info::Connected<axum::serve::IncomingStream<'_, Listener>>
    for PeerAddr
{
    fn connect_info(stream: axum::serve::IncomingStream<'_, Listener>) -> Self {
        PeerAddr(*stream.remote_addr())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_config_rejected() {
        let cfg = ListenConfig::default();
        assert!(cfg.validate().is_err());
    }

    #[tokio::test]
    async fn bind_tcp_only() {
        let cfg = ListenConfig {
            tcp: Some("127.0.0.1:0".parse().unwrap()),
            ..Default::default()
        };
        let l = Listener::bind(&cfg).await.unwrap();
        let addrs = l.bound_addrs();
        assert_eq!(addrs.len(), 1);
        assert!(addrs[0].starts_with("tcp://127.0.0.1:"));
    }
}
