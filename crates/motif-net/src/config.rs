//! Configuration types for [`Listener::bind`](super::Listener::bind) and
//! [`dial`](super::dial).

use std::net::SocketAddr;
use std::path::PathBuf;
#[cfg(feature = "tailscale")]
use std::sync::Arc;

/// Where the server should accept connections. At least one of `tcp` /
/// `tailscale` / `rendezvous` must be `Some` — `Listener::bind` rejects the
/// empty case.
#[derive(Debug, Clone, Default)]
pub struct ListenConfig {
    pub tcp: Option<SocketAddr>,
    pub tailscale: Option<TailscaleListenConfig>,
    pub rendezvous: Option<RzvListenConfig>,
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
    /// Relay address (`host:port`) to dial. Plaintext today — front the relay
    /// with a TLS-terminating proxy.
    pub url: String,
    /// The 32-byte rendezvous token (P1: the raw pairing secret).
    pub token: [u8; 32],
    /// How many idle `accept` waiters to keep parked. ≥1; defaults to 2 via
    /// [`RzvListenConfig::new`].
    pub pool: usize,
}

impl RzvListenConfig {
    pub fn new(url: impl Into<String>, token: [u8; 32]) -> Self {
        Self {
            url: url.into(),
            token,
            pool: 2,
        }
    }
}

// Redact the token so a Debug-logged ListenConfig doesn't leak the capability.
impl std::fmt::Debug for RzvListenConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("RzvListenConfig")
            .field("url", &self.url)
            .field("token", &"<redacted>")
            .field("pool", &self.pool)
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
