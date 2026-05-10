//! Configuration types for [`Listener::bind`](super::Listener::bind) and
//! [`dial`](super::dial).

use std::net::SocketAddr;
use std::path::PathBuf;
#[cfg(feature = "tailscale")]
use std::sync::Arc;

/// Where the server should accept connections. At least one of `tcp` /
/// `tailscale` must be `Some` — `Listener::bind` rejects the empty case.
#[derive(Debug, Clone, Default)]
pub struct ListenConfig {
    pub tcp:       Option<SocketAddr>,
    pub tailscale: Option<TailscaleListenConfig>,
}

/// Bring up an embedded tsnet node and listen on `port`.
#[derive(Debug, Clone)]
pub struct TailscaleListenConfig {
    pub hostname:    String,
    pub state_dir:   PathBuf,
    pub port:        u16,
    pub authkey:     Option<String>,
    pub control_url: Option<String>,
    pub ephemeral:   bool,
}

impl ListenConfig {
    pub fn validate(&self) -> Result<(), &'static str> {
        if self.tcp.is_none() && self.tailscale.is_none() {
            return Err("ListenConfig: at least one of `tcp` / `tailscale` must be set");
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
        addr:   String,
        server: Arc<motif_tailscale::TsServer>,
    },
}
