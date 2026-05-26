use serde::Serialize;
use tauri::State;

use crate::app_state::AppState;
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
    pub bound_addrs: Vec<String>,
    pub session_count: usize,
    pub sessions: Vec<SessionDto>,
    pub tailscale: Option<TsStatusDto>,
    /// First-start Tailscale login URL, when the node is waiting on auth.
    pub auth_url: Option<String>,
}

/// Start the embedded server from the saved config. Errors (bad config,
/// port in use, …) come back as strings for the UI / tray to show.
pub async fn do_start(state: &AppState) -> Result<StatusDto, String> {
    let mut guard = state.running.lock().await;
    if guard.is_some() {
        return Err("server is already running".into());
    }
    let cfg = {
        let c = state.config.lock().await;
        c.to_server_config(&state.paths.tsnet_dir)?
    };
    let running = motif_server::start(cfg).await.map_err(|e| format!("{e:#}"))?;
    *guard = Some(running);
    drop(guard);
    Ok(do_status(state).await)
}

/// Stop the server if running. Idempotent.
pub async fn do_stop(state: &AppState) -> Result<StatusDto, String> {
    let mut guard = state.running.lock().await;
    if let Some(running) = guard.take() {
        running.shutdown().await.map_err(|e| format!("{e:#}"))?;
    }
    Ok(StatusDto::default())
}

/// Current status without changing anything. Reads sessions + tailscale
/// state straight off the in-process server.
pub async fn do_status(state: &AppState) -> StatusDto {
    let guard = state.running.lock().await;
    let Some(r) = guard.as_ref() else {
        return StatusDto::default();
    };

    let sessions: Vec<SessionDto> = r
        .sessions()
        .into_iter()
        .map(|s| SessionDto {
            name: s.name,
            workdir: s.workdir.to_string_lossy().into_owned(),
            client_count: s.client_count,
        })
        .collect();

    let raw_ts = r.tailscale_status().await;
    let auth_url = r
        .tailscale_auth_url()
        .or_else(|| raw_ts.as_ref().and_then(|s| s.auth_url.clone()));
    let tailscale = raw_ts.map(|st| TsStatusDto {
        backend_state: st.backend_state,
        peer_online: st.peer_online,
        peer_total: st.peer_total,
        health: st.health,
    });

    StatusDto {
        running: true,
        bound_addrs: r.bound_addrs().to_vec(),
        session_count: sessions.len(),
        sessions,
        tailscale,
        auth_url,
    }
}

// ─────────────────────────── Tauri commands ───────────────────────────

#[tauri::command]
pub async fn start_server(state: State<'_, AppState>) -> Result<StatusDto, String> {
    do_start(state.inner()).await
}

#[tauri::command]
pub async fn stop_server(state: State<'_, AppState>) -> Result<StatusDto, String> {
    do_stop(state.inner()).await
}

#[tauri::command]
pub async fn get_status(state: State<'_, AppState>) -> Result<StatusDto, String> {
    Ok(do_status(state.inner()).await)
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

/// Toggle OS launch-at-login (via tauri-plugin-autostart) and persist the
/// choice. The plugin registers/unregisters the current executable.
#[tauri::command]
pub async fn set_launch_at_login(
    app: tauri::AppHandle,
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
        // Empty title arg so `start` treats the URL as the target, not a title.
        c.args(["/C", "start", "", url]);
        c
    };
    cmd.spawn().map(|_| ())
}
