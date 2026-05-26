use motif_server::{LogRing, RunningServer};
use tokio::sync::Mutex;

use crate::config::{AppPaths, MenuConfig};

/// Lifecycle of the embedded server. `Starting` exists because tsnet
/// bring-up can block for a while on first-run login — we must not freeze
/// the UI waiting for it, so start happens off the command path and this
/// reflects progress.
pub enum ServerState {
    Stopped,
    Starting,
    Running(RunningServer),
    /// Last start attempt failed; carries the message for the UI.
    Failed(String),
}

/// Shared app state, `manage`d by Tauri. The server lifecycle and current
/// config both live here; config is mirrored to `config.json` on every
/// `set_config`.
pub struct AppState {
    pub server: Mutex<ServerState>,
    pub config: Mutex<MenuConfig>,
    pub paths: AppPaths,
    pub log_ring: LogRing,
}

impl AppState {
    pub fn new(paths: AppPaths, config: MenuConfig, log_ring: LogRing) -> Self {
        Self {
            server: Mutex::new(ServerState::Stopped),
            config: Mutex::new(config),
            paths,
            log_ring,
        }
    }
}
