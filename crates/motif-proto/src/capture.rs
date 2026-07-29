//! Remote desktop screenshot protocol.
//!
//! Target discovery uses the normal JSON RPC response. `capture.take` shares
//! the `/rpc/<method>` request surface but returns raw `image/png` bytes on
//! success, so its request type lives here while its response is intentionally
//! not represented by a JSON DTO.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum CaptureTargetKind {
    Display,
    Window,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CaptureDisplay {
    /// Opaque, short-lived identifier. Clients must refresh targets after a
    /// display topology change or when capture reports TargetNotFound.
    pub id: String,
    pub name: String,
    pub width: u32,
    pub height: u32,
    pub x: i32,
    pub y: i32,
    pub scale_factor_milli: u32,
    pub primary: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CaptureWindow {
    /// Opaque, short-lived identifier. Window ids may be reused by the OS, so
    /// the server re-enumerates and validates the target before every capture.
    pub id: String,
    pub app_name: String,
    pub title: String,
    pub pid: u32,
    pub width: u32,
    pub height: u32,
    pub x: i32,
    pub y: i32,
    pub focused: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct TargetsParams {}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TargetsResult {
    /// False when capture was disabled, this build has no backend, or the
    /// process has no usable graphical session/permission.
    pub available: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    #[serde(default)]
    pub displays: Vec<CaptureDisplay>,
    #[serde(default)]
    pub windows: Vec<CaptureWindow>,
    /// Deduplicated 32px application icons, keyed by `CaptureWindow.app_name`.
    /// Values are PNG bytes encoded as base64 for the JSON discovery response.
    pub app_icons_png_b64: BTreeMap<String, String>,
}

impl TargetsResult {
    pub fn unavailable(reason: impl Into<String>) -> Self {
        Self {
            available: false,
            reason: Some(reason.into()),
            displays: Vec::new(),
            windows: Vec::new(),
            app_icons_png_b64: BTreeMap::new(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CaptureTarget {
    pub kind: CaptureTargetKind,
    pub id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TakeParams {
    pub target: CaptureTarget,
    /// Cursor capture is reserved in v1. The server rejects true rather than
    /// silently returning an image with platform-dependent cursor behavior.
    #[serde(default)]
    pub include_cursor: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn take_params_use_stable_tagged_target_shape() {
        let value = serde_json::to_value(TakeParams {
            target: CaptureTarget {
                kind: CaptureTargetKind::Window,
                id: "window:42".into(),
            },
            include_cursor: false,
        })
        .unwrap();
        assert_eq!(value["target"]["kind"], "window");
        assert_eq!(value["target"]["id"], "window:42");
        assert_eq!(value["include_cursor"], false);
    }
}
