//! Bundled implementation: backed by the `libtailscale` crate, which
//! statically links a Go-built `libtailscale.a`. Compiled when the
//! `bundled` feature is on.

use std::net::{IpAddr, SocketAddr};
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll};

use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};

use crate::{TsError, TsOptions, TsPeer};

/// Owns the live `libtailscale::Tailscale` plus the log-capture task.
pub struct TsServer {
    /// `Option` because `up()` (which is async) needs to call
    /// `libtailscale::Tailscale::up` (`&mut self`) on a bare value, but the
    /// rest of the API needs `&Self`. We `take` for the brief window of
    /// `up()`, then put back. Outside `up()`, this field is always `Some`.
    inner: Option<libtailscale::Tailscale>,
    /// Drains tsnet's stderr-equivalent log pipe, fishing out auth URLs.
    _log_task: tokio::task::JoinHandle<()>,
}

impl std::fmt::Debug for TsServer {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TsServer").finish_non_exhaustive()
    }
}

impl TsServer {
    pub fn new(opts: TsOptions) -> Result<Self, TsError> {
        let mut t = libtailscale::Tailscale::new();

        // Capture tsnet's logs through a pipe so we can spot the
        // `https://login.tailscale.com/...` URL on first-start auth and
        // surface it via tracing.
        let log_task = wire_log_pipe(&mut t)?;

        // Configuration must happen before `start`/`up`. libtailscale's
        // setters return Err on invalid input; we propagate as Native.
        t.set_dir(&opts.state_dir.to_string_lossy())
            .map_err(TsError::Native)?;
        if !opts.hostname.is_empty() {
            t.set_hostname(&opts.hostname).map_err(TsError::Native)?;
        }
        if let Some(k) = opts.authkey.as_deref() {
            t.set_authkey(k).map_err(TsError::Native)?;
        }
        if let Some(u) = opts.control_url.as_deref() {
            t.set_control_url(u).map_err(TsError::Native)?;
        }
        t.set_ephemeral(opts.ephemeral).map_err(TsError::Native)?;

        tracing::debug!(hostname = %opts.hostname, "TsServer::new (bundled)");
        Ok(Self { inner: Some(t), _log_task: log_task })
    }

    /// Bring the node up — block until joined to the tailnet (or until the
    /// user completes the device-auth flow on first start).
    ///
    /// Uses `block_in_place` rather than `spawn_blocking` so we don't have
    /// to dance the inner Tailscale across thread boundaries; this requires
    /// the multi-threaded tokio runtime (motifd uses `#[tokio::main]`
    /// which defaults to that).
    pub async fn up(&mut self) -> Result<(), TsError> {
        let t = self.inner.as_mut()
            .ok_or_else(|| TsError::Native("TsServer.inner missing (concurrent up()?)".into()))?;
        tokio::task::block_in_place(|| {
            t.up().map_err(TsError::Native)
        })
    }

    pub async fn dial_tcp(&self, addr: &str) -> Result<TsStream, TsError> {
        let t = self.inner.as_ref()
            .ok_or_else(|| TsError::Native("TsServer not initialized".into()))?;
        let std_stream = tokio::task::block_in_place(|| {
            t.dial("tcp", addr).map_err(TsError::Native)
        })?;
        let tokio_stream = into_tokio_stream(std_stream)?;
        Ok(TsStream { inner: tokio_stream })
    }

    pub async fn listen(self: &Arc<Self>, port: u16) -> Result<TsListener, TsError> {
        let t = self.inner.as_ref()
            .ok_or_else(|| TsError::Native("TsServer not initialized".into()))?;
        let listener: libtailscale::Listener<'_> = tokio::task::block_in_place(|| {
            t.listen("tcp", &format!(":{port}")).map_err(TsError::Native)
        })?;
        // SAFETY: the listener borrows from `*t`, which lives inside the
        // `Arc<TsServer>` we clone below. Drop order in `TsListener` (its
        // `inner` field is declared before `_server`) guarantees the
        // listener is destroyed before the Arc — and therefore before
        // Tailscale itself — so the borrow we're widening to `'static` is
        // never observed past the Tailscale's lifetime.
        let listener: libtailscale::Listener<'static> = unsafe { std::mem::transmute(listener) };
        Ok(TsListener {
            inner: Arc::new(listener),
            _server: Arc::clone(self),
        })
    }

    pub async fn list_peers(&self) -> Result<Vec<TsPeer>, TsError> {
        // libtailscale 0.2 doesn't expose a peer enumeration API; that
        // would need either the Loopback (LocalAPI) endpoint or a direct
        // libtailscale-sys call to TsnetGetIps + Status. Out of scope for
        // the initial bundled landing.
        Err(TsError::Unimplemented)
    }
}

/// `libtailscale::Tailscale` claims `Send + Sync` via a SAFETY comment
/// pointing at Go's global mutex. We re-assert here so `Arc<TsServer>`
/// works across tokio tasks.
//
// (No unsafe needed — Send/Sync are inferred for our wrapper as long as
// every field implements them, which `Option<Tailscale>` does.)

/// An async TCP stream over the tailnet. The fd handed back by libtailscale
/// is a real OS socket (one half of a socketpair, per `tailscale.h`), so
/// it works as a `tokio::net::TcpStream` once we set non-blocking.
pub struct TsStream {
    inner: tokio::net::TcpStream,
}

impl AsyncRead for TsStream {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.inner).poll_read(cx, buf)
    }
}

impl AsyncWrite for TsStream {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<std::io::Result<usize>> {
        Pin::new(&mut self.inner).poll_write(cx, buf)
    }
    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.inner).poll_flush(cx)
    }
    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.inner).poll_shutdown(cx)
    }
}

/// Listener over the tailnet. `inner` is the libtailscale-side handle
/// (with its lifetime erased — see `TsServer::listen` for the SAFETY note),
/// `_server` keeps the `TsServer` it borrows from alive.
///
/// Field order matters: `inner` is dropped first, then `_server`.
pub struct TsListener {
    inner:   Arc<libtailscale::Listener<'static>>,
    _server: Arc<TsServer>,
}

impl TsListener {
    pub async fn accept(&mut self) -> Result<(TsStream, SocketAddr), TsError> {
        // `accept_with_addr` blocks indefinitely until a peer connects — we
        // need `spawn_blocking` (not `block_in_place`) so the worker can
        // service other tasks. The `Arc<Listener>` clones cheaply; the
        // listener itself is shared.
        let inner = Arc::clone(&self.inner);
        let (std_stream, peer): (std::net::TcpStream, IpAddr) =
            tokio::task::spawn_blocking(move || inner.accept_with_addr())
                .await
                .map_err(|e| TsError::Native(format!("spawn_blocking: {e}")))?
                .map_err(TsError::Native)?;

        let tokio_stream = into_tokio_stream(std_stream)?;
        // Tailscale's accept_with_addr only gives us the peer's IP, not
        // the ephemeral port. Use 0 as a placeholder — axum's serve uses
        // this purely for logging.
        let addr = SocketAddr::new(peer, 0);
        Ok((TsStream { inner: tokio_stream }, addr))
    }
}

fn into_tokio_stream(s: std::net::TcpStream) -> Result<tokio::net::TcpStream, TsError> {
    s.set_nonblocking(true)
        .map_err(|e| TsError::Native(format!("set_nonblocking: {e}")))?;
    tokio::net::TcpStream::from_std(s)
        .map_err(|e| TsError::Native(format!("TcpStream::from_std: {e}")))
}

/// Open a pipe, hand the write end to libtailscale, spawn a task on the
/// read end. The task ends when the writer closes (i.e. when our wrapped
/// `Tailscale` is dropped, which closes its logfd).
#[cfg(unix)]
fn wire_log_pipe(t: &mut libtailscale::Tailscale) -> Result<tokio::task::JoinHandle<()>, TsError> {
    use std::os::unix::io::{FromRawFd, IntoRawFd, OwnedFd};

    let mut fds = [0i32; 2];
    // SAFETY: pipe(2) writes two fds into the array on success.
    let rc = unsafe { libc::pipe(fds.as_mut_ptr()) };
    if rc != 0 {
        return Err(TsError::Native(format!("pipe(2): {}", std::io::Error::last_os_error())));
    }
    // SAFETY: pipe(2) succeeded so both fds are valid and freshly owned.
    let read_fd:  OwnedFd = unsafe { OwnedFd::from_raw_fd(fds[0]) };
    let write_fd: OwnedFd = unsafe { OwnedFd::from_raw_fd(fds[1]) };

    // FD_CLOEXEC on both — motifd spawns PTY children, we don't want them
    // inheriting these.
    set_cloexec(&read_fd);
    set_cloexec(&write_fd);

    // Hand the write end to tsnet. libtailscale takes the int by value
    // (TsnetSetLogFD doesn't dup) — so we surrender ownership and let
    // libtailscale close it on shutdown.
    let raw_write = write_fd.into_raw_fd();
    t.set_logfd(raw_write).map_err(TsError::Native)?;

    let raw_read = read_fd.into_raw_fd();
    let handle = tokio::task::spawn_blocking(move || {
        use std::io::{BufRead, BufReader};
        // SAFETY: we own raw_read; this File takes over.
        let f = unsafe { std::fs::File::from_raw_fd(raw_read) };
        let reader = BufReader::new(f);
        for line in reader.lines() {
            let line = match line {
                Ok(l)  => l,
                Err(e) => {
                    tracing::debug!(error = %e, "tsnet log pipe read error");
                    break;
                }
            };
            // tsnet's first-start log includes a "To authenticate, visit:
            // https://login.tailscale.com/a/<id>" line. Match generously
            // on the URL prefix so format tweaks don't break us.
            if line.contains("https://login.tailscale.com/")
                || line.contains("https://controlplane.tailscale.com/")
            {
                tracing::warn!(target: "motif_tailscale", "Tailscale auth needed: {}", line);
            } else {
                tracing::debug!(target: "motif_tailscale::tsnet", "{}", line);
            }
        }
    });
    Ok(handle)
}

#[cfg(unix)]
fn set_cloexec(fd: &std::os::unix::io::OwnedFd) {
    use std::os::unix::io::AsRawFd;
    // Best-effort; failure here is harmless except for an inherited fd in
    // a child PTY, which we'd notice as a stuck process at shutdown.
    unsafe {
        let raw = fd.as_raw_fd();
        let cur = libc::fcntl(raw, libc::F_GETFD);
        if cur >= 0 {
            libc::fcntl(raw, libc::F_SETFD, cur | libc::FD_CLOEXEC);
        }
    }
}

#[cfg(not(unix))]
fn wire_log_pipe(_t: &mut libtailscale::Tailscale) -> Result<tokio::task::JoinHandle<()>, TsError> {
    Err(TsError::Native("log pipe capture is unix-only".into()))
}
