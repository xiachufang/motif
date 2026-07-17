//! Stub implementation: every API call returns `TsError::Unimplemented`.
//! Compiled when the `bundled` feature is OFF, and on non-Unix platforms where
//! upstream libtailscale's C wrapper is unavailable. Lets downstream crates
//! compile against this surface without a Go/POSIX native dependency.

use std::net::SocketAddr;
use std::pin::Pin;
use std::task::{Context, Poll};

use crate::{TsError, TsOptions, TsPeer};

#[derive(Debug)]
pub struct TsServer {
    _opts: TsOptions,
}

impl TsServer {
    pub fn new(opts: TsOptions) -> Result<Self, TsError> {
        tracing::debug!(hostname = %opts.hostname, "TsServer::new (stub)");
        Ok(Self { _opts: opts })
    }

    pub async fn up(&mut self) -> Result<(), TsError> {
        Err(TsError::Unimplemented)
    }

    pub async fn dial_tcp(&self, _addr: &str) -> Result<TsStream, TsError> {
        Err(TsError::Unimplemented)
    }

    pub async fn listen(self: &std::sync::Arc<Self>, _port: u16) -> Result<TsListener, TsError> {
        Err(TsError::Unimplemented)
    }

    pub async fn list_peers(&self) -> Result<Vec<TsPeer>, TsError> {
        Err(TsError::Unimplemented)
    }

    pub async fn backend_status(&self) -> Result<TsBackendStatus, TsError> {
        Err(TsError::Unimplemented)
    }

    /// Always `None` in stub builds — no tsnet node to log in.
    pub fn auth_url(&self) -> Option<String> {
        None
    }

    /// No-op in stub builds — returns an immediately-completed task.
    pub fn spawn_status_watcher(self: std::sync::Arc<Self>) -> tokio::task::JoinHandle<()> {
        tokio::spawn(async {})
    }
}

#[derive(Debug, Clone, Default)]
pub struct TsBackendStatus {
    pub backend_state: String,
    pub health: Vec<String>,
    pub peer_total: usize,
    pub peer_online: usize,
    pub auth_url: Option<String>,
}

/// Stub stream — never constructed, but the AsyncRead/AsyncWrite impls
/// must compile so downstream `enum Stream { Tcp, Tailscale }` projections
/// type-check.
pub struct TsStream {
    _stub: std::marker::PhantomData<()>,
}

impl tokio::io::AsyncRead for TsStream {
    fn poll_read(
        self: Pin<&mut Self>,
        _cx: &mut Context<'_>,
        _buf: &mut tokio::io::ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        Poll::Ready(Err(std::io::Error::other(
            "TsStream: stub build (no libtailscale linked)",
        )))
    }
}

impl tokio::io::AsyncWrite for TsStream {
    fn poll_write(
        self: Pin<&mut Self>,
        _cx: &mut Context<'_>,
        _buf: &[u8],
    ) -> Poll<std::io::Result<usize>> {
        Poll::Ready(Err(std::io::Error::other(
            "TsStream: stub build (no libtailscale linked)",
        )))
    }
    fn poll_flush(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Poll::Ready(Ok(()))
    }
    fn poll_shutdown(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Poll::Ready(Ok(()))
    }
}

pub struct TsListener {
    _stub: std::marker::PhantomData<()>,
}

impl TsListener {
    pub async fn accept(&mut self) -> Result<(TsStream, SocketAddr), TsError> {
        Err(TsError::Unimplemented)
    }
}
