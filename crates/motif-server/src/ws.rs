//! axum router + shared helpers for the HTTP / WS endpoints
//! (`/rpc/<method>`, `/events`, `/pty/<id>`). Heartbeat constants,
//! OutMsg framing, and Event ↔ Notification encoding live here so
//! sibling modules don't duplicate them.

use std::sync::Arc;
use std::time::{Duration, Instant};

use axum::extract::ws::Message;
use axum::extract::DefaultBodyLimit;
use axum::http::{HeaderName, Method};
use axum::routing::get;
use axum::Router;
use motif_proto::envelope::Notification;
use motif_proto::event::Event;
use serde::Deserialize;
use tower_http::cors::{Any, CorsLayer};

use crate::auth::TokenStore;
use crate::conn_registry::ConnRegistry;
use crate::http_rpc;
use crate::session::manager::SessionManager;
use crate::wire::Codec;

#[derive(Clone)]
pub struct AppState {
    pub manager: Arc<SessionManager>,
    pub auth: Arc<TokenStore>,
    /// Registry of per-session_id ConnState. Used by HTTP /rpc and the
    /// /events and /pty/<id> WS upgrades.
    pub conns: Arc<ConnRegistry>,
    /// Push-notification state: device-token store + optional relay client.
    /// Carried so `device.register`/`device.unregister` RPCs can reach it.
    pub devices: crate::relay::DeviceState,
    /// LAN-direct advertisement, set only when a rendezvous server also opened a
    /// plaintext, non-loopback, tokenless `--listen` (see `main.rs`). `/ping`
    /// echoes it so a same-LAN rendezvous client can probe and upgrade off the
    /// relay onto a direct connection. `None` ⇒ `/ping` omits the hint.
    pub rzv_direct: Option<Arc<RzvDirectInfo>>,
}

/// The LAN-direct hint advertised over `/ping`: the plaintext `--listen` port
/// plus this host's non-loopback NIC addresses.
#[derive(Debug, Clone)]
pub struct RzvDirectInfo {
    pub port: u16,
    pub addrs: Vec<String>,
}

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/", get(crate::embed::serve_index))
        .route("/ping", get(ping))
        .route("/assets/{*p}", get(crate::embed::serve_assets))
        .route(
            "/rpc/{method}",
            axum::routing::post(http_rpc::rpc_dispatch)
                // Binary fs.write carries raw image bytes that can exceed
                // axum's 2 MB default body cap; allow up to 16 MB.
                .layer(DefaultBodyLimit::max(16 * 1024 * 1024)),
        )
        .route("/events", get(crate::events_ws::events_upgrade))
        .route("/pty/{pty_id}", get(crate::pty_ws::pty_upgrade))
        .route("/tcp", get(crate::tcp_ws::tcp_upgrade))
        .fallback(crate::embed::serve_spa_fallback)
        .with_state(state)
        .layer(cors_layer())
}

fn cors_layer() -> CorsLayer {
    CorsLayer::new()
        .allow_origin(Any)
        .allow_methods([Method::GET, Method::POST, Method::OPTIONS])
        .allow_headers(Any)
        .expose_headers([HeaderName::from_static(http_rpc::SESSION_HEADER)])
}

/// `GET /ping` — unauthenticated liveness + identity probe. Returns a
/// fixed `service` tag so clients can detect a motif-server before they
/// hold a token, plus the build version for diagnostics. The payload and
/// magic string live in `motif_proto::ping` so client and server can't
/// drift.
async fn ping(
    axum::extract::State(state): axum::extract::State<AppState>,
) -> axum::Json<motif_proto::ping::PingInfo> {
    let (rzv_direct_port, rzv_direct_addrs) = match &state.rzv_direct {
        Some(d) => (Some(d.port), d.addrs.clone()),
        None => (None, Vec::new()),
    };
    axum::Json(motif_proto::ping::PingInfo {
        service: motif_proto::ping::PING_SERVICE.to_string(),
        version: env!("CARGO_PKG_VERSION").to_string(),
        capabilities: vec![WS_PROBE_CAPABILITY.to_string()],
        rzv_direct_port,
        rzv_direct_addrs,
    })
}

/// Capability and frame names for the cross-platform application-level
/// WebSocket liveness probe. Browser clients cannot emit RFC 6455 Ping control
/// frames, so `/events` and `/pty/<id>` echo this small text-frame probe.
pub const WS_PROBE_CAPABILITY: &str = "ws_probe_v1";
const WS_PROBE_REQUEST: &str = "motif.probe.v1";
const WS_PROBE_ACK: &str = "motif.probe_ack.v1";
const WS_PROBE_MAX_ID_BYTES: usize = 64;

#[derive(Deserialize)]
struct WsProbeFrame {
    #[serde(rename = "type")]
    kind: String,
    id: String,
}

/// Return an acknowledgement for a valid liveness probe text frame. Other
/// inbound messages are left to the endpoint's normal protocol handling.
pub fn probe_ack(msg: &Message) -> Option<OutMsg> {
    let Message::Text(text) = msg else {
        return None;
    };
    // Bound parsing and the echoed identifier even though both WS endpoints
    // are authenticated. Normal probe frames are well under 128 bytes.
    if text.len() > 256 {
        return None;
    }
    let probe: WsProbeFrame = serde_json::from_str(text.as_str()).ok()?;
    if probe.kind != WS_PROBE_REQUEST
        || probe.id.is_empty()
        || probe.id.len() > WS_PROBE_MAX_ID_BYTES
    {
        return None;
    }
    let payload = serde_json::json!({"type": WS_PROBE_ACK, "id": probe.id}).to_string();
    let size = payload.len();
    Some(OutMsg {
        msg: Message::Text(payload.into()),
        enqueued_at: Instant::now(),
        tag: "probe_ack".into(),
        size,
    })
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

/// Maximum number of fully encoded WebSocket frames waiting behind a slow
/// peer. PTY output and TCP forwarding can be produced much faster than a
/// relayed/mobile socket can write, so this queue must never be unbounded.
pub const OUTBOUND_FRAME_CAPACITY: usize = 64;

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
        Event::SessionThemeChanged { .. } => "evt:session.theme_changed",
        Event::Notification { .. } => "evt:notification",
    }
}

pub fn encode_event(ev: &Event, codec: Codec) -> Message {
    match codec {
        Codec::Json => {
            // Wrap the typed Event in a JSON-RPC Notification envelope by
            // round-tripping through serde_json::Value.
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
