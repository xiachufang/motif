//! Embedded Tailscale support for motif clients.
//!
//! This crate is the Rust safe wrapper around `libtailscale` (Tailscale's
//! C-ABI exposure of `tsnet`). See `docs/tailscale.md` for design.
//!
//! ## Build modes
//!
//! - **`stub`** (default): no `libtailscale` is linked. All API calls return
//!   `TsError::Unimplemented` at runtime. This lets downstream crates depend
//!   on the API surface without requiring a Go toolchain. v1.5 skeleton ships
//!   in this mode — implementing the actual FFI is a follow-up task tracked
//!   in `docs/tailscale.md` §12.
//!
//! - **`bundled`**: invoke `go build -buildmode=c-archive` against the
//!   vendored `libtailscale` submodule, generate FFI bindings via `bindgen`,
//!   and link statically. **Not yet implemented**; planned next iteration.
//!
//! - **`prebuilt`**: pull a precompiled `libtailscale-<target>.tar.gz` from
//!   the upstream GitHub release matching `vendor/libtailscale/VERSION`,
//!   verify checksum, and link statically. **Not yet implemented**.

use std::net::SocketAddr;
use std::path::PathBuf;
use std::pin::Pin;
use std::task::{Context, Poll};

#[derive(Debug, thiserror::Error)]
pub enum TsError {
    #[error("Tailscale support is not implemented in this build (enable feature `bundled` or `prebuilt`)")]
    Unimplemented,
    #[error("libtailscale call failed: {0}")]
    Native(String),
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
}

#[derive(Debug, Clone)]
pub struct TsOptions {
    pub hostname:    String,
    pub state_dir:   PathBuf,
    pub authkey:     Option<String>,
    pub control_url: Option<String>,
    pub ephemeral:   bool,
}

#[derive(Debug, Clone)]
pub struct TsPeer {
    pub hostname: String,
    pub ip:       String,
    pub os:       String,
    pub online:   bool,
}

/// A logical Tailscale node embedded in the current process.
#[derive(Debug)]
pub struct TsServer {
    _opts: TsOptions,
    #[cfg(feature = "stub")]
    _marker: std::marker::PhantomData<()>,
}

impl TsServer {
    pub fn new(opts: TsOptions) -> Result<Self, TsError> {
        tracing::debug!(hostname = %opts.hostname, "TsServer::new (stub)");
        Ok(Self { _opts: opts, #[cfg(feature = "stub")] _marker: std::marker::PhantomData })
    }

    /// Bring the node up — block until joined to the tailnet.
    pub async fn up(&self) -> Result<(), TsError> {
        Err(TsError::Unimplemented)
    }

    pub async fn dial_tcp(&self, _addr: &str) -> Result<TsStream, TsError> {
        Err(TsError::Unimplemented)
    }

    /// Listen on the tailnet for incoming TCP on `port`. Returns a listener
    /// whose `accept()` yields a TsStream + remote-peer address.
    pub async fn listen(&self, _port: u16) -> Result<TsListener, TsError> {
        Err(TsError::Unimplemented)
    }

    pub async fn list_peers(&self) -> Result<Vec<TsPeer>, TsError> {
        Err(TsError::Unimplemented)
    }
}

/// An async TCP stream over the tailnet.
///
/// Real implementation will own a tokio::io::DuplexStream wired to an
/// libtailscale-backed file descriptor. The stub never constructs an instance —
/// the AsyncRead/AsyncWrite impls below would only fire if someone built a
/// `TsStream` outside the public API, which the public API forbids in stub
/// mode (every constructor returns `Unimplemented`). They exist solely so
/// downstream crates (motif-net) can wrap `TsStream` in a generic
/// `AsyncRead+AsyncWrite` enum without conditional compilation.
pub struct TsStream {
    #[cfg(feature = "stub")]
    _stub: std::marker::PhantomData<()>,
}

impl tokio::io::AsyncRead for TsStream {
    fn poll_read(
        self: Pin<&mut Self>,
        _cx: &mut Context<'_>,
        _buf: &mut tokio::io::ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        Poll::Ready(Err(std::io::Error::other("TsStream: stub build (no libtailscale linked)")))
    }
}

impl tokio::io::AsyncWrite for TsStream {
    fn poll_write(
        self: Pin<&mut Self>,
        _cx: &mut Context<'_>,
        _buf: &[u8],
    ) -> Poll<std::io::Result<usize>> {
        Poll::Ready(Err(std::io::Error::other("TsStream: stub build (no libtailscale linked)")))
    }
    fn poll_flush(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Poll::Ready(Ok(()))
    }
    fn poll_shutdown(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Poll::Ready(Ok(()))
    }
}

/// Accept side of an embedded-tailscale listener. Returned by
/// [`TsServer::listen`]. The stub never yields a successful accept.
pub struct TsListener {
    #[cfg(feature = "stub")]
    _stub: std::marker::PhantomData<()>,
}

impl TsListener {
    /// Accept the next inbound stream. Returns the stream plus a
    /// `SocketAddr` for the remote peer. (Tailscale uses 100.64.0.0/10 CGNAT
    /// addresses, so the addr is a normal `SocketAddr` and works as the
    /// `Addr` associated type for `axum::serve::Listener`.)
    pub async fn accept(&mut self) -> Result<(TsStream, SocketAddr), TsError> {
        Err(TsError::Unimplemented)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    #[test]
    fn options_construct() {
        let o = TsOptions {
            hostname: "test".into(),
            state_dir: PathBuf::from("/tmp/motif-tailscale-test"),
            authkey: None,
            control_url: None,
            ephemeral: true,
        };
        let _s = TsServer::new(o).unwrap();
    }
}
