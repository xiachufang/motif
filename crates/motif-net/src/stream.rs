//! Type-erased duplex stream that can be either a TCP socket or a Tailscale
//! tsnet socket. Implements `tokio::io::AsyncRead` + `AsyncWrite` by
//! forwarding to whichever variant is active.

use std::io;
use std::pin::Pin;
use std::task::{Context, Poll};

use pin_project_lite::pin_project;
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::net::TcpStream;

// pin_project_lite doesn't allow `#[cfg]` on enum variants, so we define
// two enum shapes — same name, same public surface — gated by feature.
#[cfg(not(feature = "tailscale"))]
pin_project! {
    /// A connected duplex stream produced by either backend.
    #[project = StreamProj]
    pub enum Stream {
        Tcp { #[pin] inner: TcpStream },
    }
}

#[cfg(feature = "tailscale")]
pin_project! {
    /// A connected duplex stream produced by either backend.
    #[project = StreamProj]
    pub enum Stream {
        Tcp { #[pin] inner: TcpStream },
        Tailscale { #[pin] inner: motif_tailscale::TsStream },
    }
}

impl Stream {
    pub fn from_tcp(s: TcpStream) -> Self {
        Stream::Tcp { inner: s }
    }
    #[cfg(feature = "tailscale")]
    pub fn from_tailscale(s: motif_tailscale::TsStream) -> Self {
        Stream::Tailscale { inner: s }
    }
}

impl AsyncRead for Stream {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        match self.project() {
            StreamProj::Tcp { inner } => inner.poll_read(cx, buf),
            #[cfg(feature = "tailscale")]
            StreamProj::Tailscale { inner } => inner.poll_read(cx, buf),
        }
    }
}

impl AsyncWrite for Stream {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        match self.project() {
            StreamProj::Tcp { inner } => inner.poll_write(cx, buf),
            #[cfg(feature = "tailscale")]
            StreamProj::Tailscale { inner } => inner.poll_write(cx, buf),
        }
    }
    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        match self.project() {
            StreamProj::Tcp { inner } => inner.poll_flush(cx),
            #[cfg(feature = "tailscale")]
            StreamProj::Tailscale { inner } => inner.poll_flush(cx),
        }
    }
    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        match self.project() {
            StreamProj::Tcp { inner } => inner.poll_shutdown(cx),
            #[cfg(feature = "tailscale")]
            StreamProj::Tailscale { inner } => inner.poll_shutdown(cx),
        }
    }
}
