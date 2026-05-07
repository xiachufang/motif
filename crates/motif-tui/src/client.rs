//! WebSocket + JSON-RPC client used by all `motif-tui` subcommands.
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
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{anyhow, Context};
use futures_util::stream::{SplitSink, SplitStream};
use futures_util::{SinkExt, StreamExt};
use motif_proto::envelope::{Frame, Id, Notification, Request, Response};
use motif_proto::error::RpcError;
use serde::{de::DeserializeOwned, Serialize};
use serde_json::Value;
use tokio::net::TcpStream;
use tokio::sync::{mpsc, oneshot};
use tokio::task::JoinHandle;
use tokio_tungstenite::{
    connect_async, tungstenite::client::IntoClientRequest, tungstenite::http::HeaderValue,
    tungstenite::Message, MaybeTlsStream, WebSocketStream,
};

type WsStream = WebSocketStream<MaybeTlsStream<TcpStream>>;
type WsSink   = SplitSink<WsStream, Message>;
type WsRx     = SplitStream<WsStream>;

type PendingMap = Arc<Mutex<HashMap<u64, oneshot::Sender<Response>>>>;

pub struct Client {
    ws_tx:    WsSink,
    next_id:  AtomicU64,
    pending:  PendingMap,
    notif_rx: mpsc::UnboundedReceiver<Notification>,
    reader:   JoinHandle<()>,
}

impl Drop for Client {
    fn drop(&mut self) {
        self.reader.abort();
    }
}

impl Client {
    pub async fn connect(url: &str, token: &str) -> anyhow::Result<Self> {
        let normalized = normalize_ws_url(url)?;
        let mut req = normalized.as_str().into_client_request()
            .with_context(|| format!("invalid URL: {normalized}"))?;
        let bearer = format!("Bearer {token}");
        req.headers_mut().insert(
            "Authorization",
            HeaderValue::from_str(&bearer)
                .map_err(|e| anyhow!("invalid token (cannot be HTTP header value): {e}"))?,
        );
        let (ws, _resp) = connect_async(req).await
            .with_context(|| format!("failed to connect to {normalized}"))?;

        let (ws_tx, ws_rx) = ws.split();
        let pending: PendingMap = Arc::new(Mutex::new(HashMap::new()));
        let (notif_tx, notif_rx) = mpsc::unbounded_channel();
        let pending_for_reader = Arc::clone(&pending);
        let reader = tokio::spawn(reader_task(ws_rx, pending_for_reader, notif_tx));

        Ok(Self {
            ws_tx,
            next_id: AtomicU64::new(1),
            pending,
            notif_rx,
            reader,
        })
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
    /// connection has closed *and* the queue has drained.
    pub async fn recv_notification(&mut self) -> Option<Notification> {
        self.notif_rx.recv().await
    }
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
