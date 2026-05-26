//! Motif menu-bar app. Runs an embedded `motifd` in-process and controls
//! it from the macOS/Windows/Linux system tray. The server lifecycle lives
//! behind [`AppState`]; the tray menu and the settings-window commands both
//! drive the same instance.

// Hide the extra console window on Windows in release builds.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod app_state;
mod commands;
mod tray;

use app_state::AppState;

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

    tauri::Builder::default()
        .manage(AppState::default())
        .invoke_handler(tauri::generate_handler![
            commands::start_server,
            commands::stop_server,
            commands::get_status,
        ])
        .setup(|app| {
            // Menu-bar app: no Dock icon on macOS.
            #[cfg(target_os = "macos")]
            app.set_activation_policy(tauri::ActivationPolicy::Accessory);
            tray::build_tray(app.handle())?;
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
