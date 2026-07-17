//! Motif core server library.

pub mod auth;
pub mod config;
pub mod conn_registry;
pub mod devices;
pub mod embed;
pub mod events_ws;
pub mod fs;
pub mod fswatch;
pub mod git;
pub mod hook_ingress;
pub mod http_rpc;
mod paths;
pub mod pty;
pub mod pty_ws;
pub mod relay;
pub mod rpc;
pub mod rpc_log;
pub mod rzv;
pub mod session;
pub mod shell;
pub mod tcp_ws;
pub mod wake_detector;
#[cfg(windows)]
mod windows_job;
pub mod wire;
pub mod ws;

use std::path::{Path, PathBuf};
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

pub use config::{RzvListenConfig, ServerConfig, TailscaleListenConfig};
pub use ws::RzvDirectInfo;

/// Default embedded-tsnet hostname (`motifd-<sanitized system hostname>`).
/// Shared by the `motifd` binary and embedding hosts (the menu-bar app) so
/// they present as the *same* tailnet device — clients targeting
/// `motifd-<host>` reach the node regardless of which launched it.
pub fn default_tailscale_hostname() -> String {
    let raw = system_hostname().unwrap_or_default();
    let sanitized: String = raw
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' {
                c.to_ascii_lowercase()
            } else {
                '-'
            }
        })
        .collect();
    let sanitized = sanitized.trim_matches('-');
    if sanitized.is_empty() {
        "motifd".into()
    } else {
        format!("motifd-{sanitized}")
    }
}

/// Default tsnet state dir (`$XDG_DATA_HOME/motifd/tsnet`,
/// `~/.local/share/motifd/tsnet` on Unix, or local app data on Windows).
/// Shared with embedding hosts so the embedded node reuses `motifd`'s identity.
pub fn default_tailscale_state_dir() -> Option<PathBuf> {
    Some(paths::data_dir()?.join("motifd").join("tsnet"))
}

/// Default path for the persisted rzv pairing secret. Always returns a path
/// (falls back to the current directory when no data/home dir is known).
pub fn default_rzv_psk_path() -> PathBuf {
    let mut base = paths::data_dir().unwrap_or_else(|| PathBuf::from("."));
    base.push("motifd");
    base.push("rzv_psk");
    base
}

#[cfg(unix)]
fn system_hostname() -> Option<String> {
    let mut buf = [0u8; 256];
    // SAFETY: buffer of known size; gethostname writes at most buf.len() bytes
    // including the trailing NUL on success.
    let rc = unsafe { libc::gethostname(buf.as_mut_ptr() as *mut libc::c_char, buf.len()) };
    if rc != 0 {
        return None;
    }
    let nul = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
    std::str::from_utf8(&buf[..nul]).ok().map(|s| s.to_string())
}

#[cfg(not(unix))]
fn system_hostname() -> Option<String> {
    std::env::var("COMPUTERNAME").ok().filter(|s| !s.is_empty())
}

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
    rzv_status: Option<tokio::sync::watch::Receiver<motif_net::RzvStatus>>,
    manager: Arc<session::manager::SessionManager>,
    devices: relay::DeviceState,
    #[cfg(feature = "tailscale")]
    ts: Option<Arc<motif_net::motif_tailscale::TsServer>>,
    shutdown: CancellationToken,
    serve_task: JoinHandle<anyhow::Result<()>>,
    wake_task: JoinHandle<()>,
    /// Platform-local hook-ingress task, present only when push is enabled.
    hook_task: Option<JoinHandle<()>>,
}

impl RunningServer {
    /// Human-readable bound endpoints (`tcp://…`, `tailscale://*:port`).
    pub fn bound_addrs(&self) -> &[String] {
        &self.bound
    }

    /// Latest rendezvous connectivity snapshot, when a relay backend is
    /// configured. This remains independent from the local server lifecycle:
    /// motifd can keep serving LAN/loopback clients while the relay retries.
    pub fn rendezvous_status(&self) -> Option<motif_net::RzvStatus> {
        self.rzv_status
            .as_ref()
            .map(|status| status.borrow().clone())
    }

    /// Snapshot of the current sessions (name, workdir, client_count, …),
    /// read straight off the in-process manager — no HTTP round-trip.
    pub fn sessions(&self) -> Vec<motif_proto::session::SessionInfo> {
        self.manager.list().iter().map(|s| s.info()).collect()
    }

    pub fn session_count(&self) -> usize {
        self.manager.list().len()
    }

    /// Registered push devices for an embedding/admin UI. The per-device
    /// encryption key is intentionally omitted from this snapshot.
    pub fn registered_push_devices(&self) -> Vec<motif_proto::device::RegisteredDevice> {
        self.devices.store.registered_devices()
    }

    /// Send an encrypted test notification to one registered push token.
    pub async fn send_test_push(
        &self,
        device_token: &str,
    ) -> anyhow::Result<motif_proto::device::TestPushResult> {
        let Some(relay) = self.devices.relay.as_ref() else {
            anyhow::bail!("push relay is disabled");
        };
        relay
            .push_test_to_token(
                &self.devices.store,
                device_token,
                &relay::PushNotification {
                    title: "Motif test push".to_string(),
                    body: "Push notifications are working.".to_string(),
                    session_id: None,
                    kind: "test_push".to_string(),
                },
            )
            .await
    }

    /// tsnet backend snapshot (state, peers, auth URL), or `None` when the
    /// tailscale backend isn't active.
    #[cfg(feature = "tailscale")]
    pub async fn tailscale_status(&self) -> Option<motif_net::motif_tailscale::TsBackendStatus> {
        let ts = self.ts.as_ref()?;
        ts.backend_status().await.ok()
    }

    #[cfg(feature = "tailscale")]
    pub async fn tailscale_peers(&self) -> Vec<motif_net::motif_tailscale::TsPeer> {
        match self.ts.as_ref() {
            Some(ts) => ts.list_peers().await.unwrap_or_default(),
            None => Vec::new(),
        }
    }

    /// Latest first-start device-auth URL, if tsnet is waiting on login.
    #[cfg(feature = "tailscale")]
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
            rzv_status: _rzv_status,
            manager: _manager,
            devices: _devices,
            #[cfg(feature = "tailscale")]
                ts: _ts,
            shutdown,
            mut serve_task,
            wake_task,
            hook_task,
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
        if let Some(h) = hook_task {
            h.abort();
        }
        result
    }
}

/// Bind and start serving, returning a [`RunningServer`] handle immediately.
/// This is the embeddable entry point; [`serve`] wraps it for the `motifd`
/// binary.
pub async fn start(cfg: ServerConfig) -> anyhow::Result<RunningServer> {
    cfg.validate()?;

    let configured_shell = cfg
        .shell
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
        .or_else(|| {
            std::env::var("MOTIFD_SHELL")
                .ok()
                .filter(|value| !value.trim().is_empty())
        });
    let manager = session::manager::SessionManager::with_default_shell(configured_shell);
    let token_store = match cfg.token.clone() {
        Some(t) => auth::TokenStore::required(t),
        None => {
            // No psk-derived bearer — reaching here means the surface is private
            // (loopback / embed / tailscale-only). A network `--listen` gets a
            // psk bearer wired up in main.rs. Still WARN so the operator knows
            // auth is off for this listener.
            tracing::warn!(
                "auth disabled: motifd will accept WebSocket upgrades without a Bearer \
                 token. This is expected for a loopback / tailscale-only surface; a \
                 network --listen is auto-encrypted + psk-authenticated instead."
            );
            auth::TokenStore::disabled()
        }
    };
    // Push-notification state: an in-memory device-token store (not persisted
    // — see `devices` module docs) plus, when a relay URL is configured, the
    // relay client. Clients re-register on every connect, so nothing needs to
    // survive a restart.
    let device_store = devices::DeviceStore::new();
    let relay_client = cfg.push_relay_url.clone().map(relay::RelayClient::new);
    if relay_client.is_some() {
        tracing::info!(instance_id = %device_store.instance_id(), "push notifications enabled");
    }
    let device_state = relay::DeviceState {
        store: device_store,
        relay: relay_client,
    };

    let state = ws::AppState {
        manager: manager.clone(),
        auth: Arc::new(token_store),
        conns: conn_registry::ConnRegistry::new(),
        devices: device_state.clone(),
        rzv_direct: cfg.rzv_direct.clone(),
    };
    let app = ws::router(state);

    #[cfg(feature = "tailscale")]
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
    let rzv_status = listener.rendezvous_status();
    for addr in &bound {
        tracing::info!(%addr, "motifd listening");
    }
    // Grab the tsnet node handle before the listener is moved into the serve
    // task, so status queries can reach it for the server's lifetime.
    #[cfg(feature = "tailscale")]
    let ts = listener.tailscale_server();

    let shutdown = CancellationToken::new();

    // Hook ingress receives coding-agent notifications from shell integration.
    // Unix exports a UDS path; Windows exports a loopback URL + capability
    // token. Only future child PTYs inherit these process environment values.
    hook_ingress::clear_environment();
    let hook_task = if device_state.relay.is_some() {
        match hook_ingress::spawn(device_state.clone(), manager.clone(), shutdown.clone()) {
            Ok(ingress) => {
                ingress.install_environment();
                Some(ingress.into_task())
            }
            Err(e) => {
                tracing::warn!("failed to bind hook ingress: {e}; push disabled");
                None
            }
        }
    } else {
        None
    };

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
        rzv_status,
        manager,
        devices: device_state,
        #[cfg(feature = "tailscale")]
        ts,
        shutdown,
        serve_task,
        wake_task,
        hook_task,
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
