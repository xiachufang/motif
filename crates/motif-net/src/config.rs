//! Configuration types for [`Listener::bind`](super::Listener::bind) and
//! [`dial`](super::dial).

use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;

/// Where the server should accept connections. At least one of `tcp` /
/// `tailscale` / `rendezvous` must be `Some` — `Listener::bind` rejects the
/// empty case.
#[derive(Clone, Default)]
pub struct ListenConfig {
    pub tcp: Option<SocketAddr>,
    /// When set, the `tcp` backend terminates **TLS** with this server config
    /// (self-signed; the client pins the cert). Encrypts the direct `--listen`
    /// surface without an upstream proxy. `None` ⇒ plaintext `tcp` (loopback /
    /// trusted segment). Same identity motifd uses for rzv end-to-end TLS, so
    /// the pin matches whichever path a client takes.
    pub tcp_tls: Option<Arc<rustls::ServerConfig>>,
    pub tailscale: Option<TailscaleListenConfig>,
    pub rendezvous: Option<RzvListenConfig>,
}

// rustls::ServerConfig isn't Debug; render it as a presence flag.
impl std::fmt::Debug for ListenConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ListenConfig")
            .field("tcp", &self.tcp)
            .field("tcp_tls", &self.tcp_tls.is_some())
            .field("tailscale", &self.tailscale)
            .field("rendezvous", &self.rendezvous)
            .finish()
    }
}

/// Bring up an embedded tsnet node and listen on `port`.
#[derive(Debug, Clone)]
pub struct TailscaleListenConfig {
    pub hostname: String,
    pub state_dir: PathBuf,
    pub port: u16,
    pub authkey: Option<String>,
    pub control_url: Option<String>,
    pub ephemeral: bool,
}

/// Accept connections by parking `accept`-role waiters at a rendezvous relay.
/// motifd dials out to `url`, holds `pool` idle parked connections, and gets a
/// paired byte pipe back whenever a client connects with the same `token`.
/// See `docs/rzv-protocol.md`.
#[derive(Clone)]
pub struct RzvListenConfig {
    /// Relay address (`host:port`) or full `wss://` URL. Bare endpoints are
    /// expanded to `wss://<endpoint>/v2/accept`.
    pub url: String,
    /// The 32-byte rendezvous token (derived one-way from the pairing secret).
    pub token: [u8; 32],
    /// Owner JWT sent only in the WSS Upgrade request to `/v2/accept`.
    pub jwt: String,
    /// Public-root configuration for the outer WSS connection. Tests and
    /// private deployments may replace this with a config containing a custom
    /// CA; production defaults to the Web PKI roots.
    pub ws_tls: Arc<rustls::ClientConfig>,
    /// How many idle `accept` waiters to keep parked. ≥1; defaults to 2 via
    /// [`RzvListenConfig::new`].
    pub pool: usize,
    /// When set, motifd terminates **end-to-end TLS** over the relayed pipe
    /// using this server config (the relay stays a blind byte pipe; the client
    /// pins motifd's cert). `None` = plaintext over the relay.
    pub tls: Option<Arc<rustls::ServerConfig>>,
}

impl RzvListenConfig {
    pub fn new(url: impl Into<String>, token: [u8; 32], jwt: impl Into<String>) -> Self {
        let roots =
            rustls::RootCertStore::from_iter(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
        Self {
            url: url.into(),
            token,
            jwt: jwt.into(),
            ws_tls: Arc::new(
                rustls::ClientConfig::builder()
                    .with_root_certificates(roots)
                    .with_no_client_auth(),
            ),
            pool: 2,
            tls: None,
        }
    }
}

// Redact the token so a Debug-logged ListenConfig doesn't leak the capability.
impl std::fmt::Debug for RzvListenConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("RzvListenConfig")
            .field("url", &self.url)
            .field("token", &"<redacted>")
            .field("jwt", &"<redacted>")
            .field("pool", &self.pool)
            .field("tls", &self.tls.is_some())
            .finish()
    }
}

impl ListenConfig {
    pub fn validate(&self) -> Result<(), &'static str> {
        if self.tcp.is_none() && self.tailscale.is_none() && self.rendezvous.is_none() {
            return Err(
                "ListenConfig: at least one of `tcp` / `tailscale` / `rendezvous` must be set",
            );
        }
        Ok(())
    }
}

/// Where the client should dial. The `Tailscale` variant carries an
/// `Arc<TsServer>` so callers can keep a single tsnet node alive across
/// reconnects.
#[derive(Debug, Clone)]
pub enum DialTarget {
    /// `host:port` passed to `tokio::net::TcpStream::connect`. This is the
    /// underlying socket destination, not the user-facing `ws://` URL — URL
    /// parsing happens in the WebSocket-handshake layer.
    Tcp(String),
    #[cfg(feature = "tailscale")]
    Tailscale {
        addr: String,
        server: Arc<motif_tailscale::TsServer>,
    },
}
