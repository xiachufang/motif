//! Motif menu-bar app. Runs an embedded `motifd` in-process and controls
//! it from the macOS/Windows/Linux system tray. The server lifecycle lives
//! behind [`AppState`]; the tray menu and the settings-window commands both
//! drive the same instance.

// Hide the extra console window on Windows in release builds.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod app_state;
mod commands;
mod config;
mod tray;

use app_state::AppState;
use tauri::Manager;

fn main() {
    // Tauri must own the main thread for the GUI event loop, so we can't use
    // `#[tokio::main]` (it would block the main thread in `block_on`).
    // Instead build a multi-thread runtime and register it as Tauri's async
    // runtime. Multi-thread is required: tsnet bring-up uses `block_in_place`.
    let rt = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("build tokio runtime");
    tauri::async_runtime::set(rt.handle().clone());

    // GUI has no stderr console: log to a file + an in-memory ring the
    // settings window can tail.
    let paths = config::app_paths();
    let log_ring = motif_server::LogRing::new();
    let _ = motif_server::init_tracing_gui("info,motif_tailscale=info", &paths.log_dir, log_ring.clone());
    let cfg = config::MenuConfig::load(&paths.config_file);
    let start_on_launch = cfg.autostart;
    let state = AppState::new(paths, cfg, log_ring);

    tauri::Builder::default()
        .plugin(tauri_plugin_autostart::init(
            tauri_plugin_autostart::MacosLauncher::LaunchAgent,
            None,
        ))
        .manage(state)
        .invoke_handler(tauri::generate_handler![
            commands::start_server,
            commands::stop_server,
            commands::get_status,
            commands::get_config,
            commands::set_config,
            commands::generate_token,
            commands::set_launch_at_login,
            commands::open_external,
            commands::tail_logs,
        ])
        .setup(move |app| {
            // Menu-bar app: no Dock icon on macOS.
            #[cfg(target_os = "macos")]
            app.set_activation_policy(tauri::ActivationPolicy::Accessory);
            tray::build_tray(app.handle())?;
            tray::spawn_status_poller(app.handle());

            // Optionally bring the server up immediately on launch.
            if start_on_launch {
                let handle = app.handle().clone();
                tauri::async_runtime::spawn(async move {
                    let state = handle.state::<AppState>();
                    if let Err(e) = commands::do_start(state.inner()).await {
                        tracing::warn!(error = %e, "autostart: server failed to start");
                    }
                });
            }
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("error building tauri app")
        .run(|_app, event| {
            // Closing the settings window must not quit the app — only an
            // explicit Quit (which calls `app.exit(0)`, carrying a code) does.
            if let tauri::RunEvent::ExitRequested { code, api, .. } = event {
                if code.is_none() {
                    api.prevent_exit();
                }
            }
        });

    // Keep the runtime alive until the app loop returns.
    drop(rt);
}
