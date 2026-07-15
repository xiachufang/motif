//! Type-erased duplex stream produced by a backend: a plain TCP socket, a
//! Tailscale tsnet socket, or a server-side TLS stream (the rzv end-to-end
//! path). Implements `tokio::io::AsyncRead` + `AsyncWrite` by forwarding to
//! whichever variant is active.

use std::io;
use std::pin::Pin;
use std::task::{Context, Poll};

use pin_project_lite::pin_project;
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::net::TcpStream;
use tokio_rustls::server::TlsStream;

/// Type-erased async stream used by the WSS rendezvous adapter after its
/// WebSocket framing has been converted back into a byte stream.
pub trait AsyncIo: AsyncRead + AsyncWrite + Send + Unpin {}
impl<T: AsyncRead + AsyncWrite + Send + Unpin> AsyncIo for T {}

// pin_project_lite doesn't allow `#[cfg]` on enum variants, so we define
// two enum shapes — same name, same public surface — gated by feature.
//
// The `Tls` variant is not `#[pin]`-projected and is boxed: `TlsStream<TcpStream>`
// is `Unpin` (its IO is a `TcpStream`), so we can re-pin a `&mut` to it on each
// poll, and the `Box` keeps the otherwise-large TLS state off every `Stream`.
#[cfg(not(feature = "tailscale"))]
pin_project! {
    /// A connected duplex stream produced by a backend.
    #[project = StreamProj]
    pub enum Stream {
        Tcp { #[pin] inner: TcpStream },
        Tls { inner: Box<TlsStream<TcpStream>> },
        Rendezvous { inner: Box<dyn AsyncIo> },
    }
}

#[cfg(feature = "tailscale")]
pin_project! {
    /// A connected duplex stream produced by a backend.
    #[project = StreamProj]
    pub enum Stream {
        Tcp { #[pin] inner: TcpStream },
        Tailscale { #[pin] inner: motif_tailscale::TsStream },
        Tls { inner: Box<TlsStream<TcpStream>> },
        Rendezvous { inner: Box<dyn AsyncIo> },
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
    /// Wrap a server-side TLS stream (the rzv end-to-end path).
    pub fn from_tls(s: TlsStream<TcpStream>) -> Self {
        Stream::Tls { inner: Box::new(s) }
    }
    pub fn from_rendezvous(s: impl AsyncIo + 'static) -> Self {
        Stream::Rendezvous { inner: Box::new(s) }
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
            StreamProj::Tls { inner } => Pin::new(&mut **inner).poll_read(cx, buf),
            StreamProj::Rendezvous { inner } => Pin::new(&mut **inner).poll_read(cx, buf),
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
            StreamProj::Tls { inner } => Pin::new(&mut **inner).poll_write(cx, buf),
            StreamProj::Rendezvous { inner } => Pin::new(&mut **inner).poll_write(cx, buf),
        }
    }
    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        match self.project() {
            StreamProj::Tcp { inner } => inner.poll_flush(cx),
            #[cfg(feature = "tailscale")]
            StreamProj::Tailscale { inner } => inner.poll_flush(cx),
            StreamProj::Tls { inner } => Pin::new(&mut **inner).poll_flush(cx),
            StreamProj::Rendezvous { inner } => Pin::new(&mut **inner).poll_flush(cx),
        }
    }
    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        match self.project() {
            StreamProj::Tcp { inner } => inner.poll_shutdown(cx),
            #[cfg(feature = "tailscale")]
            StreamProj::Tailscale { inner } => inner.poll_shutdown(cx),
            StreamProj::Tls { inner } => Pin::new(&mut **inner).poll_shutdown(cx),
            StreamProj::Rendezvous { inner } => Pin::new(&mut **inner).poll_shutdown(cx),
        }
    }
}
