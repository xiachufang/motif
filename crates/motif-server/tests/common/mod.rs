//! Shared harness for the `tests/protocol.rs` integration suite.
//!
//! Spins motif-server up in-process on `127.0.0.1:0`, then drives it from a
//! minimal hand-rolled HTTP + WS client. We avoid pulling in `motif-client`
//! so a server bug can't be papered over by matching client behavior.

#![allow(dead_code)]

use std::collections::VecDeque;
use std::net::SocketAddr;
use std::path::Path;
use std::process::Command;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{anyhow, bail, Context, Result};
use base64::Engine;
use bytes::Bytes;
use futures_util::StreamExt;
use http::HeaderValue;
use http_body_util::{BodyExt, Full};
use hyper::client::conn::http1;
use hyper_util::rt::TokioIo;
use motif_proto::envelope::Notification;
use motif_proto::error::RpcError;
use motif_proto::event::Event;
use motif_proto::session as ses;
use serde::{de::DeserializeOwned, Serialize};
use tokio::net::TcpStream;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tokio::time::timeout;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::Message;

const SESSION_HEADER: &str = "x-motif-session";

/// Hard ceiling for any single `expect_event` wait. Keeps a wedged test from
/// hanging CI for the default tokio test timeout.
pub const EVENT_TIMEOUT: Duration = Duration::from_secs(3);

// ─────────────────────────── TestServer ───────────────────────────

pub struct TestServer {
    pub addr: SocketAddr,
    pub token: String,
    shutdown: JoinHandle<()>,
}

impl TestServer {
    pub async fn start() -> Self {
        let token = format!("test-{}", ulid::Ulid::new());
        let state = motif_server::ws::AppState {
            manager: motif_server::session::manager::SessionManager::new(),
            auth: Arc::new(motif_server::auth::TokenStore::required(token.clone())),
            conns: motif_server::conn_registry::ConnRegistry::new(),
            devices: motif_server::relay::DeviceState {
                store: motif_server::devices::DeviceStore::new(),
                relay: None,
            },
        };
        let app = motif_server::ws::router(state);
        // Serve through motif-net's Listener (like motifd does) so the
        // `into_make_service_with_connect_info::<PeerAddr>()` connect-info is
        // injected — handlers extract `ConnectInfo<PeerAddr>` and a plain
        // `axum::serve(TcpListener, app)` would 500 with "missing extension".
        let listener = motif_net::Listener::bind(&motif_net::ListenConfig {
            tcp: Some("127.0.0.1:0".parse().expect("parse loopback addr")),
            tailscale: None,
        })
        .await
        .expect("bind 127.0.0.1:0");
        let addr: SocketAddr = listener
            .bound_addrs()
            .iter()
            .find_map(|s| s.strip_prefix("tcp://").and_then(|a| a.parse().ok()))
            .expect("resolve bound tcp addr");
        let shutdown = tokio::spawn(async move {
            let _ = axum::serve(
                listener,
                app.into_make_service_with_connect_info::<motif_net::PeerAddr>(),
            )
            .await;
        });
        Self {
            addr,
            token,
            shutdown,
        }
    }

    pub fn http_base(&self) -> String {
        format!("http://{}", self.addr)
    }

    /// HTTP POST /rpc/<method> without an `X-Motif-Session` header. Suitable
    /// for `session.list`, `session.create`, and `session.destroy`, which
    /// don't need an attached client.
    pub async fn call<P: Serialize, R: DeserializeOwned>(
        &self,
        method: &str,
        params: P,
    ) -> Result<R> {
        let headers = auth_headers(&self.token);
        let path = format!("/rpc/{method}");
        let (status, _, body) =
            http_request(self.addr, "POST", &path, &headers, to_body(&params)).await?;
        if !status.is_success() {
            bail!(
                "rpc {method} ({status}): {}",
                String::from_utf8_lossy(&body)
            );
        }
        serde_json::from_slice(&body).with_context(|| {
            format!("decode {method}: {}", String::from_utf8_lossy(&body))
        })
    }
}

impl Drop for TestServer {
    fn drop(&mut self) {
        self.shutdown.abort();
    }
}

// ─────────────────────────── HTTP helper ───────────────────────────

/// One-shot HTTP request. We open a fresh TCP connection per call — cheap on
/// loopback and avoids carrying any connection-pool state across tests.
async fn http_request(
    addr: SocketAddr,
    method: &str,
    path: &str,
    headers: &[(&str, String)],
    body: Vec<u8>,
) -> Result<(http::StatusCode, http::HeaderMap, Vec<u8>)> {
    let stream = TcpStream::connect(addr)
        .await
        .with_context(|| format!("connect {addr}"))?;
    let io = TokioIo::new(stream);
    let (mut sender, conn) = http1::handshake(io)
        .await
        .context("http1 handshake")?;
    let driver = tokio::spawn(async move {
        let _ = conn.await;
    });

    let mut req = http::Request::builder()
        .method(method)
        .uri(path)
        .header(http::header::HOST, addr.to_string());
    for (k, v) in headers {
        req = req.header(*k, v.as_str());
    }
    let req = req
        .body(Full::<Bytes>::from(body))
        .context("build request")?;

    let resp = sender.send_request(req).await.context("send_request")?;
    let (parts, body) = resp.into_parts();
    let bytes = body
        .collect()
        .await
        .context("collect body")?
        .to_bytes()
        .to_vec();
    driver.abort();
    Ok((parts.status, parts.headers, bytes))
}

// ─────────────────────────── TestClient ───────────────────────────

pub struct TestClient {
    pub addr: SocketAddr,
    pub token: String,
    pub session_name: String,
    pub session_id: String,
    pub client_id: String,
    pub attach_result: ses::AttachResult,
    events_rx: mpsc::UnboundedReceiver<Event>,
    events_task: Option<JoinHandle<()>>,
    /// Events pulled from `events_rx` but skipped by `expect_event` (didn't
    /// match the predicate). Searched first on the next `expect_event` call so
    /// out-of-order arrival doesn't drop matches.
    buffer: VecDeque<Event>,
}

impl TestClient {
    /// Like [`connect`] but does NOT open the /events WebSocket. Useful when a
    /// test needs to choose the `since=` parameter for the initial WS open
    /// (replay testing). Call [`spawn_events_ws`] when ready.
    pub async fn connect_no_events(
        server: &TestServer,
        session_name: &str,
        workdir: &Path,
    ) -> Result<Self> {
        Self::connect_inner(server, session_name, workdir, /*open_events=*/ false).await
    }

    /// Create a session with `workdir`, attach to it, and open the /events
    /// WebSocket. If the session already exists, only attach.
    pub async fn connect(
        server: &TestServer,
        session_name: &str,
        workdir: &Path,
    ) -> Result<Self> {
        Self::connect_inner(server, session_name, workdir, /*open_events=*/ true).await
    }

    async fn connect_inner(
        server: &TestServer,
        session_name: &str,
        workdir: &Path,
        open_events: bool,
    ) -> Result<Self> {
        let mut me = Self {
            addr: server.addr,
            token: server.token.clone(),
            session_name: session_name.to_string(),
            session_id: String::new(),
            client_id: String::new(),
            attach_result: dummy_attach_result(),
            events_rx: mpsc::unbounded_channel().1,
            events_task: None,
            buffer: VecDeque::new(),
        };
        // Try to create; tolerate "already exists" so two clients can join
        // the same session.
        let create = serde_json::json!({ "name": session_name, "workdir": workdir });
        let (status, _, body) = http_request(
            server.addr,
            "POST",
            "/rpc/session.create",
            &auth_headers(&server.token),
            to_body(&create),
        )
        .await?;
        if !status.is_success() {
            // -32008 AlreadyExists is fine; any other error fails the test.
            let err: RpcError = serde_json::from_slice(&body).unwrap_or_else(|_| RpcError::internal(format!("{status}: {}", String::from_utf8_lossy(&body))));
            if err.code != -32008 {
                bail!("session.create failed: {err:?}");
            }
        }

        // session.attach mints the session_id; capture both the body and the
        // X-Motif-Session response header.
        let attach_params = ses::AttachParams {
            name: session_name.to_string(),
            last_seq: Some(0),
            term_fg: None,
            term_bg: None,
            theme: None,
        };
        let (status, headers, body) = http_request(
            server.addr,
            "POST",
            "/rpc/session.attach",
            &auth_headers(&server.token),
            to_body(&attach_params),
        )
        .await?;
        if !status.is_success() {
            bail!("session.attach status {status}: {}", String::from_utf8_lossy(&body));
        }
        let session_id = headers
            .get(SESSION_HEADER)
            .ok_or_else(|| anyhow!("missing X-Motif-Session response header"))?
            .to_str()?
            .to_string();
        let attach: ses::AttachResult = serde_json::from_slice(&body)
            .with_context(|| format!("decode AttachResult: {}", String::from_utf8_lossy(&body)))?;
        me.session_id = session_id;
        me.client_id = attach.client_id.clone();
        me.attach_result = attach;

        // Open /events?session=<sid>. Token is sent as Authorization header so
        // we exercise the same path browsers can't (query-string token is
        // covered by the events_ws unit test).
        if open_events {
            me.spawn_events_ws(0).await?;
        }
        Ok(me)
    }

    /// Replace the events WS (close the old one if any) and start reading from
    /// `since`. Used by the replay test.
    pub async fn spawn_events_ws(&mut self, since: u64) -> Result<()> {
        // Cancel any old reader.
        if let Some(t) = self.events_task.take() {
            t.abort();
        }
        let url = format!(
            "ws://{}/events?session={}&since={}&bin=0",
            self.addr, self.session_id, since
        );
        let mut req = url.into_client_request().context("build ws request")?;
        req.headers_mut().insert(
            "authorization",
            HeaderValue::from_str(&format!("Bearer {}", self.token))?,
        );
        let (ws, _) = tokio_tungstenite::connect_async(req)
            .await
            .context("connect /events")?;
        let (tx, rx) = mpsc::unbounded_channel::<Event>();
        let task = tokio::spawn(events_reader(ws, tx));
        self.events_rx = rx;
        self.events_task = Some(task);
        Ok(())
    }

    /// Issue a POST /rpc/<method> and parse the body as `R`. Panics on
    /// HTTP-level failures; the test should call `call_raw` if it expects an
    /// error response.
    pub async fn call<P: Serialize, R: DeserializeOwned>(
        &self,
        method: &str,
        params: P,
    ) -> Result<R> {
        let body = to_body(&params);
        let path = format!("/rpc/{method}");
        let headers = with_session(&self.token, &self.session_id);
        let (status, _, body) =
            http_request(self.addr, "POST", &path, &headers, body).await?;
        if !status.is_success() {
            let err: Result<RpcError, _> = serde_json::from_slice(&body);
            match err {
                Ok(e) => bail!("rpc {method} failed ({status}): {e}"),
                Err(_) => bail!(
                    "rpc {method} failed ({status}): {}",
                    String::from_utf8_lossy(&body)
                ),
            }
        }
        serde_json::from_slice(&body).with_context(|| {
            format!(
                "decode response for {method}: {}",
                String::from_utf8_lossy(&body)
            )
        })
    }

    /// Like `call`, but returns the raw status + body so the test can assert
    /// on specific error codes.
    pub async fn call_raw<P: Serialize>(
        &self,
        method: &str,
        params: P,
    ) -> Result<(http::StatusCode, Vec<u8>)> {
        let body = to_body(&params);
        let path = format!("/rpc/{method}");
        let headers = with_session(&self.token, &self.session_id);
        let (status, _, body) =
            http_request(self.addr, "POST", &path, &headers, body).await?;
        Ok((status, body))
    }

    /// Wait up to EVENT_TIMEOUT for an event matching `pred`. Skipped events
    /// are buffered for later matches.
    pub async fn expect_event<F>(&mut self, label: &str, pred: F) -> Event
    where
        F: Fn(&Event) -> bool,
    {
        // Search buffered events first.
        if let Some(i) = self.buffer.iter().position(&pred) {
            return self.buffer.remove(i).unwrap();
        }
        let deadline = tokio::time::Instant::now() + EVENT_TIMEOUT;
        loop {
            let wait = deadline.saturating_duration_since(tokio::time::Instant::now());
            let next = match timeout(wait, self.events_rx.recv()).await {
                Ok(Some(ev)) => ev,
                Ok(None) => panic!(
                    "[{}] events channel closed while waiting for `{label}`; buffer={:?}",
                    self.client_id, self.buffer
                ),
                Err(_) => panic!(
                    "[{}] timeout ({:?}) waiting for `{label}`; buffer={:?}",
                    self.client_id, EVENT_TIMEOUT, self.buffer
                ),
            };
            if pred(&next) {
                return next;
            }
            self.buffer.push_back(next);
        }
    }

    /// Pull every event currently in-flight without blocking. Useful for
    /// asserting "nothing else arrived" or for collecting a known set.
    pub async fn drain_events(&mut self) -> Vec<Event> {
        // Give the WS reader a chance to flush anything pending.
        tokio::time::sleep(Duration::from_millis(50)).await;
        let mut out: Vec<Event> = self.buffer.drain(..).collect();
        while let Ok(ev) = self.events_rx.try_recv() {
            out.push(ev);
        }
        out
    }

    /// Open a `/pty/<id>` WebSocket for this client's session.
    pub async fn open_pty_ws(&self, pty_id: &str, since: Option<u64>) -> Result<PtyWs> {
        let mut q = format!("session={}", self.session_id);
        if let Some(s) = since {
            q.push_str(&format!("&since={s}"));
        }
        let url = format!("ws://{}/pty/{pty_id}?{q}", self.addr);
        let mut req = url.into_client_request().context("build pty ws request")?;
        req.headers_mut().insert(
            "authorization",
            HeaderValue::from_str(&format!("Bearer {}", self.token))?,
        );
        let (ws, _) = tokio_tungstenite::connect_async(req)
            .await
            .context("connect /pty/<id>")?;
        Ok(PtyWs { ws })
    }

    /// session.detach via HTTP. Implicitly closes the /events WS server-side.
    pub async fn detach(&mut self) -> Result<()> {
        let _: ses::DetachResult = self.call("session.detach", ses::DetachParams::default()).await?;
        if let Some(t) = self.events_task.take() {
            // The server closes the WS when the session is detached; give the
            // reader task a moment to notice, then drop it.
            tokio::time::sleep(Duration::from_millis(30)).await;
            t.abort();
        }
        Ok(())
    }
}

impl Drop for TestClient {
    fn drop(&mut self) {
        if let Some(t) = self.events_task.take() {
            t.abort();
        }
    }
}

// ─────────────────────────── /pty/<id> WS ───────────────────────────

pub struct PtyWs {
    ws: tokio_tungstenite::WebSocketStream<
        tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
    >,
}

impl PtyWs {
    /// Read raw bytes until we either accumulate something matching `needle`
    /// or hit `timeout_total`. Returns the full byte log so callers can assert
    /// on it.
    pub async fn read_until(&mut self, needle: &[u8], timeout_total: Duration) -> Result<Vec<u8>> {
        let deadline = tokio::time::Instant::now() + timeout_total;
        let mut buf: Vec<u8> = Vec::new();
        while tokio::time::Instant::now() < deadline {
            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            match timeout(remaining, self.ws.next()).await {
                Ok(Some(Ok(Message::Binary(b)))) => {
                    buf.extend_from_slice(&b);
                    if find_subslice(&buf, needle).is_some() {
                        return Ok(buf);
                    }
                }
                Ok(Some(Ok(_other))) => continue,
                Ok(Some(Err(e))) => bail!("/pty ws read error: {e}"),
                Ok(None) => bail!("/pty ws closed while waiting for {:?}", String::from_utf8_lossy(needle)),
                Err(_) => {
                    bail!(
                        "/pty ws timeout after {:?}; got {:?}",
                        timeout_total,
                        String::from_utf8_lossy(&buf),
                    )
                }
            }
        }
        bail!(
            "/pty ws timeout after {:?}; got {:?}",
            timeout_total,
            String::from_utf8_lossy(&buf),
        );
    }

    /// Send raw input bytes to the PTY as a binary frame — the same path
    /// the web/iOS clients use for keystrokes now that the HTTP `pty.write`
    /// fallback is gone.
    pub async fn write(&mut self, data: &[u8]) -> Result<()> {
        use futures_util::SinkExt;
        self.ws
            .send(Message::Binary(Bytes::copy_from_slice(data)))
            .await?;
        Ok(())
    }
}

fn find_subslice(hay: &[u8], needle: &[u8]) -> Option<usize> {
    hay.windows(needle.len()).position(|w| w == needle)
}

// ─────────────────────────── events WS reader ───────────────────────────

async fn events_reader(
    mut ws: tokio_tungstenite::WebSocketStream<
        tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
    >,
    tx: mpsc::UnboundedSender<Event>,
) {
    while let Some(item) = ws.next().await {
        let msg = match item {
            Ok(m) => m,
            Err(_) => break,
        };
        let text = match msg {
            Message::Text(t) => t.to_string(),
            Message::Close(_) => break,
            _ => continue,
        };
        // Wire format is a JSON-RPC Notification — peel off the envelope, then
        // re-wrap as `{method, params}` so the adjacently-tagged Event enum
        // deserializes cleanly (without tripping on the extra `jsonrpc` field).
        let notif: Notification = match serde_json::from_str(&text) {
            Ok(n) => n,
            Err(_) => continue,
        };
        let val = serde_json::json!({ "method": notif.method, "params": notif.params });
        let event: Event = match serde_json::from_value(val) {
            Ok(e) => e,
            Err(_) => continue,
        };
        if tx.send(event).is_err() {
            break;
        }
    }
}

// ─────────────────────────── helpers ───────────────────────────

pub fn auth_headers(token: &str) -> Vec<(&'static str, String)> {
    let owned = vec![("authorization", format!("Bearer {token}"))];
    // Convert to (&'static str, String) — caller adapts to (&str, &str).
    owned
}

fn with_session(token: &str, sid: &str) -> Vec<(&'static str, String)> {
    vec![
        ("authorization", format!("Bearer {token}")),
        (SESSION_HEADER, sid.to_string()),
    ]
}

fn to_body<P: Serialize>(p: &P) -> Vec<u8> {
    serde_json::to_vec(p).expect("serialize params")
}

fn dummy_attach_result() -> ses::AttachResult {
    ses::AttachResult {
        session: ses::SessionInfo {
            id: String::new(),
            name: String::new(),
            workdir: std::path::PathBuf::new(),
            created_at: 0,
            client_count: 0,
        },
        client_id: String::new(),
        clients: vec![],
        ptys: vec![],
        views: vec![],
        active_view: None,
        last_seq: 0,
        theme: None,
    }
}

// `auth_headers` returns `Vec<(&str, String)>`; rebind to slice of refs in
// callers because `http_request` wants `&[(&str, &str)]`.
//
// Tests use `auth_headers(&t).iter().map(|(k,v)| (*k, v.as_str())).collect::<Vec<_>>()`
// inline if they need a fresh request without the session header.
//
// (Helper exposed for the small number of bare requests in `connect`.)

// ─────────────────────────── git fixture ───────────────────────────

/// Run `git init` + `git commit` so `git.*` RPCs have a real repo to chew on.
/// Returns Err if `git` is missing — callers should early-return the test.
pub fn init_git_repo(workdir: &Path) -> Result<()> {
    let must = |label: &str, args: &[&str]| -> Result<()> {
        let status = Command::new("git")
            .args(args)
            .current_dir(workdir)
            .status()
            .with_context(|| format!("spawn git {label}"))?;
        if !status.success() {
            bail!("git {label} failed: exit {status}");
        }
        Ok(())
    };
    must("init", &["init", "-q", "-b", "main"])?;
    must("config email", &["config", "user.email", "test@motif.invalid"])?;
    must("config name", &["config", "user.name", "Motif Test"])?;
    std::fs::write(workdir.join("README.md"), b"hello\n").context("write README.md")?;
    must("add", &["add", "."])?;
    must("commit", &["commit", "-q", "-m", "init"])?;
    Ok(())
}

/// Convenience: `b64.decode(s)`.
pub fn b64_decode(s: &str) -> Vec<u8> {
    base64::engine::general_purpose::STANDARD
        .decode(s.as_bytes())
        .expect("decode base64")
}

pub fn b64_encode(b: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(b)
}
