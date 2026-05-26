//! axum router + shared helpers for the HTTP / WS endpoints
//! (`/rpc/<method>`, `/events`, `/pty/<id>`). Heartbeat constants,
//! OutMsg framing, and Event ↔ Notification encoding live here so
//! sibling modules don't duplicate them.

use std::sync::Arc;
use std::time::{Duration, Instant};

use axum::extract::ws::Message;
use axum::routing::get;
use axum::Router;
use motif_proto::envelope::Notification;
use motif_proto::event::Event;

use crate::auth::TokenStore;
use crate::conn_registry::ConnRegistry;
use crate::http_rpc;
use crate::session::manager::SessionManager;
use crate::wire::Codec;

#[derive(Clone)]
pub struct AppState {
    pub manager: Arc<SessionManager>,
    pub auth: Arc<TokenStore>,
    /// Registry of per-session_id ConnState. Used by HTTP /rpc and (in
    /// later steps of the protocol redesign) by /events and /pty/<id>
    /// WS upgrades. Empty for clients still on the legacy /ws path —
    /// their state lives on the WS task, not here.
    pub conns: Arc<ConnRegistry>,
}

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/", get(crate::embed::serve_index))
        .route("/ping", get(ping))
        .route("/assets/{*p}", get(crate::embed::serve_assets))
        .route("/rpc/{method}", axum::routing::post(http_rpc::rpc_dispatch))
        .route("/events", get(crate::events_ws::events_upgrade))
        .route("/pty/{pty_id}", get(crate::pty_ws::pty_upgrade))
        .fallback(crate::embed::serve_spa_fallback)
        .with_state(state)
}

/// Stable magic string clients match on to confirm a `motif-server` is
/// answering (vs. some other service on the same host/port). Keep this
/// value frozen across versions — it's an identity probe, not a version
/// check.
pub const PING_SERVICE: &str = "motif-server";

/// `GET /ping` — unauthenticated liveness + identity probe. Returns a
/// fixed `service` tag so clients can detect a motif-server before they
/// hold a token, plus the build version for diagnostics.
async fn ping() -> axum::Json<serde_json::Value> {
    axum::Json(serde_json::json!({
        "service": PING_SERVICE,
        "version": env!("CARGO_PKG_VERSION"),
    }))
}

/// How often the server sends a Ping (echoed as Pong by every reasonable
/// peer's WS stack, including axum / tungstenite / URLSessionWebSocketTask).
const PING_INTERVAL: Duration = Duration::from_secs(20);
/// If no frame of any kind has arrived in this long, declare the client
/// gone and close the socket. Tuned to allow ~2 missed Pings before
/// trusting a wedge.
const IDLE_TIMEOUT: Duration = Duration::from_secs(45);
/// Heartbeat-task tick. Granularity for both "time to next Ping" and
/// "idle check" — they share one timer.
const HEARTBEAT_TICK: Duration = Duration::from_secs(10);

/// Public re-exports for sibling modules (events_ws, pty_ws) so they
/// can share heartbeat cadence + framing helpers without re-deriving
/// the constants.
pub const PING_INTERVAL_DUR: Duration = PING_INTERVAL;
pub const IDLE_TIMEOUT_DUR: Duration = IDLE_TIMEOUT;
pub const HEARTBEAT_TICK_DUR: Duration = HEARTBEAT_TICK;

/// Dedicated tracing target for per-frame timing. Operators flip this on
/// with `RUST_LOG=motif::rpc::timing=debug` (or `=info` for just the
/// response-side records) when investigating "git.diff slow / terminal
/// hangs" style symptoms.
pub const TIMING_TARGET: &str = "motif::rpc::timing";

/// One outbound frame queued for the WS writer task. Every send site
/// builds one of these instead of pushing a raw `Message`, so the writer
/// can log how long the frame waited in `out_tx` (queue depth proxy) and
/// how long the actual `ws_tx.send().await` took. This is the only way to
/// surface "git.diff response stalled in the write queue and starved
/// pty.output events behind it" — the very thing that makes the iOS
/// terminal feel frozen during a diff load.
pub struct OutMsg {
    pub msg: Message,
    pub enqueued_at: Instant,
    /// Short label for the log line (`rsp:git.diff:7`, `evt:pty.output`,
    /// `ping`, `close`, `parse-err`).
    pub tag: String,
    /// Payload bytes (text len for Text, byte len for Binary, 0 otherwise).
    pub size: usize,
}

/// Construct a `Message::Ping` OutMsg for sibling modules' heartbeat tasks.
pub fn out_ping() -> OutMsg {
    OutMsg {
        msg: Message::Ping(Default::default()),
        enqueued_at: Instant::now(),
        tag: "ping".into(),
        size: 0,
    }
}

/// Construct a `Message::Close(None)` OutMsg for sibling modules' idle / shutdown paths.
pub fn out_close() -> OutMsg {
    OutMsg {
        msg: Message::Close(None),
        enqueued_at: Instant::now(),
        tag: "close".into(),
        size: 0,
    }
}

pub fn msg_size(msg: &Message) -> usize {
    match msg {
        Message::Text(t) => t.len(),
        Message::Binary(b) => b.len(),
        _ => 0,
    }
}

/// Stable short name for an Event variant — used in the timing log tag
/// without parsing the encoded frame back. Names mirror the wire
/// `method` rename on each variant so log scrapes line up with what the
/// client observes.
pub fn event_tag(ev: &Event) -> &'static str {
    match ev {
        Event::TreeChanged { .. } => "evt:tree.changed",
        Event::PtyResize { .. } => "evt:pty.resize",
        Event::PtyCreated { .. } => "evt:pty.created",
        Event::PtyExited { .. } => "evt:pty.exited",
        Event::GitChanged { .. } => "evt:git.changed",
        Event::ClientJoined { .. } => "evt:client.joined",
        Event::ClientLeft { .. } => "evt:client.left",
        Event::ViewOpened { .. } => "evt:view.opened",
        Event::ViewClosed { .. } => "evt:view.closed",
        Event::ViewActiveChanged { .. } => "evt:view.active_changed",
        Event::ViewMoved { .. } => "evt:view.moved",
        Event::Unknown => "evt:unknown",
    }
}

pub fn encode_event(ev: &Event, codec: Codec) -> Message {
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
            Message::Binary(rmp_serde::to_vec_named(ev).unwrap_or_default().into())
        }
    }
}
