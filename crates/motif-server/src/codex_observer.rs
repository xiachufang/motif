//! Persistent, server-owned Codex app-server observer.
//!
//! The normal `/codex` endpoint remains a transparent one-client/one-upstream
//! proxy. Before that proxy forwards `turn/start`, this observer subscribes to
//! the target thread on its own long-lived app-server connection. It therefore
//! keeps receiving approval requests and the terminal `turn/completed` event
//! when the mobile WebSocket disappears mid-turn.

use std::collections::{HashMap, HashSet};
use std::net::SocketAddr;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use futures_util::stream::{SplitSink, SplitStream};
use futures_util::{SinkExt, StreamExt};
use parking_lot::Mutex;
use serde_json::{json, Value};
use tokio::net::TcpStream;
use tokio::sync::{mpsc, oneshot};
use tokio::time::{timeout, Instant, MissedTickBehavior};
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::WebSocketStream;
use tokio_util::sync::CancellationToken;

use crate::codex_app_server::CodexAppServer;
use crate::relay::{DeviceState, PushNotification};

const PREPARE_TIMEOUT: Duration = Duration::from_secs(10);
const START_CONFIRM_TIMEOUT: Duration = Duration::from_secs(30);
const RECONNECT_DELAY: Duration = Duration::from_millis(250);
const INITIALIZE_ID: u64 = 0;

type ObserverSocket = WebSocketStream<TcpStream>;
type ObserverSink = SplitSink<ObserverSocket, Message>;
type ObserverStream = SplitStream<ObserverSocket>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PreparedTurn {
    pub thread_id: String,
    generation: u64,
}

#[derive(Debug, thiserror::Error)]
pub enum CodexObserverError {
    #[error("codex observer command channel is closed")]
    Closed,
    #[error("codex observer did not subscribe within 10 seconds")]
    Timeout,
    #[error("codex observer could not subscribe: {0}")]
    Subscribe(String),
}

struct WorkerHandle {
    address: SocketAddr,
    commands: mpsc::UnboundedSender<Command>,
    cancel: CancellationToken,
}

pub struct CodexObserver {
    devices: DeviceState,
    worker: Mutex<Option<WorkerHandle>>,
    next_generation: AtomicU64,
}

impl CodexObserver {
    pub fn new(devices: DeviceState) -> Arc<Self> {
        Arc::new(Self {
            devices,
            worker: Mutex::new(None),
            next_generation: AtomicU64::new(1),
        })
    }

    /// Ensure the observer has subscribed before the caller forwards the
    /// corresponding `turn/start` to app-server.
    pub async fn prepare_turn(
        &self,
        runtime: Arc<CodexAppServer>,
        thread_id: &str,
    ) -> Result<PreparedTurn, CodexObserverError> {
        let thread_id = thread_id.to_string();
        let generation = self.next_generation.fetch_add(1, Ordering::Relaxed);
        // A server without a push relay has nowhere to deliver a reminder.
        // Keep its Codex proxy behavior unchanged and avoid introducing an
        // observer dependency into installations that disabled notifications.
        if self.devices.relay.is_none() {
            return Ok(PreparedTurn {
                thread_id,
                generation,
            });
        }
        let commands = self.commands_for(runtime);
        let (reply_tx, reply_rx) = oneshot::channel();
        commands
            .send(Command::Prepare {
                thread_id: thread_id.clone(),
                generation,
                reply: reply_tx,
            })
            .map_err(|_| CodexObserverError::Closed)?;

        match timeout(PREPARE_TIMEOUT, reply_rx).await {
            Ok(Ok(Ok(()))) => Ok(PreparedTurn {
                thread_id,
                generation,
            }),
            Ok(Ok(Err(error))) => Err(CodexObserverError::Subscribe(error)),
            Ok(Err(_)) => Err(CodexObserverError::Closed),
            Err(_) => {
                let _ = commands.send(Command::Cancel {
                    thread_id,
                    generation,
                });
                Err(CodexObserverError::Timeout)
            }
        }
    }

    /// Mark a forwarded `turn/start` response as successful. `turn/started`
    /// also confirms it, which covers a mobile disconnect before the response
    /// reaches the proxy.
    pub fn confirm_turn(&self, prepared: PreparedTurn) {
        if let Some(commands) = self.current_commands() {
            let _ = commands.send(Command::Confirm {
                thread_id: prepared.thread_id,
                generation: prepared.generation,
            });
        }
    }

    /// Roll back a prepared subscription when app-server rejects `turn/start`.
    pub fn cancel_turn(&self, prepared: PreparedTurn) {
        if let Some(commands) = self.current_commands() {
            let _ = commands.send(Command::Cancel {
                thread_id: prepared.thread_id,
                generation: prepared.generation,
            });
        }
    }

    pub fn stop(&self) {
        if let Some(worker) = self.worker.lock().take() {
            worker.cancel.cancel();
        }
    }

    fn current_commands(&self) -> Option<mpsc::UnboundedSender<Command>> {
        self.worker
            .lock()
            .as_ref()
            .filter(|worker| !worker.commands.is_closed())
            .map(|worker| worker.commands.clone())
    }

    fn commands_for(&self, runtime: Arc<CodexAppServer>) -> mpsc::UnboundedSender<Command> {
        let address = runtime.address();
        let mut worker_slot = self.worker.lock();
        if let Some(worker) = worker_slot
            .as_ref()
            .filter(|worker| worker.address == address && !worker.commands.is_closed())
        {
            return worker.commands.clone();
        }
        if let Some(stale) = worker_slot.take() {
            stale.cancel.cancel();
        }

        let (commands, command_rx) = mpsc::unbounded_channel();
        let cancel = CancellationToken::new();
        let worker_cancel = cancel.clone();
        let devices = self.devices.clone();
        let exited = runtime.subscribe_exit();
        tokio::spawn(async move {
            run_worker(address, devices, command_rx, worker_cancel, exited).await;
        });
        *worker_slot = Some(WorkerHandle {
            address,
            commands: commands.clone(),
            cancel,
        });
        commands
    }
}

enum Command {
    Prepare {
        thread_id: String,
        generation: u64,
        reply: oneshot::Sender<Result<(), String>>,
    },
    Confirm {
        thread_id: String,
        generation: u64,
    },
    Cancel {
        thread_id: String,
        generation: u64,
    },
}

#[derive(Default)]
struct ThreadWatch {
    pending_starts: HashMap<u64, Instant>,
    waiters: HashMap<u64, oneshot::Sender<Result<(), String>>>,
    running: bool,
    notified_requests: HashSet<String>,
}

enum PendingRpc {
    Resume(String),
    Unsubscribe(String),
}

#[derive(Default)]
struct WorkerState {
    watches: HashMap<String, ThreadWatch>,
    subscribed: HashSet<String>,
    pending_rpcs: HashMap<u64, PendingRpc>,
    next_request_id: u64,
}

impl WorkerState {
    fn new() -> Self {
        Self {
            next_request_id: 1,
            ..Self::default()
        }
    }

    fn reset_connection(&mut self) {
        self.subscribed.clear();
        self.pending_rpcs.clear();
    }

    fn has_pending_rpc(&self, thread_id: &str) -> bool {
        self.pending_rpcs.values().any(|pending| match pending {
            PendingRpc::Resume(thread) | PendingRpc::Unsubscribe(thread) => thread == thread_id,
        })
    }

    fn next_id(&mut self) -> u64 {
        let id = self.next_request_id;
        self.next_request_id = self.next_request_id.saturating_add(1);
        id
    }
}

async fn run_worker(
    address: SocketAddr,
    devices: DeviceState,
    mut commands: mpsc::UnboundedReceiver<Command>,
    cancel: CancellationToken,
    mut exited: tokio::sync::watch::Receiver<bool>,
) {
    let mut state = WorkerState::new();
    loop {
        if cancel.is_cancelled() || *exited.borrow() {
            fail_waiters(&mut state, "codex app-server stopped");
            return;
        }
        match connect_initialized(address).await {
            Ok(socket) => {
                tracing::info!(%address, "codex observer connected");
                state.reset_connection();
                let (mut sink, mut stream) = socket.split();
                if let Err(error) = restore_subscriptions(&mut state, &mut sink).await {
                    tracing::debug!(%error, "codex observer subscription restore failed");
                } else if run_connected(
                    &mut state,
                    &devices,
                    &mut commands,
                    &mut sink,
                    &mut stream,
                    &cancel,
                    &mut exited,
                )
                .await
                {
                    fail_waiters(&mut state, "codex observer stopped");
                    return;
                }
                tracing::warn!(%address, "codex observer disconnected; reconnecting");
            }
            Err(error) => {
                tracing::warn!(%address, %error, "codex observer connect failed; retrying");
            }
        }

        tokio::select! {
            _ = cancel.cancelled() => {
                fail_waiters(&mut state, "codex observer stopped");
                return;
            }
            changed = exited.changed() => {
                if changed.is_err() || *exited.borrow() {
                    fail_waiters(&mut state, "codex app-server stopped");
                    return;
                }
            }
            _ = tokio::time::sleep(RECONNECT_DELAY) => {}
        }
    }
}

async fn connect_initialized(address: SocketAddr) -> Result<ObserverSocket, String> {
    let tcp = TcpStream::connect(address)
        .await
        .map_err(|error| error.to_string())?;
    let url = format!("ws://{address}");
    let (mut socket, _) = tokio_tungstenite::client_async(url, tcp)
        .await
        .map_err(|error| error.to_string())?;
    let initialize = json!({
        "method": "initialize",
        "id": INITIALIZE_ID,
        "params": {
            "clientInfo": {
                "name": "motif_observer",
                "title": "Motif Notification Observer",
                "version": crate::VERSION,
            },
            "capabilities": {
                "experimentalApi": true,
                "optOutNotificationMethods": [
                    "item/agentMessage/delta",
                    "item/plan/delta",
                    "item/reasoning/summaryTextDelta",
                    "item/reasoning/summaryPartAdded",
                    "item/reasoning/textDelta",
                    "item/commandExecution/outputDelta",
                    "turn/diff/updated",
                    "turn/plan/updated",
                    "thread/tokenUsage/updated"
                ]
            }
        }
    });
    socket
        .send(Message::Text(initialize.to_string().into()))
        .await
        .map_err(|error| error.to_string())?;

    let initialized = timeout(PREPARE_TIMEOUT, async {
        while let Some(message) = socket.next().await {
            let message = message.map_err(|error| error.to_string())?;
            let Message::Text(text) = message else {
                continue;
            };
            let value: Value = serde_json::from_str(text.as_str()).map_err(|e| e.to_string())?;
            if value.get("id").and_then(Value::as_u64) != Some(INITIALIZE_ID) {
                continue;
            }
            if let Some(error) = value.get("error") {
                return Err(format!("initialize rejected: {error}"));
            }
            return Ok(());
        }
        Err("app-server closed during observer initialize".to_string())
    })
    .await
    .map_err(|_| "observer initialize timed out".to_string())?;
    initialized?;
    socket
        .send(Message::Text(
            json!({"method": "initialized", "params": {}})
                .to_string()
                .into(),
        ))
        .await
        .map_err(|error| error.to_string())?;
    Ok(socket)
}

async fn run_connected(
    state: &mut WorkerState,
    devices: &DeviceState,
    commands: &mut mpsc::UnboundedReceiver<Command>,
    sink: &mut ObserverSink,
    stream: &mut ObserverStream,
    cancel: &CancellationToken,
    exited: &mut tokio::sync::watch::Receiver<bool>,
) -> bool {
    let mut expiry = tokio::time::interval(Duration::from_secs(1));
    expiry.set_missed_tick_behavior(MissedTickBehavior::Skip);
    loop {
        tokio::select! {
            _ = cancel.cancelled() => return true,
            changed = exited.changed() => {
                if changed.is_err() || *exited.borrow() {
                    return true;
                }
            }
            command = commands.recv() => {
                let Some(command) = command else { return true };
                if let Err(error) = handle_command(state, command, sink).await {
                    tracing::debug!(%error, "codex observer command failed");
                    return false;
                }
            }
            message = stream.next() => {
                let Some(message) = message else { return false };
                match message {
                    Ok(Message::Text(text)) => {
                        if let Ok(value) = serde_json::from_str::<Value>(text.as_str()) {
                            if let Err(error) = handle_message(state, devices, value, sink).await {
                                tracing::debug!(%error, "codex observer message handling failed");
                                return false;
                            }
                        }
                    }
                    Ok(Message::Ping(value)) => match sink.send(Message::Pong(value)).await {
                        Ok(()) => {}
                        Err(_) => return false,
                    },
                    Ok(Message::Close(_)) | Err(_) => return false,
                    _ => {}
                }
            }
            _ = expiry.tick() => {
                if let Err(error) = expire_unconfirmed_starts(state, sink).await {
                    tracing::debug!(%error, "codex observer expiry cleanup failed");
                    return false;
                }
            }
        }
    }
}

async fn handle_command(
    state: &mut WorkerState,
    command: Command,
    sink: &mut ObserverSink,
) -> Result<(), String> {
    match command {
        Command::Prepare {
            thread_id,
            generation,
            reply,
        } => {
            let subscribed = state.subscribed.contains(&thread_id)
                && !matches!(
                    pending_for_thread(state, &thread_id),
                    Some(PendingRpc::Unsubscribe(_))
                );
            let watch = state.watches.entry(thread_id.clone()).or_default();
            watch
                .pending_starts
                .insert(generation, Instant::now() + START_CONFIRM_TIMEOUT);
            if subscribed {
                let _ = reply.send(Ok(()));
            } else {
                watch.waiters.insert(generation, reply);
                ensure_resume(state, &thread_id, sink).await?;
            }
        }
        Command::Confirm {
            thread_id,
            generation,
        } => {
            if let Some(watch) = state.watches.get_mut(&thread_id) {
                if watch.pending_starts.remove(&generation).is_some() {
                    watch.running = true;
                }
            }
        }
        Command::Cancel {
            thread_id,
            generation,
        } => {
            if let Some(watch) = state.watches.get_mut(&thread_id) {
                watch.pending_starts.remove(&generation);
                if let Some(waiter) = watch.waiters.remove(&generation) {
                    let _ = waiter.send(Err("turn/start was cancelled".to_string()));
                }
            }
            cleanup_if_idle(state, &thread_id, sink).await?;
        }
    }
    Ok(())
}

async fn handle_message(
    state: &mut WorkerState,
    devices: &DeviceState,
    value: Value,
    sink: &mut ObserverSink,
) -> Result<(), String> {
    if let Some(id) = value.get("id").and_then(Value::as_u64) {
        if value.get("result").is_some() || value.get("error").is_some() {
            return handle_rpc_response(state, id, value, sink).await;
        }
    }

    let Some(method) = value.get("method").and_then(Value::as_str) else {
        return Ok(());
    };
    match method {
        "turn/started" => {
            if let Some(thread_id) = thread_id(&value) {
                if let Some(watch) = state.watches.get_mut(thread_id) {
                    watch.running = true;
                    watch.pending_starts.clear();
                }
            }
        }
        "turn/completed" => {
            if let Some(thread_id) = thread_id(&value).map(str::to_string) {
                if state.watches.contains_key(&thread_id) {
                    let turn_id = value
                        .pointer("/params/turn/id")
                        .and_then(Value::as_str)
                        .map(str::to_string);
                    let status = value
                        .pointer("/params/turn/status")
                        .and_then(Value::as_str)
                        .unwrap_or("completed");
                    let body = completed_body(&value, status);
                    spawn_push(
                        devices.clone(),
                        PushNotification {
                            title: match status {
                                "failed" => "Codex failed".to_string(),
                                "interrupted" => "Codex stopped".to_string(),
                                _ => "Codex finished".to_string(),
                            },
                            body,
                            session_id: None,
                            view_id: None,
                            thread_id: Some(thread_id.clone()),
                            turn_id,
                            request_id: None,
                            kind: match status {
                                "failed" => "codex_failed".to_string(),
                                "interrupted" => "codex_interrupted".to_string(),
                                _ => "codex_finished".to_string(),
                            },
                        },
                    );
                    if let Some(watch) = state.watches.get_mut(&thread_id) {
                        watch.running = false;
                    }
                    cleanup_if_idle(state, &thread_id, sink).await?;
                }
            }
        }
        "item/commandExecution/requestApproval"
        | "item/fileChange/requestApproval"
        | "item/permissions/requestApproval"
        | "item/tool/requestUserInput"
        | "mcpServer/elicitation/request" => {
            if let Some(thread_id) = thread_id(&value).map(str::to_string) {
                let request_id = value.get("id").map(json_id_string);
                let dedup_key = request_id
                    .as_deref()
                    .map(|id| format!("{method}:{id}"))
                    .unwrap_or_else(|| method.to_string());
                let should_notify = state
                    .watches
                    .get_mut(&thread_id)
                    .is_some_and(|watch| watch.notified_requests.insert(dedup_key));
                if should_notify {
                    let turn_id = value
                        .pointer("/params/turnId")
                        .and_then(Value::as_str)
                        .map(str::to_string);
                    spawn_push(
                        devices.clone(),
                        PushNotification {
                            title: "Codex needs your input".to_string(),
                            body: approval_body(method).to_string(),
                            session_id: None,
                            view_id: None,
                            thread_id: Some(thread_id),
                            turn_id,
                            request_id,
                            kind: "codex_needs_input".to_string(),
                        },
                    );
                }
            }
        }
        _ => {}
    }
    Ok(())
}

async fn handle_rpc_response(
    state: &mut WorkerState,
    id: u64,
    value: Value,
    sink: &mut ObserverSink,
) -> Result<(), String> {
    let Some(pending) = state.pending_rpcs.remove(&id) else {
        return Ok(());
    };
    let error = value.get("error").map(ToString::to_string);
    match pending {
        PendingRpc::Resume(thread_id) => {
            if let Some(error) = error {
                if let Some(mut watch) = state.watches.remove(&thread_id) {
                    for (_, waiter) in watch.waiters.drain() {
                        let _ = waiter.send(Err(error.clone()));
                    }
                }
            } else {
                state.subscribed.insert(thread_id.clone());
                if let Some(watch) = state.watches.get_mut(&thread_id) {
                    for (generation, waiter) in watch.waiters.drain() {
                        if watch.pending_starts.contains_key(&generation) {
                            let _ = waiter.send(Ok(()));
                        }
                    }
                } else {
                    begin_unsubscribe(state, &thread_id, sink).await?;
                }
            }
        }
        PendingRpc::Unsubscribe(thread_id) => {
            state.subscribed.remove(&thread_id);
            if state.watches.contains_key(&thread_id) {
                ensure_resume(state, &thread_id, sink).await?;
            }
        }
    }
    Ok(())
}

async fn restore_subscriptions(
    state: &mut WorkerState,
    sink: &mut ObserverSink,
) -> Result<(), String> {
    let thread_ids = state.watches.keys().cloned().collect::<Vec<_>>();
    for thread_id in thread_ids {
        ensure_resume(state, &thread_id, sink).await?;
    }
    Ok(())
}

async fn ensure_resume(
    state: &mut WorkerState,
    thread_id: &str,
    sink: &mut ObserverSink,
) -> Result<(), String> {
    if state.subscribed.contains(thread_id) || state.has_pending_rpc(thread_id) {
        return Ok(());
    }
    let id = state.next_id();
    let request = json!({
        "method": "thread/resume",
        "id": id,
        "params": {"threadId": thread_id, "excludeTurns": true}
    });
    sink.send(Message::Text(request.to_string().into()))
        .await
        .map_err(|error| error.to_string())?;
    state
        .pending_rpcs
        .insert(id, PendingRpc::Resume(thread_id.to_string()));
    Ok(())
}

async fn cleanup_if_idle(
    state: &mut WorkerState,
    thread_id: &str,
    sink: &mut ObserverSink,
) -> Result<(), String> {
    let idle = state
        .watches
        .get(thread_id)
        .is_some_and(|watch| !watch.running && watch.pending_starts.is_empty());
    if !idle {
        return Ok(());
    }
    state.watches.remove(thread_id);
    if state.subscribed.contains(thread_id) && !state.has_pending_rpc(thread_id) {
        begin_unsubscribe(state, thread_id, sink).await?;
    }
    Ok(())
}

async fn begin_unsubscribe(
    state: &mut WorkerState,
    thread_id: &str,
    sink: &mut ObserverSink,
) -> Result<(), String> {
    if !state.subscribed.contains(thread_id) || state.has_pending_rpc(thread_id) {
        return Ok(());
    }
    let id = state.next_id();
    let request = json!({
        "method": "thread/unsubscribe",
        "id": id,
        "params": {"threadId": thread_id}
    });
    sink.send(Message::Text(request.to_string().into()))
        .await
        .map_err(|error| error.to_string())?;
    state
        .pending_rpcs
        .insert(id, PendingRpc::Unsubscribe(thread_id.to_string()));
    Ok(())
}

async fn expire_unconfirmed_starts(
    state: &mut WorkerState,
    sink: &mut ObserverSink,
) -> Result<(), String> {
    let now = Instant::now();
    let thread_ids = state.watches.keys().cloned().collect::<Vec<_>>();
    for thread_id in thread_ids {
        if let Some(watch) = state.watches.get_mut(&thread_id) {
            let expired = watch
                .pending_starts
                .iter()
                .filter_map(|(generation, deadline)| (*deadline <= now).then_some(*generation))
                .collect::<Vec<_>>();
            for generation in expired {
                watch.pending_starts.remove(&generation);
                if let Some(waiter) = watch.waiters.remove(&generation) {
                    let _ = waiter.send(Err("turn/start confirmation timed out".to_string()));
                }
            }
        }
        cleanup_if_idle(state, &thread_id, sink).await?;
    }
    Ok(())
}

fn pending_for_thread<'a>(state: &'a WorkerState, thread_id: &str) -> Option<&'a PendingRpc> {
    state.pending_rpcs.values().find(|pending| match pending {
        PendingRpc::Resume(thread) | PendingRpc::Unsubscribe(thread) => thread == thread_id,
    })
}

fn fail_waiters(state: &mut WorkerState, message: &str) {
    for watch in state.watches.values_mut() {
        for (_, waiter) in watch.waiters.drain() {
            let _ = waiter.send(Err(message.to_string()));
        }
    }
}

fn thread_id(value: &Value) -> Option<&str> {
    value
        .pointer("/params/threadId")
        .and_then(Value::as_str)
        .or_else(|| value.pointer("/params/thread/id").and_then(Value::as_str))
}

fn json_id_string(value: &Value) -> String {
    value
        .as_str()
        .map(str::to_string)
        .unwrap_or_else(|| value.to_string())
}

fn approval_body(method: &str) -> &'static str {
    match method {
        "item/commandExecution/requestApproval" => "Approve a command to continue.",
        "item/fileChange/requestApproval" => "Approve file changes to continue.",
        "item/permissions/requestApproval" => "Approve requested permissions to continue.",
        "mcpServer/elicitation/request" => "An MCP server needs your response.",
        _ => "Answer a question to continue.",
    }
}

fn completed_body(value: &Value, status: &str) -> String {
    if let Some(message) = value
        .pointer("/params/turn/items")
        .and_then(Value::as_array)
        .and_then(|items| {
            items.iter().rev().find_map(|item| {
                (item.get("type").and_then(Value::as_str) == Some("agentMessage"))
                    .then(|| item.get("text").and_then(Value::as_str))
                    .flatten()
            })
        })
    {
        return summarize(message);
    }
    match status {
        "failed" => value
            .pointer("/params/turn/error/message")
            .and_then(Value::as_str)
            .map(summarize)
            .unwrap_or_else(|| "The turn failed.".to_string()),
        "interrupted" => "The turn was stopped.".to_string(),
        _ => "The turn completed.".to_string(),
    }
}

fn summarize(value: &str) -> String {
    let one_line = value.split_whitespace().collect::<Vec<_>>().join(" ");
    const MAX_CHARS: usize = 140;
    if one_line.chars().count() <= MAX_CHARS {
        return one_line;
    }
    let mut result = one_line.chars().take(MAX_CHARS).collect::<String>();
    result.push('…');
    result
}

fn spawn_push(devices: DeviceState, notification: PushNotification) {
    let Some(relay) = devices.relay.clone() else {
        return;
    };
    tokio::spawn(async move {
        relay.push_to_all(&devices.store, &notification).await;
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn read_json<S>(socket: &mut WebSocketStream<S>) -> Value
    where
        S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
    {
        loop {
            let message = timeout(Duration::from_secs(2), socket.next())
                .await
                .expect("timed out waiting for observer message")
                .expect("observer closed its socket")
                .expect("observer websocket read failed");
            if let Message::Text(text) = message {
                return serde_json::from_str(text.as_str()).unwrap();
            }
        }
    }

    #[test]
    fn extracts_thread_ids_from_turns_and_requests() {
        assert_eq!(
            thread_id(&json!({"params": {"threadId": "thread-a"}})),
            Some("thread-a")
        );
        assert_eq!(
            thread_id(&json!({"params": {"thread": {"id": "thread-b"}}})),
            Some("thread-b")
        );
    }

    #[test]
    fn completion_prefers_the_final_agent_message() {
        let value = json!({
            "params": {
                "turn": {
                    "items": [
                        {"type": "agentMessage", "text": "first"},
                        {"type": "agentMessage", "text": "Done — all tests pass."}
                    ]
                }
            }
        });
        assert_eq!(
            completed_body(&value, "completed"),
            "Done — all tests pass."
        );
    }

    #[test]
    fn completion_summary_is_notification_sized() {
        let summary = summarize(&"x".repeat(200));
        assert_eq!(summary.chars().count(), 141);
        assert!(summary.ends_with('…'));
    }

    #[tokio::test]
    async fn disabled_push_does_not_start_or_gate_the_observer() {
        let observer = CodexObserver::new(DeviceState {
            store: crate::devices::DeviceStore::new(),
            relay: None,
        });
        let prepared = observer
            .prepare_turn(CodexAppServer::fake(), "thread-a")
            .await
            .unwrap();

        assert_eq!(prepared.thread_id, "thread-a");
        assert!(observer.worker.lock().is_none());
    }

    #[tokio::test]
    async fn subscribes_before_start_and_unsubscribes_after_completion() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let runtime = CodexAppServer::fake_at(address);
        let observer = CodexObserver::new(DeviceState {
            store: crate::devices::DeviceStore::new(),
            // No devices are registered, so this enables observation without
            // causing an outbound request during the test.
            relay: Some(crate::relay::RelayClient::new(
                "http://127.0.0.1:9/push".to_string(),
            )),
        });
        let (resume_seen_tx, resume_seen_rx) = oneshot::channel();
        let (allow_resume_tx, allow_resume_rx) = oneshot::channel();

        let server = tokio::spawn(async move {
            let (tcp, _) = listener.accept().await.unwrap();
            let mut socket = tokio_tungstenite::accept_async(tcp).await.unwrap();

            let initialize = read_json(&mut socket).await;
            assert_eq!(initialize["method"], "initialize");
            assert_eq!(initialize["id"], INITIALIZE_ID);
            socket
                .send(Message::Text(
                    json!({"id": INITIALIZE_ID, "result": {}})
                        .to_string()
                        .into(),
                ))
                .await
                .unwrap();
            assert_eq!(read_json(&mut socket).await["method"], "initialized");

            let resume = read_json(&mut socket).await;
            assert_eq!(resume["method"], "thread/resume");
            assert_eq!(resume["params"]["threadId"], "thread-a");
            let resume_id = resume["id"].clone();
            let _ = resume_seen_tx.send(());
            let _ = allow_resume_rx.await;
            socket
                .send(Message::Text(
                    json!({"id": resume_id, "result": {"thread": {"id": "thread-a"}}})
                        .to_string()
                        .into(),
                ))
                .await
                .unwrap();

            socket
                .send(Message::Text(
                    json!({
                        "method": "turn/started",
                        "params": {"threadId": "thread-a", "turn": {"id": "turn-a"}}
                    })
                    .to_string()
                    .into(),
                ))
                .await
                .unwrap();
            socket
                .send(Message::Text(
                    json!({
                        "method": "item/tool/requestUserInput",
                        "id": 77,
                        "params": {"threadId": "thread-a", "turnId": "turn-a"}
                    })
                    .to_string()
                    .into(),
                ))
                .await
                .unwrap();
            socket
                .send(Message::Text(
                    json!({
                        "method": "turn/completed",
                        "params": {
                            "threadId": "thread-a",
                            "turn": {"id": "turn-a", "status": "completed", "items": []}
                        }
                    })
                    .to_string()
                    .into(),
                ))
                .await
                .unwrap();

            // The observer deliberately does not answer the approval request.
            // Its next client message is lifecycle cleanup.
            let unsubscribe = read_json(&mut socket).await;
            assert_eq!(unsubscribe["method"], "thread/unsubscribe");
            assert_eq!(unsubscribe["params"]["threadId"], "thread-a");
        });

        let prepare = tokio::spawn({
            let observer = Arc::clone(&observer);
            let runtime = Arc::clone(&runtime);
            async move { observer.prepare_turn(runtime, "thread-a").await }
        });
        timeout(Duration::from_secs(3), resume_seen_rx)
            .await
            .unwrap()
            .unwrap();
        assert!(
            !prepare.is_finished(),
            "prepare_turn returned before thread/resume succeeded"
        );
        let _ = allow_resume_tx.send(());
        let prepared = timeout(Duration::from_secs(3), prepare)
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        observer.confirm_turn(prepared);
        timeout(Duration::from_secs(3), server)
            .await
            .unwrap()
            .unwrap();
        observer.stop();
    }
}
