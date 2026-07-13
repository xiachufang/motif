//! `GET /tcp?session=<sid>&host=127.0.0.1&port=<port>` — raw TCP tunnel.
//!
//! The client opens a local loopback listener and, for every browser TCP
//! connection, opens one `/tcp` WebSocket. This handler dials the requested
//! loopback service from the motifd host and splices bytes both ways.

use std::sync::Arc;
use std::time::Instant;

use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{ConnectInfo, Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::IntoResponse;
use futures_util::{SinkExt, StreamExt};
use motif_net::PeerAddr;
use motif_proto::common::ClientId;
use serde::Deserialize;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::sync::mpsc;

use crate::session::Session;
use crate::ws::{
    self, AppState, OutMsg, HEARTBEAT_TICK_DUR, IDLE_TIMEOUT_DUR, PING_INTERVAL_DUR, TIMING_TARGET,
};

const TCP_READ_CHUNK_BYTES: usize = 32 * 1024;

#[derive(Debug, Default, Deserialize)]
pub struct TcpQuery {
    pub session: Option<String>,
    pub token: Option<String>,
    #[serde(default)]
    pub host: Option<String>,
    pub port: Option<u16>,
}

pub async fn tcp_upgrade(
    State(state): State<AppState>,
    ConnectInfo(peer): ConnectInfo<PeerAddr>,
    headers: HeaderMap,
    Query(q): Query<TcpQuery>,
    ws: WebSocketUpgrade,
) -> impl IntoResponse {
    if !state
        .auth
        .verify_header_or_query(&headers, q.token.as_deref())
    {
        tracing::warn!(peer = %peer, "tcp ws auth rejected");
        return (StatusCode::UNAUTHORIZED, "missing or invalid Bearer token").into_response();
    }

    let Some(session_id) = q.session.clone() else {
        return (StatusCode::BAD_REQUEST, "missing ?session=<id>").into_response();
    };
    let Some(entry) = state.conns.get(&session_id) else {
        return (StatusCode::CONFLICT, "unknown or expired session_id").into_response();
    };
    let snap = entry.state.lock().snapshot();
    if snap.attached.is_none() {
        return (StatusCode::CONFLICT, "session not attached").into_response();
    }
    let Some(session) = crate::rpc::current_session(&state.manager, &snap) else {
        return (StatusCode::NOT_FOUND, "attached motif session vanished").into_response();
    };

    let host = q.host.unwrap_or_else(|| "127.0.0.1".to_string());
    if !is_allowed_remote_host(&host) {
        return (
            StatusCode::FORBIDDEN,
            "tcp forwarding is restricted to remote loopback hosts",
        )
            .into_response();
    }
    let Some(port) = q.port.filter(|p| *p != 0) else {
        return (
            StatusCode::BAD_REQUEST,
            "missing or invalid ?port=<1-65535>",
        )
            .into_response();
    };

    let client_id = snap.client_id;
    tracing::info!(
        peer = %peer,
        client_id = %client_id,
        host = %host,
        port,
        "tcp ws upgrade requested",
    );

    ws.on_upgrade(move |socket| handle_tcp_socket(socket, session, client_id, host, port, peer))
}

fn is_allowed_remote_host(host: &str) -> bool {
    matches!(host, "127.0.0.1" | "localhost" | "::1")
}

async fn handle_tcp_socket(
    socket: WebSocket,
    session: Arc<Session>,
    client_id: ClientId,
    host: String,
    port: u16,
    peer: PeerAddr,
) {
    let target = format!("{host}:{port}");
    tracing::info!(
        peer = %peer,
        client_id = %client_id,
        target = %target,
        "tcp ws connected",
    );

    let tcp = match TcpStream::connect((host.as_str(), port)).await {
        Ok(tcp) => tcp,
        Err(e) => {
            tracing::warn!(client_id = %client_id, target = %target, error = %e, "tcp dial failed");
            return;
        }
    };

    let (mut ws_tx, mut ws_rx) = socket.split();
    let (mut tcp_rx, mut tcp_tx) = tcp.into_split();
    let (out_tx, mut out_rx) = mpsc::unbounded_channel::<OutMsg>();

    let writer_client_id = client_id.clone();
    let writer_target = target.clone();
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
                channel   = "tcp",
                tcp_target = %writer_target,
                "tx",
            );
            if res.is_err() {
                break;
            }
        }
    });

    let last_recv = Arc::new(std::sync::Mutex::new(Instant::now()));
    let hb_out_tx = out_tx.clone();
    let hb_last = Arc::clone(&last_recv);
    let hb_client = client_id.clone();
    let hb_target = target.clone();
    let heartbeat = tokio::spawn(async move {
        let mut ticker = tokio::time::interval(HEARTBEAT_TICK_DUR);
        ticker.tick().await;
        let mut next_ping = Instant::now() + PING_INTERVAL_DUR;
        loop {
            ticker.tick().await;
            let now = Instant::now();
            let idle = now.duration_since(*hb_last.lock().unwrap());
            if idle > IDLE_TIMEOUT_DUR {
                tracing::warn!(
                    client_id = %hb_client,
                    tcp_target = %hb_target,
                    idle_secs = idle.as_secs(),
                    "tcp ws idle timeout"
                );
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

    let tcp_to_ws = tokio::spawn({
        let out_tx = out_tx.clone();
        async move {
            let mut buf = vec![0u8; TCP_READ_CHUNK_BYTES];
            loop {
                let n = match tcp_rx.read(&mut buf).await {
                    Ok(0) => break,
                    Ok(n) => n,
                    Err(e) => {
                        tracing::debug!(error = %e, "tcp read error");
                        break;
                    }
                };
                if out_tx
                    .send(OutMsg {
                        msg: Message::Binary(buf[..n].to_vec().into()),
                        enqueued_at: Instant::now(),
                        tag: "tcp.output".into(),
                        size: n,
                    })
                    .is_err()
                {
                    break;
                }
            }
        }
    });

    let mut shutdown = session.subscribe_shutdown();
    loop {
        if *shutdown.borrow() {
            break;
        }
        let item = tokio::select! {
            changed = shutdown.changed() => {
                if changed.is_err() || *shutdown.borrow() {
                    break;
                }
                continue;
            }
            item = ws_rx.next() => item,
        };
        let Some(item) = item else { break };
        let msg = match item {
            Ok(m) => m,
            Err(e) => {
                tracing::debug!(error = %e, "tcp ws read error");
                break;
            }
        };
        *last_recv.lock().unwrap() = Instant::now();
        match msg {
            Message::Binary(b) => {
                if let Err(e) = tcp_tx.write_all(&b).await {
                    tracing::debug!(error = %e, "tcp write error");
                    break;
                }
            }
            Message::Close(_) => break,
            _ => continue,
        }
    }

    let _ = tcp_tx.shutdown().await;
    tcp_to_ws.abort();
    heartbeat.abort();
    write_task.abort();
    tracing::info!(client_id = %client_id, target = %target, "tcp ws disconnected");
}

fn us_to_ms(us: u64) -> f64 {
    us as f64 / 1000.0
}
