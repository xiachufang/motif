//! macOS window enumeration and capture across all Spaces.
//!
//! xcap 0.9.7 hard-codes `OptionOnScreenOnly`, which excludes every window
//! outside the active Space. Core Graphics' `OptionAll` includes on-screen and
//! off-screen windows in the current login session.

#![allow(deprecated)]

use std::{
    collections::{HashMap, HashSet},
    ffi::c_void,
    ptr::NonNull,
    sync::OnceLock,
};

use motif_proto::capture::CaptureWindow;
use objc2_app_kit::{NSRunningApplication, NSWorkspace};
use objc2_core_foundation::{
    CFArray, CFBoolean, CFDictionary, CFNumber, CFNumberType, CFRetained, CFString, CGRect,
};
use objc2_core_graphics::{
    CGDataProvider, CGImage, CGPreflightScreenCaptureAccess,
    CGRectMakeWithDictionaryRepresentation, CGWindowImageOption, CGWindowListCopyWindowInfo,
    CGWindowListCreateImage, CGWindowListOption,
};

const WINDOW_ID_KEY: &str = "kCGWindowNumber";
const OWNER_PID_KEY: &str = "kCGWindowOwnerPID";
const OWNER_NAME_KEY: &str = "kCGWindowOwnerName";
const WINDOW_NAME_KEY: &str = "kCGWindowName";
const WINDOW_BOUNDS_KEY: &str = "kCGWindowBounds";
const WINDOW_LAYER_KEY: &str = "kCGWindowLayer";
const SHARING_STATE_KEY: &str = "kCGWindowSharingState";
const IS_ONSCREEN_KEY: &str = "kCGWindowIsOnscreen";

// Private SkyLight flags used by macOS window managers such as AltTab. With
// only INCLUDE_ALL_SPACES, CGSCopyWindowsWithOptionsAndTags excludes surfaces
// tagged invisible by WindowServer while still returning normal windows from
// every Space passed to it.
const ALL_SPACES_MASK: i32 = 7;
const INCLUDE_ALL_SPACES: isize = 1 << 1;

type CgsMainConnectionId = unsafe extern "C" fn() -> i32;
type CgsCopySpacesForWindows =
    unsafe extern "C" fn(i32, i32, *const CFArray<CFNumber>) -> *const CFArray<CFNumber>;
type CgsCopyWindowsWithOptionsAndTags = unsafe extern "C" fn(
    i32,
    isize,
    *const CFArray<CFNumber>,
    isize,
    *mut isize,
    *mut isize,
) -> *const CFArray<CFNumber>;

struct CgsApi {
    main_connection_id: CgsMainConnectionId,
    copy_spaces_for_windows: CgsCopySpacesForWindows,
    copy_windows_with_options_and_tags: CgsCopyWindowsWithOptionsAndTags,
}

static CGS_API: OnceLock<Option<CgsApi>> = OnceLock::new();

pub(super) fn all_windows() -> Result<Vec<CaptureWindow>, String> {
    if !CGPreflightScreenCaptureAccess() {
        return Err(
            "Screen Recording permission is required to enumerate windows across Spaces".into(),
        );
    }

    let frontmost_pid = NSWorkspace::sharedWorkspace()
        .frontmostApplication()
        .map(|application| application.processIdentifier() as u32);
    let window_info = copy_all_window_info()?;
    let normal_window_ids = normal_window_ids_across_spaces(&window_info);
    let mut excluded_processes = HashMap::new();
    let mut windows = Vec::new();

    for index in 0..window_info.count() {
        let Some(dictionary) = window_dictionary(&window_info, index) else {
            continue;
        };

        // OptionAll also exposes menu bar, Dock, tooltip and WindowServer
        // surfaces. Real application windows are layer zero and shareable.
        if dictionary_i32(dictionary, WINDOW_LAYER_KEY) != Some(0)
            || dictionary_i32(dictionary, SHARING_STATE_KEY) == Some(0)
        {
            continue;
        }

        let (Some(id), Some(pid), Some(bounds)) = (
            dictionary_u32(dictionary, WINDOW_ID_KEY),
            dictionary_u32(dictionary, OWNER_PID_KEY),
            dictionary_bounds(dictionary),
        ) else {
            continue;
        };
        let width = dimension_to_u32(bounds.size.width);
        let height = dimension_to_u32(bounds.size.height);
        if id == 0 || pid == 0 || width == 0 || height == 0 {
            continue;
        }

        let app_name = dictionary_string(dictionary, OWNER_NAME_KEY)
            .unwrap_or_default()
            .trim()
            .to_string();
        let title = dictionary_string(dictionary, WINDOW_NAME_KEY)
            .unwrap_or_default()
            .trim()
            .to_string();
        // OptionAll includes hidden AppKit/Electron layout surfaces for menu
        // bars, full-screen transitions and inactive displays. Most have no
        // kCGWindowName, so reject them before the remaining filters.
        if app_name.is_empty() || title.is_empty() {
            continue;
        }
        if *excluded_processes
            .entry(pid)
            .or_insert_with(|| is_system_surface_owner(pid, &app_name))
        {
            continue;
        }

        // Some applications keep a named, capturable backing surface after
        // closing their last real window. WindowServer tags those surfaces as
        // invisible. Unlike kCGWindowIsOnscreen or AXWindows, the normal CGS
        // list still contains real windows from inactive Spaces.
        let in_normal_window_list = normal_window_ids
            .as_ref()
            .map(|window_ids| window_ids.contains(&id));
        let is_onscreen = dictionary_bool(dictionary, IS_ONSCREEN_KEY).unwrap_or(false);
        if !is_user_capture_target(&app_name, &title, in_normal_window_list, is_onscreen) {
            continue;
        }

        windows.push(CaptureWindow {
            id: format!("window:{id}"),
            app_name,
            title,
            pid,
            width,
            height,
            x: coordinate_to_i32(bounds.origin.x),
            y: coordinate_to_i32(bounds.origin.y),
            focused: frontmost_pid == Some(pid),
        });
    }

    Ok(windows)
}

pub(super) fn capture_window(window_id: u32) -> Result<xcap::image::RgbaImage, String> {
    if !CGPreflightScreenCaptureAccess() {
        return Err("Screen Recording permission is required to capture windows".into());
    }

    let bounds = find_window_bounds(window_id)?;
    let cg_image = CGWindowListCreateImage(
        bounds,
        CGWindowListOption::OptionIncludingWindow,
        window_id,
        CGWindowImageOption::BoundsIgnoreFraming,
    )
    .ok_or_else(|| "capture target no longer exists or has no drawable image".to_string())?;

    let width = CGImage::width(Some(cg_image.as_ref()));
    let height = CGImage::height(Some(cg_image.as_ref()));
    let width_u32 = u32::try_from(width)
        .map_err(|_| "captured window width exceeds the supported range".to_string())?;
    let height_u32 = u32::try_from(height)
        .map_err(|_| "captured window height exceeds the supported range".to_string())?;
    let bytes_per_row = CGImage::bytes_per_row(Some(cg_image.as_ref()));
    let row_bytes = width
        .checked_mul(4)
        .ok_or_else(|| "captured window dimensions overflow".to_string())?;
    if width == 0 || height == 0 || bytes_per_row < row_bytes {
        return Err("captured window has an invalid image layout".into());
    }

    let provider = CGImage::data_provider(Some(cg_image.as_ref()))
        .ok_or_else(|| "captured window has no image provider".to_string())?;
    let data = CGDataProvider::data(Some(provider.as_ref()))
        .ok_or_else(|| "captured window image data is unavailable".to_string())?;
    let required_len = bytes_per_row
        .checked_mul(height)
        .ok_or_else(|| "captured window buffer size overflow".to_string())?;
    let source = data.to_vec();
    if source.len() < required_len {
        return Err("captured window image buffer is truncated".into());
    }

    let mut rgba = Vec::with_capacity(
        row_bytes
            .checked_mul(height)
            .ok_or_else(|| "captured window buffer size overflow".to_string())?,
    );
    for row in source[..required_len].chunks_exact(bytes_per_row) {
        rgba.extend_from_slice(&row[..row_bytes]);
    }
    for bgra in rgba.chunks_exact_mut(4) {
        bgra.swap(0, 2);
    }

    xcap::image::RgbaImage::from_raw(width_u32, height_u32, rgba)
        .ok_or_else(|| "could not construct the captured window image".to_string())
}

fn copy_all_window_info() -> Result<CFRetained<CFArray>, String> {
    CGWindowListCopyWindowInfo(
        CGWindowListOption::OptionAll | CGWindowListOption::ExcludeDesktopElements,
        0,
    )
    .ok_or_else(|| "Core Graphics returned no window list".to_string())
}

fn find_window_bounds(window_id: u32) -> Result<CGRect, String> {
    let window_info = copy_all_window_info()?;
    for index in 0..window_info.count() {
        let Some(dictionary) = window_dictionary(&window_info, index) else {
            continue;
        };
        if dictionary_u32(dictionary, WINDOW_ID_KEY) == Some(window_id) {
            return dictionary_bounds(dictionary)
                .ok_or_else(|| "capture target has invalid bounds".to_string());
        }
    }
    Err("capture target not found; it may no longer exist".into())
}

fn window_dictionary(window_info: &CFArray, index: isize) -> Option<&CFDictionary> {
    // SAFETY: values returned by CGWindowListCopyWindowInfo are retained for
    // the lifetime of the array and documented as CFDictionary instances.
    unsafe {
        let raw = window_info.value_at_index(index) as *const CFDictionary;
        raw.as_ref()
    }
}

fn dictionary_value(dictionary: &CFDictionary, key: &str) -> Option<*const c_void> {
    let key = CFString::from_str(key);
    // SAFETY: Core Graphics dictionaries use CFString keys and the returned
    // value remains owned by the dictionary.
    let value = unsafe { dictionary.value((key.as_ref() as *const CFString).cast()) };
    (!value.is_null()).then_some(value)
}

fn dictionary_i32(dictionary: &CFDictionary, key: &str) -> Option<i32> {
    let number = dictionary_value(dictionary, key)? as *const CFNumber;
    let mut value = 0i32;
    // SAFETY: every key passed here is documented as a CFNumber.
    unsafe {
        (*number)
            .value(
                CFNumberType::IntType,
                (&mut value as *mut i32).cast::<c_void>(),
            )
            .then_some(value)
    }
}

fn dictionary_u32(dictionary: &CFDictionary, key: &str) -> Option<u32> {
    dictionary_i32(dictionary, key).and_then(|value| u32::try_from(value).ok())
}

fn dictionary_bool(dictionary: &CFDictionary, key: &str) -> Option<bool> {
    let boolean = dictionary_value(dictionary, key)? as *const CFBoolean;
    // SAFETY: kCGWindowIsOnscreen is documented as a CFBoolean.
    Some(unsafe { boolean.as_ref()?.as_bool() })
}

fn dictionary_string(dictionary: &CFDictionary, key: &str) -> Option<String> {
    let string = dictionary_value(dictionary, key)? as *const CFString;
    // SAFETY: every key passed here is documented as a CFString.
    Some(unsafe { (*string).to_string() })
}

fn dictionary_bounds(dictionary: &CFDictionary) -> Option<CGRect> {
    let bounds = dictionary_value(dictionary, WINDOW_BOUNDS_KEY)? as *const CFDictionary;
    let bounds = unsafe { bounds.as_ref()? };
    let mut rect = CGRect::default();
    // SAFETY: kCGWindowBounds is documented as a CGRect dictionary.
    unsafe { CGRectMakeWithDictionaryRepresentation(Some(bounds), &mut rect) }.then_some(rect)
}

fn is_system_surface_owner(pid: u32, app_name: &str) -> bool {
    if matches!(app_name, "Window Server" | "Control Center") {
        return true;
    }
    NSRunningApplication::runningApplicationWithProcessIdentifier(pid as _)
        .and_then(|application| application.bundleIdentifier())
        .is_some_and(|bundle_id| bundle_id.to_string() == "com.apple.controlcenter")
}

/// Returns the normal (not WindowServer-invisible) window IDs across every
/// Space represented in the Core Graphics snapshot.
///
/// These are private APIs, so any load/query failure returns `None`; callers
/// then fail open rather than collapsing the list back to the current Space.
fn normal_window_ids_across_spaces(window_info: &CFArray) -> Option<HashSet<u32>> {
    let api = cgs_api()?;
    let window_numbers: Vec<_> = (0..window_info.count())
        .filter_map(|index| {
            let dictionary = window_dictionary(window_info, index)?;
            let id = dictionary_u32(dictionary, WINDOW_ID_KEY)?;
            (id != 0).then(|| CFNumber::new_i64(i64::from(id)))
        })
        .collect();
    if window_numbers.is_empty() {
        return None;
    }
    let window_ids = CFArray::from_retained_objects(&window_numbers);

    // SAFETY: the dynamically loaded functions use the stable SkyLight ABI
    // exercised above, and all CFArray arguments contain CFNumber values.
    let connection_id = unsafe { (api.main_connection_id)() };
    let spaces = unsafe {
        retained_array_from_create_rule((api.copy_spaces_for_windows)(
            connection_id,
            ALL_SPACES_MASK,
            window_ids.as_ref(),
        ))?
    };
    if spaces.is_empty() {
        return None;
    }

    let mut set_tags = 0isize;
    let mut clear_tags = 0isize;
    let normal_windows = unsafe {
        retained_array_from_create_rule((api.copy_windows_with_options_and_tags)(
            connection_id,
            0,
            spaces.as_ref(),
            INCLUDE_ALL_SPACES,
            &mut set_tags,
            &mut clear_tags,
        ))?
    };

    let mut ids = HashSet::with_capacity(normal_windows.len());
    for index in 0..normal_windows.len() {
        // SAFETY: CGSCopyWindowsWithOptionsAndTags returns CFNumber window IDs.
        let number = unsafe { normal_windows.get_unchecked(index as isize) };
        if let Some(id) = number.as_i64().and_then(|id| u32::try_from(id).ok()) {
            ids.insert(id);
        }
    }
    Some(ids)
}

unsafe fn retained_array_from_create_rule(
    array: *const CFArray<CFNumber>,
) -> Option<CFRetained<CFArray<CFNumber>>> {
    let array = NonNull::new(array.cast_mut())?;
    // SAFETY: both CGS functions are Copy/Create-rule functions and return a
    // retained CFArray when non-null.
    Some(unsafe { CFRetained::from_raw(array) })
}

fn cgs_api() -> Option<&'static CgsApi> {
    CGS_API.get_or_init(load_cgs_api).as_ref()
}

fn load_cgs_api() -> Option<CgsApi> {
    // Resolve at runtime so older/newer macOS versions that remove these
    // private symbols degrade safely instead of failing to launch Motif.
    let handle = unsafe {
        libc::dlopen(
            c"/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight".as_ptr(),
            libc::RTLD_LAZY | libc::RTLD_LOCAL,
        )
    };
    if handle.is_null() {
        return None;
    }

    let main_connection_id = dlsym(handle, c"CGSMainConnectionID")?;
    let copy_spaces_for_windows = dlsym(handle, c"CGSCopySpacesForWindows")?;
    let copy_windows_with_options_and_tags = dlsym(handle, c"CGSCopyWindowsWithOptionsAndTags")?;

    // Keep SkyLight loaded for the lifetime of the process; the stored
    // function pointers would be invalid after dlclose.
    Some(CgsApi {
        // SAFETY: each symbol name is paired with its known SkyLight ABI.
        main_connection_id: unsafe { std::mem::transmute(main_connection_id) },
        copy_spaces_for_windows: unsafe { std::mem::transmute(copy_spaces_for_windows) },
        copy_windows_with_options_and_tags: unsafe {
            std::mem::transmute(copy_windows_with_options_and_tags)
        },
    })
}

fn dlsym(handle: *mut c_void, name: &std::ffi::CStr) -> Option<*mut c_void> {
    let symbol = unsafe { libc::dlsym(handle, name.as_ptr()) };
    (!symbol.is_null()).then_some(symbol)
}

fn dimension_to_u32(value: f64) -> u32 {
    if value.is_finite() && value > 0.0 && value <= u32::MAX as f64 {
        value.round() as u32
    } else {
        0
    }
}

fn coordinate_to_i32(value: f64) -> i32 {
    if !value.is_finite() {
        0
    } else {
        value.round().clamp(i32::MIN as f64, i32::MAX as f64) as i32
    }
}

fn is_user_capture_target(
    app_name: &str,
    title: &str,
    in_normal_window_list: Option<bool>,
    is_onscreen: bool,
) -> bool {
    !app_name.trim().is_empty()
        && !title.trim().is_empty()
        && (is_onscreen || in_normal_window_list.unwrap_or(true))
}

#[cfg(test)]
mod tests {
    use super::is_user_capture_target;

    #[test]
    fn empty_window_names_are_not_user_capture_targets() {
        assert!(!is_user_capture_target("ChatGPT", "", Some(true), true));
        assert!(!is_user_capture_target("ChatGPT", "   ", Some(true), true));
        assert!(!is_user_capture_target("", "Document", Some(true), true));
        assert!(is_user_capture_target(
            "ChatGPT",
            "ChatGPT",
            Some(true),
            true
        ));
    }

    #[test]
    fn windowserver_invisible_windows_are_not_user_capture_targets() {
        assert!(!is_user_capture_target(
            "GitHub Desktop",
            "GitHub Desktop",
            Some(false),
            false
        ));
        assert!(is_user_capture_target(
            "Feishu",
            "Feishu",
            Some(true),
            false
        ));
    }

    #[test]
    fn onscreen_windows_survive_an_inconsistent_cgs_snapshot() {
        assert!(is_user_capture_target("Motif", "Motif", Some(false), true));
    }

    #[test]
    fn windowserver_query_failures_do_not_hide_windows() {
        assert!(is_user_capture_target("Motif", "Motif", None, false));
    }
}
