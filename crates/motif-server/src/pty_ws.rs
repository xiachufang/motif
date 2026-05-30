//! `GET /pty/<pty_id>?session=<sid>&since=<bytes>` —
//! per-PTY raw bytestream WebSocket.
//!
//! Carries PTY output (and inbound stdin) as bare master input/output
//! bytes — no envelope, no codec negotiation, no JSON-RPC. Each PTY tab
//! on a client opens one of these.
//!
//! ## Replay semantics
//!
//! Each PTY has a dedicated emulator thread (see [`crate::pty`]) owning a 2 MB
//! byte ring AND a headless libghostty terminal. On connect the handler asks it
//! (via `Pty::subscribe`) for the bytes to send before going live:
//!
//! - `origin <= since <= total`    — warm resume: raw byte delta `[since, total)`.
//! - `since` omitted / `< origin` / `> total` — cold/truncated/stale: a full VT
//!   **snapshot** of the current screen + scrollback (with a mode/cursor
//!   prelude), resuming live from `total`.
//!
//! The snapshot collapses in-place redraw churn (progress bars, full-screen
//! TUIs) to its rendered result, so a busy PTY replays kilobytes instead of
//! megabytes. The replay slice and the live receiver are taken atomically on
//! the emulator thread, so no output falls between them.
//!
//! ## Meta frame
//!
//! Every connection leads with a single WebSocket **Text** frame
//! `{"since":<offset>}` — the absolute byte offset of the first data byte that
//! follows (`since` for a warm delta, `total` for a snapshot). All data frames
//! are Binary, so the client tells them apart by frame type and adopts
//! `offset` as its resume cursor. Both replay kinds are opaque bytes the client
//! feeds into its terminal identically.
//!
//! A live subscriber that lags past the broadcast capacity is closed with 4011;
//! the client reconnects without `since=` and gets a fresh snapshot.

use std::sync::Arc;
use std::time::Instant;

use axum::extract::ws::{CloseCode, CloseFrame, Message, WebSocket, WebSocketUpgrade};
use axum::extract::{ConnectInfo, Path as AxumPath, Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::IntoResponse;
use futures_util::{SinkExt, StreamExt};
use motif_net::PeerAddr;
use motif_proto::common::{ClientId, PtyId};
use motif_proto::event::Event;
use serde::Deserialize;
use tokio::sync::mpsc;

use crate::pty::Pty;
use crate::session::Session;
use crate::ws::{
    self, AppState, OutMsg, HEARTBEAT_TICK_DUR, IDLE_TIMEOUT_DUR, PING_INTERVAL_DUR, TIMING_TARGET,
};

/// 4011 — a live subscriber fell too far behind and the broadcast channel
/// lagged (skipped bytes). The client reconnects without `since=` and gets a
/// fresh VT snapshot. (Cold/truncated/stale cursors no longer close the
/// socket — the emulator serves a snapshot inline instead.)
const CLOSE_HISTORY_TRUNCATED: CloseCode = 4011;

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

    // Primary ownership (which client's size the master follows) is claimed by
    // view.open / view.activate (tab switch / focus, see `rpc::mark_pty_primary`)
    // AND by sending input on this stream — see the read loop below, where each
    // inbound frame marks this client primary so the device you type on drives
    // the grid.

    let (mut ws_tx, mut ws_rx) = socket.split();
    let (out_tx, mut out_rx) = mpsc::unbounded_channel::<OutMsg>();

    // ─ Replay ─
    // The PTY's emulator thread decides what to send before live: a raw byte
    // **delta** `[since, total)` when `since` lands inside the ring (warm
    // incremental resume), or a full VT **snapshot** of the current screen +
    // scrollback when the cursor is cold (`since` omitted), truncated
    // (`< origin`), or stale (`> total`). Both arrive as opaque bytes here —
    // the client feeds either into its terminal identically. The replay slice
    // and the live receiver are taken atomically on the emulator thread, so no
    // output can fall between them. `start` is the absolute byte offset of the
    // first byte after the meta frame; the client adopts it as its cursor.
    let Some(reply) = pty.subscribe(since).await else {
        // Emulator thread is gone — the PTY has already exited. Nothing to
        // serve; let the socket close.
        tracing::info!(client_id = %client_id, pty_id = %pty_id, "pty subscribe: emulator gone");
        return;
    };
    let start = reply.start;
    let replay = reply.replay;
    let mut output_rx = reply.rx;

    // Lead with a Text meta frame announcing the absolute offset the client
    // adopts as its cursor. `start` is chosen (server-side) so that counting
    // the replay bytes that follow lands the cursor exactly on the ring
    // `total` — true for both a warm delta and a synthetic snapshot — so the
    // client keeps one dead-simple accounting rule and needs no snapshot flag.
    // All data frames are Binary; this meta is the only Text frame.
    let meta = format!("{{\"since\":{start}}}");
    if ws_tx.send(Message::Text(meta.into())).await.is_err() {
        return;
    }

    // Stream the replay (byte delta or VT snapshot) as bounded frames instead
    // of one giant Binary message. URLSession (and most WS clients) only
    // surface a frame once it is *fully* received, so a single multi-MB replay
    // leaves the terminal blank until the whole thing arrives — painfully
    // visible on a cold / DERP-relayed tailnet path. Chunking renders
    // progressively and lets the client advance its byte cursor per frame, so a
    // mid-replay drop resumes from where it left off.
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
    // Inbound binary frames are raw stdin bytes for the master — the only PTY
    // write path. Typing also claims primary: the client actively sending
    // input drives the shared master grid size (so output is laid out for the
    // device you're typing on). `mark_primary` is a cheap lock+compare no-op
    // once this client already owns primary, so calling it per input frame is
    // free in the steady state and only resizes + broadcasts on an actual
    // handover.
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
                if let Some((cols, rows)) = pty.mark_primary(client_id.clone()) {
                    let pid = pty_id.clone();
                    session.publish_event(|seq| Event::PtyResize {
                        pty_id: pid,
                        cols,
                        rows,
                        seq,
                    });
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
