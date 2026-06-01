//! In-memory registry of push-notification devices (APNs tokens + per-device
//! encryption keys).
//!
//! Deliberately NOT persisted — it matches motifd's session/PTY lifecycle
//! (everything but the tsnet identity is in-memory). The rationale: a push can
//! only originate from a Claude Code hook running inside a PTY, and a PTY only
//! exists after a client connects and creates it. A connecting client always
//! re-registers its token (idempotent upsert) before any hook can fire, so a
//! token from before a restart would never be read before being re-registered.
//! Keeping it in memory also means the per-device AES key never touches
//! motifd's disk — it lives only in RAM, re-supplied over the authenticated
//! RPC channel on each connect.
//!
//! Trade-off: a *second* device that registered before a restart but hasn't
//! reconnected since won't receive pushes until it next connects. Negligible
//! for a personal, few-device setup.

use std::collections::HashSet;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use parking_lot::Mutex;

#[derive(Debug, Clone)]
pub struct DeviceEntry {
    /// APNs device token, lowercase hex.
    pub device_token: String,
    pub platform: String,
    pub environment: Option<String>,
    /// Base64 of the 32-byte AES-256-GCM key shared with this device.
    pub enc_key: String,
    pub app_version: Option<String>,
    /// Unix ms when last registered.
    pub registered_at: u64,
    /// Session names this device has muted — the relay skips this device when a
    /// notification's session is in here. Per-device (lives with the entry, so
    /// it's dropped automatically on unregister/prune).
    pub muted_sessions: HashSet<String>,
}

/// Thread-safe in-memory device registry.
pub struct DeviceStore {
    /// Stable per-process id. Minted once at startup and echoed to clients so a
    /// tapped notification can route back to the right server. Re-minted on
    /// restart; clients re-map on their next register (nothing routes before
    /// then), so it needn't survive restarts.
    instance_id: String,
    devices: Mutex<Vec<DeviceEntry>>,
}

impl DeviceStore {
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            instance_id: ulid::Ulid::new().to_string(),
            devices: Mutex::new(Vec::new()),
        })
    }

    pub fn instance_id(&self) -> String {
        self.instance_id.clone()
    }

    /// Upsert a device by token. `muted` is the authoritative muted-session set
    /// when `Some` (replayed by the client on every connect); `None` preserves
    /// whatever set the existing entry already had. `entry.muted_sessions` is
    /// ignored — this method fills it.
    pub fn register(&self, mut entry: DeviceEntry, muted: Option<HashSet<String>>) {
        if entry.registered_at == 0 {
            entry.registered_at = now_ms();
        }
        let mut g = self.devices.lock();
        if let Some(existing) = g.iter_mut().find(|d| d.device_token == entry.device_token) {
            entry.muted_sessions = muted.unwrap_or_else(|| existing.muted_sessions.clone());
            *existing = entry;
        } else {
            entry.muted_sessions = muted.unwrap_or_default();
            g.push(entry);
        }
    }

    /// Mute/unmute a session for a single device (no-op if the token is absent).
    pub fn set_session_muted(&self, token: &str, session: &str, muted: bool) {
        let mut g = self.devices.lock();
        if let Some(d) = g.iter_mut().find(|d| d.device_token == token) {
            if muted {
                d.muted_sessions.insert(session.to_string());
            } else {
                d.muted_sessions.remove(session);
            }
        }
    }

    /// Remove a device by token (no-op if absent).
    pub fn unregister(&self, token: &str) {
        self.devices.lock().retain(|d| d.device_token != token);
    }

    /// Drop a token that APNs reported as no longer valid (410/BadDeviceToken).
    pub fn prune(&self, token: &str) {
        self.unregister(token);
    }

    /// Snapshot of all registered devices.
    pub fn all(&self) -> Vec<DeviceEntry> {
        self.devices.lock().clone()
    }
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(token: &str) -> DeviceEntry {
        DeviceEntry {
            device_token: token.into(),
            platform: "ios".into(),
            environment: Some("sandbox".into()),
            enc_key: "AAAA".into(),
            app_version: None,
            registered_at: 0,
            muted_sessions: HashSet::new(),
        }
    }

    #[test]
    fn register_unregister_prune_and_upsert() {
        let store = DeviceStore::new();
        assert!(!store.instance_id().is_empty());

        store.register(entry("aa"), None);
        store.register(entry("bb"), None);
        // Upsert: same token replaces, doesn't duplicate.
        store.register(entry("aa"), None);
        assert_eq!(store.all().len(), 2);

        store.prune("aa");
        let remaining = store.all();
        assert_eq!(remaining.len(), 1);
        assert_eq!(remaining[0].device_token, "bb");

        store.unregister("missing"); // no-op
        assert_eq!(store.all().len(), 1);
    }

    #[test]
    fn per_session_mute_toggles_and_register_preserves() {
        let store = DeviceStore::new();
        store.register(entry("aa"), None);

        store.set_session_muted("aa", "work", true);
        assert!(store.all()[0].muted_sessions.contains("work"));

        // Re-register with None preserves the muted set (e.g. a reconnect that
        // didn't send the list).
        store.register(entry("aa"), None);
        assert!(store.all()[0].muted_sessions.contains("work"));

        // Re-register with Some is authoritative (full replay from the client).
        store.register(entry("aa"), Some(HashSet::from(["other".to_string()])));
        let m = &store.all()[0].muted_sessions;
        assert!(m.contains("other") && !m.contains("work"));

        store.set_session_muted("aa", "other", false);
        assert!(store.all()[0].muted_sessions.is_empty());
    }

    #[test]
    fn instance_id_is_minted_per_store() {
        let a = DeviceStore::new();
        let b = DeviceStore::new();
        assert_ne!(a.instance_id(), b.instance_id());
        // Stable within a store.
        assert_eq!(a.instance_id(), a.instance_id());
    }
}
