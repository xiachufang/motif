//! `GET /pty/<pty_id>?session=<sid>&since=<bytes>&primary=<0|1>` —
//! per-PTY raw bytestream WebSocket.
//!
//! Replaces the `pty.output` event branch on the legacy `/ws` for the
//! new protocol. Frames are bare master input/output bytes — no
//! envelope, no codec negotiation, no JSON-RPC. Each PTY tab on a
//! client opens one of these.
//!
//! ## Replay semantics
//!
//! The Pty's byte-indexed ring (2 MB, see [`crate::pty::PtyRing`])
//! supports `?since=N` reconnects. The handler distinguishes:
//!
//! - `since == total`              — no replay, just go live.
//! - `origin <= since < total`     — replay the slice, then live.
//! - `since < origin`              — close 4011 ("history truncated").
//! - `since > total`               — close 4012 ("stale cursor").
//!
//! 4011/4012 tells the client "your scrollback is gone; reconnect
//! without `since=` and clear the local terminal buffer".

use std::sync::Arc;
use std::time::Instant;

use axum::extract::ws::{CloseCode, CloseFrame, Message, WebSocket, WebSocketUpgrade};
use axum::extract::{Path as AxumPath, Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::IntoResponse;
use futures_util::{SinkExt, StreamExt};
use motif_proto::common::{ClientId, PtyId};
use serde::Deserialize;
use tokio::sync::mpsc;

use crate::pty::{Pty, SinceOutcome};
use crate::session::Session;
use crate::ws::{
    self, AppState, OutMsg, HEARTBEAT_TICK_DUR, IDLE_TIMEOUT_DUR, PING_INTERVAL_DUR, TIMING_TARGET,
};

/// 4011 — server's per-PTY ring rolled past the client's `since`.
const CLOSE_HISTORY_TRUNCATED: CloseCode = 4011;
/// 4012 — client's `since` is ahead of server total (server restarted
/// or the cursor is bogus).
const CLOSE_STALE_CURSOR: CloseCode = 4012;

#[derive(Debug, Default, Deserialize)]
pub struct PtyQuery {
    pub session: Option<String>,
    pub token: Option<String>,
    #[serde(default)]
    pub since: Option<u64>,
    #[serde(default)]
    pub primary: Option<u8>,
}

pub async fn pty_upgrade(
    State(state): State<AppState>,
    AxumPath(pty_id): AxumPath<String>,
    headers: HeaderMap,
    Query(q): Query<PtyQuery>,
    ws: WebSocketUpgrade,
) -> impl IntoResponse {
    if !state
        .auth
        .verify_header_or_query(&headers, q.token.as_deref())
    {
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
    let since = q.since.unwrap_or_else(|| pty.snapshot_since_total());
    let primary = q.primary == Some(1);

    ws.on_upgrade(move |socket| {
        handle_pty_socket(socket, session, pty, client_id, pty_id, since, primary)
    })
}

async fn handle_pty_socket(
    socket: WebSocket,
    session: Arc<Session>,
    pty: Arc<Pty>,
    client_id: ClientId,
    pty_id: PtyId,
    since: u64,
    request_primary: bool,
) {
    tracing::info!(
        client_id = %client_id,
        session   = %session.name,
        pty_id    = %pty_id,
        since,
        request_primary,
        "pty ws connected",
    );

    // Apply primary request before subscribing — if a resize event
    // ends up being emitted as a result, the new subscriber catches
    // it on /events, not here.
    if request_primary {
        if let Some((cols, rows)) = pty.mark_primary(client_id.clone()) {
            let pty_id_for_event = pty_id.clone();
            session.publish_event(|seq| motif_proto::event::Event::PtyResize {
                pty_id: pty_id_for_event,
                cols,
                rows,
                seq,
            });
        }
    }

    let (mut ws_tx, mut ws_rx) = socket.split();
    let (out_tx, mut out_rx) = mpsc::unbounded_channel::<OutMsg>();

    // ─ Replay or close-with-truncate ─
    // Server doesn't track per-client byte cursors — the client owns
    // that state (passes its own `since=` on reconnect). The local
    // `total` from the snapshot lives only long enough to log.
    match pty.snapshot_since(since) {
        SinceOutcome::Truncated { ring_origin, total } => {
            tracing::info!(client_id = %client_id, pty_id = %pty_id, since, ring_origin, total, "pty replay truncated; closing 4011");
            let _ = ws_tx
                .send(Message::Close(Some(CloseFrame {
                    code: CLOSE_HISTORY_TRUNCATED,
                    reason: "history truncated".into(),
                })))
                .await;
            return;
        }
        SinceOutcome::Stale { total } => {
            tracing::info!(client_id = %client_id, pty_id = %pty_id, since, total, "pty stale cursor; closing 4012");
            let _ = ws_tx
                .send(Message::Close(Some(CloseFrame {
                    code: CLOSE_STALE_CURSOR,
                    reason: "stale cursor".into(),
                })))
                .await;
            return;
        }
        SinceOutcome::UpToDate { .. } => {}
        SinceOutcome::Replay { replay, total } => {
            // Send the snapshot in one binary frame. Sub-MB pushes
            // fit comfortably; if a future ring is larger, swap to
            // chunking here without changing the protocol.
            let size = replay.len();
            let _ = ws_tx.send(Message::Binary(replay.into())).await;
            tracing::debug!(
                target: TIMING_TARGET,
                client_id = %client_id,
                tag       = "pty.replay",
                size,
                total,
                channel   = "pty",
                pty_id    = %pty_id,
                "tx",
            );
        }
    }

    // Now subscribe to live output. Done AFTER replay snapshot so we
    // don't double-deliver bytes that landed in the ring between
    // snapshot and subscribe — broadcast channel only delivers bytes
    // sent after subscribe() returns.
    //
    // NOTE: there's still a small race where the reader thread pushed
    // bytes between snapshot's lock-release and broadcast::subscribe,
    // and the snapshot already covered them. We'd then duplicate.
    // For new protocol clients this is harmless (terminal emulators
    // are byte-stream tolerant); a future tighten could grab both
    // under a single critical section.
    let mut output_rx = pty.subscribe_output();

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
    // Inbound binary frames are raw stdin bytes for the master.
    // First write also lazy-marks this client as primary, mirroring
    // the legacy `mark_pty_primary` behavior on `pty.write`.
    let mut is_primary = request_primary;
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
                if !is_primary {
                    if let Some((cols, rows)) = pty.mark_primary(client_id.clone()) {
                        let pty_id_for_event = pty_id.clone();
                        session.publish_event(|seq| motif_proto::event::Event::PtyResize {
                            pty_id: pty_id_for_event,
                            cols,
                            rows,
                            seq,
                        });
                    }
                    is_primary = true;
                }
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
