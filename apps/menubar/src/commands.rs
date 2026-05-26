use std::net::{Ipv4Addr, SocketAddr};

use motif_server::ServerConfig;
use serde::Serialize;
use tauri::State;

use crate::app_state::AppState;

/// Status sent to the settings window / used for the tray.
#[derive(Serialize, Clone, Default)]
pub struct StatusDto {
    pub running: bool,
    pub bound_addrs: Vec<String>,
    pub session_count: usize,
}

/// Phase 1: a fixed loopback config. Token-less is allowed here because the
/// surface is 127.0.0.1 only (see `ServerConfig::validate`). Listen address,
/// auth, and tailscale become user-configurable in Phase 2.
fn phase1_config() -> ServerConfig {
    ServerConfig {
        listen: Some(SocketAddr::from((Ipv4Addr::LOCALHOST, 7777))),
        tailscale: None,
        token: None,
        cert: None,
        key: None,
        allow_insecure_no_auth: false,
    }
}

/// Start the embedded server if not already running. Errors (e.g. port in
/// use) are surfaced as strings for the UI / tray to show.
pub async fn do_start(state: &AppState) -> Result<StatusDto, String> {
    let mut guard = state.running.lock().await;
    if guard.is_some() {
        return Err("server is already running".into());
    }
    let running = motif_server::start(phase1_config())
        .await
        .map_err(|e| format!("{e:#}"))?;
    let dto = StatusDto {
        running: true,
        bound_addrs: running.bound_addrs().to_vec(),
        session_count: running.session_count(),
    };
    *guard = Some(running);
    Ok(dto)
}

/// Stop the server if running. Idempotent: a no-op when already stopped.
pub async fn do_stop(state: &AppState) -> Result<StatusDto, String> {
    let mut guard = state.running.lock().await;
    if let Some(running) = guard.take() {
        running.shutdown().await.map_err(|e| format!("{e:#}"))?;
    }
    Ok(StatusDto::default())
}

/// Current status without changing anything.
pub async fn do_status(state: &AppState) -> StatusDto {
    let guard = state.running.lock().await;
    match guard.as_ref() {
        Some(r) => StatusDto {
            running: true,
            bound_addrs: r.bound_addrs().to_vec(),
            session_count: r.session_count(),
        },
        None => StatusDto::default(),
    }
}

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
