//! `device.*` request/response types — push-notification device registration.
//!
//! A client (currently iOS) registers its APNs device token plus a per-device
//! symmetric key. The key is shared only between the client and this motifd
//! instance (over the already-authenticated RPC channel); the push relay never
//! sees it, so notification content is end-to-end encrypted. See
//! `docs/prd.md` and the push-relay design notes.

use serde::{Deserialize, Serialize};

// ────────────────────────────────────────────────────── device.register

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RegisterParams {
    /// APNs device token, lowercase hex.
    pub device_token: String,
    /// Client platform, e.g. `"ios"`.
    pub platform: String,
    /// APNs environment hint: `"sandbox"` (dev builds) or `"production"`
    /// (App Store / TestFlight). The relay uses it to pick the APNs host.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub environment: Option<String>,
    /// Base64 of a 32-byte AES-256-GCM key generated on-device. motifd uses it
    /// to encrypt the notification payload per device; the relay only ever sees
    /// the ciphertext.
    pub enc_key: String,
    /// Optional client app version, for diagnostics.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub app_version: Option<String>,
    /// Full set of session names this device has muted. Sent on every connect
    /// so the (in-memory) server state is restored after a motifd restart.
    /// `None` leaves any existing muted set untouched; `Some` is authoritative.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub muted_sessions: Option<Vec<String>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RegisterResult {
    /// This motifd instance's stable id. The client persists
    /// `instance_id → server` so a tapped notification can be routed back to
    /// the right configured server for deep-linking.
    pub instance_id: String,
}

// ──────────────────────────────────────────────────── device.unregister

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UnregisterParams {
    pub device_token: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct UnregisterResult {}

// ─────────────────────────────────────────────── device.set_session_muted

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SetSessionMutedParams {
    pub device_token: String,
    /// Session name to mute/unmute notifications for.
    pub session: String,
    /// `true` mutes (no pushes to this device for this session), `false` unmutes.
    pub muted: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct SetSessionMutedResult {}

// ─────────────────────────────────────────────── admin/debug surfaces

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RegisteredDevice {
    /// APNs device token, lowercase hex.
    pub device_token: String,
    pub platform: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub environment: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub app_version: Option<String>,
    pub registered_at: u64,
    #[serde(default)]
    pub muted_sessions: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct TestPushResult {
    /// `true` when the relay accepted the test notification for APNs delivery.
    pub sent: bool,
    /// `true` when the relay reported this token invalid and motifd pruned it.
    pub pruned: bool,
}
