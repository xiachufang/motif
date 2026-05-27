use std::time::Duration;

use tauri::{
    image::Image,
    menu::{Menu, MenuItem, PredefinedMenuItem},
    tray::TrayIconBuilder,
    AppHandle, Manager, WebviewUrl, WebviewWindowBuilder, Wry,
};

use crate::app_state::{AppState, ServerState};
use crate::commands;

const TRAY_ID: &str = "main";

/// Run state the tray icon reflects. Shown via a corner badge shape (not
/// color), so the icon can stay a single system-tinted template color.
#[derive(Clone, Copy, PartialEq, Eq)]
enum TrayState {
    Stopped,
    Starting,
    Running,
    NeedsLogin,
}

/// Build the menu for the current run state: only Start (stopped) or only
/// Stop (running), plus Settings + Quit. Rebuilt on state change rather than
/// toggling item visibility (muda has no per-item visibility).
fn build_menu(app: &AppHandle, running: bool) -> tauri::Result<Menu<Wry>> {
    let toggle = if running {
        MenuItem::with_id(app, "stop", "Stop Server", true, None::<&str>)?
    } else {
        MenuItem::with_id(app, "start", "Start Server", true, None::<&str>)?
    };
    let settings_i = MenuItem::with_id(app, "settings", "Open Settings…", true, None::<&str>)?;
    let quit_i = MenuItem::with_id(app, "quit", "Quit Motif", true, None::<&str>)?;
    let sep = PredefinedMenuItem::separator(app)?;
    Menu::with_items(app, &[&toggle, &sep, &settings_i, &quit_i])
}

/// Build the status-bar tray icon + menu.
pub fn build_tray(app: &AppHandle) -> tauri::Result<()> {
    let menu = build_menu(app, false)?;
    TrayIconBuilder::with_id(TRAY_ID)
        // Single-color template image (macOS tints it for the menu bar);
        // status is the corner badge shape, not color.
        .icon(status_icon(TrayState::Stopped))
        .icon_as_template(true)
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
                let guard = state.server.lock().await;
                match &*guard {
                    ServerState::Stopped | ServerState::Failed(_) => TrayState::Stopped,
                    ServerState::Starting => TrayState::Starting,
                    ServerState::Running(r) => {
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
            let was_running = last.map(|s| s != TrayState::Stopped);
            last = Some(cur);
            let running = cur != TrayState::Stopped;
            let app2 = app.clone();
            // Tray mutations go on the main thread to be safe across platforms.
            let _ = app.run_on_main_thread(move || {
                if let Some(tray) = app2.tray_by_id(TRAY_ID) {
                    let _ = tray.set_icon(Some(status_icon(cur)));
                    // Only swap the menu when the running/stopped split flips
                    // (NeedsLogin↔Running keeps the same Stop item).
                    if was_running != Some(running) {
                        if let Ok(menu) = build_menu(&app2, running) {
                            let _ = tray.set_menu(Some(menu));
                        }
                    }
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
                if let Err(e) = commands::do_start(&app).await {
                    tracing::warn!(error = %e, "tray: start failed");
                }
            });
        }
        "stop" => {
            let app = app.clone();
            tauri::async_runtime::spawn(async move {
                if let Err(e) = commands::do_stop(&app).await {
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
///
/// On macOS an Accessory app (no Dock icon) can't reliably bring a window
/// to the front with `set_focus()` alone — the app isn't frontmost. So we
/// promote to `Regular` while the window is open (which also surfaces it),
/// and drop back to `Accessory` when it closes. The Dock icon is only
/// present while Settings is showing.
pub fn open_settings(app: &AppHandle) {
    #[cfg(target_os = "macos")]
    let _ = app.set_activation_policy(tauri::ActivationPolicy::Regular);

    if let Some(w) = app.get_webview_window("settings") {
        let _ = w.unminimize();
        let _ = w.show();
        let _ = w.set_focus();
        return;
    }

    match WebviewWindowBuilder::new(app, "settings", WebviewUrl::App("index.html".into()))
        .title("Motif")
        .inner_size(440.0, 640.0)
        .resizable(true)
        .focused(true)
        .build()
    {
        Ok(w) => {
            // Revert to a Dock-less accessory app once Settings is dismissed.
            #[cfg(target_os = "macos")]
            {
                let app = app.clone();
                w.on_window_event(move |ev| {
                    if matches!(
                        ev,
                        tauri::WindowEvent::CloseRequested { .. } | tauri::WindowEvent::Destroyed
                    ) {
                        let _ = app.set_activation_policy(tauri::ActivationPolicy::Accessory);
                    }
                });
            }
            let _ = w.set_focus();
        }
        Err(e) => tracing::warn!(error = %e, "failed to open settings window"),
    }
}

/// The seed-of-life motif (same mark as the app icon) as a single-color
/// template image, with a bottom-right badge encoding run state by shape:
/// stopped = none, starting = hollow ring, running = filled dot,
/// needs-login = "!". A transparent knockout halo separates the badge from
/// the motif strokes. RGB is black; macOS tints the template for the bar.
/// 64px for retina crispness.
fn status_icon(state: TrayState) -> Image<'static> {
    const N: u32 = 64;
    let nf = N as f32;
    let c = (nf - 1.0) / 2.0;
    let boundary_r = nf * 0.40;
    let r = boundary_r / 2.0;
    let hw = nf * 0.025; // half stroke width

    let mut centers = [(c, c); 7];
    for k in 0..6 {
        let a = std::f32::consts::FRAC_PI_3 * k as f32 - std::f32::consts::FRAC_PI_6;
        centers[k + 1] = (c + r * a.cos(), c + r * a.sin());
    }
    let ring = |d: f32, cr: f32| (hw + 0.5 - (d - cr).abs()).clamp(0.0, 1.0);
    let disc = |d: f32, rr: f32| (rr + 0.5 - d).clamp(0.0, 1.0);
    let sring = |d: f32, rr: f32, h: f32| (h + 0.5 - (d - rr).abs()).clamp(0.0, 1.0);

    let (bx, by) = (nf * 0.74, nf * 0.74); // badge center
    let knock = nf * 0.27; // transparent halo radius

    let mut rgba = vec![0u8; (N * N * 4) as usize];
    for y in 0..N {
        for x in 0..N {
            let (px, py) = (x as f32, y as f32);

            // Motif strokes.
            let mut a = ring((px - c).hypot(py - c), boundary_r);
            for (cxx, cyy) in centers.iter() {
                if a >= 1.0 {
                    break;
                }
                a = a.max(ring((px - cxx).hypot(py - cyy), r));
            }

            if !matches!(state, TrayState::Stopped) {
                let db = (px - bx).hypot(py - by);
                a *= 1.0 - disc(db, knock); // clear a halo for the badge
                let glyph = match state {
                    TrayState::Running => disc(db, nf * 0.165),
                    TrayState::Starting => sring(db, nf * 0.15, nf * 0.045),
                    TrayState::NeedsLogin => {
                        // "!" — a short vertical capsule + a dot below.
                        let cyy = py.clamp(by - nf * 0.14, by + nf * 0.02);
                        let bar = (nf * 0.052 + 0.5 - (px - bx).hypot(py - cyy)).clamp(0.0, 1.0);
                        let dot =
                            (nf * 0.06 + 0.5 - (px - bx).hypot(py - (by + nf * 0.12))).clamp(0.0, 1.0);
                        bar.max(dot)
                    }
                    TrayState::Stopped => 0.0,
                };
                a = a.max(glyph);
            }

            let i = ((y * N + x) * 4) as usize;
            // Template image: color is black; status is shape, not color.
            rgba[i + 3] = (a * 255.0).round() as u8;
        }
    }
    Image::new_owned(rgba, N, N)
}
