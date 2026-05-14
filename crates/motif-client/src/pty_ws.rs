//! `WS /pty/<pty_id>?session=<sid>&since=<bytes>&primary=<0|1>`
//! client. One per open PTY tab.
//!
//! Bidirectional binary stream — no envelope. Inbound frames from the
//! server are raw PTY output bytes; outbound frames are stdin bytes.
//! On close-with-code 4011 / 4012 the caller is expected to clear its
//! local terminal buffer and reconnect without `since=`.

use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::{anyhow, Context};
use bytes::Bytes;
use futures_util::sink::Sink;
use futures_util::stream::Stream as FuturesStream;
use futures_util::{SinkExt, StreamExt};
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::TcpStream;
use tokio::sync::mpsc;
use tokio_tungstenite::{
    client_async, tungstenite::client::IntoClientRequest, tungstenite::http::HeaderValue,
    tungstenite::Message,
};

const PING_INTERVAL: Duration = Duration::from_secs(20);
const IDLE_TIMEOUT: Duration = Duration::from_secs(45);
const HEARTBEAT_TICK: Duration = Duration::from_secs(10);

type WsErr = tokio_tungstenite::tungstenite::Error;
type WsSink = Pin<Box<dyn Sink<Message, Error = WsErr> + Send>>;
type WsRx = Pin<Box<dyn FuturesStream<Item = Result<Message, WsErr>> + Send>>;

/// Server-side `/pty/<id>` close codes — see
/// `crates/motif-server/src/pty_ws.rs`. Caller branches on these.
pub const CLOSE_HISTORY_TRUNCATED: u16 = 4011;
pub const CLOSE_STALE_CURSOR: u16 = 4012;

#[derive(Debug, Clone, Copy)]
pub enum CloseReason {
    /// Peer (server) closed gracefully — typically PTY exited or
    /// session detached.
    Normal,
    /// 4011 — ring rolled past our `since`. Caller should clear the
    /// local terminal buffer and reconnect without `since=`.
    HistoryTruncated,
    /// 4012 — `since` was ahead of server total (server restart).
    /// Same recovery as 4011.
    StaleCursor,
    /// Read error, peer dropped without sending a Close frame.
    Transport,
}

pub struct PtyClient {
    /// Raw output bytes from the master.
    pub outputs: mpsc::UnboundedReceiver<Bytes>,
    /// Set when the connection closes; tells the caller why.
    closed: Arc<Mutex<Option<CloseReason>>>,
    /// stdin bytes to push to the master. Caller can clone the channel
    /// for forwarding from a terminal emulator.
    pub stdin: mpsc::UnboundedSender<Bytes>,
    reader: tokio::task::JoinHandle<()>,
    writer: tokio::task::JoinHandle<()>,
    heartbeat: tokio::task::JoinHandle<()>,
    bytes_seen: Arc<std::sync::atomic::AtomicU64>,
}

impl Drop for PtyClient {
    fn drop(&mut self) {
        self.reader.abort();
        self.writer.abort();
        self.heartbeat.abort();
    }
}

impl PtyClient {
    /// Total bytes received since the connection opened. Add to the
    /// `?since=` you passed to compute the cursor for a subsequent
    /// reconnect.
    pub fn bytes_received(&self) -> u64 {
        self.bytes_seen.load(std::sync::atomic::Ordering::Relaxed)
    }

    pub fn close_reason(&self) -> Option<CloseReason> {
        *self.closed.lock().unwrap()
    }

    pub async fn connect_tcp(
        addr: &str,
        token: &str,
        session_id: &str,
        pty_id: &str,
        since: u64,
        primary: bool,
    ) -> anyhow::Result<Self> {
        let stream = TcpStream::connect(addr)
            .await
            .with_context(|| format!("dial {}", addr))?;
        Self::connect_with_stream(addr, token, session_id, pty_id, since, primary, stream).await
    }

    pub async fn connect_with_stream<S>(
        authority: &str,
        token: &str,
        session_id: &str,
        pty_id: &str,
        since: u64,
        primary: bool,
        stream: S,
    ) -> anyhow::Result<Self>
    where
        S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
    {
        let url = format!(
            "ws://{authority}/pty/{pty_id}?session={session_id}&since={since}&primary={}",
            if primary { 1 } else { 0 },
        );
        let mut req = url
            .as_str()
            .into_client_request()
            .with_context(|| format!("invalid url: {url}"))?;
        req.headers_mut().insert(
            "Authorization",
            HeaderValue::from_str(&format!("Bearer {token}"))
                .map_err(|e| anyhow!("invalid token: {e}"))?,
        );
        let (ws, _resp) = client_async(req, stream)
            .await
            .with_context(|| format!("/pty/{pty_id} ws handshake"))?;
        let (tx, rx) = ws.split();

        let (out_tx, out_rx) = mpsc::unbounded_channel::<Bytes>();
        let (stdin_tx, stdin_rx) = mpsc::unbounded_channel::<Bytes>();
        let liveness = Arc::new(Mutex::new(Instant::now()));
        let closed = Arc::new(Mutex::new(None::<CloseReason>));
        let bytes_seen = Arc::new(std::sync::atomic::AtomicU64::new(0));

        let reader = tokio::spawn(reader_task(
            Box::pin(rx),
            out_tx,
            Arc::clone(&closed),
            Arc::clone(&liveness),
            Arc::clone(&bytes_seen),
        ));
        let writer = tokio::spawn(writer_task(Box::pin(tx), stdin_rx));
        let hb_tx_for_close = stdin_tx.clone();
        let heartbeat = tokio::spawn(heartbeat_task(hb_tx_for_close, liveness));

        Ok(Self {
            outputs: out_rx,
            closed,
            stdin: stdin_tx,
            reader,
            writer,
            heartbeat,
            bytes_seen,
        })
    }
}

async fn reader_task(
    mut ws_rx: WsRx,
    out_tx: mpsc::UnboundedSender<Bytes>,
    closed: Arc<Mutex<Option<CloseReason>>>,
    liveness: Arc<Mutex<Instant>>,
    bytes_seen: Arc<std::sync::atomic::AtomicU64>,
) {
    while let Some(item) = ws_rx.next().await {
        let msg = match item {
            Ok(m) => m,
            Err(e) => {
                tracing::debug!(error = %e, "/pty/<id> read");
                *closed.lock().unwrap() = Some(CloseReason::Transport);
                break;
            }
        };
        *liveness.lock().unwrap() = Instant::now();
        match msg {
            Message::Binary(b) => {
                bytes_seen.fetch_add(b.len() as u64, std::sync::atomic::Ordering::Relaxed);
                if out_tx.send(Bytes::from(b.to_vec())).is_err() {
                    break;
                }
            }
            Message::Close(frame) => {
                let reason = match frame.map(|f| u16::from(f.code)) {
                    Some(code) if code == CLOSE_HISTORY_TRUNCATED => CloseReason::HistoryTruncated,
                    Some(code) if code == CLOSE_STALE_CURSOR => CloseReason::StaleCursor,
                    _ => CloseReason::Normal,
                };
                *closed.lock().unwrap() = Some(reason);
                break;
            }
            Message::Text(_) | Message::Ping(_) | Message::Pong(_) | Message::Frame(_) => continue,
        }
    }
}

async fn writer_task(mut ws_tx: WsSink, mut stdin_rx: mpsc::UnboundedReceiver<Bytes>) {
    while let Some(bytes) = stdin_rx.recv().await {
        if bytes.is_empty() {
            continue;
        }
        if ws_tx
            .send(Message::Binary(bytes.to_vec().into()))
            .await
            .is_err()
        {
            return;
        }
    }
    let _ = ws_tx.send(Message::Close(None)).await;
}

async fn heartbeat_task(_stdin_tx: mpsc::UnboundedSender<Bytes>, liveness: Arc<Mutex<Instant>>) {
    // Note: PTY stdin channel is for application bytes; we don't push
    // Pings through it. Heartbeat here is degenerate (no Pings) — we
    // rely on the server to ping us, which bumps liveness via reader.
    // If the server stops pinging, we'll notice idle and abort.
    let mut ticker = tokio::time::interval(HEARTBEAT_TICK);
    ticker.tick().await;
    loop {
        ticker.tick().await;
        let idle = Instant::now().duration_since(*liveness.lock().unwrap());
        if idle > IDLE_TIMEOUT {
            tracing::warn!(idle_secs = idle.as_secs(), "/pty/<id> idle");
            return;
        }
        let _ = PING_INTERVAL; // silence unused-const
    }
}
