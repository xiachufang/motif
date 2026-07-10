//! Server-side listener. Implements `axum::serve::Listener` so it drops
//! straight into `axum::serve(listener, app)`. With both backends
//! configured, accepts are fanned in concurrently via `tokio::select!`.

use std::future::Future;
use std::io;
use std::net::SocketAddr;
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

use crate::config::{ListenConfig, RzvListenConfig};
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
    /// TLS config for the `tcp` backend, when it should terminate TLS
    /// (see [`ListenConfig::tcp_tls`]). `None` ⇒ plaintext tcp.
    tcp_tls: Option<std::sync::Arc<rustls::ServerConfig>>,
    #[cfg(feature = "tailscale")]
    ts: Option<TsBackend>,
    /// Rendezvous backend: a pool of `accept` waiters parked at the relay,
    /// funnelled into `rx` exactly like the tailscale pump. Always compiled
    /// (pure tokio, no feature gate).
    rzv: Option<RzvBackend>,
}

/// Rendezvous-relay accept backend. See `docs/rzv-protocol.md`. Each pump task
/// keeps one `accept` connection parked at the relay; when the relay pairs it
/// with a client, the now-transparent stream is pushed into `rx` and the pump
/// loops to park a fresh one.
struct RzvBackend {
    rx: tokio::sync::mpsc::Receiver<io::Result<(Stream, SocketAddr)>>,
    /// Relay address, for `bound_addrs()`.
    url: String,
    /// Held to keep the pump tasks alive for the listener's lifetime.
    _pumps: Vec<tokio::task::JoinHandle<()>>,
}

// rzv wire constants — keep in lockstep with `motif-rendezvous` and
// `docs/rzv-protocol.md`.
const RZV_MAGIC: [u8; 4] = *b"MRZV";
const RZV_VERSION: u8 = 1;
const RZV_ROLE_ACCEPT: u8 = 0;
const RZV_CTRL_PING: u8 = 0x01;
const RZV_CTRL_PONG: u8 = 0x02;
const RZV_CTRL_PAIRED: u8 = 0x10;

/// The relay sends a PING immediately after parking and every 15 seconds by
/// default.  If none arrive for three normal keepalive periods, the socket is
/// probably half-open (common after sleep or a network-interface change).
/// Bound the wait here so the pump can drop it and enter its reconnect loop
/// even when the kernel never reports EOF/reset on the old TCP path.
const RZV_PING_IDLE_TIMEOUT: Duration = Duration::from_secs(45);

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

        let rzv = cfg.rendezvous.as_ref().map(bind_rzv);

        Ok(Self {
            tcp,
            tcp_tls: cfg.tcp_tls.clone(),
            #[cfg(feature = "tailscale")]
            ts,
            rzv,
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
        if let Some(b) = &self.rzv {
            out.push(format!("rzv://{}", b.url));
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

/// Start the rendezvous backend: a pool of pump tasks, each holding one parked
/// `accept` waiter at the relay and re-parking after every pairing. Mirrors the
/// tailscale pump's mpsc fan-in.
fn bind_rzv(c: &RzvListenConfig) -> RzvBackend {
    // Bounded buffer applies backpressure: if axum isn't pulling accepted
    // streams, the pumps stop re-parking rather than piling up.
    let (tx, rx) = tokio::sync::mpsc::channel::<io::Result<(Stream, SocketAddr)>>(8);
    let pool = c.pool.max(1);
    let mut pumps = Vec::with_capacity(pool);
    for _ in 0..pool {
        let tx = tx.clone();
        let url = c.url.clone();
        let token = c.token;
        let tls = c.tls.clone();
        pumps.push(tokio::spawn(async move {
            // Backoff only grows on repeated failures; reset after a success.
            let mut backoff = Duration::from_millis(250);
            loop {
                match park_accept(&url, &token, tls.clone()).await {
                    Ok(stream) => {
                        backoff = Duration::from_millis(250);
                        let addr = SocketAddr::from(([0, 0, 0, 0], 0));
                        tracing::info!(relay = %url, transport = "rzv", "motif-net: accept");
                        if tx.send(Ok((stream, addr))).await.is_err() {
                            tracing::debug!("rzv pump: receiver dropped, exiting");
                            return;
                        }
                        // Loop immediately to park a fresh waiter.
                    }
                    Err(e) => {
                        tracing::warn!(relay = %url, error = %e, "rzv pump: park failed; retrying");
                        tokio::time::sleep(backoff).await;
                        backoff = (backoff * 2).min(Duration::from_secs(15));
                    }
                }
            }
        }));
    }
    RzvBackend {
        rx,
        url: c.url.clone(),
        _pumps: pumps,
    }
}

/// Dial the relay, park as an `accept` waiter, and block until the relay pairs
/// us (`PAIRED`). Answers `PING` keepalives with `PONG` while parked. When
/// `tls` is set, terminates end-to-end TLS over the now-transparent pipe before
/// returning (the relay never sees plaintext); otherwise returns the plain
/// stream. Either way the result is ready for axum to serve over.
async fn park_accept(
    url: &str,
    token: &[u8; 32],
    tls: Option<std::sync::Arc<rustls::ServerConfig>>,
) -> io::Result<Stream> {
    park_accept_with_idle_timeout(url, token, tls, RZV_PING_IDLE_TIMEOUT).await
}

async fn park_accept_with_idle_timeout(
    url: &str,
    token: &[u8; 32],
    tls: Option<std::sync::Arc<rustls::ServerConfig>>,
    ping_idle_timeout: Duration,
) -> io::Result<Stream> {
    let mut s = TcpStream::connect(url).await?;

    let mut hello = Vec::with_capacity(38);
    hello.extend_from_slice(&RZV_MAGIC);
    hello.push(RZV_VERSION);
    hello.push(RZV_ROLE_ACCEPT);
    hello.extend_from_slice(token);
    s.write_all(&hello).await?;
    s.flush().await?;

    // Read one control byte at a time until PAIRED so we never consume the
    // client's first application bytes (which only arrive after PAIRED).
    loop {
        let mut b = [0u8; 1];
        tokio::time::timeout(ping_idle_timeout, s.read_exact(&mut b))
            .await
            .map_err(|_| {
                io::Error::new(
                    io::ErrorKind::TimedOut,
                    format!("rzv: no relay control frame for {ping_idle_timeout:?} while parked"),
                )
            })??;
        match b[0] {
            RZV_CTRL_PAIRED => break,
            RZV_CTRL_PING => {
                s.write_all(&[RZV_CTRL_PONG]).await?;
                s.flush().await?;
            }
            other => {
                // Unexpected pre-pairing byte: treat as a protocol error.
                return Err(io::Error::other(format!(
                    "rzv: unexpected control byte {other:#04x} before PAIRED"
                )));
            }
        }
    }

    match tls {
        Some(cfg) => {
            let acceptor = tokio_rustls::TlsAcceptor::from(cfg);
            let tls_stream = acceptor.accept(s).await?;
            Ok(Stream::from_tls(tls_stream))
        }
        None => Ok(Stream::from_tcp(s)),
    }
}

async fn accept_rzv(o: Option<&mut RzvBackend>) -> io::Result<(Stream, SocketAddr)> {
    match o {
        Some(b) => match b.rx.recv().await {
            Some(res) => res,
            None => {
                // All pumps exited (receiver can't outlive senders unless they
                // all dropped). Wedge instead of spinning the outer loop.
                std::future::pending().await
            }
        },
        None => std::future::pending().await,
    }
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
                    let Self {
                        tcp,
                        tcp_tls,
                        ts,
                        rzv,
                    } = self;
                    tokio::select! {
                        biased;
                        r = accept_tcp(tcp.as_ref(), tcp_tls.as_ref()) => r,
                        r = accept_ts(ts.as_mut())   => r,
                        r = accept_rzv(rzv.as_mut())  => r,
                    }
                };
                #[cfg(not(feature = "tailscale"))]
                let res: io::Result<(Stream, SocketAddr)> = {
                    let Self { tcp, tcp_tls, rzv } = self;
                    tokio::select! {
                        biased;
                        r = accept_tcp(tcp.as_ref(), tcp_tls.as_ref()) => r,
                        r = accept_rzv(rzv.as_mut())  => r,
                    }
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
        if self.rzv.is_some() {
            // Rendezvous streams arrive over outbound relay connections; there
            // is no local bind addr. Synthesize one so axum can log something.
            return Ok(SocketAddr::from(([0, 0, 0, 0], 0)));
        }
        Err(io::Error::other("Listener has no backends"))
    }
}

async fn accept_tcp(
    o: Option<&TcpListener>,
    tls: Option<&std::sync::Arc<rustls::ServerConfig>>,
) -> io::Result<(Stream, SocketAddr)> {
    match o {
        Some(t) => {
            let (s, a) = t.accept().await?;
            match tls {
                Some(cfg) => {
                    // Terminate TLS with the self-signed identity; the client
                    // pins the cert. Same path rzv uses (see `park_accept`).
                    let acceptor = tokio_rustls::TlsAcceptor::from(cfg.clone());
                    let tls_stream = acceptor.accept(s).await?;
                    tracing::info!(peer = %a, transport = "tcp+tls", "motif-net: accept");
                    Ok((Stream::from_tls(tls_stream), a))
                }
                None => {
                    tracing::info!(peer = %a, transport = "tcp", "motif-net: accept");
                    Ok((Stream::from_tcp(s), a))
                }
            }
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

    #[tokio::test]
    async fn parked_rzv_connection_times_out_when_relay_goes_silent() {
        let relay = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let relay_addr = relay.local_addr().unwrap();
        let relay_task = tokio::spawn(async move {
            let (mut stream, _) = relay.accept().await.unwrap();
            let mut hello = [0u8; 38];
            stream.read_exact(&mut hello).await.unwrap();
            assert_eq!(&hello[..4], &RZV_MAGIC);

            // Keep the TCP socket open but send no PING. The motifd side must
            // still detect this as dead instead of waiting on read_exact forever.
            let mut byte = [0u8; 1];
            assert_eq!(stream.read(&mut byte).await.unwrap(), 0);
        });

        let result = park_accept_with_idle_timeout(
            &relay_addr.to_string(),
            &[7u8; 32],
            None,
            Duration::from_millis(50),
        )
        .await;
        let err = match result {
            Ok(_) => panic!("silent relay should not leave a parked stream alive"),
            Err(err) => err,
        };
        assert_eq!(err.kind(), io::ErrorKind::TimedOut);
        relay_task.await.unwrap();
    }
}
