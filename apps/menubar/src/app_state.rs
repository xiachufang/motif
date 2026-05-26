use motif_server::RunningServer;
use tokio::sync::Mutex;

/// Shared app state, `manage`d by Tauri. The running server (if any) lives
/// here behind an async mutex so both the tray menu handlers and the
/// settings-window commands drive the same instance. `None` = stopped.
#[derive(Default)]
pub struct AppState {
    pub running: Mutex<Option<RunningServer>>,
}
