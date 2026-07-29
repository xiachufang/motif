//! Cross-platform one-shot screen capture service.
//!
//! The public service owns policy (opt-in enablement, single-flight, size
//! limits). Platform-specific enumeration/capture stays behind `CaptureBackend`
//! so protocol tests can use a deterministic fake without a graphical session.

use std::sync::Arc;

#[cfg(all(
    feature = "screen-capture",
    any(target_os = "macos", target_os = "windows", target_os = "linux")
))]
use std::collections::{BTreeMap, HashSet};

#[cfg(all(feature = "screen-capture", target_os = "linux"))]
use motif_proto::capture::CaptureWindow;
#[cfg(all(
    feature = "screen-capture",
    any(target_os = "macos", target_os = "windows", target_os = "linux")
))]
use motif_proto::capture::{CaptureDisplay, CaptureTargetKind};
use motif_proto::capture::{CaptureTarget, TargetsResult};
use motif_proto::error::{ErrorCode, RpcError};
use parking_lot::Mutex;

#[cfg(all(feature = "screen-capture", target_os = "macos"))]
#[path = "capture_macos.rs"]
mod capture_macos;

#[cfg(all(feature = "screen-capture", target_os = "windows"))]
#[path = "capture_windows.rs"]
mod capture_windows;

const MAX_CAPTURE_PIXELS: u64 = 50_000_000;
const MAX_CAPTURE_BYTES: usize = 32 * 1024 * 1024;

#[derive(Debug, Clone)]
pub struct CapturedImage {
    pub png: Vec<u8>,
    pub width: u32,
    pub height: u32,
}

pub trait CaptureBackend: Send + Sync + 'static {
    /// Whether this binary contains a usable implementation for its target OS.
    fn supported_in_build(&self) -> bool;
    fn targets(&self) -> Result<TargetsResult, RpcError>;
    fn capture(&self, target: &CaptureTarget) -> Result<CapturedImage, RpcError>;
}

#[derive(Clone)]
pub struct CaptureService {
    enabled: bool,
    backend: Arc<dyn CaptureBackend>,
    gate: Arc<Mutex<()>>,
}

impl std::fmt::Debug for CaptureService {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CaptureService")
            .field("enabled", &self.enabled)
            .field("supported_in_build", &self.backend.supported_in_build())
            .finish()
    }
}

impl CaptureService {
    pub fn system(enabled: bool) -> Arc<Self> {
        Arc::new(Self::new(enabled, Arc::new(SystemCaptureBackend)))
    }

    pub fn disabled() -> Arc<Self> {
        Arc::new(Self::new(false, Arc::new(UnavailableBackend)))
    }

    pub fn new(enabled: bool, backend: Arc<dyn CaptureBackend>) -> Self {
        Self {
            enabled,
            backend,
            gate: Arc::new(Mutex::new(())),
        }
    }

    pub fn is_advertised(&self) -> bool {
        self.enabled && self.backend.supported_in_build()
    }

    pub fn targets(&self) -> Result<TargetsResult, RpcError> {
        if !self.enabled {
            return Ok(TargetsResult::unavailable(
                "Remote screen capture is disabled on this server",
            ));
        }
        if !self.backend.supported_in_build() {
            return Ok(TargetsResult::unavailable(
                "This motifd build has no screen capture backend",
            ));
        }
        self.backend.targets()
    }

    pub fn capture(&self, target: &CaptureTarget) -> Result<CapturedImage, RpcError> {
        if !self.enabled {
            return Err(RpcError::new(
                ErrorCode::CaptureUnavailable,
                "remote screen capture is disabled on this server",
            ));
        }
        if !self.backend.supported_in_build() {
            return Err(RpcError::new(
                ErrorCode::CaptureUnavailable,
                "this motifd build has no screen capture backend",
            ));
        }
        let Some(_guard) = self.gate.try_lock() else {
            return Err(RpcError::new(
                ErrorCode::CaptureBusy,
                "another screenshot is already in progress",
            ));
        };
        let image = self.backend.capture(target)?;
        let pixels = u64::from(image.width) * u64::from(image.height);
        if pixels > MAX_CAPTURE_PIXELS || image.png.len() > MAX_CAPTURE_BYTES {
            return Err(RpcError::new(
                ErrorCode::CaptureTooLarge,
                format!(
                    "captured image is {}x{} ({} bytes), exceeds server limit",
                    image.width,
                    image.height,
                    image.png.len()
                ),
            ));
        }
        Ok(image)
    }
}

struct UnavailableBackend;

impl CaptureBackend for UnavailableBackend {
    fn supported_in_build(&self) -> bool {
        false
    }

    fn targets(&self) -> Result<TargetsResult, RpcError> {
        Ok(TargetsResult::unavailable(
            "This motifd build has no screen capture backend",
        ))
    }

    fn capture(&self, _target: &CaptureTarget) -> Result<CapturedImage, RpcError> {
        Err(RpcError::new(
            ErrorCode::CaptureUnavailable,
            "this motifd build has no screen capture backend",
        ))
    }
}

struct SystemCaptureBackend;

#[cfg(all(
    feature = "screen-capture",
    any(target_os = "macos", target_os = "windows", target_os = "linux")
))]
impl CaptureBackend for SystemCaptureBackend {
    fn supported_in_build(&self) -> bool {
        true
    }

    fn targets(&self) -> Result<TargetsResult, RpcError> {
        system_targets()
    }

    fn capture(&self, target: &CaptureTarget) -> Result<CapturedImage, RpcError> {
        system_capture(target)
    }
}

#[cfg(not(all(
    feature = "screen-capture",
    any(target_os = "macos", target_os = "windows", target_os = "linux")
)))]
impl CaptureBackend for SystemCaptureBackend {
    fn supported_in_build(&self) -> bool {
        false
    }

    fn targets(&self) -> Result<TargetsResult, RpcError> {
        UnavailableBackend.targets()
    }

    fn capture(&self, target: &CaptureTarget) -> Result<CapturedImage, RpcError> {
        UnavailableBackend.capture(target)
    }
}

#[cfg(all(
    feature = "screen-capture",
    any(target_os = "macos", target_os = "windows", target_os = "linux")
))]
fn system_targets() -> Result<TargetsResult, RpcError> {
    let monitor_result = xcap::Monitor::all();
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    let window_result = xcap::Window::all();
    let mut displays = Vec::new();
    let mut windows = Vec::new();
    let mut app_icons_png_b64 = BTreeMap::new();
    let mut icon_attempted = HashSet::new();
    let mut errors = Vec::new();

    match monitor_result {
        Ok(found) => {
            for monitor in found {
                let (Ok(id), Ok(width), Ok(height)) =
                    (monitor.id(), monitor.width(), monitor.height())
                else {
                    continue;
                };
                if width == 0 || height == 0 {
                    continue;
                }
                let name = monitor
                    .friendly_name()
                    .or_else(|_| monitor.name())
                    .unwrap_or_else(|_| format!("Display {id}"));
                let scale_factor_milli = monitor
                    .scale_factor()
                    .ok()
                    .map(|value| (value.max(0.0) * 1000.0).round() as u32)
                    .unwrap_or(1000);
                displays.push(CaptureDisplay {
                    id: format!("display:{id}"),
                    name,
                    width,
                    height,
                    x: monitor.x().unwrap_or_default(),
                    y: monitor.y().unwrap_or_default(),
                    scale_factor_milli,
                    primary: monitor.is_primary().unwrap_or(false),
                });
            }
        }
        Err(error) => errors.push(format!("display enumeration: {error}")),
    }

    #[cfg(target_os = "macos")]
    match capture_macos::all_windows() {
        Ok(found) => windows = found,
        Err(error) => errors.push(format!("window enumeration: {error}")),
    }
    #[cfg(target_os = "macos")]
    windows.retain(|window| !is_macos_system_surface_app(&window.app_name));

    #[cfg(target_os = "windows")]
    match capture_windows::all_windows() {
        Ok(found) => windows = found,
        Err(error) => errors.push(format!("window enumeration: {error}")),
    }

    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    match window_result {
        Ok(found) => {
            for window in found {
                if window.is_minimized().unwrap_or(true) {
                    continue;
                }
                let (Ok(id), Ok(pid), Ok(width), Ok(height)) =
                    (window.id(), window.pid(), window.width(), window.height())
                else {
                    continue;
                };
                if width == 0 || height == 0 {
                    continue;
                }
                let title = window.title().unwrap_or_default().trim().to_string();
                let app_name = window.app_name().unwrap_or_default().trim().to_string();
                if title.is_empty() && app_name.is_empty() {
                    continue;
                }
                windows.push(CaptureWindow {
                    id: format!("window:{id}"),
                    app_name,
                    title,
                    pid,
                    width,
                    height,
                    x: window.x().unwrap_or_default(),
                    y: window.y().unwrap_or_default(),
                    focused: window.is_focused().unwrap_or(false),
                });
            }
        }
        Err(error) => errors.push(format!("window enumeration: {error}")),
    }

    #[cfg(target_os = "linux")]
    if linux_wayland_session() {
        errors.push(
            "Wayland does not allow silent enumeration of native windows; only XWayland windows are listed"
                .to_string(),
        );
    }

    for window in &windows {
        if !window.app_name.is_empty() && icon_attempted.insert(window.app_name.clone()) {
            if let Some(icon) = application_icon_png_b64(window.pid, &window.app_name) {
                app_icons_png_b64.insert(window.app_name.clone(), icon);
            }
        }
    }

    if displays.is_empty() && windows.is_empty() {
        let reason = if errors.is_empty() {
            "No displays or capturable windows are available".to_string()
        } else {
            errors.join("; ")
        };
        return Ok(TargetsResult::unavailable(reason));
    }

    displays.sort_by_key(|display| (!display.primary, display.name.clone()));
    windows.sort_by_key(|window| {
        (
            !window.focused,
            window.app_name.clone(),
            window.title.clone(),
        )
    });
    Ok(TargetsResult {
        available: true,
        reason: (!errors.is_empty()).then(|| errors.join("; ")),
        displays,
        windows,
        app_icons_png_b64,
    })
}

#[cfg(all(feature = "screen-capture", target_os = "macos"))]
fn application_icon_png_b64(pid: u32, _app_name: &str) -> Option<String> {
    use objc2_app_kit::NSRunningApplication;

    let application = NSRunningApplication::runningApplicationWithProcessIdentifier(pid as _)?;
    let url = application
        .bundleURL()
        .or_else(|| application.executableURL())?;
    let path = url.path()?.to_string();
    encode_file_icon_png(path)
}

#[cfg(all(feature = "screen-capture", target_os = "windows"))]
fn application_icon_png_b64(pid: u32, _app_name: &str) -> Option<String> {
    use std::ffi::OsString;
    use std::os::windows::ffi::OsStringExt;
    use windows_sys::Win32::Foundation::CloseHandle;
    use windows_sys::Win32::System::Threading::{
        OpenProcess, QueryFullProcessImageNameW, PROCESS_QUERY_LIMITED_INFORMATION,
    };

    // SAFETY: the process handle is checked before use, the UTF-16 buffer is
    // writable for the reported capacity, and the handle is always closed.
    let path = unsafe {
        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
        if process.is_null() {
            return None;
        }
        let mut buffer = vec![0u16; 32_768];
        let mut len = buffer.len() as u32;
        let ok = QueryFullProcessImageNameW(process, 0, buffer.as_mut_ptr(), &mut len);
        let _ = CloseHandle(process);
        if ok == 0 || len == 0 {
            return None;
        }
        OsString::from_wide(&buffer[..len as usize])
    };
    encode_file_icon_png(path)
}

#[cfg(all(
    feature = "screen-capture",
    any(target_os = "macos", target_os = "windows")
))]
fn encode_file_icon_png(path: impl AsRef<std::path::Path>) -> Option<String> {
    use base64::Engine;

    let icon = file_icon_provider::get_file_icon(path, 32).ok()?;
    let image = xcap::image::RgbaImage::from_raw(icon.width, icon.height, icon.pixels)?;
    let mut cursor = std::io::Cursor::new(Vec::new());
    xcap::image::DynamicImage::ImageRgba8(image)
        .write_to(&mut cursor, xcap::image::ImageFormat::Png)
        .ok()?;
    Some(base64::engine::general_purpose::STANDARD.encode(cursor.into_inner()))
}

#[cfg(all(feature = "screen-capture", target_os = "linux"))]
fn application_icon_png_b64(_pid: u32, app_name: &str) -> Option<String> {
    use base64::Engine;

    let normalized = app_name.trim().to_ascii_lowercase();
    let dashed = normalized.replace([' ', '_'], "-");
    let names = if dashed == normalized {
        vec![normalized]
    } else {
        vec![normalized, dashed]
    };
    let directories = [
        "/usr/share/icons/hicolor/48x48/apps",
        "/usr/share/icons/hicolor/64x64/apps",
        "/usr/share/icons/hicolor/32x32/apps",
        "/usr/share/icons/hicolor/128x128/apps",
        "/usr/share/pixmaps",
    ];
    for directory in directories {
        for name in &names {
            let path = std::path::Path::new(directory).join(format!("{name}.png"));
            let Ok(bytes) = std::fs::read(path) else {
                continue;
            };
            if bytes.len() <= 512 * 1024 && bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
                return Some(base64::engine::general_purpose::STANDARD.encode(bytes));
            }
        }
    }
    None
}

#[cfg(all(feature = "screen-capture", target_os = "linux"))]
fn linux_wayland_session() -> bool {
    std::env::var("XDG_SESSION_TYPE").is_ok_and(|value| value.eq_ignore_ascii_case("wayland"))
        || std::env::var_os("WAYLAND_DISPLAY").is_some()
}

#[cfg(all(feature = "screen-capture", target_os = "macos"))]
fn is_macos_system_surface_app(app_name: &str) -> bool {
    let app_name = app_name.trim();
    app_name.eq_ignore_ascii_case("Control Center")
        || app_name.eq_ignore_ascii_case("Window Server")
}

#[cfg(all(
    feature = "screen-capture",
    any(target_os = "macos", target_os = "windows", target_os = "linux")
))]
fn system_capture(target: &CaptureTarget) -> Result<CapturedImage, RpcError> {
    let image = match target.kind {
        CaptureTargetKind::Display => {
            let id = parse_target_id(&target.id, "display")?;
            let monitor = xcap::Monitor::all()
                .map_err(capture_backend_error)?
                .into_iter()
                .find(|monitor| monitor.id().ok() == Some(id))
                .ok_or_else(target_not_found)?;
            ensure_capture_dimensions(
                monitor.width().map_err(capture_backend_error)?,
                monitor.height().map_err(capture_backend_error)?,
            )?;
            monitor.capture_image().map_err(capture_backend_error)?
        }
        CaptureTargetKind::Window => {
            let id = parse_target_id(&target.id, "window")?;

            #[cfg(target_os = "macos")]
            {
                capture_macos::capture_window(id).map_err(platform_capture_error)?
            }

            #[cfg(target_os = "windows")]
            {
                capture_windows::capture_window(id).map_err(platform_capture_error)?
            }

            #[cfg(not(any(target_os = "macos", target_os = "windows")))]
            {
                let window = xcap::Window::all()
                    .map_err(capture_backend_error)?
                    .into_iter()
                    .find(|window| window.id().ok() == Some(id))
                    .ok_or_else(target_not_found)?;
                if window.is_minimized().unwrap_or(true) {
                    return Err(target_not_found());
                }
                ensure_capture_dimensions(
                    window.width().map_err(capture_backend_error)?,
                    window.height().map_err(capture_backend_error)?,
                )?;
                window.capture_image().map_err(capture_backend_error)?
            }
        }
    };

    let (width, height) = image.dimensions();
    let pixels = u64::from(width) * u64::from(height);
    if pixels > MAX_CAPTURE_PIXELS {
        return Err(RpcError::new(
            ErrorCode::CaptureTooLarge,
            format!("capture is {width}x{height}, exceeds 50 megapixels"),
        ));
    }
    let mut cursor = std::io::Cursor::new(Vec::new());
    xcap::image::DynamicImage::ImageRgba8(image)
        .write_to(&mut cursor, xcap::image::ImageFormat::Png)
        .map_err(|error| RpcError::internal(format!("encode screenshot PNG: {error}")))?;
    Ok(CapturedImage {
        png: cursor.into_inner(),
        width,
        height,
    })
}

#[cfg(all(
    feature = "screen-capture",
    any(target_os = "macos", target_os = "windows", target_os = "linux")
))]
fn ensure_capture_dimensions(width: u32, height: u32) -> Result<(), RpcError> {
    let pixels = u64::from(width) * u64::from(height);
    if width == 0 || height == 0 {
        return Err(RpcError::new(
            ErrorCode::CaptureTargetNotFound,
            "capture target has no visible area",
        ));
    }
    if pixels > MAX_CAPTURE_PIXELS {
        return Err(RpcError::new(
            ErrorCode::CaptureTooLarge,
            format!("capture is {width}x{height}, exceeds 50 megapixels"),
        ));
    }
    Ok(())
}

#[cfg(all(
    feature = "screen-capture",
    any(target_os = "macos", target_os = "windows", target_os = "linux")
))]
fn parse_target_id(raw: &str, expected_prefix: &str) -> Result<u32, RpcError> {
    raw.strip_prefix(expected_prefix)
        .and_then(|value| value.strip_prefix(':'))
        .and_then(|value| value.parse::<u32>().ok())
        .ok_or_else(|| RpcError::invalid_params(format!("invalid {expected_prefix} target id")))
}

#[cfg(all(
    feature = "screen-capture",
    any(target_os = "macos", target_os = "windows", target_os = "linux")
))]
fn target_not_found() -> RpcError {
    RpcError::new(
        ErrorCode::CaptureTargetNotFound,
        "capture target no longer exists",
    )
}

#[cfg(all(
    feature = "screen-capture",
    any(target_os = "macos", target_os = "windows", target_os = "linux")
))]
fn capture_backend_error(error: xcap::XCapError) -> RpcError {
    let message = error.to_string();
    let lower = message.to_ascii_lowercase();
    let code = if lower.contains("permission")
        || lower.contains("denied")
        || lower.contains("not authorized")
    {
        ErrorCode::CapturePermissionDenied
    } else {
        ErrorCode::CaptureUnavailable
    };
    RpcError::new(code, message)
}

#[cfg(all(
    feature = "screen-capture",
    any(target_os = "macos", target_os = "windows")
))]
fn platform_capture_error(message: String) -> RpcError {
    let lower = message.to_ascii_lowercase();
    let code = if lower.contains("permission")
        || lower.contains("denied")
        || lower.contains("not authorized")
    {
        ErrorCode::CapturePermissionDenied
    } else if lower.contains("no longer exists") || lower.contains("not found") {
        ErrorCode::CaptureTargetNotFound
    } else {
        ErrorCode::CaptureUnavailable
    };
    RpcError::new(code, message)
}

#[cfg(test)]
mod tests {
    use super::*;
    use motif_proto::capture::CaptureTargetKind;

    struct FakeBackend;

    impl CaptureBackend for FakeBackend {
        fn supported_in_build(&self) -> bool {
            true
        }

        fn targets(&self) -> Result<TargetsResult, RpcError> {
            Ok(TargetsResult {
                available: true,
                reason: None,
                displays: vec![],
                windows: vec![],
                app_icons_png_b64: Default::default(),
            })
        }

        fn capture(&self, _target: &CaptureTarget) -> Result<CapturedImage, RpcError> {
            Ok(CapturedImage {
                png: vec![1, 2, 3],
                width: 1,
                height: 1,
            })
        }
    }

    #[test]
    fn disabled_service_returns_availability_instead_of_panicking() {
        let service = CaptureService::new(false, Arc::new(FakeBackend));
        let result = service.targets().unwrap();
        assert!(!result.available);
        assert!(!service.is_advertised());
    }

    #[test]
    fn enabled_fake_backend_is_advertised_and_captures() {
        let service = CaptureService::new(true, Arc::new(FakeBackend));
        assert!(service.is_advertised());
        let image = service
            .capture(&CaptureTarget {
                kind: CaptureTargetKind::Display,
                id: "display:1".into(),
            })
            .unwrap();
        assert_eq!(image.png, [1, 2, 3]);
    }

    #[cfg(all(feature = "screen-capture", target_os = "macos"))]
    #[test]
    fn macos_system_surface_apps_are_filtered() {
        assert!(is_macos_system_surface_app("Control Center"));
        assert!(is_macos_system_surface_app(" Window Server "));
        assert!(!is_macos_system_surface_app("System Settings"));
    }
}
