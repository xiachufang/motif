//! New-protocol coordinator: thin façade over `HttpRpc` + `EventsClient`.
//!
//! The new wire protocol (see `docs/rpc.md`) splits transport into three
//! channels:
//!   * `POST /rpc/<method>` for control-plane RPC,
//!   * `WS /events` for the 12 structured server events,
//!   * `WS /pty/<id>` raw byte stream for PTY output + stdin.
//!
//! `Coordinator` owns the first two; callers drive the PTY streams
//! themselves through [`Coordinator::open_pty`], which hands back a fresh
//! [`PtyClient`]. There is no client-side synthesis of legacy
//! `pty.output` / `pty.command_*` / `pty.cwd_changed` notifications —
//! shell-integration parsing happens in the consumer (motif-tui /
//! motif-cast).
//!
//! ## Routing rules
//!
//! - `session.attach`     → HttpRpc::attach + spin up EventsClient
//! - `session.detach`     → HttpRpc::detach + tear down events
//! - everything else      → HttpRpc::call passthrough
//!
//! PTY input goes to `PtyClient.stdin`; PTY output comes from
//! `PtyClient.outputs`. Neither path crosses the JSON-RPC notification
//! stream.

use std::sync::{Arc, Mutex};

use anyhow::{anyhow, Context, Result};
use serde::{de::DeserializeOwned, Serialize};
use serde_json::Value;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::sync::{mpsc, Mutex as AsyncMutex};

use motif_proto::envelope::Notification;
use motif_proto::event::Event;

use crate::events::EventsClient;
use crate::http::{tcp_factory, HttpRpc, StreamFactory};
use crate::pty_ws::PtyClient;

pub struct Coordinator {
    /// HTTP transport for non-PTY RPC.
    pub rpc: Arc<HttpRpc>,
    authority: String,
    token: String,
    factory: StreamFactory,
    /// Push end of the structured event stream (the 12 real `/events`
    /// notifications).
    notif_tx: mpsc::UnboundedSender<Notification>,
    /// Pull end. Wrapped in async mutex because `recv_notification`
    /// takes `&self`. Single consumer in practice (the TUI main loop).
    notif_rx: AsyncMutex<mpsc::UnboundedReceiver<Notification>>,
    /// EventsClient lifetime tied to coordinator. Replaced (with
    /// previous instance dropped/aborted) on re-attach.
    events: Mutex<Option<EventsClient>>,
    /// Background tasks (event forwarder). Aborted on drop.
    bg: Mutex<Vec<tokio::task::JoinHandle<()>>>,
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
            _ => self.rpc.call(method, &params).await,
        }
    }

    /// `GET /ping` identity probe — confirm the target is a motif-server
    /// before opening a session. Delegates to the HTTP transport.
    pub async fn ping(&self) -> Result<motif_proto::ping::PingInfo> {
        self.rpc.ping().await
    }

    pub async fn recv_notification(&self) -> Option<Notification> {
        self.notif_rx.lock().await.recv().await
    }

    /// Take the notification receiver out for callers that want to
    /// drive it from a free-standing select (motif-cast). After this
    /// returns `Some(rx)`, `recv_notification()` yields `None`
    /// immediately.
    pub async fn take_notifications(&self) -> Option<mpsc::UnboundedReceiver<Notification>> {
        // Replace the live rx with a closed dummy. The producer side
        // (notif_tx) keeps working — its sends just fail silently once
        // the dummy's tx half drops.
        let (_dummy_tx, dummy_rx) = mpsc::unbounded_channel::<Notification>();
        drop(_dummy_tx);
        let mut guard = self.notif_rx.lock().await;
        let taken = std::mem::replace(&mut *guard, dummy_rx);
        Some(taken)
    }

    pub fn session_id(&self) -> Option<String> {
        self.rpc.session_id()
    }

    /// Open a `/pty/<id>` WebSocket. Callers own the returned
    /// [`PtyClient`] and decide when to drop it. `since` is the byte
    /// offset to resume from (0 = tail; equivalent to omitting `?since=`
    /// on the wire, but server-side both paths converge once the meta
    /// frame is sent).
    pub async fn open_pty(&self, pty_id: &str, since: u64) -> Result<PtyClient> {
        let session_id = self
            .rpc
            .session_id()
            .ok_or_else(|| anyhow!("open_pty: not attached"))?;
        let stream = (self.factory)().await?;
        PtyClient::connect_with_stream(
            &self.authority,
            &self.token,
            &session_id,
            pty_id,
            since,
            stream,
        )
        .await
    }

    /// Same as [`Self::open_pty`] but the caller supplies the duplex
    /// stream (used by motif-cast when it wants to layer its own
    /// transport).
    pub async fn open_pty_raw<S>(&self, pty_id: &str, since: u64, stream: S) -> Result<PtyClient>
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
            stream,
        )
        .await
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

        serde_json::from_value(attach_value).map_err(|e| anyhow!("decode attach result: {e}"))
    }

    async fn do_detach<R>(&self) -> Result<R>
    where
        R: DeserializeOwned,
    {
        *self.events.lock().unwrap() = None;
        self.rpc.detach().await?;
        serde_json::from_value(serde_json::Value::Null)
            .map_err(|e| anyhow!("decode detach result: {e}"))
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
}
