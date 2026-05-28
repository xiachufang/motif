//! `GET /pty/<pty_id>?session=<sid>&since=<bytes>` —
//! per-PTY raw bytestream WebSocket.
//!
//! Carries PTY output (and inbound stdin) as bare master input/output
//! bytes — no envelope, no codec negotiation, no JSON-RPC. Each PTY tab
//! on a client opens one of these.
//!
//! ## Replay semantics
//!
//! The Pty's byte-indexed ring (2 MB, see [`crate::pty::PtyRing`])
//! supports `?since=N` reconnects. With an explicit `since=N` the handler
//! distinguishes:
//!
//! - `since == total`              — no replay, just go live.
//! - `origin <= since < total`     — replay the slice, then live.
//! - `since < origin`              — close 4011 ("history truncated").
//! - `since > total`               — close 4012 ("stale cursor").
//!
//! Omitting `since` is a **tail** request: the handler reads the ring's
//! current `origin` atomically with the snapshot + live subscribe and serves
//! `[origin, total)` then live.
//!
//! ## Meta frame
//!
//! Every (non-error) connection leads with a single WebSocket **Text** frame
//! `{"since":<offset>}` — the absolute byte offset of the first data byte
//! that follows (the honored `since` for a cursor connect, the resolved
//! `origin` for a tail connect). All data frames are Binary, so the client
//! tells them apart by frame type. The client adopts `offset` as its cursor;
//! because it is resolved server-side at connect time it can never be stale
//! by the time the client records it (no reconnect race), and the client
//! resumes incrementally afterwards.
//!
//! 4011/4012 tells the client "your cursor is unusable; clear the local
//! terminal buffer and reconnect *without* `since=`" — i.e. fall back to a
//! tail request, which re-establishes an exact cursor via the meta frame.

use std::sync::Arc;
use std::time::Instant;

use axum::extract::ws::{CloseCode, CloseFrame, Message, WebSocket, WebSocketUpgrade};
use axum::extract::{ConnectInfo, Path as AxumPath, Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::IntoResponse;
use futures_util::{SinkExt, StreamExt};
use motif_net::PeerAddr;
use motif_proto::common::{ClientId, PtyId};
use serde::Deserialize;
use tokio::sync::mpsc;

use crate::pty::{Pty, SinceOutcomeWithLive};
use crate::session::Session;
use crate::ws::{
    self, AppState, OutMsg, HEARTBEAT_TICK_DUR, IDLE_TIMEOUT_DUR, PING_INTERVAL_DUR, TIMING_TARGET,
};

/// 4011 — server's per-PTY ring rolled past the client's `since`.
const CLOSE_HISTORY_TRUNCATED: CloseCode = 4011;
/// 4012 — client's `since` is ahead of server total (server restarted
/// or the cursor is bogus).
const CLOSE_STALE_CURSOR: CloseCode = 4012;

/// Frame size for streaming the `?since=` replay. Small enough that a
/// large scrollback renders progressively (and a mid-replay drop only
/// loses one frame), large enough to amortize per-frame overhead.
const REPLAY_CHUNK_BYTES: usize = 64 * 1024;

#[derive(Debug, Default, Deserialize)]
pub struct PtyQuery {
    pub session: Option<String>,
    pub token: Option<String>,
    #[serde(default)]
    pub since: Option<u64>,
}

pub async fn pty_upgrade(
    State(state): State<AppState>,
    ConnectInfo(peer): ConnectInfo<PeerAddr>,
    AxumPath(pty_id): AxumPath<String>,
    headers: HeaderMap,
    Query(q): Query<PtyQuery>,
    ws: WebSocketUpgrade,
) -> impl IntoResponse {
    tracing::info!(peer = %peer, pty_id = %pty_id, "pty ws upgrade requested");
    if !state
        .auth
        .verify_header_or_query(&headers, q.token.as_deref())
    {
        tracing::warn!(peer = %peer, pty_id = %pty_id, "pty ws auth rejected");
        return (StatusCode::UNAUTHORIZED, "missing or invalid Bearer token").into_response();
    }
    let Some(session_id) = q.session.clone() else {
        return (StatusCode::BAD_REQUEST, "missing ?session=<id>").into_response();
    };
    let Some(entry) = state.conns.get(&session_id) else {
        return (StatusCode::CONFLICT, "unknown or expired session_id").into_response();
    };
    let snap = entry.state.lock().snapshot();
    let Some(attached_name) = snap.attached.clone() else {
        return (StatusCode::CONFLICT, "session not attached").into_response();
    };
    let Some(session) = state.manager.get(&attached_name) else {
        return (StatusCode::NOT_FOUND, "attached motif session vanished").into_response();
    };
    let Some(pty) = session.pty_pool.get(&pty_id) else {
        return (StatusCode::NOT_FOUND, "pty not found in attached session").into_response();
    };

    let client_id = snap.client_id;
    // `Some(n)` ⇒ client owns an absolute cursor (exact replay/truncate
    // handling, pure-binary stream). `None` ⇒ "tail" request: serve the
    // current ring atomically and hand back the resolved start offset in a
    // leading Text meta frame. See `handle_pty_socket`.
    let since = q.since;

    ws.on_upgrade(move |socket| {
        handle_pty_socket(socket, session, pty, client_id, pty_id, since, peer)
    })
}

async fn handle_pty_socket(
    socket: WebSocket,
    session: Arc<Session>,
    pty: Arc<Pty>,
    client_id: ClientId,
    pty_id: PtyId,
    since: Option<u64>,
    peer: PeerAddr,
) {
    tracing::info!(
        peer      = %peer,
        client_id = %client_id,
        session   = %session.name,
        pty_id    = %pty_id,
        since     = ?since,
        "pty ws connected",
    );

    // /pty is pure transport: it never claims primary. Primary ownership is
    // driven entirely by view.open / view.activate (a client re-asserts its
    // active view on focus/foreground). See `rpc::mark_pty_primary`.

    let (mut ws_tx, mut ws_rx) = socket.split();
    let (out_tx, mut out_rx) = mpsc::unbounded_channel::<OutMsg>();

    // ─ Replay or close-with-truncate ─
    // Server doesn't track per-client byte cursors — the client owns
    // that state (passes its own `since=` on reconnect). Replay lookup
    // and live subscribe happen under the Pty state lock so bytes cannot
    // fall between the two phases.
    // `start` is the absolute byte offset of the first byte that follows the
    // meta frame; the client adopts it as its cursor.
    let (start, replay, mut output_rx) = match since {
        // ── Exact cursor (`?since=N`) ──
        Some(since) => match pty.subscribe_since(since) {
            SinceOutcomeWithLive::Truncated { ring_origin, total } => {
                tracing::info!(client_id = %client_id, pty_id = %pty_id, since, ring_origin, total, "pty replay truncated; closing 4011");
                let _ = ws_tx
                    .send(Message::Close(Some(CloseFrame {
                        code: CLOSE_HISTORY_TRUNCATED,
                        reason: "history truncated".into(),
                    })))
                    .await;
                return;
            }
            SinceOutcomeWithLive::Stale { total } => {
                tracing::info!(client_id = %client_id, pty_id = %pty_id, since, total, "pty stale cursor; closing 4012");
                let _ = ws_tx
                    .send(Message::Close(Some(CloseFrame {
                        code: CLOSE_STALE_CURSOR,
                        reason: "stale cursor".into(),
                    })))
                    .await;
                return;
            }
            // `since` is honored exactly (origin ≤ since ≤ total), so the
            // first byte we serve sits at `since`.
            SinceOutcomeWithLive::UpToDate { rx, .. } => (since, Vec::new(), rx),
            SinceOutcomeWithLive::Replay { replay, rx, .. } => (since, replay, rx),
        },
        // ── Tail (`since` omitted) ──
        // Resolve the start offset atomically with the snapshot + live
        // subscribe so the client adopts an exact cursor without a
        // stale-origin reconnect race.
        None => {
            let tail = pty.subscribe_tail();
            (tail.start, tail.replay, tail.rx)
        }
    };

    // Lead with a Text meta frame announcing the absolute offset of the bytes
    // that follow. Sent on every (non-error) connection so the client never
    // has to guess where its cursor should sit; all data frames are Binary.
    let meta = format!("{{\"since\":{start}}}");
    if ws_tx.send(Message::Text(meta.into())).await.is_err() {
        return;
    }

    // Stream the snapshot as bounded frames instead of one giant Binary
    // message. URLSession (and most WS clients) only surface a frame once it
    // is *fully* received, so a single multi-MB replay leaves the terminal
    // blank until the whole ring arrives — painfully visible on a cold /
    // DERP-relayed tailnet path. Chunking renders progressively and lets the
    // client advance its byte cursor per frame, so a mid-replay drop resumes
    // from where it left off instead of refetching the whole ring.
    if !replay.is_empty() {
        let size = replay.len();
        for chunk in replay.chunks(REPLAY_CHUNK_BYTES) {
            if ws_tx
                .send(Message::Binary(chunk.to_vec().into()))
                .await
                .is_err()
            {
                return;
            }
        }
        tracing::debug!(
            target: TIMING_TARGET,
            client_id = %client_id,
            tag       = "pty.replay",
            size,
            channel   = "pty",
            pty_id    = %pty_id,
            "tx",
        );
    }

    // ─ Writer task ─
    let writer_client_id = client_id.clone();
    let writer_pty_id = pty_id.clone();
    let write_task = tokio::spawn(async move {
        while let Some(out) = out_rx.recv().await {
            let wait_us = out.enqueued_at.elapsed().as_micros() as u64;
            let send_started = Instant::now();
            let res = ws_tx.send(out.msg).await;
            let send_us = send_started.elapsed().as_micros() as u64;
            tracing::debug!(
                target: TIMING_TARGET,
                client_id = %writer_client_id,
                tag       = %out.tag,
                size      = out.size,
                wait_ms   = us_to_ms(wait_us),
                send_ms   = us_to_ms(send_us),
                channel   = "pty",
                pty_id    = %writer_pty_id,
                "tx",
            );
            if res.is_err() {
                break;
            }
        }
    });

    // ─ Heartbeat ─
    let last_recv = Arc::new(std::sync::Mutex::new(Instant::now()));
    let hb_out_tx = out_tx.clone();
    let hb_last = Arc::clone(&last_recv);
    let hb_client = client_id.clone();
    let hb_pty = pty_id.clone();
    let heartbeat = tokio::spawn(async move {
        let mut ticker = tokio::time::interval(HEARTBEAT_TICK_DUR);
        ticker.tick().await;
        let mut next_ping = Instant::now() + PING_INTERVAL_DUR;
        loop {
            ticker.tick().await;
            let now = Instant::now();
            let idle = now.duration_since(*hb_last.lock().unwrap());
            if idle > IDLE_TIMEOUT_DUR {
                tracing::warn!(client_id = %hb_client, pty_id = %hb_pty, idle_secs = idle.as_secs(), "pty idle timeout");
                let _ = hb_out_tx.send(ws::out_close());
                return;
            }
            if now >= next_ping {
                if hb_out_tx.send(ws::out_ping()).is_err() {
                    return;
                }
                next_ping = now + PING_INTERVAL_DUR;
            }
        }
    });

    // ─ Output forwarder ─
    let out_tx_fwd = out_tx.clone();
    let fwd_pty_id = pty_id.clone();
    let fwd_client = client_id.clone();
    let forwarder = tokio::spawn(async move {
        loop {
            match output_rx.recv().await {
                Ok(bytes) => {
                    let size = bytes.len();
                    let send = out_tx_fwd.send(OutMsg {
                        msg: Message::Binary(bytes.to_vec().into()),
                        enqueued_at: Instant::now(),
                        tag: "pty.output".into(),
                        size,
                    });
                    if send.is_err() {
                        break;
                    }
                }
                Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                    // Subscriber too slow — its view is now
                    // inconsistent (we skipped bytes). Best honest
                    // recovery: close 4011 so the client knows to
                    // resync from current total.
                    tracing::warn!(
                        client_id = %fwd_client, pty_id = %fwd_pty_id,
                        skipped = n, "pty subscriber lagged; closing 4011",
                    );
                    let _ = out_tx_fwd.send(OutMsg {
                        msg: Message::Close(Some(CloseFrame {
                            code: CLOSE_HISTORY_TRUNCATED,
                            reason: "subscriber lagged".into(),
                        })),
                        enqueued_at: Instant::now(),
                        tag: "close".into(),
                        size: 0,
                    });
                    break;
                }
                Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
            }
        }
    });

    // ─ Read loop ─
    // Inbound binary frames are raw stdin bytes for the master — this is the
    // only PTY write path. Writing never claims primary (see the transport
    // note above).
    while let Some(item) = ws_rx.next().await {
        let msg = match item {
            Ok(m) => m,
            Err(e) => {
                tracing::debug!(error = %e, "pty ws read error");
                break;
            }
        };
        *last_recv.lock().unwrap() = Instant::now();
        match msg {
            Message::Binary(b) => {
                if let Err(e) = pty.write_bytes(&b) {
                    tracing::warn!(pty_id = %pty_id, "pty write: {e}");
                }
            }
            Message::Close(_) => break,
            _ => continue,
        }
    }

    forwarder.abort();
    heartbeat.abort();
    write_task.abort();
    tracing::info!(client_id = %client_id, pty_id = %pty_id, "pty ws disconnected");
}

fn us_to_ms(us: u64) -> f64 {
    us as f64 / 1000.0
}
