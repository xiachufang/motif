//! Motif embeddable server: a thin, stable C ABI over `motif-server` so an
//! in-process host (the Flutter desktop app) can run and control an embedded
//! `motifd` over `dart:ffi` — the same capability the Tauri menu-bar app gets
//! natively. There is exactly one embedded server per process, so the state
//! lives in a process-global behind a tokio mutex (mirroring the menu-bar
//! app's `manage(AppState)` singleton).
//!
//! The lifecycle logic (non-blocking start → `Starting` → `Running`/`Failed`,
//! graceful stop, status snapshot) is ported from the original Tauri menu-bar
//! app; the config mapping lives in [`config`]. The host owns persistence and
//! all UI — this crate is UI-free.
//!
//! ## ABI conventions
//! - Strings in: NUL-terminated UTF-8 (`*const c_char`), borrowed.
//! - Strings out: heap-allocated UTF-8 the caller must release with
//!   [`motif_embed_free`]. A null return means "nothing"/error.
//! - All entry points are synchronous from the caller's view; the slow
//!   server bring-up runs on the embedded runtime so the host never blocks.

mod config;

use std::ffi::{c_char, c_int, CStr, CString};
use std::path::PathBuf;
use std::sync::OnceLock;

use serde::Serialize;
use tokio::runtime::Runtime;
use tokio::sync::Mutex;

use config::MenuConfig;
use motif_server::{LogRing, RunningServer};

/// Lifecycle of the embedded server. `Starting` exists because tsnet bring-up
/// can block for a while on first-run login — start happens off the caller's
/// thread and this reflects progress. Ported from `app_state::ServerState`.
enum ServerState {
    Stopped,
    Starting,
    Running(RunningServer),
    /// Last start attempt failed; carries the message for the host UI.
    Failed(String),
}

/// Process-global embedded-server state. Set once by [`motif_embed_init`].
struct EmbedState {
    server: Mutex<ServerState>,
    log_ring: LogRing,
    /// Fallback tsnet state dir when `motif_server::default_tailscale_state_dir`
    /// can't resolve one. Resolved at init from the platform data dir.
    tsnet_dir: PathBuf,
}

static RT: OnceLock<Runtime> = OnceLock::new();
static STATE: OnceLock<EmbedState> = OnceLock::new();

fn rt() -> &'static Runtime {
    RT.get().expect("motif_embed_init not called")
}

fn state() -> &'static EmbedState {
    STATE.get().expect("motif_embed_init not called")
}

// ─────────────────────────── status DTOs ───────────────────────────
// Ported from the original Tauri menu-bar app; serialized to JSON for the host.

#[derive(Serialize, Clone)]
struct SessionDto {
    name: String,
    workdir: String,
    client_count: u32,
}

// Built without `tailscale` this is still named by `StatusDto.tailscale`'s type
// but never constructed, so silence the dead-field lint in that configuration.
#[cfg_attr(not(feature = "tailscale"), allow(dead_code))]
#[derive(Serialize, Clone)]
struct TsStatusDto {
    backend_state: String,
    peer_online: usize,
    peer_total: usize,
    health: Vec<String>,
}

#[derive(Serialize, Clone, Default)]
struct StatusDto {
    running: bool,
    starting: bool,
    bound_addrs: Vec<String>,
    session_count: usize,
    sessions: Vec<SessionDto>,
    tailscale: Option<TsStatusDto>,
    /// First-start Tailscale login URL, when the node is waiting on auth.
    auth_url: Option<String>,
    /// Last start failure, if any.
    error: Option<String>,
}

// ─────────────────────────── lifecycle ───────────────────────────

/// Begin starting the server. Returns immediately: the potentially-slow
/// `motif_server::start` (tsnet bring-up can wait on first-run login) runs on
/// a background task so the caller never blocks. Ported from `commands::do_start`.
async fn do_start(cfg: MenuConfig) -> Result<(), String> {
    let st = state();

    // Claim the Starting slot, rejecting double-starts.
    {
        let mut s = st.server.lock().await;
        match &*s {
            ServerState::Starting => return Err("server is already starting".into()),
            ServerState::Running(_) => return Err("server is already running".into()),
            _ => {}
        }
        *s = ServerState::Starting;
    }

    // Build the server config up front so obvious mistakes fail fast (and
    // reset the state) rather than after a spawn.
    let server_cfg = match cfg.to_server_config(&st.tsnet_dir) {
        Ok(c) => c,
        Err(e) => {
            *st.server.lock().await = ServerState::Failed(e.clone());
            return Err(e);
        }
    };

    // Run the (possibly long) bring-up off the command path.
    rt().spawn(async move {
        let result = motif_server::start(server_cfg).await;
        let mut s = st.server.lock().await;
        if matches!(&*s, ServerState::Starting) {
            *s = match result {
                Ok(rs) => ServerState::Running(rs),
                Err(e) => ServerState::Failed(format!("{e:#}")),
            };
        } else {
            // The host stopped (or restarted) while we were bringing up. If we
            // nonetheless got a live server, shut it back down so it doesn't
            // linger holding the port.
            drop(s);
            if let Ok(rs) = result {
                let _ = rs.shutdown().await;
            }
        }
    });

    Ok(())
}

/// Stop the server if running. Idempotent. Marking Stopped first means a
/// concurrent in-flight start observes the change and tears its result down.
/// Ported from `commands::do_stop`.
async fn do_stop() -> Result<(), String> {
    let st = state();
    let taken = {
        let mut s = st.server.lock().await;
        std::mem::replace(&mut *s, ServerState::Stopped)
    };
    if let ServerState::Running(rs) = taken {
        rs.shutdown().await.map_err(|e| format!("{e:#}"))?;
    }
    Ok(())
}

/// Current status without changing anything. Ported from `commands::do_status`.
async fn do_status() -> StatusDto {
    let st = state();
    let s = st.server.lock().await;
    match &*s {
        ServerState::Stopped => StatusDto::default(),
        ServerState::Failed(e) => StatusDto {
            error: Some(e.clone()),
            ..StatusDto::default()
        },
        ServerState::Starting => StatusDto {
            starting: true,
            // The server handle doesn't exist yet, so the login URL (if any)
            // is read from the log ring.
            auth_url: latest_auth_url(&st.log_ring),
            ..StatusDto::default()
        },
        ServerState::Running(r) => {
            let sessions: Vec<SessionDto> = r
                .sessions()
                .into_iter()
                .map(|sess| SessionDto {
                    name: sess.name,
                    workdir: sess.workdir.to_string_lossy().into_owned(),
                    client_count: sess.client_count,
                })
                .collect();

            // tailscale_status/auth_url only exist when motif-server is built
            // with the `tailscale` feature; without it there is no tsnet to
            // report, so both fields are simply absent.
            #[cfg(feature = "tailscale")]
            let (tailscale, auth_url) = {
                let raw_ts = r.tailscale_status().await;
                let auth_url = r
                    .tailscale_auth_url()
                    .or_else(|| raw_ts.as_ref().and_then(|s| s.auth_url.clone()));
                let tailscale = raw_ts.map(|s| TsStatusDto {
                    backend_state: s.backend_state,
                    peer_online: s.peer_online,
                    peer_total: s.peer_total,
                    health: s.health,
                });
                (tailscale, auth_url)
            };
            #[cfg(not(feature = "tailscale"))]
            let (tailscale, auth_url): (Option<TsStatusDto>, Option<String>) = (None, None);

            StatusDto {
                running: true,
                starting: false,
                bound_addrs: r.bound_addrs().to_vec(),
                session_count: sessions.len(),
                sessions,
                tailscale,
                auth_url,
                error: None,
            }
        }
    }
}

/// Most recent tailscale device-auth URL seen in the log ring, if any.
/// Ported from `commands::latest_auth_url`.
fn latest_auth_url(ring: &LogRing) -> Option<String> {
    ring.snapshot().iter().rev().find_map(|line| {
        let idx = line.find("login.tailscale.com/a/")?;
        let start = line[..idx]
            .rfind(char::is_whitespace)
            .map(|i| i + 1)
            .unwrap_or(0);
        let rest = &line[start..];
        let end = rest.find(char::is_whitespace).unwrap_or(rest.len());
        Some(rest[..end].to_string())
    })
}

// ─────────────────────────── ABI helpers ───────────────────────────

/// Move a Rust `String` onto the C heap. Released by [`motif_embed_free`].
fn into_c_string(s: String) -> *mut c_char {
    match CString::new(s) {
        Ok(c) => c.into_raw(),
        // The string contained an interior NUL — drop it rather than truncate.
        Err(_) => std::ptr::null_mut(),
    }
}

/// Borrow a caller-owned C string as a Rust `&str`. `None` on null or non-UTF-8.
///
/// # Safety
/// `ptr` must be null or a valid NUL-terminated string the caller keeps alive
/// for the duration of the call.
unsafe fn cstr_to_str<'a>(ptr: *const c_char) -> Option<&'a str> {
    if ptr.is_null() {
        return None;
    }
    CStr::from_ptr(ptr).to_str().ok()
}

// ─────────────────────────── C entry points ───────────────────────────

/// One-time init: build the embedded async runtime, route GUI logging into a
/// rolling file under `log_dir` + an in-memory ring (tailable via
/// [`motif_embed_tail_logs`]), and create the global state. Idempotent —
/// safe to call again (subsequent calls are a no-op returning 0).
///
/// Returns 0 on success, -1 if `log_dir` is null/invalid.
///
/// # Safety
/// `log_dir` must be null or a valid NUL-terminated UTF-8 path string.
#[no_mangle]
pub unsafe extern "C" fn motif_embed_init(log_dir: *const c_char) -> c_int {
    if STATE.get().is_some() {
        return 0;
    }
    let Some(log_dir) = cstr_to_str(log_dir) else {
        return -1;
    };
    let log_dir = PathBuf::from(log_dir);

    // Multi-thread runtime: tsnet bring-up uses `block_in_place`, which needs
    // a multi-thread scheduler. Same requirement as the menu-bar app's main.
    let runtime = match tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
    {
        Ok(r) => r,
        Err(_) => return -1,
    };
    let _ = RT.set(runtime);

    let log_ring = LogRing::new();
    // Best-effort: a second init in the same process would fail to re-register
    // the global tracing subscriber, which is fine.
    let _ = motif_server::init_tracing_gui("info,motif_tailscale=info", &log_dir, log_ring.clone());

    // Fallback tsnet state dir under the platform data dir, mirroring the
    // menu-bar app's `app_paths()` (`<data>/motif/tsnet`).
    let tsnet_dir = dirs::data_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("motif")
        .join("tsnet");

    let _ = STATE.set(EmbedState {
        server: Mutex::new(ServerState::Stopped),
        log_ring,
        tsnet_dir,
    });
    0
}

/// Generate a fresh bearer token (32 bytes, base64url). Caller frees with
/// [`motif_embed_free`].
#[no_mangle]
pub extern "C" fn motif_embed_generate_token() -> *mut c_char {
    into_c_string(motif_server::auth::generate_token())
}

/// Start the embedded server with the given config (the `MenuConfig` JSON
/// shape). Non-blocking: returns 0 once the start is *accepted* (the server
/// transitions to Starting), or -1 on a null/invalid-JSON config or a
/// fast-failing config (e.g. auth on with no token). Poll
/// [`motif_embed_status_json`] for progress and any `error`.
///
/// # Safety
/// `config_json` must be null or a valid NUL-terminated UTF-8 JSON string.
#[no_mangle]
pub unsafe extern "C" fn motif_embed_start(config_json: *const c_char) -> c_int {
    let Some(json) = cstr_to_str(config_json) else {
        return -1;
    };
    let cfg: MenuConfig = match serde_json::from_str(json) {
        Ok(c) => c,
        Err(e) => {
            tracing::warn!(error = %e, "motif_embed_start: bad config json");
            return -1;
        }
    };
    match rt().block_on(do_start(cfg)) {
        Ok(()) => 0,
        Err(e) => {
            tracing::warn!(error = %e, "motif_embed_start failed");
            -1
        }
    }
}

/// Stop the embedded server. Idempotent. Returns 0 on success, -1 if the
/// graceful shutdown errored.
#[no_mangle]
pub extern "C" fn motif_embed_stop() -> c_int {
    match rt().block_on(do_stop()) {
        Ok(()) => 0,
        Err(e) => {
            tracing::warn!(error = %e, "motif_embed_stop failed");
            -1
        }
    }
}

/// Current status as JSON (the `StatusDto` shape). Never null on success;
/// caller frees with [`motif_embed_free`].
#[no_mangle]
pub extern "C" fn motif_embed_status_json() -> *mut c_char {
    let status = rt().block_on(do_status());
    let json = serde_json::to_string(&status).unwrap_or_else(|_| "{}".to_string());
    into_c_string(json)
}

/// Last `n` log lines as a JSON string array. Caller frees with
/// [`motif_embed_free`].
#[no_mangle]
pub extern "C" fn motif_embed_tail_logs(n: c_int) -> *mut c_char {
    let all = state().log_ring.snapshot();
    let n = n.max(0) as usize;
    let start = all.len().saturating_sub(n);
    let json = serde_json::to_string(&all[start..]).unwrap_or_else(|_| "[]".to_string());
    into_c_string(json)
}

/// Release a string returned by any `motif_embed_*` function. Null-safe.
///
/// # Safety
/// `ptr` must be null or a pointer previously returned by this library and not
/// yet freed.
#[no_mangle]
pub unsafe extern "C" fn motif_embed_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(CString::from_raw(ptr));
    }
}
