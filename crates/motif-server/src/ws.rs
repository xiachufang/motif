//! axum router + WebSocket upgrade for both `/ws` (control) and
//! `/blob/<id>` (data).

use std::sync::Arc;
use std::time::{Duration, Instant};

use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{Path as AxumPath, Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::IntoResponse;
use axum::routing::get;
use axum::Router;
use futures_util::{SinkExt, StreamExt};
use motif_proto::common::{ClientId, Seq};
use motif_proto::envelope::{Frame, Id, Notification, Request, Response};
use motif_proto::error::RpcError;
use motif_proto::event::Event;
use motif_proto::fs::BlobMode;
use serde::Deserialize;
use sha2::Digest;
use std::sync::Arc as StdArc;
use tokio::sync::mpsc;

use crate::auth::TokenStore;
use crate::blob::BlobTransfer;
use crate::rpc::{self, ConnState};
use crate::rpc_log;
use crate::session::manager::SessionManager;
use crate::session::Session;
use crate::wire::{rmpv_to_json, Codec};

#[derive(Clone)]
pub struct AppState {
    pub manager: Arc<SessionManager>,
    pub auth: Arc<TokenStore>,
}

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/ws", get(ws_upgrade))
        .route("/blob/{tid}", get(blob_upgrade))
        .with_state(state)
}

/// `/ws` query string. `?bin=1` opts the connection into MessagePack
/// framing for the whole lifetime of the socket; the JSON path is the
/// default so older clients keep working unchanged.
#[derive(Debug, Default, Deserialize)]
struct WsParams {
    #[serde(default)]
    bin: Option<u8>,
}

impl WsParams {
    fn codec(&self) -> Codec {
        if self.bin == Some(1) {
            Codec::Binary
        } else {
            Codec::Json
        }
    }
}

async fn ws_upgrade(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(params): Query<WsParams>,
    ws: WebSocketUpgrade,
) -> impl IntoResponse {
    if !state.auth.verify_header(&headers) {
        return (StatusCode::UNAUTHORIZED, "missing or invalid Bearer token").into_response();
    }
    let codec = params.codec();
    ws.on_upgrade(move |socket| handle_socket(socket, state.manager, codec))
}

async fn blob_upgrade(
    State(state): State<AppState>,
    AxumPath(tid): AxumPath<String>,
    headers: HeaderMap,
    ws: WebSocketUpgrade,
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

/// How often the server sends a Ping (echoed as Pong by every reasonable
/// peer's WS stack, including axum / tungstenite / URLSessionWebSocketTask).
const PING_INTERVAL: Duration = Duration::from_secs(20);
/// If no frame of any kind has arrived in this long, declare the client
/// gone and close the socket. Tuned to allow ~2 missed Pings before
/// trusting a wedge.
const IDLE_TIMEOUT:  Duration = Duration::from_secs(45);
/// Heartbeat-task tick. Granularity for both "time to next Ping" and
/// "idle check" — they share one timer.
const HEARTBEAT_TICK: Duration = Duration::from_secs(10);

async fn handle_socket(socket: WebSocket, manager: Arc<SessionManager>, codec: Codec) {
    let mut conn = ConnState::new();
    tracing::info!(
        client_id = %conn.client_id,
        codec     = ?codec,
        "client connected",
    );

    let (mut ws_tx, mut ws_rx) = socket.split();
    let (out_tx, mut out_rx) = mpsc::unbounded_channel::<Message>();

    let write_task = tokio::spawn(async move {
        while let Some(msg) = out_rx.recv().await {
            if ws_tx.send(msg).await.is_err() {
                break;
            }
        }
    });

    // Liveness watermark. The read loop bumps it on every received frame
    // (text / binary / ping / pong / close); the heartbeat task reads it
    // every tick to decide whether to close on idle. Mutex<Instant> is
    // cheaper than the alternatives — contention is at most one writer +
    // one reader per tick, and the lock is held for nanoseconds.
    let last_recv = Arc::new(std::sync::Mutex::new(Instant::now()));

    let hb_out_tx   = out_tx.clone();
    let hb_last     = Arc::clone(&last_recv);
    let hb_client_id = conn.client_id.clone();
    let heartbeat_task = tokio::spawn(async move {
        let mut ticker    = tokio::time::interval(HEARTBEAT_TICK);
        ticker.tick().await; // skip immediate first tick
        let mut next_ping = Instant::now() + PING_INTERVAL;
        loop {
            ticker.tick().await;
            let now  = Instant::now();
            let idle = now.duration_since(*hb_last.lock().unwrap());
            if idle > IDLE_TIMEOUT {
                tracing::warn!(
                    client_id = %hb_client_id,
                    idle_secs = idle.as_secs(),
                    "ws idle timeout; closing",
                );
                let _ = hb_out_tx.send(Message::Close(None));
                return;
            }
            if now >= next_ping {
                if hb_out_tx.send(Message::Ping(Default::default())).is_err() {
                    return;
                }
                next_ping = now + PING_INTERVAL;
            }
        }
    });

    let mut event_task: Option<tokio::task::JoinHandle<()>> = None;

    while let Some(item) = ws_rx.next().await {
        let msg = match item {
            Ok(m) => m,
            Err(e) => {
                tracing::debug!(error = %e, "ws read error");
                break;
            }
        };
        // Any received frame counts as proof-of-life — including auto-
        // generated Pongs from the peer's WS stack — so we can trust the
        // far end isn't actually wedged even during long idle windows.
        *last_recv.lock().unwrap() = Instant::now();

        let frame = match decode_inbound(&conn.client_id, codec, msg) {
            DecodeOutcome::Frame(f) => f,
            DecodeOutcome::ParseError(err) => {
                let _ = out_tx.send(encode_response(&err, codec));
                continue;
            }
            DecodeOutcome::Skip => continue,
            DecodeOutcome::Close => break,
        };

        let req = match frame {
            Frame::Request(r) => r,
            _ => continue,
        };

        // Mutating methods (session.attach / session.detach) run serially
        // on this task: they touch &mut conn AND, on a successful attach,
        // need the post-dispatch event_task setup to fire before we read
        // the next frame. Everything else fans out into a tokio task that
        // runs on the blocking pool — so a slow fs.read or git.diff from
        // this same client doesn't block subsequent RPCs from the same
        // connection (and doesn't tie up a runtime worker either).
        if !rpc::is_mutating_method(&req.method) {
            let manager_c = Arc::clone(&manager);
            let snap = conn.snapshot();
            let out_tx_c = out_tx.clone();
            let client_id = conn.client_id.clone();
            let req_id = req.id.clone();
            tokio::spawn(async move {
                let resp = match tokio::task::spawn_blocking(move || {
                    rpc::dispatch_concurrent(&manager_c, &snap, req)
                })
                .await
                {
                    Ok(r) => r,
                    Err(e) => Response::err(
                        req_id,
                        motif_proto::error::RpcError::internal(format!("dispatch panic: {e}")),
                    ),
                };
                let resp_msg = encode_response(&resp, codec);
                trace_outbound(&client_id, "tx-rsp", &resp_msg);
                let _ = out_tx_c.send(resp_msg);
            });
            continue;
        }

        // Serial path: attach / detach. The per-connection event forwarder
        // must track ConnState exactly: attach starts one subscriber; detach
        // or re-attach aborts the old subscriber before replacing it.
        let method = req.method.clone();
        let attached_before = conn.attached.clone();
        let resp = rpc::dispatch_mut(&manager, &mut conn, req);
        let attached_after = conn.attached.clone();
        let attach_succeeded = method == "session.attach" && resp.error.is_none();

        if attached_before != attached_after || attach_succeeded {
            if let Some(t) = event_task.take() {
                t.abort();
            }
            if let Some(name) = &attached_after {
                if let Some(s) = manager.get(name) {
                    let replay_since = conn.pending_replay_since.take().unwrap_or(0);
                    event_task = Some(spawn_event_forwarder(
                        s,
                        out_tx.clone(),
                        conn.client_id.clone(),
                        replay_since,
                        codec,
                    ));
                } else {
                    conn.pending_replay_since = None;
                }
            } else {
                conn.pending_replay_since = None;
            }
        }

        let resp_msg = encode_response(&resp, codec);
        trace_outbound(&conn.client_id, "tx-rsp", &resp_msg);
        let _ = out_tx.send(resp_msg);
    }

    rpc::on_disconnect(&manager, &conn.snapshot());
    if let Some(t) = event_task {
        t.abort();
    }
    heartbeat_task.abort();
    write_task.abort();
    tracing::info!(client_id = %conn.client_id, "client disconnected");
}

fn spawn_event_forwarder(
    session: Arc<Session>,
    out_tx: mpsc::UnboundedSender<Message>,
    client_id: ClientId,
    replay_since: Seq,
    codec: Codec,
) -> tokio::task::JoinHandle<()> {
    let mut rx = session.subscribe();
    tokio::spawn(async move {
        // Order: subscribe FIRST so events published during replay land in
        // `rx` and aren't lost. Events emitted in the window [subscribe,
        // replay_since snapshot] sit in BOTH the ring and `rx`, so track the
        // highest seq replayed and skip anything ≤ that on `rx`.
        let past = session.replay_since(replay_since);
        let mut last_replayed = replay_since;
        for ev in past {
            last_replayed = last_replayed.max(ev.seq());
            if is_self_client_event(ev.as_ref(), &client_id) {
                continue;
            }
            if !send_event(&out_tx, &client_id, ev, codec) {
                return;
            }
        }

        loop {
            match rx.recv().await {
                Ok(ev) => {
                    if ev.seq() <= last_replayed {
                        continue;
                    }
                    if is_self_client_event(ev.as_ref(), &client_id) {
                        continue;
                    }
                    if !send_event(&out_tx, &client_id, ev, codec) {
                        break;
                    }
                }
                Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                    tracing::warn!(skipped = n, "subscriber lagged");
                }
                Err(_) => break,
            }
        }
    })
}

fn is_self_client_event(ev: &Event, client_id: &str) -> bool {
    matches!(ev, Event::ClientJoined { client_id: cid, .. } if cid == client_id)
        || matches!(ev, Event::ClientLeft { client_id: cid, .. } if cid == client_id)
}

fn send_event(
    out_tx: &mpsc::UnboundedSender<Message>,
    client_id: &str,
    ev: Arc<Event>,
    codec: Codec,
) -> bool {
    let n = StdArc::try_unwrap(ev).unwrap_or_else(|a| (*a).clone());
    let msg = encode_event(&n, codec);
    trace_outbound(client_id, "tx-evt", &msg);
    out_tx.send(msg).is_ok()
}

async fn handle_blob(
    socket: WebSocket,
    _session: Arc<crate::session::Session>,
    transfer: Arc<BlobTransfer>,
) {
    match transfer.mode {
        BlobMode::Read => blob_read(socket, transfer).await,
        BlobMode::Write => blob_write(socket, transfer).await,
    }
}

async fn blob_read(socket: WebSocket, transfer: Arc<BlobTransfer>) {
    let (mut ws_tx, mut ws_rx) = socket.split();
    // Drive a background task to drain incoming control messages (close, ping).
    let drain = tokio::spawn(async move { while let Some(_) = ws_rx.next().await {} });

    let path = transfer.path.clone();
    let send_res = async move {
        // 1MB chunks streamed as binary frames.
        let bytes = match std::fs::read(&path) {
            Ok(b) => b,
            Err(e) => {
                tracing::warn!(?path, "blob read open failed: {e}");
                return Err(());
            }
        };
        for chunk in bytes.chunks(1024 * 1024) {
            if ws_tx
                .send(Message::Binary(chunk.to_vec().into()))
                .await
                .is_err()
            {
                return Err(());
            }
        }
        let _ = ws_tx.send(Message::Close(None)).await;
        Ok(())
    }
    .await;

    if send_res.is_err() {
        tracing::debug!("blob read aborted");
    }
    drain.abort();
}

async fn blob_write(socket: WebSocket, transfer: Arc<BlobTransfer>) {
    let (mut ws_tx, mut ws_rx) = socket.split();

    // Allocate a tmp file under <workdir>/.motif/blobs/.
    let tmp_dir = transfer
        .path
        .parent()
        .unwrap_or(std::path::Path::new("."))
        .join(".motif")
        .join("blobs");
    let _ = std::fs::create_dir_all(&tmp_dir);
    let tmp_path = tmp_dir.join(format!("{}.tmp", transfer.id));
    let mut tmp_file = match std::fs::File::create(&tmp_path) {
        Ok(f) => f,
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
            Ok(m) => m,
            Err(_) => break,
        };
        match msg {
            Message::Binary(b) => {
                {
                    let mut st = transfer.state.lock();
                    st.bytes_received += b.len() as u64;
                    st.running_hash.update(&b);
                }
                if tmp_file.write_all(&b).is_err() {
                    break;
                }
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

/// Outcome of attempting to decode one inbound `Message` for the
/// per-connection RPC loop. Lets the read loop branch cleanly on JSON vs
/// binary codecs without duplicating the surrounding state-machine.
enum DecodeOutcome {
    Frame(Frame),
    ParseError(Response),
    /// Non-fatal frame we should ignore (ping/pong, opposite-codec frame).
    Skip,
    /// Client closed the socket.
    Close,
}

fn decode_inbound(client_id: &str, codec: Codec, msg: Message) -> DecodeOutcome {
    match (codec, msg) {
        // ── JSON path (original) ──
        (Codec::Json, Message::Text(t)) => {
            let s = t.to_string();
            tracing::trace!(
                target: rpc_log::TARGET,
                "rx     [{}] {}",
                client_id,
                rpc_log::truncate(&s),
            );
            match serde_json::from_str::<Frame>(&s) {
                Ok(f) => DecodeOutcome::Frame(f),
                Err(e) => DecodeOutcome::ParseError(Response::err(
                    Id::Num(0),
                    RpcError::parse_error(e.to_string()),
                )),
            }
        }
        (Codec::Json, Message::Binary(_)) => DecodeOutcome::Skip,

        // ── Binary path (MessagePack) ──
        (Codec::Binary, Message::Binary(b)) => {
            tracing::trace!(
                target: rpc_log::TARGET,
                "rx-bin [{}] len={}",
                client_id,
                b.len(),
            );
            match decode_binary_request(&b) {
                Ok(f) => DecodeOutcome::Frame(f),
                Err(e) => DecodeOutcome::ParseError(Response::err(
                    Id::Num(0),
                    RpcError::parse_error(e),
                )),
            }
        }
        (Codec::Binary, Message::Text(_)) => DecodeOutcome::ParseError(Response::err(
            Id::Num(0),
            RpcError::parse_error("binary codec received text frame".to_string()),
        )),

        // Common control frames.
        (_, Message::Ping(_)) | (_, Message::Pong(_)) => DecodeOutcome::Skip,
        (_, Message::Close(_)) => DecodeOutcome::Close,
    }
}

/// Inbound binary envelope. `params` is held as `rmpv::Value` so we don't
/// truncate msgpack `bin` types — the dispatch handlers want a JSON Value
/// for compatibility with the existing JSON path, so we convert at the
/// boundary via `rmpv_to_json` (base64-encoding any byte strings).
#[derive(Deserialize)]
struct BinaryRequestEnvelope {
    #[serde(default)]
    #[allow(dead_code)]
    jsonrpc: Option<String>,
    id:      Id,
    method:  String,
    #[serde(default = "rmpv_nil")]
    params:  rmpv::Value,
}

fn rmpv_nil() -> rmpv::Value { rmpv::Value::Nil }

fn decode_binary_request(buf: &[u8]) -> Result<Frame, String> {
    let env: BinaryRequestEnvelope =
        rmp_serde::from_slice(buf).map_err(|e| format!("msgpack decode: {e}"))?;
    Ok(Frame::Request(Request {
        jsonrpc: motif_proto::envelope::JSONRPC_V2.into(),
        id:      env.id,
        method:  env.method,
        params:  rmpv_to_json(env.params),
    }))
}

fn encode_response(r: &Response, codec: Codec) -> Message {
    match codec {
        Codec::Json => Message::Text(
            serde_json::to_string(r)
                .unwrap_or_else(|_| "{}".into())
                .into(),
        ),
        Codec::Binary => Message::Binary(
            rmp_serde::to_vec_named(r)
                .unwrap_or_default()
                .into(),
        ),
    }
}

fn encode_event(ev: &Event, codec: Codec) -> Message {
    match codec {
        Codec::Json => {
            // Wrap the typed Event in a JSON-RPC Notification envelope by
            // round-tripping through serde_json::Value — the same path the
            // legacy code took. Cheap and keeps the wire identical for
            // older clients.
            let value = serde_json::to_value(ev).unwrap_or(serde_json::Value::Null);
            let (method, params) = match value {
                serde_json::Value::Object(mut map) => {
                    let m = map
                        .remove("method")
                        .and_then(|v| v.as_str().map(String::from))
                        .unwrap_or_default();
                    let p = map.remove("params").unwrap_or(serde_json::Value::Null);
                    (m, p)
                }
                _ => (String::new(), serde_json::Value::Null),
            };
            let notif = Notification {
                jsonrpc: motif_proto::envelope::JSONRPC_V2.into(),
                method,
                params,
            };
            Message::Text(
                serde_json::to_string(&notif)
                    .unwrap_or_else(|_| "{}".into())
                    .into(),
            )
        }
        Codec::Binary => {
            // Serialize the Event directly via msgpack so byte fields stay
            // native `bin` (this is the high-volume path). Adjacent-tag
            // serialization produces `{method: ..., params: {...}}`, which
            // the iOS decoder reads as a notification (no `id`).
            Message::Binary(
                rmp_serde::to_vec_named(ev)
                    .unwrap_or_default()
                    .into(),
            )
        }
    }
}

fn trace_outbound(client_id: &str, tag: &str, msg: &Message) {
    match msg {
        Message::Text(body) => tracing::trace!(
            target: rpc_log::TARGET,
            "{} [{}] {}",
            tag,
            client_id,
            rpc_log::truncate(body),
        ),
        Message::Binary(body) => tracing::trace!(
            target: rpc_log::TARGET,
            "{}-bin [{}] len={}",
            tag,
            client_id,
            body.len(),
        ),
        _ => {}
    }
}

#[cfg(test)]
mod codec_tests {
    use super::*;
    use motif_proto::pty::OutputScope;

    #[test]
    fn pty_output_event_binary_uses_msgpack_bin() {
        let raw = vec![0u8, 1, 2, 3, 0xff, 0xfe];
        let ev = Event::PtyOutput {
            pty_id:   "p1".into(),
            data:     raw.clone(),
            block_id: None,
            scope:    OutputScope::Output,
            seq:      7,
        };
        let msg = encode_event(&ev, Codec::Binary);
        let bytes = match msg {
            Message::Binary(b) => b,
            _ => panic!("expected Message::Binary"),
        };
        // msgpack bin8 marker (0xc4) followed by length byte == raw.len()
        // proves the PTY bytes travel as native bin, not base64.
        assert!(bytes.windows(2).any(|w| w[0] == 0xc4 && w[1] == raw.len() as u8));
        // Decode round-trip.
        let back: Event = rmp_serde::from_slice(&bytes).unwrap();
        match back {
            Event::PtyOutput { data, .. } => assert_eq!(data, raw),
            _ => panic!("expected PtyOutput"),
        }
    }

    #[test]
    fn binary_request_decode_round_trips_pty_write_bytes() {
        use motif_proto::pty::PtyWriteParams;
        let raw = vec![3u8, 0x1b, 0x5b, 0x41]; // Ctrl-C + arrow up — non-ASCII-printable
        // Build the wire bytes via rmpv: an outer map carrying the JSON-RPC
        // envelope, with `params` encoded by rmp-serde so PtyWriteParams.data
        // lands on the wire as native msgpack bin.
        let params = PtyWriteParams { pty_id: "p1".into(), data: raw.clone() };
        let params_bytes = rmp_serde::to_vec_named(&params).unwrap();
        let params_rmpv: rmpv::Value = rmp_serde::from_slice(&params_bytes).unwrap();
        let frame_val = rmpv::Value::Map(vec![
            (rmpv::Value::from("jsonrpc"), rmpv::Value::from("2.0")),
            (rmpv::Value::from("id"),      rmpv::Value::from(11u64)),
            (rmpv::Value::from("method"),  rmpv::Value::from("pty.write")),
            (rmpv::Value::from("params"),  params_rmpv),
        ]);
        let mut buf = Vec::new();
        rmpv::encode::write_value(&mut buf, &frame_val).unwrap();

        let frame = decode_binary_request(&buf).expect("decode");
        let req = match frame {
            Frame::Request(r) => r,
            _ => panic!("expected Request"),
        };
        assert_eq!(req.method, "pty.write");
        // Dispatch will run parse::<PtyWriteParams>(req.params) — same as JSON
        // path. The wire adapter base64-decodes the (rmpv→json-via-base64)
        // string back to Vec<u8>.
        let p: PtyWriteParams = serde_json::from_value(req.params).expect("typed parse");
        assert_eq!(p.pty_id, "p1");
        assert_eq!(p.data, raw);
    }
}
