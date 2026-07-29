//! Windows window enumeration across virtual desktops.
//!
//! xcap excludes every DWM-cloaked window. Windows on another virtual desktop
//! are normally cloaked by the Shell, so we retain `DWM_CLOAKED_SHELL` windows
//! while still excluding windows cloaked by their application or owner.

use std::{collections::HashMap, ffi::c_void, mem};

use motif_proto::capture::CaptureWindow;
use windows_sys::Win32::{
    Foundation::{HWND, LPARAM, RECT},
    Graphics::{
        Dwm::{DwmGetWindowAttribute, DWMWA_CLOAKED, DWMWA_EXTENDED_FRAME_BOUNDS},
        Gdi::{
            CreateCompatibleBitmap, CreateCompatibleDC, DeleteDC, DeleteObject, GetDIBits,
            GetWindowDC, ReleaseDC, SelectObject, BITMAPINFO, BITMAPINFOHEADER, BI_RGB,
            DIB_RGB_COLORS, HBITMAP, HDC, HGDIOBJ,
        },
    },
    Storage::Xps::PrintWindow,
    System::Threading::GetCurrentProcessId,
    UI::WindowsAndMessaging::{
        EnumWindows, GetClassNameW, GetForegroundWindow, GetWindowLongPtrW, GetWindowRect,
        GetWindowTextLengthW, GetWindowTextW, GetWindowThreadProcessId, IsIconic, IsWindow,
        IsWindowVisible, GWL_EXSTYLE, WS_EX_TOOLWINDOW,
    },
};

const DWM_CLOAKED_APP: u32 = 0x1;
const DWM_CLOAKED_SHELL: u32 = 0x2;
const DWM_CLOAKED_INHERITED: u32 = 0x4;
const PW_RENDERFULLCONTENT: u32 = 0x2;

pub(super) fn all_windows() -> Result<Vec<CaptureWindow>, String> {
    let mut handles = Vec::<HWND>::new();
    let callback_data = (&mut handles as *mut Vec<HWND>) as LPARAM;
    // SAFETY: callback_data points to `handles` for the synchronous duration
    // of EnumWindows and the callback only appends HWND values to that vector.
    if unsafe { EnumWindows(Some(collect_window), callback_data) } == 0 {
        return Err(format!(
            "EnumWindows failed: {}",
            std::io::Error::last_os_error()
        ));
    }

    // xcap resolves localized ProductName/FileDescription for visible windows.
    // Reuse those names and fall back to the executable name for windows from
    // other virtual desktops that xcap intentionally omits.
    let visible_app_names: HashMap<u32, String> = xcap::Window::all()
        .unwrap_or_default()
        .into_iter()
        .filter_map(|window| Some((window.id().ok()?, window.app_name().ok()?)))
        .collect();
    let foreground = unsafe { GetForegroundWindow() };
    let mut windows = Vec::new();

    for hwnd in handles {
        if !is_capture_candidate(hwnd) {
            continue;
        }
        let Some(id) = hwnd_id(hwnd) else {
            continue;
        };
        let pid = window_pid(hwnd);
        let Some(bounds) = window_bounds(hwnd) else {
            continue;
        };
        let width = bounds.right.saturating_sub(bounds.left);
        let height = bounds.bottom.saturating_sub(bounds.top);
        if pid == 0 || width <= 0 || height <= 0 {
            continue;
        }

        let title = window_text(hwnd).trim().to_string();
        let app_name = visible_app_names
            .get(&id)
            .filter(|name| !name.trim().is_empty())
            .cloned()
            .or_else(|| process_executable_name(pid))
            .unwrap_or_default();
        if app_name.is_empty() && title.is_empty() {
            continue;
        }

        windows.push(CaptureWindow {
            id: format!("window:{id}"),
            app_name,
            title,
            pid,
            width: width as u32,
            height: height as u32,
            x: bounds.left,
            y: bounds.top,
            focused: hwnd == foreground,
        });
    }

    Ok(windows)
}

pub(super) fn capture_window(window_id: u32) -> Result<xcap::image::RgbaImage, String> {
    let hwnd = window_id as usize as HWND;
    if unsafe { IsWindow(hwnd) } == 0 {
        return Err("capture target not found; it may no longer exist".into());
    }
    let bounds =
        window_bounds(hwnd).ok_or_else(|| "capture target has invalid bounds".to_string())?;
    let width = bounds.right.saturating_sub(bounds.left);
    let height = bounds.bottom.saturating_sub(bounds.top);
    if width <= 0 || height <= 0 {
        return Err("capture target has no drawable area".into());
    }
    let buffer_len = (width as usize)
        .checked_mul(height as usize)
        .and_then(|pixels| pixels.checked_mul(4))
        .ok_or_else(|| "captured window buffer size overflow".to_string())?;

    let resources = GdiResources::new(hwnd, width, height)?;
    // PW_RENDERFULLCONTENT asks DWM for the composed window even when the
    // Shell has cloaked it on another virtual desktop. Fall back for older
    // applications that only implement the original PrintWindow contract.
    let rendered = unsafe {
        PrintWindow(hwnd, resources.memory_dc, PW_RENDERFULLCONTENT) != 0
            || PrintWindow(hwnd, resources.memory_dc, 0) != 0
    };
    if !rendered {
        return Err("capture window failed".into());
    }

    let mut bitmap_info = BITMAPINFO {
        bmiHeader: BITMAPINFOHEADER {
            biSize: mem::size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: width,
            biHeight: -height,
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB,
            biSizeImage: buffer_len as u32,
            ..Default::default()
        },
        ..Default::default()
    };
    let mut bgra = vec![0u8; buffer_len];
    let copied = unsafe {
        GetDIBits(
            resources.memory_dc,
            resources.bitmap,
            0,
            height as u32,
            bgra.as_mut_ptr().cast::<c_void>(),
            &mut bitmap_info,
            DIB_RGB_COLORS,
        )
    };
    if copied == 0 {
        return Err("could not read captured window pixels".into());
    }
    for pixel in bgra.chunks_exact_mut(4) {
        pixel.swap(0, 2);
    }
    xcap::image::RgbaImage::from_raw(width as u32, height as u32, bgra)
        .ok_or_else(|| "could not construct the captured window image".to_string())
}

unsafe extern "system" fn collect_window(hwnd: HWND, data: LPARAM) -> i32 {
    let handles = unsafe { &mut *(data as *mut Vec<HWND>) };
    handles.push(hwnd);
    1
}

fn is_capture_candidate(hwnd: HWND) -> bool {
    unsafe {
        if IsWindow(hwnd) == 0 || IsWindowVisible(hwnd) == 0 || IsIconic(hwnd) != 0 {
            return false;
        }
    }
    let class_name = window_class_name(hwnd);
    if class_name.is_empty() || matches!(class_name.as_str(), "Progman" | "Button") {
        return false;
    }
    if window_pid(hwnd) == unsafe { GetCurrentProcessId() } {
        return false;
    }
    let is_tool_window =
        unsafe { GetWindowLongPtrW(hwnd, GWL_EXSTYLE) as u32 } & WS_EX_TOOLWINDOW != 0;
    if is_tool_window && window_text(hwnd).trim().is_empty() {
        return false;
    }

    let cloaked = window_cloak_state(hwnd);
    cloaked == 0
        || (cloaked & DWM_CLOAKED_SHELL != 0
            && cloaked & (DWM_CLOAKED_APP | DWM_CLOAKED_INHERITED) == 0)
}

fn window_cloak_state(hwnd: HWND) -> u32 {
    let mut value = 0u32;
    let result = unsafe {
        DwmGetWindowAttribute(
            hwnd,
            DWMWA_CLOAKED as u32,
            (&mut value as *mut u32).cast::<c_void>(),
            mem::size_of::<u32>() as u32,
        )
    };
    if result < 0 {
        0
    } else {
        value
    }
}

fn window_bounds(hwnd: HWND) -> Option<RECT> {
    let mut bounds = RECT::default();
    let dwm_result = unsafe {
        DwmGetWindowAttribute(
            hwnd,
            DWMWA_EXTENDED_FRAME_BOUNDS as u32,
            (&mut bounds as *mut RECT).cast::<c_void>(),
            mem::size_of::<RECT>() as u32,
        )
    };
    if dwm_result >= 0 {
        return Some(bounds);
    }
    (unsafe { GetWindowRect(hwnd, &mut bounds) } != 0).then_some(bounds)
}

fn window_pid(hwnd: HWND) -> u32 {
    let mut pid = 0u32;
    unsafe { GetWindowThreadProcessId(hwnd, &mut pid) };
    pid
}

fn window_text(hwnd: HWND) -> String {
    let length = unsafe { GetWindowTextLengthW(hwnd) };
    if length <= 0 {
        return String::new();
    }
    let mut buffer = vec![0u16; length as usize + 1];
    let copied = unsafe { GetWindowTextW(hwnd, buffer.as_mut_ptr(), buffer.len() as i32) };
    String::from_utf16_lossy(&buffer[..copied.max(0) as usize])
}

fn window_class_name(hwnd: HWND) -> String {
    let mut buffer = vec![0u16; 256];
    let copied = unsafe { GetClassNameW(hwnd, buffer.as_mut_ptr(), buffer.len() as i32) };
    String::from_utf16_lossy(&buffer[..copied.max(0) as usize])
}

fn hwnd_id(hwnd: HWND) -> Option<u32> {
    u32::try_from(hwnd as usize).ok()
}

fn process_executable_name(pid: u32) -> Option<String> {
    use std::ffi::OsString;
    use std::os::windows::ffi::OsStringExt;
    use windows_sys::Win32::{
        Foundation::CloseHandle,
        System::Threading::{
            OpenProcess, QueryFullProcessImageNameW, PROCESS_QUERY_LIMITED_INFORMATION,
        },
    };

    let process = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) };
    if process.is_null() {
        return None;
    }
    let mut buffer = vec![0u16; 32_768];
    let mut length = buffer.len() as u32;
    let queried =
        unsafe { QueryFullProcessImageNameW(process, 0, buffer.as_mut_ptr(), &mut length) };
    unsafe { CloseHandle(process) };
    if queried == 0 || length == 0 {
        return None;
    }
    let path = std::path::PathBuf::from(OsString::from_wide(&buffer[..length as usize]));
    path.file_stem()
        .map(|name| name.to_string_lossy().into_owned())
}

struct GdiResources {
    hwnd: HWND,
    window_dc: HDC,
    memory_dc: HDC,
    bitmap: HBITMAP,
    previous_object: HGDIOBJ,
}

impl GdiResources {
    fn new(hwnd: HWND, width: i32, height: i32) -> Result<Self, String> {
        let window_dc = unsafe { GetWindowDC(hwnd) };
        if window_dc.is_null() {
            return Err("could not acquire the window device context".into());
        }
        let memory_dc = unsafe { CreateCompatibleDC(window_dc) };
        if memory_dc.is_null() {
            unsafe { ReleaseDC(hwnd, window_dc) };
            return Err("could not create the capture device context".into());
        }
        let bitmap = unsafe { CreateCompatibleBitmap(window_dc, width, height) };
        if bitmap.is_null() {
            unsafe {
                DeleteDC(memory_dc);
                ReleaseDC(hwnd, window_dc);
            }
            return Err("could not create the capture bitmap".into());
        }
        let previous_object = unsafe { SelectObject(memory_dc, bitmap) };
        if previous_object.is_null() {
            unsafe {
                DeleteObject(bitmap);
                DeleteDC(memory_dc);
                ReleaseDC(hwnd, window_dc);
            }
            return Err("could not select the capture bitmap".into());
        }
        Ok(Self {
            hwnd,
            window_dc,
            memory_dc,
            bitmap,
            previous_object,
        })
    }
}

impl Drop for GdiResources {
    fn drop(&mut self) {
        unsafe {
            SelectObject(self.memory_dc, self.previous_object);
            DeleteObject(self.bitmap);
            DeleteDC(self.memory_dc);
            ReleaseDC(self.hwnd, self.window_dc);
        }
    }
}
