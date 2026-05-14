//! `GET /events?session=<sid>&since=<seq>&bin=<0|1>` — server → client
//! structured-event push channel.
//!
//! Mirrors the event-forwarder half of `handle_socket` in `ws.rs`:
//! subscribe to the session's broadcast tx, replay buffered events past
//! `since`, then stream live. Difference: no inbound RPC handling here
//! — clients send RPC over HTTP. The receive side of the WS exists
//! only to detect peer close, gracefully tear down, and keep the
//! session's attached-client count in sync with browser lifetime.

use std::sync::Arc;
use std::time::Instant;

use axum::extract::ws::{WebSocket, WebSocketUpgrade};
use axum::extract::{Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::IntoResponse;
use futures_util::{SinkExt, StreamExt};
use motif_proto::common::{ClientId, Seq};
use motif_proto::event::Event;
use serde::Deserialize;
use tokio::sync::mpsc;

use crate::session::Session;
use crate::wire::Codec;
use crate::ws::{
    self, encode_event, AppState, OutMsg, HEARTBEAT_TICK_DUR, IDLE_TIMEOUT_DUR, PING_INTERVAL_DUR,
    TIMING_TARGET,
};

#[derive(Debug, Default, Deserialize)]
pub struct EventsQuery {
    pub session: Option<String>,
    pub token: Option<String>,
    #[serde(default)]
    pub since: Option<Seq>,
    #[serde(default)]
    pub bin: Option<u8>,
}

impl EventsQuery {
    fn codec(&self) -> Codec {
        if self.bin == Some(1) {
            Codec::Binary
        } else {
            Codec::Json
        }
    }
}

pub async fn events_upgrade(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(q): Query<EventsQuery>,
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

    // Snapshot which motif session this conn is attached to, plus the
    // client_id. Without an attachment there's nothing to subscribe to
    // — reject upfront rather than upgrade and immediately close.
    let snap = entry.state.lock().snapshot();
    let Some(attached_name) = snap.attached.clone() else {
        return (
            StatusCode::CONFLICT,
            "session not attached (call session.attach first)",
        )
            .into_response();
    };
    let Some(motif_session) = state.manager.get(&attached_name) else {
        return (StatusCode::NOT_FOUND, "attached motif session vanished").into_response();
    };
    let client_id = snap.client_id;
    let since = q.since.unwrap_or(0);
    let codec = q.codec();

    ws.on_upgrade(move |socket| {
        handle_events_socket(socket, motif_session, client_id, since, codec)
    })
}

async fn handle_events_socket(
    socket: WebSocket,
    session: Arc<Session>,
    client_id: ClientId,
    replay_since: Seq,
    codec: Codec,
) {
    tracing::info!(
        client_id = %client_id,
        session   = %session.name,
        codec     = ?codec,
        replay_since,
        "events ws connected",
    );

    let (mut ws_tx, mut ws_rx) = socket.split();
    let (out_tx, mut out_rx) = mpsc::unbounded_channel::<OutMsg>();

    // Writer task: drains out_tx, logs per-frame timing on the same
    // timing target the HTTP path uses.
    let writer_client_id = client_id.clone();
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
                channel   = "events",
                "tx",
            );
            if res.is_err() {
                break;
            }
        }
    });

    // Heartbeat. /events tends to be silent for long stretches so we
    // need Pings to keep NATs / proxies honest; same cadence as the
    // legacy /ws handler.
    let last_recv = Arc::new(std::sync::Mutex::new(Instant::now()));
    let hb_out_tx = out_tx.clone();
    let hb_last = Arc::clone(&last_recv);
    let hb_client = client_id.clone();
    let heartbeat = tokio::spawn(async move {
        let mut ticker = tokio::time::interval(HEARTBEAT_TICK_DUR);
        ticker.tick().await;
        let mut next_ping = Instant::now() + PING_INTERVAL_DUR;
        loop {
            ticker.tick().await;
            let now = Instant::now();
            let idle = now.duration_since(*hb_last.lock().unwrap());
            if idle > IDLE_TIMEOUT_DUR {
                tracing::warn!(client_id = %hb_client, idle_secs = idle.as_secs(), "events idle timeout");
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

    // Event forwarder. Subscribe FIRST, then replay — anything that
    // arrives during replay sits in both the ring AND `rx`, so track
    // the highest replayed seq and skip duplicates on `rx`.
    let sub_session = Arc::clone(&session);
    let sub_out_tx = out_tx.clone();
    let sub_client = client_id.clone();
    let forwarder = tokio::spawn(async move {
        let mut rx = sub_session.subscribe();
        let past = sub_session.replay_since(replay_since);
        let mut last_replayed = replay_since;
        for ev in past {
            last_replayed = last_replayed.max(ev.seq());
            if should_drop(&sub_session, ev.as_ref(), &sub_client) {
                continue;
            }
            if !send_event(&sub_out_tx, ev, codec) {
                return;
            }
        }
        loop {
            match rx.recv().await {
                Ok(ev) => {
                    if ev.seq() <= last_replayed {
                        continue;
                    }
                    if should_drop(&sub_session, ev.as_ref(), &sub_client) {
                        continue;
                    }
                    if !send_event(&sub_out_tx, ev, codec) {
                        break;
                    }
                }
                Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                    tracing::warn!(skipped = n, "events subscriber lagged");
                }
                Err(_) => break,
            }
        }
    });

    // Read loop: we don't expect inbound frames, but a peer close /
    // any frame counts as proof-of-life for the heartbeat watermark.
    while let Some(item) = ws_rx.next().await {
        match item {
            Ok(_) => *last_recv.lock().unwrap() = Instant::now(),
            Err(e) => {
                tracing::debug!(error = %e, "events ws read error");
                break;
            }
        }
    }

    forwarder.abort();
    heartbeat.abort();
    write_task.abort();
    let detached = session.detach_client(&client_id);
    tracing::info!(client_id = %client_id, detached, "events ws disconnected");
}

fn is_self_event(ev: &Event, client_id: &str) -> bool {
    matches!(ev, Event::ClientJoined { client_id: cid, .. } if cid == client_id)
        || matches!(ev, Event::ClientLeft { client_id: cid, .. } if cid == client_id)
}

/// Per-client delivery filter. Always drops self-attach/detach echoes; also
/// drops `tree.changed` / `git.changed` for clients that haven't opted into
/// the fs watch via `fs.watch`. Both checks are cheap (HashSet lookup +
/// pattern match) — fine to run on the hot replay/broadcast path.
fn should_drop(session: &Session, ev: &Event, client_id: &str) -> bool {
    if is_self_event(ev, client_id) {
        return true;
    }
    if matches!(ev, Event::TreeChanged { .. } | Event::GitChanged { .. })
        && !session.is_fs_subscribed(client_id)
    {
        return true;
    }
    false
}

fn send_event(out_tx: &mpsc::UnboundedSender<OutMsg>, ev: Arc<Event>, codec: Codec) -> bool {
    let event = std::sync::Arc::try_unwrap(ev).unwrap_or_else(|a| (*a).clone());
    let tag = ws::event_tag(&event);
    let msg = encode_event(&event, codec);
    let size = ws::msg_size(&msg);
    out_tx
        .send(OutMsg {
            msg,
            enqueued_at: Instant::now(),
            tag: tag.into(),
            size,
        })
        .is_ok()
}

fn us_to_ms(us: u64) -> f64 {
    us as f64 / 1000.0
}
