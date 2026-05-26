use std::time::Duration;

use serde::Serialize;
use tauri::{AppHandle, Manager, State};

use crate::app_state::{AppState, ServerState};
use crate::config::MenuConfig;

#[derive(Serialize, Clone)]
pub struct SessionDto {
    pub name: String,
    pub workdir: String,
    pub client_count: u32,
}

#[derive(Serialize, Clone)]
pub struct TsStatusDto {
    pub backend_state: String,
    pub peer_online: usize,
    pub peer_total: usize,
    pub health: Vec<String>,
}

/// Full status for the settings window + tray.
#[derive(Serialize, Clone, Default)]
pub struct StatusDto {
    pub running: bool,
    pub starting: bool,
    pub bound_addrs: Vec<String>,
    pub session_count: usize,
    pub sessions: Vec<SessionDto>,
    pub tailscale: Option<TsStatusDto>,
    /// First-start Tailscale login URL, when the node is waiting on auth.
    pub auth_url: Option<String>,
    /// Last start failure, if any.
    pub error: Option<String>,
}

/// Begin starting the server. Returns immediately (non-blocking): the
/// potentially-slow `motif_server::start()` (tsnet bring-up can wait on
/// first-run login) runs on a background task so the UI never freezes. The
/// state machine in [`ServerState`] reflects progress.
pub async fn do_start(app: &AppHandle) -> Result<(), String> {
    let state = app.state::<AppState>();

    // Claim the Starting slot, rejecting double-starts.
    {
        let mut s = state.server.lock().await;
        match &*s {
            ServerState::Starting => return Err("server is already starting".into()),
            ServerState::Running(_) => return Err("server is already running".into()),
            _ => {}
        }
        *s = ServerState::Starting;
    }

    // Build the config up front so obvious mistakes fail fast (and reset
    // the state) rather than after a spawn.
    let (cfg, ts_enabled) = {
        let c = state.config.lock().await;
        match c.to_server_config(&state.paths.tsnet_dir) {
            Ok(cfg) => (cfg, c.tailscale.enabled),
            Err(e) => {
                *state.server.lock().await = ServerState::Failed(e.clone());
                return Err(e);
            }
        }
    };

    // If tailscale is on, watch for a first-run login URL and open it so the
    // user isn't left wondering why nothing happened.
    if ts_enabled {
        spawn_login_url_opener(app.clone());
    }

    // Run the (possibly long) bring-up off the command path.
    let app2 = app.clone();
    tauri::async_runtime::spawn(async move {
        let result = motif_server::start(cfg).await;
        let state = app2.state::<AppState>();
        let mut s = state.server.lock().await;
        if matches!(&*s, ServerState::Starting) {
            *s = match result {
                Ok(rs) => ServerState::Running(rs),
                Err(e) => ServerState::Failed(format!("{e:#}")),
            };
        } else {
            // The user stopped (or restarted) while we were bringing up. If
            // we nonetheless got a live server, shut it back down so it
            // doesn't linger holding the port.
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
pub async fn do_stop(app: &AppHandle) -> Result<(), String> {
    let state = app.state::<AppState>();
    let taken = {
        let mut s = state.server.lock().await;
        std::mem::replace(&mut *s, ServerState::Stopped)
    };
    if let ServerState::Running(rs) = taken {
        rs.shutdown().await.map_err(|e| format!("{e:#}"))?;
    }
    Ok(())
}

/// Current status without changing anything.
pub async fn do_status(app: &AppHandle) -> StatusDto {
    let state = app.state::<AppState>();
    let s = state.server.lock().await;
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
            auth_url: latest_auth_url(&state.log_ring),
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

            let raw_ts = r.tailscale_status().await;
            let auth_url = r
                .tailscale_auth_url()
                .or_else(|| raw_ts.as_ref().and_then(|st| st.auth_url.clone()));
            let tailscale = raw_ts.map(|st| TsStatusDto {
                backend_state: st.backend_state,
                peer_online: st.peer_online,
                peer_total: st.peer_total,
                health: st.health,
            });

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

/// Poll the log ring for a first-run tailscale login URL and open it once,
/// until the server stops being in the `Starting` state.
fn spawn_login_url_opener(app: AppHandle) {
    tauri::async_runtime::spawn(async move {
        let state = app.state::<AppState>();
        for _ in 0..120 {
            if !matches!(&*state.server.lock().await, ServerState::Starting) {
                return;
            }
            if let Some(url) = latest_auth_url(&state.log_ring) {
                let _ = open_url(&url);
                return;
            }
            tokio::time::sleep(Duration::from_millis(500)).await;
        }
    });
}

/// Most recent tailscale device-auth URL seen in the log ring, if any.
fn latest_auth_url(ring: &motif_server::LogRing) -> Option<String> {
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

// ─────────────────────────── Tauri commands ───────────────────────────

#[tauri::command]
pub async fn start_server(app: AppHandle) -> Result<StatusDto, String> {
    do_start(&app).await?;
    Ok(do_status(&app).await)
}

#[tauri::command]
pub async fn stop_server(app: AppHandle) -> Result<StatusDto, String> {
    do_stop(&app).await?;
    Ok(do_status(&app).await)
}

#[tauri::command]
pub async fn get_status(app: AppHandle) -> Result<StatusDto, String> {
    Ok(do_status(&app).await)
}

#[tauri::command]
pub async fn get_config(state: State<'_, AppState>) -> Result<MenuConfig, String> {
    Ok(state.config.lock().await.clone())
}

/// Persist the settings window's config to disk and cache it. Does not
/// restart a running server — the user restarts to apply.
#[tauri::command]
pub async fn set_config(state: State<'_, AppState>, config: MenuConfig) -> Result<(), String> {
    config
        .save(&state.paths.config_file)
        .map_err(|e| format!("saving config: {e}"))?;
    *state.config.lock().await = config;
    Ok(())
}

#[tauri::command]
pub fn generate_token() -> String {
    motif_server::auth::generate_token()
}

/// Toggle OS launch-at-login (via tauri-plugin-autostart) and persist it.
#[tauri::command]
pub async fn set_launch_at_login(
    app: AppHandle,
    state: State<'_, AppState>,
    enable: bool,
) -> Result<(), String> {
    use tauri_plugin_autostart::ManagerExt;
    let mgr = app.autolaunch();
    let res = if enable { mgr.enable() } else { mgr.disable() };
    res.map_err(|e| format!("autostart: {e}"))?;
    let mut c = state.config.lock().await;
    c.launch_at_login = enable;
    c.save(&state.paths.config_file)
        .map_err(|e| format!("saving config: {e}"))?;
    Ok(())
}

/// Open an http(s) URL (the Tailscale login link) in the default browser.
#[tauri::command]
pub fn open_external(url: String) -> Result<(), String> {
    if !(url.starts_with("https://") || url.starts_with("http://")) {
        return Err("refusing to open a non-http(s) URL".into());
    }
    open_url(&url).map_err(|e| format!("opening browser: {e}"))
}

#[tauri::command]
pub async fn tail_logs(state: State<'_, AppState>, lines: usize) -> Result<Vec<String>, String> {
    let all = state.log_ring.snapshot();
    let start = all.len().saturating_sub(lines);
    Ok(all[start..].to_vec())
}

/// Spawn the platform "open this URL" helper. No shell, args passed
/// directly, so the (already http-validated) URL can't be reinterpreted.
fn open_url(url: &str) -> std::io::Result<()> {
    #[cfg(target_os = "macos")]
    let mut cmd = {
        let mut c = std::process::Command::new("open");
        c.arg(url);
        c
    };
    #[cfg(target_os = "linux")]
    let mut cmd = {
        let mut c = std::process::Command::new("xdg-open");
        c.arg(url);
        c
    };
    #[cfg(target_os = "windows")]
    let mut cmd = {
        let mut c = std::process::Command::new("cmd");
        c.args(["/C", "start", "", url]);
        c
    };
    cmd.spawn().map(|_| ())
}
