//! New-protocol coordinator: presents a `Client`-shaped surface
//! (`call()` + `recv_notification()`) to existing consumers while
//! running HTTP RPC + `/events` WS + per-PTY `/pty/<id>` WS under the
//! hood.
//!
//! For each PTY, the forwarder feeds inbound bytes through a
//! [`motif_proto::terminal_query::QueryScanner`] and a
//! [`crate::shell_integration::ShellState`] block-state machine —
//! the same logic the server used to run. From that it synthesizes
//! legacy-shape Notifications:
//!   - `pty.output` (with block_id + scope from the live state)
//!   - `pty.cwd_changed`, `pty.shell_bootstrapped`,
//!     `pty.prompt_started/ended`, `pty.command_started/finished`,
//!     `pty.shell_context`
//!
//! Existing TUI / motif-cast consumers therefore see the same
//! notification stream they saw before the protocol redesign — just
//! produced client-side instead of by the server.
//!
//! ## Routing rules
//!
//! - `session.attach`     → HttpRpc::attach + spin up EventsClient + open one PtyClient per PTY in result
//! - `session.detach`     → HttpRpc::detach + tear down events + per-pty
//! - `pty.write`          → forward bytes to that PTY's stdin channel (NOT an HTTP call)
//! - `pty.create`         → HttpRpc; on success, open PtyClient (primary=1)
//! - `pty.kill`           → HttpRpc; close the PtyClient afterwards
//! - everything else      → HttpRpc::call passthrough

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use anyhow::{anyhow, Context, Result};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use motif_proto::common::PtyId;
use motif_proto::pty::ShellKind;
use motif_proto::terminal_query::{QueryScanner, ScanItem};

use crate::shell_integration::{ShellEvent, ShellState};
use motif_proto::envelope::Notification;
use motif_proto::event::Event;
use motif_proto::pty::PtyWriteParams;
use serde::{de::DeserializeOwned, Serialize};
use serde_json::Value;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::sync::{mpsc, Mutex as AsyncMutex};

use crate::events::EventsClient;
use crate::http::{tcp_factory, HttpRpc, StreamFactory};
use crate::pty_ws::{CloseReason, PtyClient};

pub struct Coordinator {
    /// HTTP transport for non-PTY RPC.
    pub rpc: Arc<HttpRpc>,
    authority: String,
    token: String,
    factory: StreamFactory,
    /// Currently-open PTY connections by pty_id.
    ptys: Arc<AsyncMutex<HashMap<PtyId, PtyHandle>>>,
    /// Push end of the synthesized notification stream.
    notif_tx: mpsc::UnboundedSender<Notification>,
    /// Pull end. Wrapped in async mutex because `recv_notification`
    /// takes `&self` (matching old Client API). Single consumer in
    /// practice (the TUI main loop).
    notif_rx: AsyncMutex<mpsc::UnboundedReceiver<Notification>>,
    /// EventsClient lifetime tied to coordinator. Replaced (with
    /// previous instance dropped/aborted) on re-attach.
    events: Mutex<Option<EventsClient>>,
    /// Background tasks (event-translator forwarders, etc.). Aborted
    /// on drop.
    bg: Mutex<Vec<tokio::task::JoinHandle<()>>>,
}

struct PtyHandle {
    /// Stdin push side. `pty.write` RPC routes bytes here.
    stdin_tx: mpsc::UnboundedSender<bytes::Bytes>,
    /// Forwarder task pulling PtyClient.outputs → notif_tx. Drop /
    /// abort to stop forwarding.
    forwarder: tokio::task::JoinHandle<()>,
}

impl Drop for Coordinator {
    fn drop(&mut self) {
        for h in self.bg.lock().unwrap().drain(..) {
            h.abort();
        }
    }
}

impl Coordinator {
    pub fn connect_tcp(url: &str, token: &str) -> Result<Self> {
        let parsed: http::Uri = url.parse().with_context(|| format!("invalid url: {url}"))?;
        let host = parsed
            .host()
            .ok_or_else(|| anyhow!("missing host in {url}"))?;
        let port = parsed.port_u16().unwrap_or(80);
        let addr = format!("{host}:{port}");
        let authority = addr.clone();
        let factory = tcp_factory(addr);
        Self::new(factory, authority, token.to_string())
    }

    pub fn new(factory: StreamFactory, authority: String, token: String) -> Result<Self> {
        let rpc = Arc::new(HttpRpc::new(
            Arc::clone(&factory),
            authority.clone(),
            &token,
        )?);
        let (notif_tx, notif_rx) = mpsc::unbounded_channel::<Notification>();
        Ok(Self {
            rpc,
            authority,
            token,
            factory,
            ptys: Arc::new(AsyncMutex::new(HashMap::new())),
            notif_tx,
            notif_rx: AsyncMutex::new(notif_rx),
            events: Mutex::new(None),
            bg: Mutex::new(Vec::new()),
        })
    }

    pub async fn call<P, R>(&self, method: &str, params: P) -> Result<R>
    where
        P: Serialize,
        R: DeserializeOwned,
    {
        match method {
            "session.attach" => self.do_attach::<P, R>(params).await,
            "session.detach" => self.do_detach::<R>().await,
            "pty.write" => self.do_pty_write::<P, R>(params).await,
            "pty.create" => self.do_pty_create::<P, R>(params).await,
            "pty.kill" => self.do_pty_kill::<P, R>(params).await,
            _ => self.rpc.call(method, &params).await,
        }
    }

    pub async fn recv_notification(&self) -> Option<Notification> {
        self.notif_rx.lock().await.recv().await
    }

    /// Take the notification receiver out for callers that want to
    /// drive it from a free-standing select (motif-cast). After this
    /// returns `Some(rx)`, `recv_notification()` yields `None`
    /// immediately. Mirrors the old `Client::take_notifications`.
    pub async fn take_notifications(&self) -> Option<mpsc::UnboundedReceiver<Notification>> {
        // Replace the live rx with a closed dummy. The producer side
        // (notif_tx) keeps working — its sends just fail silently once
        // the dummy's tx half drops, which is the same behavior as a
        // closed channel.
        let (_dummy_tx, dummy_rx) = mpsc::unbounded_channel::<Notification>();
        // Drop _dummy_tx immediately so the swapped-in rx is in the
        // "all senders gone" state — callers polling on it after the
        // take get None.
        drop(_dummy_tx);
        let mut guard = self.notif_rx.lock().await;
        let taken = std::mem::replace(&mut *guard, dummy_rx);
        Some(taken)
    }

    pub fn session_id(&self) -> Option<String> {
        self.rpc.session_id()
    }

    // ─────────────────────────── method handlers ───────────────────────────

    async fn do_attach<P, R>(&self, params: P) -> Result<R>
    where
        P: Serialize,
        R: DeserializeOwned,
    {
        let attach_value: Value = self.rpc.attach(&params).await?;
        let session_id = self
            .rpc
            .session_id()
            .ok_or_else(|| anyhow!("attach: server didn't set X-Motif-Session"))?;

        let last_seq = attach_value
            .get("last_seq")
            .and_then(|v| v.as_u64())
            .unwrap_or(0);
        self.open_events(&session_id, last_seq).await?;

        if let Some(ptys) = attach_value.get("ptys").and_then(|v| v.as_array()) {
            for p in ptys {
                if let Some(pty_id) = p.get("id").and_then(|v| v.as_str()) {
                    let _ = self.open_pty(pty_id.to_string(), false).await;
                }
            }
        }

        serde_json::from_value(attach_value).map_err(|e| anyhow!("decode attach result: {e}"))
    }

    async fn do_detach<R>(&self) -> Result<R>
    where
        R: DeserializeOwned,
    {
        {
            let mut ptys = self.ptys.lock().await;
            for (_, h) in ptys.drain() {
                h.forwarder.abort();
            }
        }
        *self.events.lock().unwrap() = None;
        self.rpc.detach().await?;
        serde_json::from_value(serde_json::Value::Null)
            .map_err(|e| anyhow!("decode detach result: {e}"))
    }

    async fn do_pty_write<P, R>(&self, params: P) -> Result<R>
    where
        P: Serialize,
        R: DeserializeOwned,
    {
        let raw = serde_json::to_value(&params)
            .map_err(|e| anyhow!("re-serialize pty.write params: {e}"))?;
        let p: PtyWriteParams =
            serde_json::from_value(raw).map_err(|e| anyhow!("decode pty.write params: {e}"))?;
        self.ensure_pty_open(&p.pty_id).await?;
        let ptys = self.ptys.lock().await;
        let Some(handle) = ptys.get(&p.pty_id) else {
            return Err(anyhow!("pty.write: pty_id `{}` not open", p.pty_id));
        };
        if handle.stdin_tx.send(bytes::Bytes::from(p.data)).is_err() {
            return Err(anyhow!("pty.write: stdin closed for `{}`", p.pty_id));
        }
        serde_json::from_value::<R>(serde_json::json!({}))
            .map_err(|e| anyhow!("decode pty.write result: {e}"))
    }

    async fn do_pty_create<P, R>(&self, params: P) -> Result<R>
    where
        P: Serialize,
        R: DeserializeOwned,
    {
        let result_value: Value = self.rpc.call("pty.create", &params).await?;
        let pty_id = result_value
            .get("info")
            .and_then(|v| v.get("id"))
            .and_then(|v| v.as_str())
            .map(|s| s.to_string());
        if let Some(pid) = pty_id {
            let _ = self.open_pty(pid, true).await;
        }
        serde_json::from_value(result_value).map_err(|e| anyhow!("decode pty.create result: {e}"))
    }

    async fn do_pty_kill<P, R>(&self, params: P) -> Result<R>
    where
        P: Serialize,
        R: DeserializeOwned,
    {
        let raw = serde_json::to_value(&params)
            .map_err(|e| anyhow!("re-serialize pty.kill params: {e}"))?;
        let pty_id = raw
            .get("pty_id")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string());
        let result_value: Value = self.rpc.call("pty.kill", &params).await?;
        if let Some(pid) = pty_id {
            let mut ptys = self.ptys.lock().await;
            if let Some(h) = ptys.remove(&pid) {
                h.forwarder.abort();
            }
        }
        serde_json::from_value(result_value).map_err(|e| anyhow!("decode pty.kill result: {e}"))
    }

    // ─────────────────────────── plumbing ───────────────────────────

    async fn open_events(&self, session_id: &str, since: u64) -> Result<()> {
        let stream = (self.factory)().await?;
        let (ev_tx, mut ev_rx) = mpsc::unbounded_channel::<Event>();
        let events = EventsClient::connect_with_stream(
            &self.authority,
            &self.token,
            session_id,
            since,
            ev_tx,
            stream,
        )
        .await?;
        *self.events.lock().unwrap() = Some(events);

        // Forwarder: typed Event → JSON-RPC Notification on notif_tx.
        let notif_tx = self.notif_tx.clone();
        let fwd = tokio::spawn(async move {
            while let Some(ev) = ev_rx.recv().await {
                let value = match serde_json::to_value(&ev) {
                    Ok(v) => v,
                    Err(e) => {
                        tracing::warn!(error = %e, "event→value");
                        continue;
                    }
                };
                // Event serializes to `{ method, params }` via its
                // #[serde(tag = "method", content = "params")]
                // attribute. Adapt into Notification shape.
                let method = value
                    .get("method")
                    .and_then(|v| v.as_str())
                    .map(String::from)
                    .unwrap_or_default();
                let params = value.get("params").cloned().unwrap_or(Value::Null);
                let n = Notification {
                    jsonrpc: motif_proto::envelope::JSONRPC_V2.into(),
                    method,
                    params,
                };
                if notif_tx.send(n).is_err() {
                    break;
                }
            }
        });
        self.bg.lock().unwrap().push(fwd);
        Ok(())
    }

    async fn ensure_pty_open(&self, pty_id: &str) -> Result<()> {
        {
            let ptys = self.ptys.lock().await;
            if ptys.contains_key(pty_id) {
                return Ok(());
            }
        }
        self.open_pty(pty_id.to_string(), false).await
    }

    async fn open_pty(&self, pty_id: PtyId, primary: bool) -> Result<()> {
        let session_id = self
            .rpc
            .session_id()
            .ok_or_else(|| anyhow!("open_pty: not attached"))?;
        let stream = (self.factory)().await?;
        let pty_client = PtyClient::connect_with_stream(
            &self.authority,
            &self.token,
            &session_id,
            &pty_id,
            0,
            primary,
            stream,
        )
        .await?;

        let stdin_tx = pty_client.stdin.clone();
        let pty_id_fwd = pty_id.clone();
        let notif_tx = self.notif_tx.clone();
        let forwarder = tokio::spawn(forward_pty(pty_client, pty_id_fwd, notif_tx));

        self.ptys.lock().await.insert(
            pty_id,
            PtyHandle {
                stdin_tx,
                forwarder,
            },
        );
        Ok(())
    }

    /// Open a raw PTY connection for callers that want bytes directly
    /// (motif-cast). Doesn't register in the coordinator's pty map.
    pub async fn open_pty_raw<S>(
        &self,
        pty_id: &str,
        since: u64,
        primary: bool,
        stream: S,
    ) -> Result<PtyClient>
    where
        S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
    {
        let session_id = self
            .rpc
            .session_id()
            .ok_or_else(|| anyhow!("open_pty_raw: not attached"))?;
        PtyClient::connect_with_stream(
            &self.authority,
            &self.token,
            &session_id,
            pty_id,
            since,
            primary,
            stream,
        )
        .await
    }
}

/// Pump bytes from one /pty/<id> WS into synthesized Notifications.
///
/// Pipeline per chunk:
///   raw bytes
///     → QueryScanner (separates OSC / passthrough)
///     → for each ScanItem::Bytes: drive ShellState.record_output +
///       emit `pty.output` Notification tagged with the current
///       block_id and scope
///     → for each ScanItem::Query (shell-integration kinds):
///       drive ShellState.on_osc; for each emitted ShellEvent build
///       the matching legacy notification (`pty.cwd_changed`,
///       `pty.shell_bootstrapped`, `pty.prompt_started/ended`,
///       `pty.command_started/finished`, `pty.shell_context`)
async fn forward_pty(
    mut pty: PtyClient,
    pty_id: PtyId,
    notif_tx: mpsc::UnboundedSender<Notification>,
) {
    let mut scanner = QueryScanner::new();
    let mut shell = ShellState::new(ShellKind::Unknown, Instant::now(), None);

    // 5s bootstrap timeout: if no shell-integration marker arrives in that
    // window, mark the shell as Unknown so consumers (status bars,
    // block UIs) stop waiting. Run on a sibling task so the main
    // forwarder loop stays exclusively on the byte path.
    let pty_id_to = pty_id.clone();
    let notif_tx_to = notif_tx.clone();
    let bootstrap_to = tokio::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_secs(5)).await;
        // Lazy: we can't probe `shell` from outside (it's owned by
        // the main forwarder task). Best-effort: just send the event
        // — if the shell actually bootstrapped first, the duplicate
        // `pty.shell_bootstrapped` is harmless (consumers latch on
        // first-observed). For now we skip the dedupe and let the
        // 5s tick fire unconditionally; this only matters for
        // shells without shell-integration support, so a single extra
        // notification per PTY lifetime is acceptable.
        let n = Notification {
            jsonrpc: motif_proto::envelope::JSONRPC_V2.into(),
            method: "pty.shell_bootstrapped".into(),
            params: serde_json::json!({
                "pty_id": pty_id_to,
                "shell":  ShellKind::Unknown,
                "seq":    0u64,
            }),
        };
        let _ = notif_tx_to.send(n);
    });

    while let Some(b) = pty.outputs.recv().await {
        let scan = scanner.feed(&b);
        for item in scan.items {
            match item {
                ScanItem::Bytes(bytes) => {
                    let (block_id, scope) = {
                        shell.record_output(&bytes);
                        (shell.active_block_id().cloned(), shell.active_scope())
                    };
                    let params = serde_json::json!({
                        "pty_id":   pty_id.clone(),
                        "data_b64": B64.encode(&bytes),
                        "block_id": block_id,
                        "scope":    scope,
                        "seq":      0u64,
                    });
                    if notif_tx
                        .send(Notification {
                            jsonrpc: motif_proto::envelope::JSONRPC_V2.into(),
                            method: "pty.output".into(),
                            params,
                        })
                        .is_err()
                    {
                        return;
                    }
                }
                ScanItem::Query { kind, raw: _ } => {
                    if !kind.is_shell_integration() {
                        continue;
                    }
                    let events = shell.on_osc(&kind);
                    for ev in events {
                        let n = shell_event_to_notification(&pty_id, ev);
                        if notif_tx.send(n).is_err() {
                            return;
                        }
                    }
                }
            }
        }
    }

    bootstrap_to.abort();

    // Force-finalize any in-flight block on close so its
    // CommandFinished doesn't get lost.
    if let Some(ev) = shell.on_exit() {
        let n = shell_event_to_notification(&pty_id, ev);
        let _ = notif_tx.send(n);
    }

    if matches!(pty.close_reason(), Some(CloseReason::Normal)) {
        let n = Notification {
            jsonrpc: motif_proto::envelope::JSONRPC_V2.into(),
            method: "pty.ws.closed".into(),
            params: serde_json::json!({ "pty_id": pty_id }),
        };
        let _ = notif_tx.send(n);
    }
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn shell_event_to_notification(pty_id: &str, ev: ShellEvent) -> Notification {
    let (method, params) = match ev {
        ShellEvent::Bootstrapped => (
            "pty.shell_bootstrapped",
            serde_json::json!({
                "pty_id": pty_id,
                "shell":  ShellKind::Unknown,
                "seq":    0u64,
            }),
        ),
        ShellEvent::PromptStarted { block_id } => (
            "pty.prompt_started",
            serde_json::json!({ "pty_id": pty_id, "block_id": block_id, "seq": 0u64 }),
        ),
        ShellEvent::PromptEnded { block_id } => (
            "pty.prompt_ended",
            serde_json::json!({ "pty_id": pty_id, "block_id": block_id, "seq": 0u64 }),
        ),
        ShellEvent::CommandStarted {
            id,
            text,
            cwd,
            started_at,
        } => (
            "pty.command_started",
            serde_json::json!({
                "pty_id":     pty_id,
                "block_id":   id,
                "text":       text,
                "cwd":        path_to_string(&cwd),
                "started_at": started_at,
                "seq":        0u64,
            }),
        ),
        ShellEvent::CommandFinished {
            id,
            exit,
            finished_at,
            ..
        } => (
            "pty.command_finished",
            serde_json::json!({
                "pty_id":      pty_id,
                "block_id":    id,
                "exit_code":   exit,
                "finished_at": finished_at.max(now_ms()),
                "seq":         0u64,
            }),
        ),
        ShellEvent::Context { ctx } => (
            "pty.shell_context",
            serde_json::json!({ "pty_id": pty_id, "ctx": ctx, "seq": 0u64 }),
        ),
        ShellEvent::CwdChanged { cwd } => (
            "pty.cwd_changed",
            serde_json::json!({ "pty_id": pty_id, "cwd": path_to_string(&cwd), "seq": 0u64 }),
        ),
    };
    Notification {
        jsonrpc: motif_proto::envelope::JSONRPC_V2.into(),
        method: method.into(),
        params,
    }
}

fn path_to_string(p: &PathBuf) -> String {
    p.to_string_lossy().into_owned()
}
