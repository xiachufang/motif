use std::time::Duration;

use tauri::{
    image::Image,
    menu::{IsMenuItem, Menu, MenuItem, PredefinedMenuItem},
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
///
/// "Open Web UI…" (in-app window) and "Open in Browser…" (default browser) are
/// shown only while running — they point at the server's served HTTP endpoint,
/// so there's nothing to open when stopped.
fn build_menu(app: &AppHandle, running: bool) -> tauri::Result<Menu<Wry>> {
    let toggle = if running {
        MenuItem::with_id(app, "stop", "Stop Server", true, None::<&str>)?
    } else {
        MenuItem::with_id(app, "start", "Start Server", true, None::<&str>)?
    };
    let web_i = MenuItem::with_id(app, "open_web", "Open Web UI…", true, None::<&str>)?;
    let browser_i = MenuItem::with_id(app, "open_browser", "Open in Browser…", true, None::<&str>)?;
    let settings_i = MenuItem::with_id(app, "settings", "Open Settings…", true, None::<&str>)?;
    let quit_i = MenuItem::with_id(app, "quit", "Quit Motif", true, None::<&str>)?;
    let sep = PredefinedMenuItem::separator(app)?;
    let mut items: Vec<&dyn IsMenuItem<Wry>> = vec![&toggle];
    if running {
        items.push(&web_i);
        items.push(&browser_i);
    }
    items.extend([&sep as &dyn IsMenuItem<Wry>, &settings_i, &quit_i]);
    Menu::with_items(app, &items)
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
                    // set_icon drops the template flag, so re-assert it or the
                    // icon renders solid black instead of being system-tinted.
                    let _ = tray.set_icon_as_template(true);
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
        "open_web" => open_web_ui(app),
        "open_browser" => open_web_in_browser(app),
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
            #[cfg(target_os = "macos")]
            revert_accessory_on_last_close(app, &w);
            let _ = w.set_focus();
        }
        Err(e) => tracing::warn!(error = %e, "failed to open settings window"),
    }
}

/// Open the server's served web UI in its own window. Unlike Settings (which
/// loads the embedded menubar dist), this points at the running server's HTTP
/// endpoint over loopback. The menu item only appears while running, but the
/// state can still change between the click and here, so this re-checks.
pub fn open_web_ui(app: &AppHandle) {
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        let Some(url) = web_ui_url(&app).await else {
            tracing::warn!("open web ui: no local HTTP endpoint (server stopped or Tailscale-only)");
            return;
        };
        // Window/activation-policy mutations belong on the main thread.
        let app2 = app.clone();
        let _ = app.run_on_main_thread(move || show_web_window(&app2, &url));
    });
}

/// The loopback HTTP URL the running server can be reached at locally, or
/// `None` if it isn't running or only listens on Tailscale (no local TCP).
/// `0.0.0.0` (LAN mode) is reachable via `127.0.0.1` from this machine.
///
/// When auth is enabled, the configured token is appended as a `?token=`
/// query param so the web UI auto-connects instead of prompting for it. The
/// web app strips the param from the address bar after reading it.
async fn web_ui_url(app: &AppHandle) -> Option<String> {
    let state = app.state::<AppState>();
    let guard = state.server.lock().await;
    let ServerState::Running(r) = &*guard else {
        return None;
    };
    let base = r.bound_addrs().iter().find_map(|a| {
        let host_port = a.strip_prefix("tcp://")?.replacen("0.0.0.0", "127.0.0.1", 1);
        Some(format!("http://{host_port}/"))
    })?;
    drop(guard);

    let auth = {
        let cfg = state.config.lock().await;
        cfg.auth.clone()
    };
    if !auth.enabled || auth.token.trim().is_empty() {
        return Some(base);
    }
    match url::Url::parse(&base) {
        Ok(mut u) => {
            u.query_pairs_mut().append_pair("token", auth.token.trim());
            Some(u.into())
        }
        // Fall back to the token-less URL rather than failing to open at all.
        Err(e) => {
            tracing::warn!(error = %e, %base, "web ui: bad base URL; opening without token");
            Some(base)
        }
    }
}

/// Open the server's web UI in the user's default browser (token embedded, as
/// in `open_web_ui`). Same running re-check; the menu item only shows while up.
pub fn open_web_in_browser(app: &AppHandle) {
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        let Some(url) = web_ui_url(&app).await else {
            tracing::warn!("open in browser: no local HTTP endpoint (server stopped or Tailscale-only)");
            return;
        };
        if let Err(e) = open_in_default_browser(&url) {
            tracing::warn!(error = %e, %url, "failed to open web ui in browser");
        }
    });
}

/// Hand a URL to the OS default browser. Uses the platform launcher rather
/// than pulling in a Tauri plugin, since this is the app's only such need.
fn open_in_default_browser(url: &str) -> std::io::Result<()> {
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
        // `start` is a cmd builtin; the empty "" is the window-title arg so a
        // quoted URL isn't mistaken for the title.
        let mut c = std::process::Command::new("cmd");
        c.args(["/C", "start", "", url]);
        c
    };
    cmd.spawn().map(|_| ())
}

/// Create (or focus) the web-UI window, pointed at `url`. Mirrors the
/// Settings window's macOS Dock-icon dance so an Accessory app can bring it
/// frontmost. Must run on the main thread.
fn show_web_window(app: &AppHandle, url: &str) {
    #[cfg(target_os = "macos")]
    let _ = app.set_activation_policy(tauri::ActivationPolicy::Regular);

    if let Some(w) = app.get_webview_window("webui") {
        let _ = w.unminimize();
        let _ = w.show();
        let _ = w.set_focus();
        return;
    }

    let parsed = match url.parse() {
        Ok(u) => u,
        Err(e) => {
            tracing::warn!(error = %e, %url, "web ui: bad URL");
            return;
        }
    };

    match WebviewWindowBuilder::new(app, "webui", WebviewUrl::External(parsed))
        .title("Motif Web")
        .inner_size(1024.0, 720.0)
        .resizable(true)
        .focused(true)
        .build()
    {
        Ok(w) => {
            #[cfg(target_os = "macos")]
            revert_accessory_on_last_close(app, &w);
            let _ = w.set_focus();
        }
        Err(e) => tracing::warn!(error = %e, "failed to open web ui window"),
    }
}

/// Drop back to a Dock-less Accessory app once the *last* app window is gone.
/// Checked on destroy (the closing window is already out of the registry by
/// then) so closing one of several windows doesn't hide the rest.
#[cfg(target_os = "macos")]
fn revert_accessory_on_last_close(app: &AppHandle, w: &tauri::WebviewWindow) {
    let app = app.clone();
    w.on_window_event(move |ev| {
        if matches!(ev, tauri::WindowEvent::Destroyed) && app.webview_windows().is_empty() {
            let _ = app.set_activation_policy(tauri::ActivationPolicy::Accessory);
        }
    });
}

/// Three stacked water-ripple waves as a single-color template image, with a
/// bottom-right badge encoding run state by shape: stopped = none,
/// starting = hollow ring, running = filled dot, needs-login = "!". A
/// transparent knockout halo separates the badge from the waves. RGB is
/// black; macOS tints the template for the bar. 64px for retina crispness.
fn status_icon(state: TrayState) -> Image<'static> {
    const N: u32 = 64;
    let nf = N as f32;
    let c = (nf - 1.0) / 2.0;

    let hw = nf * 0.05; // half stroke width (≈0.10·N stroke)
    let amp = nf * 0.055; // wave amplitude
    let k = std::f32::consts::TAU / (nf * 0.62); // ≈1.5 cycles across the mark
    let bases = [0.27_f32, 0.50, 0.73]; // wave baselines (fraction of N)
    let half_w = nf * 0.40; // clip waves to the central band

    let disc = |d: f32, rr: f32| (rr + 0.5 - d).clamp(0.0, 1.0);
    let sring = |d: f32, rr: f32, h: f32| (h + 0.5 - (d - rr).abs()).clamp(0.0, 1.0);

    let (bx, by) = (nf * 0.76, nf * 0.76); // badge center
    let knock = nf * 0.25; // transparent halo radius

    let mut rgba = vec![0u8; (N * N * 4) as usize];
    for y in 0..N {
        for x in 0..N {
            let (px, py) = (x as f32, y as f32);

            // Waves.
            let mut a = 0.0_f32;
            if (px - c).abs() <= half_w {
                for b in bases {
                    let yy = nf * b + amp * ((px - c) * k).sin();
                    a = a.max((hw + 0.5 - (py - yy).abs()).clamp(0.0, 1.0));
                }
            }

            if !matches!(state, TrayState::Stopped) {
                let db = (px - bx).hypot(py - by);
                a *= 1.0 - disc(db, knock); // clear a halo for the badge
                let glyph = match state {
                    TrayState::Running => disc(db, nf * 0.15),
                    TrayState::Starting => sring(db, nf * 0.135, nf * 0.045),
                    TrayState::NeedsLogin => {
                        // "!" — a short vertical capsule + a dot below.
                        let cyy = py.clamp(by - nf * 0.13, by + nf * 0.02);
                        let bar = (nf * 0.05 + 0.5 - (px - bx).hypot(py - cyy)).clamp(0.0, 1.0);
                        let dot =
                            (nf * 0.055 + 0.5 - (px - bx).hypot(py - (by + nf * 0.11))).clamp(0.0, 1.0);
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
