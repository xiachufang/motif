use tauri::{
    image::Image,
    menu::{Menu, MenuItem, PredefinedMenuItem},
    tray::TrayIconBuilder,
    AppHandle, Manager, WebviewUrl, WebviewWindowBuilder,
};

use crate::app_state::AppState;
use crate::commands;

/// Build the status-bar tray icon + menu. Phase 1 menu is static
/// (Start/Stop/Settings/Quit); live status text in the tray comes in Phase 3.
pub fn build_tray(app: &AppHandle) -> tauri::Result<()> {
    let start_i = MenuItem::with_id(app, "start", "Start Server", true, None::<&str>)?;
    let stop_i = MenuItem::with_id(app, "stop", "Stop Server", true, None::<&str>)?;
    let settings_i = MenuItem::with_id(app, "settings", "Open Settings…", true, None::<&str>)?;
    let quit_i = MenuItem::with_id(app, "quit", "Quit Motif", true, None::<&str>)?;
    let sep = PredefinedMenuItem::separator(app)?;
    let menu = Menu::with_items(app, &[&start_i, &stop_i, &sep, &settings_i, &quit_i])?;

    TrayIconBuilder::with_id("main")
        .icon(tray_icon())
        .icon_as_template(true)
        .menu(&menu)
        .show_menu_on_left_click(true)
        .on_menu_event(|app, event| on_menu_event(app, event.id.as_ref()))
        .build(app)?;
    Ok(())
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
        .inner_size(420.0, 320.0)
        .resizable(true)
        .build()
    {
        tracing::warn!(error = %e, "failed to open settings window");
    }
}

/// A 32×32 filled disc, rendered black + alpha so macOS can tint it as a
/// template image. Built in code so Phase 1 needs no tray icon asset.
fn tray_icon() -> Image<'static> {
    const N: u32 = 32;
    let mut rgba = vec![0u8; (N * N * 4) as usize];
    let c = (N as f32 - 1.0) / 2.0;
    let r = N as f32 * 0.42;
    for y in 0..N {
        for x in 0..N {
            let dx = x as f32 - c;
            let dy = y as f32 - c;
            if dx * dx + dy * dy <= r * r {
                let i = ((y * N + x) * 4) as usize;
                rgba[i + 3] = 255; // opaque black (rgb already 0)
            }
        }
    }
    Image::new_owned(rgba, N, N)
}
