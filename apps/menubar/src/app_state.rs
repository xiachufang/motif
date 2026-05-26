use motif_server::{LogRing, RunningServer};
use tokio::sync::Mutex;

use crate::config::{AppPaths, MenuConfig};

/// Shared app state, `manage`d by Tauri. The running server (if any) lives
/// behind an async mutex so both the tray menu handlers and the
/// settings-window commands drive the same instance. The current config is
/// cached here (mirrored to `config.json` on every `set_config`).
pub struct AppState {
    pub running: Mutex<Option<RunningServer>>,
    pub config: Mutex<MenuConfig>,
    pub paths: AppPaths,
    pub log_ring: LogRing,
}

impl AppState {
    pub fn new(paths: AppPaths, config: MenuConfig, log_ring: LogRing) -> Self {
        Self {
            running: Mutex::new(None),
            config: Mutex::new(config),
            paths,
            log_ring,
        }
    }
}
