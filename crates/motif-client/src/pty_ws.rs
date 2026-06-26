//! `WS /pty/<pty_id>?session=<sid>&since=<bytes>`
//! client. One per open PTY tab.
//!
//! Bidirectional binary stream. Each connection leads with a single Text meta
//! frame `{"since":<offset>}` (the absolute byte offset of the first data byte
//! that follows). New clients request `pty_frame=v1&pty_compress=zlib`; if the
//! server confirms it in the meta frame, inbound Binary frames carry a 1-byte
//! application header (`bit0 = zlib-compressed`) and are decoded before they
//! reach callers. Outbound frames remain raw stdin bytes. We adopt the meta
//! offset and advance it by decoded PTY bytes so [`PtyClient::resume_cursor`]
//! hands the caller an absolute `?since=` to warm-resume from on the next connect.
//! On close-with-code 4011 (live subscriber lagged) or legacy/compat 4012, the
//! caller is expected to clear its local terminal buffer and reconnect without
//! `since=`.

use std::io::Read;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::{anyhow, Context};
use bytes::Bytes;
use flate2::read::ZlibDecoder;
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
const FRAME_FLAG_COMPRESSED: u8 = 0x01;
const FRAME_FLAG_RESERVED: u8 = !FRAME_FLAG_COMPRESSED;

type WsErr = tokio_tungstenite::tungstenite::Error;
type WsSink = Pin<Box<dyn Sink<Message, Error = WsErr> + Send>>;
type WsRx = Pin<Box<dyn FuturesStream<Item = Result<Message, WsErr>> + Send>>;

/// Server-side `/pty/<id>` close codes — see
/// `crates/motif-server/src/pty_ws.rs`. Caller branches on these.
pub const CLOSE_HISTORY_TRUNCATED: u16 = 4011;
pub const CLOSE_STALE_CURSOR: u16 = 4012;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PtyOutputMode {
    Legacy,
    FramedZlib,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct PtyMeta {
    since: u64,
    output_mode: PtyOutputMode,
}

#[derive(Debug, Clone, Copy)]
pub enum CloseReason {
    /// Peer (server) closed gracefully — typically PTY exited or
    /// session detached.
    Normal,
    /// 4011 — live subscriber lagged past the server broadcast capacity.
    /// Caller should clear the local terminal buffer and reconnect without
    /// `since=`.
    HistoryTruncated,
    /// 4012 — legacy/compat stale cursor signal. Same recovery as 4011.
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
    /// Absolute byte offset of the next byte we expect — the value to pass
    /// as `?since=` on reconnect. Seeded from the leading `{"since":N}` meta
    /// frame, then advanced by each Binary frame's length. `None` until the
    /// meta frame arrives.
    cursor: Arc<std::sync::atomic::AtomicU64>,
    cursor_set: Arc<std::sync::atomic::AtomicBool>,
}

impl Drop for PtyClient {
    fn drop(&mut self) {
        self.reader.abort();
        self.writer.abort();
        self.heartbeat.abort();
    }
}

impl PtyClient {
    /// Absolute byte offset to resume from on reconnect — pass it verbatim
    /// as `?since=`. Adopted from the leading `{"since":N}` meta frame (so it
    /// is correct for both a warm byte-delta, where the server honors the
    /// requested `since`, and a cold VT snapshot, where the server reports
    /// `start = total - snapshot.len()` and counting the snapshot's bytes
    /// still lands the cursor exactly on `total`). `None` until the meta
    /// frame arrives (e.g. the connection dropped before the leading frame).
    pub fn resume_cursor(&self) -> Option<u64> {
        if self.cursor_set.load(std::sync::atomic::Ordering::Relaxed) {
            Some(self.cursor.load(std::sync::atomic::Ordering::Relaxed))
        } else {
            None
        }
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
    ) -> anyhow::Result<Self> {
        let stream = TcpStream::connect(addr)
            .await
            .with_context(|| format!("dial {}", addr))?;
        Self::connect_with_stream(addr, token, session_id, pty_id, since, stream).await
    }

    pub async fn connect_with_stream<S>(
        authority: &str,
        token: &str,
        session_id: &str,
        pty_id: &str,
        since: u64,
        stream: S,
    ) -> anyhow::Result<Self>
    where
        S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
    {
        let url = format!(
            "ws://{authority}/pty/{pty_id}?session={session_id}&since={since}&pty_frame=v1&pty_compress=zlib"
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
        let cursor = Arc::new(std::sync::atomic::AtomicU64::new(0));
        let cursor_set = Arc::new(std::sync::atomic::AtomicBool::new(false));

        let reader = tokio::spawn(reader_task(
            Box::pin(rx),
            out_tx,
            Arc::clone(&closed),
            Arc::clone(&liveness),
            Arc::clone(&cursor),
            Arc::clone(&cursor_set),
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
            cursor,
            cursor_set,
        })
    }
}

async fn reader_task(
    mut ws_rx: WsRx,
    out_tx: mpsc::UnboundedSender<Bytes>,
    closed: Arc<Mutex<Option<CloseReason>>>,
    liveness: Arc<Mutex<Instant>>,
    cursor: Arc<std::sync::atomic::AtomicU64>,
    cursor_set: Arc<std::sync::atomic::AtomicBool>,
) {
    use std::sync::atomic::Ordering::Relaxed;
    let mut output_mode = PtyOutputMode::Legacy;
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
                let bytes = match decode_pty_payload(&b, output_mode) {
                    Ok(bytes) => bytes,
                    Err(e) => {
                        tracing::warn!(error = %e, "/pty/<id> framed decode");
                        *closed.lock().unwrap() = Some(CloseReason::Transport);
                        break;
                    }
                };
                // Advance the resume cursor only once the leading meta frame
                // has seeded its absolute base — otherwise we'd be counting
                // from 0 and undershoot a snapshot's true `total`.
                if cursor_set.load(Relaxed) {
                    cursor.fetch_add(bytes.len() as u64, Relaxed);
                }
                if out_tx.send(bytes).is_err() {
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
            // Leading `{"since":N}` meta frame: adopt N as the absolute base
            // for the resume cursor. It's the sole Text frame the server
            // sends; counting the Binary frames that follow lands the cursor
            // on the ring `total` for both warm deltas and cold snapshots.
            Message::Text(s) => {
                if !cursor_set.load(Relaxed) {
                    if let Some(meta) = parse_meta(&s) {
                        output_mode = meta.output_mode;
                        cursor.store(meta.since, Relaxed);
                        cursor_set.store(true, Relaxed);
                    }
                }
            }
            Message::Ping(_) | Message::Pong(_) | Message::Frame(_) => continue,
        }
    }
}

/// Pull the absolute byte offset out of a `/pty/<id>` leading meta frame
/// (`{"since":<offset>}`). Returns `None` for any non-meta / malformed text.
fn parse_meta_since(s: &str) -> Option<u64> {
    parse_meta(s).map(|meta| meta.since)
}

fn parse_meta(s: &str) -> Option<PtyMeta> {
    let value = serde_json::from_str::<serde_json::Value>(s).ok()?;
    let since = value.get("since")?.as_u64()?;
    let output_mode = match (
        value.get("pty_frame").and_then(|v| v.as_str()),
        value.get("pty_compress").and_then(|v| v.as_str()),
    ) {
        (Some("v1"), Some("zlib")) => PtyOutputMode::FramedZlib,
        _ => PtyOutputMode::Legacy,
    };
    Some(PtyMeta { since, output_mode })
}

fn decode_pty_payload(payload: &[u8], output_mode: PtyOutputMode) -> Result<Bytes, String> {
    match output_mode {
        PtyOutputMode::Legacy => Ok(Bytes::copy_from_slice(payload)),
        PtyOutputMode::FramedZlib => decode_framed_zlib_payload(payload),
    }
}

fn decode_framed_zlib_payload(frame: &[u8]) -> Result<Bytes, String> {
    let (&flags, payload) = frame
        .split_first()
        .ok_or_else(|| "empty framed pty frame".to_string())?;
    if flags & FRAME_FLAG_RESERVED != 0 {
        return Err(format!("reserved pty frame flags set: 0x{flags:02x}"));
    }
    if flags & FRAME_FLAG_COMPRESSED == 0 {
        return Ok(Bytes::copy_from_slice(payload));
    }
    let mut decoder = ZlibDecoder::new(payload);
    let mut out = Vec::new();
    decoder
        .read_to_end(&mut out)
        .map_err(|e| format!("zlib decode failed: {e}"))?;
    Ok(Bytes::from(out))
}

#[cfg(test)]
mod tests {
    use super::{
        decode_pty_payload, parse_meta, parse_meta_since, PtyMeta, PtyOutputMode,
        FRAME_FLAG_COMPRESSED,
    };
    use flate2::write::ZlibEncoder;
    use flate2::Compression;
    use std::io::Write;

    fn zlib(data: &[u8]) -> Vec<u8> {
        let mut encoder = ZlibEncoder::new(Vec::new(), Compression::fast());
        encoder.write_all(data).unwrap();
        encoder.finish().unwrap()
    }

    #[test]
    fn parses_well_formed_meta() {
        assert_eq!(parse_meta_since(r#"{"since":0}"#), Some(0));
        assert_eq!(
            parse_meta_since(r#"{"since":1717171717}"#),
            Some(1_717_171_717)
        );
        // The server seeds the ring origin from MAX_SCROLLBACK (~1.6 GiB),
        // so a snapshot's reported offset is large — must survive as u64.
        assert_eq!(
            parse_meta_since(r#"{"since":1610612736}"#),
            Some(1_610_612_736)
        );
        assert_eq!(
            parse_meta(r#"{"since":5,"pty_frame":"v1","pty_compress":"zlib"}"#),
            Some(PtyMeta {
                since: 5,
                output_mode: PtyOutputMode::FramedZlib,
            })
        );
        assert_eq!(
            parse_meta(r#"{"since":5,"pty_frame":"v1"}"#),
            Some(PtyMeta {
                since: 5,
                output_mode: PtyOutputMode::Legacy,
            })
        );
    }

    #[test]
    fn rejects_non_meta_or_malformed() {
        assert_eq!(parse_meta_since("not json"), None);
        assert_eq!(parse_meta_since("{}"), None);
        assert_eq!(parse_meta_since(r#"{"other":5}"#), None);
        assert_eq!(parse_meta_since(r#"{"since":-1}"#), None);
        assert_eq!(parse_meta_since(r#"{"since":"x"}"#), None);
    }

    #[test]
    fn decodes_legacy_payload_without_frame_header() {
        assert_eq!(
            decode_pty_payload(b"abc", PtyOutputMode::Legacy)
                .unwrap()
                .as_ref(),
            b"abc"
        );
    }

    #[test]
    fn decodes_framed_raw_payload() {
        assert_eq!(
            decode_pty_payload(b"\x00abc", PtyOutputMode::FramedZlib)
                .unwrap()
                .as_ref(),
            b"abc"
        );
    }

    #[test]
    fn decodes_framed_zlib_payload() {
        let mut frame = vec![FRAME_FLAG_COMPRESSED];
        frame.extend_from_slice(&zlib(b"abcabcabc"));
        assert_eq!(
            decode_pty_payload(&frame, PtyOutputMode::FramedZlib)
                .unwrap()
                .as_ref(),
            b"abcabcabc"
        );
    }

    #[test]
    fn rejects_bad_framed_payloads() {
        assert!(decode_pty_payload(b"", PtyOutputMode::FramedZlib).is_err());
        assert!(decode_pty_payload(b"\x02abc", PtyOutputMode::FramedZlib).is_err());
        assert!(decode_pty_payload(b"\x01not-zlib", PtyOutputMode::FramedZlib).is_err());
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
