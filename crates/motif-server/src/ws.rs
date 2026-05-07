//! axum router + WebSocket upgrade for both `/ws` (control) and
//! `/blob/<id>` (data).

use std::sync::Arc;

use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{Path as AxumPath, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::IntoResponse;
use axum::routing::get;
use axum::Router;
use futures_util::{SinkExt, StreamExt};
use motif_proto::envelope::{Frame, Notification, Response};
use motif_proto::error::RpcError;
use motif_proto::event::Event;
use motif_proto::fs::BlobMode;
use sha2::Digest;
use std::sync::Arc as StdArc;
use tokio::sync::mpsc;

use crate::auth::TokenStore;
use crate::blob::BlobTransfer;
use crate::rpc::{self, ConnState};
use crate::session::manager::SessionManager;

#[derive(Clone)]
pub struct AppState {
    pub manager: Arc<SessionManager>,
    pub auth:    Arc<TokenStore>,
}

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/ws",         get(ws_upgrade))
        .route("/blob/{tid}", get(blob_upgrade))
        .with_state(state)
}

async fn ws_upgrade(
    State(state): State<AppState>,
    headers:      HeaderMap,
    ws:           WebSocketUpgrade,
) -> impl IntoResponse {
    if !state.auth.verify_header(&headers) {
        return (StatusCode::UNAUTHORIZED, "missing or invalid Bearer token").into_response();
    }
    ws.on_upgrade(move |socket| handle_socket(socket, state.manager))
}

async fn blob_upgrade(
    State(state):     State<AppState>,
    AxumPath(tid):    AxumPath<String>,
    headers:          HeaderMap,
    ws:               WebSocketUpgrade,
) -> impl IntoResponse {
    if !state.auth.verify_header(&headers) {
        return (StatusCode::UNAUTHORIZED, "missing or invalid Bearer token").into_response();
    }
    // Look the transfer up across all sessions.
    let mut found: Option<(Arc<crate::session::Session>, Arc<BlobTransfer>)> = None;
    for s in state.manager.list() {
        if let Some(t) = s.blobs.get(&tid) {
            found = Some((s, t));
            break;
        }
    }
    let Some((session, transfer)) = found else {
        return (StatusCode::GONE, "blob transfer not found or expired").into_response();
    };
    ws.on_upgrade(move |socket| handle_blob(socket, session, transfer))
}

async fn handle_socket(socket: WebSocket, manager: Arc<SessionManager>) {
    let mut conn = ConnState::new();
    tracing::info!(client_id = %conn.client_id, "client connected");

    let (mut ws_tx, mut ws_rx) = socket.split();
    let (out_tx, mut out_rx) = mpsc::unbounded_channel::<Message>();

    let write_task = tokio::spawn(async move {
        while let Some(msg) = out_rx.recv().await {
            if ws_tx.send(msg).await.is_err() { break; }
        }
    });

    let mut event_task: Option<tokio::task::JoinHandle<()>> = None;

    while let Some(item) = ws_rx.next().await {
        let msg = match item {
            Ok(m)  => m,
            Err(e) => { tracing::debug!(error = %e, "ws read error"); break; }
        };
        let text = match msg {
            Message::Text(t)   => t.to_string(),
            Message::Binary(_) => continue,
            Message::Ping(_) | Message::Pong(_) => continue,
            Message::Close(_)  => break,
        };

        let frame: Frame = match serde_json::from_str(&text) {
            Ok(f)  => f,
            Err(e) => {
                let err = Response::err(
                    motif_proto::envelope::Id::Num(0),
                    RpcError::parse_error(e.to_string()),
                );
                let _ = out_tx.send(serialize_response(&err));
                continue;
            }
        };

        let req = match frame {
            Frame::Request(r) => r,
            _ => continue,
        };

        let was_attached_before = conn.attached.is_some();
        let resp = rpc::dispatch(&manager, &mut conn, req).await;

        if !was_attached_before && conn.attached.is_some() {
            if let Some(name) = &conn.attached {
                if let Some(s) = manager.get(name) {
                    let mut rx        = s.subscribe();
                    let out_tx_clone  = out_tx.clone();
                    let client_id     = conn.client_id.clone();
                    let replay_since  = conn.pending_replay_since.take().unwrap_or(0);
                    let session_for_replay = Arc::clone(&s);
                    event_task = Some(tokio::spawn(async move {
                        // Order: subscribe FIRST so events published during
                        // replay land in `rx` and aren't lost. Events emitted
                        // in the window [subscribe, replay_since snapshot] sit
                        // in BOTH the ring and `rx`, so we track the highest
                        // seq we replayed and skip anything ≤ that on `rx`.
                        let past = session_for_replay.replay_since(replay_since);
                        let mut last_replayed = replay_since;
                        for ev in past {
                            last_replayed = last_replayed.max(ev.seq());
                            if matches!(&*ev, Event::ClientJoined { client_id: ref cid, .. } if *cid == client_id) {
                                continue;
                            }
                            let n = StdArc::try_unwrap(ev).unwrap_or_else(|a| (*a).clone());
                            let notif = event_to_notification(n);
                            if let Ok(json) = serde_json::to_string(&notif) {
                                if out_tx_clone.send(Message::Text(json.into())).is_err() { return; }
                            }
                        }
                        loop {
                            match rx.recv().await {
                                Ok(ev) => {
                                    if ev.seq() <= last_replayed { continue; }
                                    if matches!(&*ev, Event::ClientJoined { client_id: ref cid, .. } if *cid == client_id) {
                                        continue;
                                    }
                                    let n = StdArc::try_unwrap(ev).unwrap_or_else(|a| (*a).clone());
                                    let notif = event_to_notification(n);
                                    if let Ok(json) = serde_json::to_string(&notif) {
                                        if out_tx_clone.send(Message::Text(json.into())).is_err() { break; }
                                    }
                                }
                                Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                                    tracing::warn!(skipped = n, "subscriber lagged");
                                }
                                Err(_) => break,
                            }
                        }
                    }));
                }
            }
        }

        let _ = out_tx.send(serialize_response(&resp));
    }

    rpc::on_disconnect(&manager, &conn);
    if let Some(t) = event_task { t.abort(); }
    write_task.abort();
    tracing::info!(client_id = %conn.client_id, "client disconnected");
}

async fn handle_blob(
    socket:    WebSocket,
    _session:  Arc<crate::session::Session>,
    transfer:  Arc<BlobTransfer>,
) {
    match transfer.mode {
        BlobMode::Read  => blob_read(socket, transfer).await,
        BlobMode::Write => blob_write(socket, transfer).await,
    }
}

async fn blob_read(socket: WebSocket, transfer: Arc<BlobTransfer>) {
    let (mut ws_tx, mut ws_rx) = socket.split();
    // Drive a background task to drain incoming control messages (close, ping).
    let drain = tokio::spawn(async move {
        while let Some(_) = ws_rx.next().await {}
    });

    let path = transfer.path.clone();
    let send_res = async move {
        // 1MB chunks streamed as binary frames.
        let bytes = match std::fs::read(&path) {
            Ok(b)  => b,
            Err(e) => {
                tracing::warn!(?path, "blob read open failed: {e}");
                return Err(());
            }
        };
        for chunk in bytes.chunks(1024 * 1024) {
            if ws_tx.send(Message::Binary(chunk.to_vec().into())).await.is_err() {
                return Err(());
            }
        }
        let _ = ws_tx.send(Message::Close(None)).await;
        Ok(())
    }.await;

    if send_res.is_err() {
        tracing::debug!("blob read aborted");
    }
    drain.abort();
}

async fn blob_write(socket: WebSocket, transfer: Arc<BlobTransfer>) {
    let (mut ws_tx, mut ws_rx) = socket.split();

    // Allocate a tmp file under <workdir>/.motif/blobs/.
    let tmp_dir = transfer.path.parent().unwrap_or(std::path::Path::new("."))
        .join(".motif").join("blobs");
    let _ = std::fs::create_dir_all(&tmp_dir);
    let tmp_path = tmp_dir.join(format!("{}.tmp", transfer.id));
    let mut tmp_file = match std::fs::File::create(&tmp_path) {
        Ok(f)  => f,
        Err(e) => {
            tracing::warn!(?tmp_path, "blob tmp create failed: {e}");
            let _ = ws_tx.send(Message::Close(None)).await;
            return;
        }
    };
    {
        let mut st = transfer.state.lock();
        st.tmp_file = Some(tmp_path.clone());
    }
    use std::io::Write;
    while let Some(item) = ws_rx.next().await {
        let msg = match item {
            Ok(m)  => m,
            Err(_) => break,
        };
        match msg {
            Message::Binary(b) => {
                {
                    let mut st = transfer.state.lock();
                    st.bytes_received += b.len() as u64;
                    st.running_hash.update(&b);
                }
                if tmp_file.write_all(&b).is_err() { break; }
            }
            Message::Close(_) => break,
            _ => continue,
        }
    }
    let _ = tmp_file.flush();
    {
        let mut st = transfer.state.lock();
        st.completed = true;
    }
    let _ = ws_tx.send(Message::Close(None)).await;
}

fn serialize_response(r: &Response) -> Message {
    Message::Text(serde_json::to_string(r).unwrap_or_else(|_| "{}".into()).into())
}

fn event_to_notification(ev: Event) -> Notification {
    let value = serde_json::to_value(&ev).unwrap_or(serde_json::Value::Null);
    let (method, params) = match value {
        serde_json::Value::Object(mut map) => {
            let m = map.remove("method").and_then(|v| v.as_str().map(String::from)).unwrap_or_default();
            let p = map.remove("params").unwrap_or(serde_json::Value::Null);
            (m, p)
        }
        _ => (String::new(), serde_json::Value::Null),
    };
    Notification {
        jsonrpc: motif_proto::envelope::JSONRPC_V2.into(),
        method,
        params,
    }
}

