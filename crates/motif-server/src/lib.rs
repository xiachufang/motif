//! Motif core server library.

pub mod auth;
pub mod config;
pub mod conn_registry;
pub mod embed;
pub mod events_ws;
pub mod fs;
pub mod fswatch;
pub mod git;
pub mod http_rpc;
pub mod pty;
pub mod pty_ws;
pub mod rpc;
pub mod rpc_log;
pub mod session;
pub mod shell;
pub mod wake_detector;
pub mod wire;
pub mod ws;

use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use anyhow::Context;
use time::macros::format_description;
use tokio::task::JoinHandle;
use tokio_util::sync::CancellationToken;
use tracing_subscriber::fmt::time::LocalTime;
use tracing_subscriber::{fmt, prelude::*, EnvFilter, Registry};

/// Compact local-time format used by all our log layers:
/// `YYYY-MM-DD HH:MM:SS.sss`. Operators read logs in their wall-clock
/// timezone — RFC3339 with full subsecond + offset is just noise.
fn local_timer() -> LocalTime<&'static [time::format_description::FormatItem<'static>]> {
    LocalTime::new(format_description!(
        "[year]-[month]-[day] [hour]:[minute]:[second].[subsecond digits:3]"
    ))
}

pub use config::{ServerConfig, TailscaleListenConfig};

/// Install the global tracing subscriber.
///
/// The stderr layer applies the user-supplied filter, but always turns
/// the `motif::rpc` target off so the RPC dump (which is large and
/// frame-by-frame) doesn't drown the operator's regular logs. When
/// `rpc_log` is set, a second file layer captures only that target —
/// giving us a clean per-frame audit trail for debugging the wire
/// protocol.
pub fn init_tracing(filter: &str, rpc_log: Option<&Path>) -> anyhow::Result<()> {
    // The RPC frame-dump target is force-off on stderr (it goes to the
    // rpc-log file only). But its child target `motif::rpc::timing` —
    // per-request latency lines — IS meant for stderr so operators see
    // git.diff slowness without having to opt into --rpc-log. Use a
    // longer prefix to override the parent's `=off` for that one path.
    let stderr_filter = EnvFilter::try_new(format!(
        "{filter},{}=off,{}=info",
        rpc_log::TARGET,
        ws::TIMING_TARGET,
    ))
    .unwrap_or_else(|_| {
        EnvFilter::new(format!(
            "info,{}=off,{}=info",
            rpc_log::TARGET,
            ws::TIMING_TARGET,
        ))
    });
    let stderr_layer = fmt::layer()
        .with_writer(std::io::stderr)
        .with_timer(local_timer())
        .with_filter(stderr_filter);

    let file_layer = match rpc_log {
        Some(path) => {
            let file = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(path)
                .with_context(|| format!("failed to open --rpc-log {}", path.display()))?;
            // Synchronous Mutex<File> is fine — frames are small and the
            // log is opt-in for debug runs only. with_ansi(false) keeps
            // the file clean of color escape codes.
            let writer = std::sync::Mutex::new(file);
            let filter = EnvFilter::new(format!("{}=trace", rpc_log::TARGET));
            Some(
                fmt::layer()
                    .with_writer(writer)
                    .with_timer(local_timer())
                    .with_ansi(false)
                    .with_target(false)
                    .with_filter(filter),
            )
        }
        None => None,
    };

    Registry::default()
        .with(stderr_layer)
        .with(file_layer)
        .try_init()
        .ok();
    Ok(())
}

/// Max lines retained by a [`LogRing`]. Old lines are dropped front-first.
const LOG_RING_CAP: usize = 2000;

/// In-memory ring of recent log lines, for hosts with no stderr console
/// (the menu-bar app). Cloning shares the same buffer (`Arc`). Fed by the
/// ring layer that [`init_tracing_gui`] installs; read with [`LogRing::snapshot`].
#[derive(Clone, Default)]
pub struct LogRing(pub Arc<parking_lot::Mutex<std::collections::VecDeque<String>>>);

impl LogRing {
    pub fn new() -> Self {
        Self::default()
    }

    /// Oldest-to-newest copy of the retained lines.
    pub fn snapshot(&self) -> Vec<String> {
        self.0.lock().iter().cloned().collect()
    }

    fn push_line(&self, line: String) {
        let mut q = self.0.lock();
        while q.len() >= LOG_RING_CAP {
            q.pop_front();
        }
        q.push_back(line);
    }
}

/// One formatted event, accumulated then pushed to the ring on drop. The
/// `fmt` layer writes a whole event (ending in `\n`) through a fresh writer,
/// so draining on drop yields exactly one ring entry per event. Public only
/// because it's the `MakeWriter::Writer` associated type for [`LogRing`].
pub struct RingWriter {
    ring: LogRing,
    buf: Vec<u8>,
}

impl std::io::Write for RingWriter {
    fn write(&mut self, data: &[u8]) -> std::io::Result<usize> {
        self.buf.extend_from_slice(data);
        Ok(data.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl Drop for RingWriter {
    fn drop(&mut self) {
        let text = String::from_utf8_lossy(&self.buf);
        let line = text.trim_end_matches(['\r', '\n']);
        if !line.is_empty() {
            self.ring.push_line(line.to_string());
        }
    }
}

impl<'a> fmt::MakeWriter<'a> for LogRing {
    type Writer = RingWriter;
    fn make_writer(&'a self) -> Self::Writer {
        RingWriter {
            ring: self.clone(),
            buf: Vec::new(),
        }
    }
}

/// Tracing init for a GUI host (the menu-bar app) — no stderr console.
/// Writes to a rolling-append file under `log_dir` and into the provided
/// `LogRing` for the settings window to tail. Returns the same ring for
/// convenience. Like [`init_tracing`], the RPC frame-dump target is off and
/// the timing target stays at info.
pub fn init_tracing_gui(filter: &str, log_dir: &Path, ring: LogRing) -> anyhow::Result<LogRing> {
    std::fs::create_dir_all(log_dir)
        .with_context(|| format!("creating log dir {}", log_dir.display()))?;
    let log_path = log_dir.join("motifd.log");
    let file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&log_path)
        .with_context(|| format!("opening log file {}", log_path.display()))?;

    let base_filter = || {
        EnvFilter::try_new(format!(
            "{filter},{}=off,{}=info",
            rpc_log::TARGET,
            ws::TIMING_TARGET,
        ))
        .unwrap_or_else(|_| {
            EnvFilter::new(format!(
                "info,{}=off,{}=info",
                rpc_log::TARGET,
                ws::TIMING_TARGET,
            ))
        })
    };

    let file_layer = fmt::layer()
        .with_writer(std::sync::Mutex::new(file))
        .with_timer(local_timer())
        .with_ansi(false)
        .with_filter(base_filter());

    let ring_layer = fmt::layer()
        .with_writer(ring.clone())
        .with_timer(local_timer())
        .with_ansi(false)
        .with_filter(base_filter());

    Registry::default()
        .with(file_layer)
        .with(ring_layer)
        .try_init()
        .ok();
    Ok(ring)
}

/// A bound, serving motifd. Returned by [`start`] so an embedding host (the
/// menu-bar app) gets control back instead of blocking forever, can read
/// live status, and can stop the server gracefully.
///
/// Drop does NOT stop the server — call [`RunningServer::shutdown`]. (Drop
/// only detaches; the spawned serve task keeps running.)
pub struct RunningServer {
    bound: Vec<String>,
    manager: Arc<session::manager::SessionManager>,
    ts: Option<Arc<motif_net::motif_tailscale::TsServer>>,
    shutdown: CancellationToken,
    serve_task: JoinHandle<anyhow::Result<()>>,
    wake_task: JoinHandle<()>,
}

impl RunningServer {
    /// Human-readable bound endpoints (`tcp://…`, `tailscale://*:port`).
    pub fn bound_addrs(&self) -> &[String] {
        &self.bound
    }

    /// Snapshot of the current sessions (name, workdir, client_count, …),
    /// read straight off the in-process manager — no HTTP round-trip.
    pub fn sessions(&self) -> Vec<motif_proto::session::SessionInfo> {
        self.manager.list().iter().map(|s| s.info()).collect()
    }

    pub fn session_count(&self) -> usize {
        self.manager.list().len()
    }

    /// tsnet backend snapshot (state, peers, auth URL), or `None` when the
    /// tailscale backend isn't active.
    pub async fn tailscale_status(&self) -> Option<motif_net::motif_tailscale::TsBackendStatus> {
        let ts = self.ts.as_ref()?;
        ts.backend_status().await.ok()
    }

    pub async fn tailscale_peers(&self) -> Vec<motif_net::motif_tailscale::TsPeer> {
        match self.ts.as_ref() {
            Some(ts) => ts.list_peers().await.unwrap_or_default(),
            None => Vec::new(),
        }
    }

    /// Latest first-start device-auth URL, if tsnet is waiting on login.
    pub fn tailscale_auth_url(&self) -> Option<String> {
        self.ts.as_ref().and_then(|ts| ts.auth_url())
    }

    /// Trigger graceful shutdown and wait for the serve task to wind down.
    /// Open PTY/WS connections never close on their own, so we cap the
    /// graceful wait and then force-abort — otherwise a single live terminal
    /// would hang stop forever. Also aborts the wake-detector task.
    pub async fn shutdown(self) -> anyhow::Result<()> {
        const GRACE: Duration = Duration::from_secs(3);
        let RunningServer {
            bound: _bound,
            manager: _manager,
            ts: _ts,
            shutdown,
            mut serve_task,
            wake_task,
        } = self;

        shutdown.cancel();
        let result = match tokio::time::timeout(GRACE, &mut serve_task).await {
            Ok(Ok(res)) => res,
            Ok(Err(join_err)) => Err(anyhow::anyhow!("serve task panicked: {join_err}")),
            Err(_) => {
                // Grace window elapsed with connections still open — force it.
                tracing::warn!("graceful shutdown timed out after {GRACE:?}; aborting serve task");
                serve_task.abort();
                Ok(())
            }
        };
        wake_task.abort();
        result
    }
}

/// Bind and start serving, returning a [`RunningServer`] handle immediately.
/// This is the embeddable entry point; [`serve`] wraps it for the `motifd`
/// binary.
pub async fn start(cfg: ServerConfig) -> anyhow::Result<RunningServer> {
    cfg.validate()?;

    if cfg.cert.is_some() {
        anyhow::bail!(
            "TLS support not yet implemented (M1 supports loopback plaintext only); see prd.md §7"
        );
    }

    let manager = session::manager::SessionManager::new();
    let token_store = match cfg.token.clone() {
        Some(t) => auth::TokenStore::required(t),
        None => {
            // `validate()` already refuses to expose a token-less listener
            // on non-loopback TCP, so reaching here means the surface is
            // private (loopback or tailscale-only). Still WARN so the
            // operator knows auth is off.
            tracing::warn!(
                "no --token-file configured: motifd will accept WebSocket upgrades without \
                 a Bearer token. Make sure access to this listener is gated elsewhere \
                 (loopback only / tailnet ACLs)."
            );
            auth::TokenStore::disabled()
        }
    };
    let state = ws::AppState {
        manager: manager.clone(),
        auth: Arc::new(token_store),
        conns: conn_registry::ConnRegistry::new(),
    };
    let app = ws::router(state);

    if let Some(ts) = &cfg.tailscale {
        tracing::info!(
            hostname  = %ts.hostname,
            state_dir = %ts.state_dir.display(),
            port      = ts.port,
            "embedded tailscale node bringing up",
        );
        if ts.authkey.is_none() && !ts.state_dir.join("tailscaled.state").exists() {
            // First-time bring-up without authkey: libtailscale will print a
            // login URL on stderr. Surface a hint so the user knows to
            // expect it. Skip when the state dir already has a session — the
            // node will reuse its persisted identity, no login needed.
            tracing::warn!(
                "tsnet has no authkey and {} appears empty; libtailscale will \
                 print a Tailscale login URL on stderr — open it once in a \
                 browser to authorize this node. After first auth the identity \
                 is cached in the state dir.",
                ts.state_dir.display(),
            );
        }
    }

    // Diagnostic: surface Mac sleep/wake events as WARN lines so the
    // tsnet snapshot logs that follow can be correlated with a known
    // suspend cycle. Cheap; runs regardless of --tailscale.
    let wake_task = wake_detector::spawn();

    let listener = motif_net::Listener::bind(&cfg.to_listen_config())
        .await
        .with_context(|| "failed to bind listener")?;
    let bound = listener.bound_addrs();
    for addr in &bound {
        tracing::info!(%addr, "motifd listening");
    }
    // Grab the tsnet node handle before the listener is moved into the serve
    // task, so status queries can reach it for the server's lifetime.
    let ts = listener.tailscale_server();

    let shutdown = CancellationToken::new();
    let child = shutdown.clone();
    // `into_make_service_with_connect_info::<PeerAddr>()` so handlers
    // can pull the peer addr via `ConnectInfo<PeerAddr>` and stamp it
    // onto request logs. `PeerAddr` is a `SocketAddr` newtype because
    // orphan rules don't let motif-net implement `Connected` for std's
    // `SocketAddr` directly. For tailscale accepts the wrapped addr has
    // port = 0 (libtailscale doesn't surface ephemeral ports).
    let serve_task = tokio::spawn(async move {
        axum::serve(
            listener,
            app.into_make_service_with_connect_info::<motif_net::PeerAddr>(),
        )
        .with_graceful_shutdown(async move { child.cancelled().await })
        .await
        .map_err(Into::into)
    });

    Ok(RunningServer {
        bound,
        manager,
        ts,
        shutdown,
        serve_task,
        wake_task,
    })
}

/// Run the server until Ctrl-C, then shut down gracefully. The `motifd`
/// binary's entry point; embedders should use [`start`] instead.
pub async fn serve(cfg: ServerConfig) -> anyhow::Result<()> {
    let running = start(cfg).await?;
    tokio::signal::ctrl_c()
        .await
        .context("waiting for ctrl-c")?;
    tracing::info!("ctrl-c received; shutting down");
    running.shutdown().await
}
