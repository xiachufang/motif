use std::time::Duration;

use tauri::{
    image::Image,
    menu::{Menu, MenuItem, PredefinedMenuItem},
    tray::TrayIconBuilder,
    AppHandle, Manager, WebviewUrl, WebviewWindowBuilder,
};

use crate::app_state::AppState;
use crate::commands;

const TRAY_ID: &str = "main";

/// What the tray icon color reflects.
#[derive(Clone, Copy, PartialEq, Eq)]
enum TrayState {
    Stopped,
    Running,
    NeedsLogin,
}

impl TrayState {
    fn rgb(self) -> (u8, u8, u8) {
        match self {
            TrayState::Stopped => (142, 142, 147),   // gray
            TrayState::Running => (40, 200, 90),      // green
            TrayState::NeedsLogin => (245, 158, 11),  // amber
        }
    }
}

/// Build the status-bar tray icon + menu.
pub fn build_tray(app: &AppHandle) -> tauri::Result<()> {
    let start_i = MenuItem::with_id(app, "start", "Start Server", true, None::<&str>)?;
    let stop_i = MenuItem::with_id(app, "stop", "Stop Server", true, None::<&str>)?;
    let settings_i = MenuItem::with_id(app, "settings", "Open Settings…", true, None::<&str>)?;
    let quit_i = MenuItem::with_id(app, "quit", "Quit Motif", true, None::<&str>)?;
    let sep = PredefinedMenuItem::separator(app)?;
    let menu = Menu::with_items(app, &[&start_i, &stop_i, &sep, &settings_i, &quit_i])?;

    TrayIconBuilder::with_id(TRAY_ID)
        // Colored status disc — NOT a template image, so the green/amber/gray
        // shows through on every platform (template mode would strip color).
        .icon(disc_icon(TrayState::Stopped))
        .icon_as_template(false)
        .menu(&menu)
        .show_menu_on_left_click(true)
        .on_menu_event(|app, event| on_menu_event(app, event.id.as_ref()))
        .build(app)?;
    Ok(())
}

/// Poll the server state every few seconds and recolor the tray icon when
/// it changes. Uses only cheap, local checks (no LocalAPI round-trip):
/// running + whether tsnet is waiting on a login URL.
pub fn spawn_status_poller(app: &AppHandle) {
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        let mut last: Option<TrayState> = None;
        loop {
            tokio::time::sleep(Duration::from_secs(3)).await;
            let cur = {
                let state = app.state::<AppState>();
                let guard = state.running.lock().await;
                match guard.as_ref() {
                    None => TrayState::Stopped,
                    Some(r) => {
                        if r.tailscale_auth_url().is_some() {
                            TrayState::NeedsLogin
                        } else {
                            TrayState::Running
                        }
                    }
                }
            };
            if Some(cur) == last {
                continue;
            }
            last = Some(cur);
            let app2 = app.clone();
            // Tray mutations go on the main thread to be safe across platforms.
            let _ = app.run_on_main_thread(move || {
                if let Some(tray) = app2.tray_by_id(TRAY_ID) {
                    let _ = tray.set_icon(Some(disc_icon(cur)));
                }
            });
        }
    });
}

fn on_menu_event(app: &AppHandle, id: &str) {
    match id {
        "start" => {
            let app = app.clone();
            tauri::async_runtime::spawn(async move {
                let state = app.state::<AppState>();
                if let Err(e) = commands::do_start(state.inner()).await {
                    tracing::warn!(error = %e, "tray: start failed");
                }
            });
        }
        "stop" => {
            let app = app.clone();
            tauri::async_runtime::spawn(async move {
                let state = app.state::<AppState>();
                if let Err(e) = commands::do_stop(state.inner()).await {
                    tracing::warn!(error = %e, "tray: stop failed");
                }
            });
        }
        "settings" => open_settings(app),
        "quit" => app.exit(0),
        _ => {}
    }
}

/// Show the settings window, creating it the first time. The window is a
/// regular webview pointed at the embedded `dist/index.html`.
pub fn open_settings(app: &AppHandle) {
    if let Some(w) = app.get_webview_window("settings") {
        let _ = w.show();
        let _ = w.set_focus();
        return;
    }
    if let Err(e) = WebviewWindowBuilder::new(app, "settings", WebviewUrl::App("index.html".into()))
        .title("Motif")
        .inner_size(440.0, 640.0)
        .resizable(true)
        .build()
    {
        tracing::warn!(error = %e, "failed to open settings window");
    }
}

/// A 32×32 filled disc in the given color (opaque), transparent elsewhere.
fn disc_icon(state: TrayState) -> Image<'static> {
    const N: u32 = 32;
    let (r8, g8, b8) = state.rgb();
    let mut rgba = vec![0u8; (N * N * 4) as usize];
    let c = (N as f32 - 1.0) / 2.0;
    let rad = N as f32 * 0.42;
    for y in 0..N {
        for x in 0..N {
            let dx = x as f32 - c;
            let dy = y as f32 - c;
            if dx * dx + dy * dy <= rad * rad {
                let i = ((y * N + x) * 4) as usize;
                rgba[i] = r8;
                rgba[i + 1] = g8;
                rgba[i + 2] = b8;
                rgba[i + 3] = 255;
            }
        }
    }
    Image::new_owned(rgba, N, N)
}
