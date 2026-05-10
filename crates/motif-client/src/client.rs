//! WebSocket + JSON-RPC client shared by `motif-tui` and `motif-cast`.
//!
//! Single-reader architecture: a dedicated tokio task drives `ws.next()`,
//! routes Response frames to per-call `oneshot` channels by id, and pushes
//! Notifications onto an mpsc queue drained by the caller. This way,
//! notifications arriving while a `call` is in flight are NOT lost — they
//! sit in the queue until the caller asks for them via `recv_notification`.
//!
//! Why this matters: server-side RPC handlers (e.g. `pty.create`) publish
//! notifications synchronously inside the same dispatch — `pty.created`,
//! `view.opened`, `view.active_changed` and the spawned shell's first
//! `pty.output` (the prompt) all arrive on the wire while the client is
//! still awaiting the response. A naive "drop notifications during call"
//! reader would silently swallow the prompt and the new tab's view state.

use std::collections::HashMap;
use std::pin::Pin;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{anyhow, Context};
use futures_util::sink::Sink;
use futures_util::stream::Stream as FuturesStream;
use futures_util::{SinkExt, StreamExt};
use motif_proto::envelope::{Frame, Id, Notification, Request, Response};
use motif_proto::error::RpcError;
use serde::{de::DeserializeOwned, Serialize};
use serde_json::Value;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::sync::{mpsc, oneshot};
use tokio::task::JoinHandle;
use tokio_tungstenite::{
    client_async, connect_async, tungstenite::client::IntoClientRequest,
    tungstenite::http::HeaderValue, tungstenite::Message,
};

// Sink/stream halves are type-erased via `Box<dyn …>` so the same `Client`
// type works for both transports: `connect()` (which keeps tungstenite's
// `MaybeTlsStream<TcpStream>` for transparent `wss://` support) and
// `connect_with_stream()` (which feeds an arbitrary `AsyncRead+AsyncWrite`
// produced by `motif-net`, e.g. a tsnet socket). One heap alloc + a vtable
// hop per WebSocket frame is negligible against the JSON encode cost.
type WsErr  = tokio_tungstenite::tungstenite::Error;
type WsSink = Pin<Box<dyn Sink<Message, Error = WsErr> + Send>>;
type WsRx   = Pin<Box<dyn FuturesStream<Item = Result<Message, WsErr>> + Send>>;

type PendingMap = Arc<Mutex<HashMap<u64, oneshot::Sender<Response>>>>;

pub struct Client {
    ws_tx:    WsSink,
    next_id:  AtomicU64,
    pending:  PendingMap,
    /// `None` once the caller has taken the notification stream out via
    /// [`Client::take_notifications`]. Lets `motif-cast` move the receiver
    /// into its own select loop while keeping the rest of `Client` available
    /// (under `Arc<Mutex<…>>`) for `pty.write` / `pty.resize` / `session.*`
    /// calls. In-place users (`motif-tui`) just keep calling
    /// [`Client::recv_notification`] and never touch this branch.
    notif_rx: Option<mpsc::UnboundedReceiver<Notification>>,
    reader:   JoinHandle<()>,
}

impl Drop for Client {
    fn drop(&mut self) {
        self.reader.abort();
    }
}

impl Client {
    /// Direct connect: dials the URL and runs the WebSocket handshake using
    /// `tokio_tungstenite::connect_async`, which retains transparent
    /// `wss://` TLS via `MaybeTlsStream`. Use this for plain TCP / TLS.
    pub async fn connect(url: &str, token: &str) -> anyhow::Result<Self> {
        let normalized = normalize_ws_url(url)?;
        let req = build_request(&normalized, token)?;
        let (ws, _resp) = connect_async(req).await
            .with_context(|| format!("failed to connect to {normalized}"))?;
        let (tx, rx) = ws.split();
        Ok(Self::from_split(Box::pin(tx), Box::pin(rx)))
    }

    /// Run the WebSocket handshake on a caller-provided byte stream — the
    /// stream has already been dialed (e.g. via `motif_net::dial`). The URL
    /// is used for the WS upgrade `Host` header / origin negotiation only;
    /// no DNS or TCP connect happens here.
    ///
    /// Note: tungstenite's `client_async` does *not* run TLS, so callers
    /// must pass a plaintext stream (or wrap their own TLS). This is the
    /// path used by the `--via tailscale://…` branch.
    pub async fn connect_with_stream<S>(
        url:    &str,
        token:  &str,
        stream: S,
    ) -> anyhow::Result<Self>
    where
        S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
    {
        let normalized = normalize_ws_url(url)?;
        let req = build_request(&normalized, token)?;
        let (ws, _resp) = client_async(req, stream).await
            .with_context(|| format!("ws handshake on supplied stream for {normalized}"))?;
        let (tx, rx) = ws.split();
        Ok(Self::from_split(Box::pin(tx), Box::pin(rx)))
    }

    fn from_split(ws_tx: WsSink, ws_rx: WsRx) -> Self {
        let pending: PendingMap = Arc::new(Mutex::new(HashMap::new()));
        let (notif_tx, notif_rx) = mpsc::unbounded_channel();
        let pending_for_reader = Arc::clone(&pending);
        let reader = tokio::spawn(reader_task(ws_rx, pending_for_reader, notif_tx));

        Self {
            ws_tx,
            next_id: AtomicU64::new(1),
            pending,
            notif_rx: Some(notif_rx),
            reader,
        }
    }

    /// Move the notification stream out so it can be polled independently of
    /// the rest of the `Client` (which the caller might want to put behind a
    /// shared `Arc<Mutex<…>>` for `call`s). After this returns `Some`,
    /// [`Client::recv_notification`] yields `None` immediately.
    pub fn take_notifications(&mut self) -> Option<mpsc::UnboundedReceiver<Notification>> {
        self.notif_rx.take()
    }

    /// Send a request, await its response. While we wait, server-pushed
    /// notifications continue to be queued by the reader task — they're not
    /// dropped, and the caller can drain them later via `recv_notification`.
    pub async fn call<P, R>(&mut self, method: &str, params: P) -> anyhow::Result<R>
    where
        P: Serialize,
        R: DeserializeOwned,
    {
        let id  = self.next_id.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = oneshot::channel();
        self.pending.lock().unwrap().insert(id, tx);

        let req = Request::new(id, method, params);
        let raw = serde_json::to_string(&req)?;
        if let Err(e) = self.ws_tx.send(Message::Text(raw.into())).await {
            self.pending.lock().unwrap().remove(&id);
            return Err(anyhow!("ws send failed: {e}"));
        }

        let resp = match tokio::time::timeout(Duration::from_secs(15), rx).await {
            Ok(Ok(r))  => r,
            Ok(Err(_)) => {
                // oneshot Sender dropped — reader task exited (connection closed).
                return Err(anyhow!("connection closed before response"));
            }
            Err(_) => {
                self.pending.lock().unwrap().remove(&id);
                return Err(anyhow!("RPC '{method}' timed out"));
            }
        };
        decode_response(resp)
    }

    /// Wait for the next server-pushed notification. Returns `None` once the
    /// connection has closed *and* the queue has drained, or immediately if
    /// the receiver has been moved out via [`Client::take_notifications`].
    pub async fn recv_notification(&mut self) -> Option<Notification> {
        match self.notif_rx.as_mut() {
            Some(rx) => rx.recv().await,
            None     => None,
        }
    }
}

fn build_request(url: &str, token: &str) -> anyhow::Result<tokio_tungstenite::tungstenite::handshake::client::Request> {
    let mut req = url.into_client_request()
        .with_context(|| format!("invalid URL: {url}"))?;
    let bearer = format!("Bearer {token}");
    req.headers_mut().insert(
        "Authorization",
        HeaderValue::from_str(&bearer)
            .map_err(|e| anyhow!("invalid token (cannot be HTTP header value): {e}"))?,
    );
    Ok(req)
}

async fn reader_task(
    mut ws_rx:  WsRx,
    pending:    PendingMap,
    notif_tx:   mpsc::UnboundedSender<Notification>,
) {
    while let Some(item) = ws_rx.next().await {
        let msg = match item {
            Ok(m)  => m,
            Err(e) => {
                tracing::debug!(error = %e, "ws read error");
                break;
            }
        };
        let text = match msg {
            Message::Text(t)  => t.to_string(),
            Message::Binary(_) | Message::Ping(_) | Message::Pong(_) => continue,
            Message::Close(_) => break,
            Message::Frame(_) => continue,
        };
        let frame: Frame = match serde_json::from_str(&text) {
            Ok(f)  => f,
            Err(e) => {
                tracing::warn!(error = %e, raw = %text, "malformed frame");
                continue;
            }
        };
        match frame {
            Frame::Response(r) => {
                let id = match &r.id {
                    Id::Num(n) => *n,
                    Id::Str(_) => {
                        tracing::warn!("response with string id ignored");
                        continue;
                    }
                };
                let entry = pending.lock().unwrap().remove(&id);
                if let Some(tx) = entry {
                    let _ = tx.send(r);
                } else {
                    tracing::warn!(id, "response without pending caller");
                }
            }
            Frame::Notification(n) => {
                if notif_tx.send(n).is_err() { break; }
            }
            Frame::Request(_) => {
                // Server doesn't request from client in v1; ignore.
            }
        }
    }
    // Drop pending senders so any in-flight callers get a clean RecvError
    // (which `call` translates into "connection closed before response").
    pending.lock().unwrap().clear();
}

fn decode_response<R: DeserializeOwned>(r: Response) -> anyhow::Result<R> {
    if let Some(err) = r.error {
        return Err(anyhow!("rpc error {}: {}", err.code, err.message));
    }
    let result = r.result.unwrap_or(Value::Null);
    serde_json::from_value(result).map_err(|e| anyhow!("decoding response: {e}"))
}

#[allow(dead_code)]
pub fn fmt_rpc_error(e: &RpcError) -> String {
    format!("rpc error {}: {}", e.code, e.message)
}

#[allow(dead_code)]
pub fn dbg_notification(n: &Notification) -> String {
    let p = serde_json::to_string(&n.params).unwrap_or_default();
    format!("{} {}", n.method, p)
}

/// If the user passed `ws(s)://host:port/` we route to `/ws`. Anything more
/// specific is left alone — power users can override.
fn normalize_ws_url(input: &str) -> anyhow::Result<String> {
    let mut url = url::Url::parse(input)
        .with_context(|| format!("invalid URL: {input}"))?;
    match url.scheme() {
        "ws" | "wss" => {}
        other => anyhow::bail!("expected ws:// or wss:// URL, got {other}://"),
    }
    if url.path().is_empty() || url.path() == "/" {
        url.set_path("/ws");
    }
    Ok(url.to_string())
}

#[cfg(test)]
mod tests {
    use super::normalize_ws_url;

    #[test]
    fn appends_ws_to_root() {
        assert_eq!(normalize_ws_url("ws://host:7777/").unwrap(),  "ws://host:7777/ws");
        assert_eq!(normalize_ws_url("wss://host:7777").unwrap(),   "wss://host:7777/ws");
    }
    #[test]
    fn keeps_explicit_path() {
        assert_eq!(normalize_ws_url("wss://host:7777/api/ws").unwrap(), "wss://host:7777/api/ws");
    }
    #[test]
    fn rejects_non_ws_scheme() {
        assert!(normalize_ws_url("https://host/").is_err());
    }
}
