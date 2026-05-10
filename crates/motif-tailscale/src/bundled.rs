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
    /// LocalAPI loopback endpoint (`addr` + basic-auth `credential`) cached
    /// during `up()`. `loopback()` itself requires `&mut self` on the
    /// underlying Tailscale, so we call it once and remember the result for
    /// later `list_peers()` use against `&self`.
    loopback: Option<libtailscale::Loopback>,
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
        Ok(Self { inner: Some(t), loopback: None, _log_task: log_task })
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
        let lb = tokio::task::block_in_place(|| -> Result<libtailscale::Loopback, TsError> {
            t.up().map_err(TsError::Native)?;
            t.loopback().map_err(TsError::Native)
        })?;
        self.loopback = Some(lb);
        Ok(())
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

    /// Enumerate peers visible on the current tailnet by hitting tsnet's
    /// LocalAPI (running on the loopback address libtailscale opened during
    /// `up()`). Returns one `TsPeer` per node — including `online: false`
    /// peers, since the caller may want to show offline nodes too.
    pub async fn list_peers(&self) -> Result<Vec<TsPeer>, TsError> {
        let lb = self.loopback.as_ref()
            .ok_or_else(|| TsError::Native("up() must be called before list_peers".into()))?;
        eprintln!("[list_peers] calling fetch_localapi");
        let raw = fetch_localapi(&lb.address, &lb.credential, "/localapi/v0/status").await?;
        eprintln!("[list_peers] fetch ok body_len={}", raw.len());
        // Dump body for offline inspection.
        let _ = std::fs::write("/tmp/motif-localapi-body.json", &raw);
        eprintln!("[list_peers] body dumped to /tmp/motif-localapi-body.json");
        let status: StatusJson = match serde_json::from_slice(&raw) {
            Ok(s) => { eprintln!("[list_peers] json ok"); s }
            Err(e) => {
                eprintln!("[list_peers] json ERR: {e}");
                return Err(TsError::Native(format!("LocalAPI status JSON: {e}")));
            }
        };
        eprintln!("[list_peers] json parsed peer_count={}",
            status.peer.as_ref().map(|m| m.len()).unwrap_or(0));
        let mut peers = Vec::with_capacity(status.peer.as_ref().map(|m| m.len()).unwrap_or(0));
        if let Some(m) = status.peer {
            for (_pubkey, p) in m {
                let ip = p.tailscale_ips.into_iter().next().unwrap_or_default();
                peers.push(TsPeer {
                    hostname: p.host_name,
                    ip,
                    os:       p.os.unwrap_or_default(),
                    online:   p.online,
                });
            }
        }
        Ok(peers)
    }
}

/// Hand-rolled HTTP/1.0 GET against tsnet's LocalAPI. Inlined rather than
/// pulling in a full HTTP client crate — the request shape is fixed and
/// the body is small (single JSON document, capped at ~1MB).
///
/// LocalAPI auth requires BOTH the `Sec-Tailscale: localapi` header and
/// HTTP basic auth with empty username + the credential as password.
async fn fetch_localapi(addr: &str, credential: &str, path: &str) -> Result<Vec<u8>, TsError> {
    use base64::Engine;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    // The username `tsnet` is what libtailscale's own examples use; tsnet's
    // LocalAPI handler doesn't strictly require it but rejecting empty
    // username has been observed in some versions, so match the example to
    // be safe.
    let auth = base64::engine::general_purpose::STANDARD.encode(format!("tsnet:{credential}"));
    let req = format!(
        "GET {path} HTTP/1.1\r\n\
         Host: {addr}\r\n\
         Sec-Tailscale: localapi\r\n\
         Authorization: Basic {auth}\r\n\
         Connection: close\r\n\
         \r\n",
    );

    eprintln!("[fetch_localapi] connecting addr={addr}");
    let mut s = tokio::net::TcpStream::connect(addr).await?;
    eprintln!("[fetch_localapi] connected, writing {} bytes", req.len());
    s.write_all(req.as_bytes()).await?;
    eprintln!("[fetch_localapi] wrote, awaiting response");
    // Don't half-close the write side — tsnet's loopback server does
    // protocol detection between SOCKS5 and HTTP, and a write-FIN before
    // the server has identified the protocol can confuse it (observed:
    // server holds the request open without responding). With
    // `Connection: close` in the request the server itself will close
    // after writing the response, giving us a clean EOF on read.

    // Cap the response so a misbehaving server can't OOM us.
    const CAP: usize = 1 << 20;
    let mut buf = Vec::with_capacity(8 * 1024);
    let mut chunk = [0u8; 8 * 1024];
    loop {
        let n = s.read(&mut chunk).await?;
        eprintln!("[fetch_localapi] read n={n}");
        if n == 0 { break; }
        if buf.len() + n > CAP {
            return Err(TsError::Native("LocalAPI response exceeded 1 MiB cap".into()));
        }
        buf.extend_from_slice(&chunk[..n]);
    }
    eprintln!("[fetch_localapi] EOF, total={} bytes", buf.len());
    eprintln!("[fetch_localapi] head={:?}",
        std::str::from_utf8(&buf[..buf.len().min(200)]).unwrap_or("<non-utf8>"));

    // Quick status-line check — if it's not 200, surface the line as the
    // error so misconfig is obvious.
    let line_end = buf.iter().position(|&b| b == b'\r').unwrap_or(buf.len());
    let status_line = std::str::from_utf8(&buf[..line_end])
        .map_err(|_| TsError::Native("LocalAPI status line not utf-8".into()))?;
    eprintln!("[fetch_localapi] status_line={status_line:?}");
    if !status_line.contains(" 200 ") {
        return Err(TsError::Native(format!("LocalAPI: {status_line}")));
    }

    let body_start = buf.windows(4).position(|w| w == b"\r\n\r\n")
        .map(|i| i + 4)
        .ok_or_else(|| TsError::Native("LocalAPI: no header/body separator".into()))?;
    let headers = &buf[..body_start];
    let body    = &buf[body_start..];

    // tsnet's net/http defaults to chunked transfer encoding for
    // unknown-length responses; decode if so. Header match is
    // case-insensitive per RFC 7230.
    let chunked = headers
        .windows(b"transfer-encoding".len())
        .any(|w| w.eq_ignore_ascii_case(b"transfer-encoding"))
        && headers
            .windows(b"chunked".len())
            .any(|w| w.eq_ignore_ascii_case(b"chunked"));

    let body = if chunked { decode_chunked(body)? } else { body.to_vec() };
    eprintln!("[fetch_localapi] body_start={body_start} chunked={chunked} body_len={}", body.len());
    Ok(body)
}

/// Decode HTTP/1.1 Transfer-Encoding: chunked. Format: each chunk is
/// `<size in hex>\r\n<data>\r\n`, terminated by a chunk of size 0
/// followed by an optional trailer + final `\r\n`.
fn decode_chunked(mut input: &[u8]) -> Result<Vec<u8>, TsError> {
    let mut out = Vec::with_capacity(input.len());
    loop {
        // Find the size line terminator.
        let crlf = input.windows(2).position(|w| w == b"\r\n")
            .ok_or_else(|| TsError::Native("chunked: missing size CRLF".into()))?;
        let size_str = std::str::from_utf8(&input[..crlf])
            .map_err(|_| TsError::Native("chunked: non-utf8 size line".into()))?
            .split(';').next().unwrap_or("").trim();    // strip chunk-extensions if any
        let size = usize::from_str_radix(size_str, 16)
            .map_err(|e| TsError::Native(format!("chunked: bad size {size_str:?}: {e}")))?;
        input = &input[crlf + 2..];
        if size == 0 { break; }
        if input.len() < size + 2 {
            return Err(TsError::Native("chunked: short chunk data".into()));
        }
        out.extend_from_slice(&input[..size]);
        // Expect trailing CRLF after the chunk data.
        if &input[size..size + 2] != b"\r\n" {
            return Err(TsError::Native("chunked: missing trailing CRLF".into()));
        }
        input = &input[size + 2..];
    }
    Ok(out)
}

#[derive(serde::Deserialize)]
struct StatusJson {
    /// `null` on a freshly-started node that hasn't received its first
    /// netmap yet. Map keys are peer pubkeys.
    #[serde(rename = "Peer")]
    peer: Option<std::collections::HashMap<String, PeerJson>>,
}

#[derive(serde::Deserialize)]
struct PeerJson {
    #[serde(rename = "HostName")]
    host_name: String,
    #[serde(rename = "TailscaleIPs", default)]
    tailscale_ips: Vec<String>,
    #[serde(rename = "Online", default)]
    online: bool,
    #[serde(rename = "OS")]
    os: Option<String>,
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
            // https://login.tailscale.com/a/<token>" line. Match the
            // `/a/` path specifically so generic mentions of
            // controlplane.tailscale.com / login.tailscale.com (e.g.
            // network errors during shutdown) don't get promoted to WARN.
            if line.contains("login.tailscale.com/a/") {
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
