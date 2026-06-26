//! Embedded-server settings and the mapping onto the server's
//! [`ServerConfig`]. This is the JSON contract with the Flutter host: the
//! Dart `EmbeddedServerConfig` mirrors [`MenuConfig`] field-for-field, so the
//! app passes its settings to `motif_embed_start` as this exact JSON shape.
//!
//! Ported from the original Tauri menu-bar app's config, minus the on-disk
//! load/save and `AppPaths` — the Flutter app owns persistence; here the
//! config only ever arrives as JSON from the host.

use std::net::{Ipv4Addr, SocketAddr};
use std::path::{Path, PathBuf};

use motif_server::{ServerConfig, TailscaleListenConfig};
use serde::{Deserialize, Serialize};

const DEFAULT_PUSH_RELAY_ADDRESS: &str = "motif-push-relay.slothease.com";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum ListenMode {
    /// 127.0.0.1 only — private, token-less is fine.
    #[default]
    Loopback,
    /// 0.0.0.0 — reachable on the LAN; requires a token.
    Lan,
    /// No TCP listener; Tailscale-only.
    Off,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TsConfig {
    #[serde(default)]
    pub enabled: bool,
    /// Empty → tsnet uses the machine hostname.
    #[serde(default)]
    pub hostname: String,
    /// Empty → interactive browser login (URL surfaced in the UI).
    #[serde(default)]
    pub authkey: String,
    /// Empty → Tailscale SaaS (controlplane.tailscale.com). Set to a
    /// Headscale base URL (e.g. https://hs.example.com) to self-host control.
    #[serde(default)]
    pub control_url: String,
}

impl Default for TsConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            hostname: String::new(),
            authkey: String::new(),
            control_url: String::new(),
        }
    }
}

/// Rendezvous-relay backend for the embedded server: park `accept` waiters at
/// a relay so a phone can pair with this in-process motifd without direct
/// connectivity. The pairing secret + identity cert are auto-generated and
/// persisted (same files the `motifd` CLI uses); the app shows the resulting
/// `motif://pair` QR.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct RzvConfig {
    #[serde(default)]
    pub enabled: bool,
    /// Relay address (`host:port`) to dial. Empty disables rzv.
    #[serde(default)]
    pub relay: String,
}

/// The `ServerConfig` plus the `motif://pair` link to surface in the host UI
/// (present only when the rendezvous backend is configured).
pub struct BuiltServerConfig {
    pub server: ServerConfig,
    pub pairing_uri: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MenuConfig {
    #[serde(default)]
    pub listen_mode: ListenMode,
    #[serde(default = "default_port")]
    pub port: u16,
    #[serde(default)]
    pub tailscale: TsConfig,
    #[serde(default)]
    pub rzv: RzvConfig,
    /// Push relay address or full URL. A bare host is expanded to
    /// `https://<host>/v1/push`; an empty string disables push.
    #[serde(default = "default_push_relay_url")]
    pub push_relay_url: String,
    /// Start the embedded server automatically when the app launches. The
    /// host (Flutter) acts on this; the embed crate just round-trips it.
    #[serde(default)]
    pub autostart: bool,
}

fn default_port() -> u16 {
    7777
}

fn default_push_relay_url() -> String {
    DEFAULT_PUSH_RELAY_ADDRESS.to_string()
}

impl Default for MenuConfig {
    fn default() -> Self {
        Self {
            listen_mode: ListenMode::default(),
            port: default_port(),
            tailscale: TsConfig::default(),
            rzv: RzvConfig::default(),
            push_relay_url: default_push_relay_url(),
            autostart: false,
        }
    }
}

impl MenuConfig {
    /// Translate into a [`ServerConfig`] (plus the pairing link when rzv is on),
    /// applying the same guards the settings UI hints at. Returns a user-facing
    /// error string when the combination can't safely start.
    pub fn to_server_config(&self, tsnet_dir: &Path) -> Result<BuiltServerConfig, String> {
        let listen = match self.listen_mode {
            ListenMode::Loopback => Some(SocketAddr::from((Ipv4Addr::LOCALHOST, self.port))),
            ListenMode::Lan => Some(SocketAddr::from((Ipv4Addr::UNSPECIFIED, self.port))),
            ListenMode::Off => None,
        };

        let rzv_on = self.rzv.enabled && !self.rzv.relay.trim().is_empty();
        // A LAN listener is a network surface: encrypt it (self-signed TLS,
        // client pins the cert) and authenticate with a psk-derived bearer, same
        // as the `motifd` CLI. Loopback stays plaintext (local host app only).
        let is_lan = matches!(self.listen_mode, ListenMode::Lan);

        if listen.is_none() && !self.tailscale.enabled && !rzv_on {
            return Err(
                "Listener is Off, Tailscale is disabled, and no relay is set — nothing to serve."
                    .into(),
            );
        }

        // In a pairing mode (LAN listen or relay), derive everything from one
        // persisted psk: the TLS identity (→ pin), the relay token, the access
        // bearer, and a single `motif://pair` link (rzv form or direct form).
        let mut rendezvous = None;
        let mut listen_tls = None;
        let mut rzv_direct = None;
        let mut token = None;
        let mut pairing_uri = None;
        if is_lan || rzv_on {
            let psk_path = motif_server::default_rzv_psk_path();
            let psk = motif_server::rzv::load_or_create_psk(&psk_path)
                .map_err(|e| format!("pairing secret: {e}"))?;
            let rzv_dir = psk_path
                .parent()
                .map(Path::to_path_buf)
                .unwrap_or_else(|| PathBuf::from("."));
            let identity = motif_server::rzv::load_or_create_identity(&rzv_dir)
                .map_err(|e| format!("TLS identity: {e}"))?;
            let pin = identity.cert_sha256;
            let name = motif_server::default_tailscale_hostname();

            token = Some(motif_server::rzv::bearer_token(&psk));

            if is_lan {
                listen_tls = Some(identity.server_config.clone());
            }
            if rzv_on {
                let relay = self.rzv.relay.trim().to_string();
                let mut c = motif_server::RzvListenConfig::new(
                    relay.clone(),
                    motif_server::rzv::derive_token(&psk),
                );
                c.tls = Some(identity.server_config.clone());
                rendezvous = Some(c);
                pairing_uri = Some(motif_server::rzv::pair_uri(
                    &relay,
                    &psk,
                    Some(&pin),
                    Some(&name),
                ));
                if is_lan {
                    let addrs = motif_server::rzv::local_nic_addrs();
                    if !addrs.is_empty() {
                        rzv_direct = Some(std::sync::Arc::new(motif_server::RzvDirectInfo {
                            port: self.port,
                            addrs,
                        }));
                    }
                }
            } else {
                // Direct (no relay): advertise all NIC addresses in the QR.
                let hosts = motif_server::rzv::local_nic_addrs();
                pairing_uri = Some(motif_server::rzv::pair_uri_direct(
                    &hosts,
                    self.port,
                    &psk,
                    Some(&pin),
                    Some(&name),
                ));
            }
        }

        let tailscale = if self.tailscale.enabled {
            let authkey = {
                let k = self.tailscale.authkey.trim();
                (!k.is_empty()).then(|| k.to_string())
            };
            // Match motifd's defaults so the embedded node is the *same*
            // tailnet device (hostname `motifd-<host>`, state dir
            // `~/.local/share/motifd/tsnet`) — otherwise a client targeting
            // motifd's tailnet name can't reach an app-launched server.
            let hostname = {
                let h = self.tailscale.hostname.trim();
                if h.is_empty() {
                    motif_server::default_tailscale_hostname()
                } else {
                    h.to_string()
                }
            };
            let state_dir = motif_server::default_tailscale_state_dir()
                .unwrap_or_else(|| tsnet_dir.to_path_buf());
            Some(TailscaleListenConfig {
                hostname,
                state_dir,
                port: self.port,
                authkey,
                control_url: {
                    let u = self.tailscale.control_url.trim();
                    (!u.is_empty()).then(|| u.to_string())
                },
                ephemeral: false,
            })
        } else {
            None
        };

        Ok(BuiltServerConfig {
            server: ServerConfig {
                listen,
                listen_tls,
                tailscale,
                rendezvous,
                rzv_direct,
                token,
                push_relay_url: normalize_push_relay_url(&self.push_relay_url),
            },
            pairing_uri,
        })
    }
}

fn normalize_push_relay_url(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }

    let candidate = if trimmed.contains("://") {
        trimmed.to_string()
    } else {
        format!("https://{trimmed}")
    };

    match url::Url::parse(&candidate) {
        Ok(mut url) => {
            if url.path().is_empty() || url.path() == "/" {
                url.set_path("/v1/push");
            }
            Some(url.to_string())
        }
        Err(_) => Some(candidate),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn tsnet() -> PathBuf {
        PathBuf::from("/tmp/motif-embed-tsnet-test")
    }

    #[test]
    fn loopback_tokenless_ok() {
        let c = MenuConfig::default(); // loopback, auth off
        let sc = c
            .to_server_config(&tsnet())
            .expect("loopback should map")
            .server;
        assert!(sc.listen.unwrap().ip().is_loopback());
        assert!(sc.token.is_none());
        assert!(sc.tailscale.is_none());
    }

    #[test]
    fn lan_is_encrypted_and_paired() {
        // A LAN listener auto-derives a psk bearer + self-signed TLS identity and
        // a direct pairing link. Point XDG_DATA_HOME at a throwaway dir so the
        // persisted psk/cert don't touch the real data dir.
        let tmp = std::env::temp_dir().join(format!("motif-embed-test-{}", std::process::id()));
        std::fs::create_dir_all(&tmp).unwrap();
        std::env::set_var("XDG_DATA_HOME", &tmp);

        let mut c = MenuConfig::default();
        c.listen_mode = ListenMode::Lan;
        let built = c.to_server_config(&tsnet()).expect("lan should map");
        let sc = &built.server;
        assert!(!sc.listen.unwrap().ip().is_loopback());
        assert!(sc.token.is_some(), "LAN derives a psk bearer");
        assert!(sc.listen_tls.is_some(), "LAN terminates TLS");
        let uri = built
            .pairing_uri
            .expect("LAN advertises a direct pairing link");
        assert!(uri.starts_with("motif://pair?"));
        assert!(uri.contains("&pk="), "carries the cert pin");
        assert!(!uri.contains("&rzv="), "direct form (no relay)");

        std::env::remove_var("XDG_DATA_HOME");
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn off_requires_tailscale() {
        let mut c = MenuConfig::default();
        c.listen_mode = ListenMode::Off;
        assert!(c.to_server_config(&tsnet()).is_err());

        c.tailscale.enabled = true;
        let sc = c
            .to_server_config(&tsnet())
            .expect("off+tailscale should map")
            .server;
        assert!(sc.listen.is_none());
        assert!(sc.tailscale.is_some());
    }

    #[test]
    fn config_parses_from_host_json() {
        // The Dart `EmbeddedServerConfig` shape must deserialize cleanly.
        // A legacy `auth` key is tolerated (ignored) for forward-compat.
        let json = r#"{
            "listen_mode": "lan",
            "port": 9001,
            "tailscale": { "enabled": true, "hostname": "my-dev" },
            "auth": { "enabled": true, "token": "abc" },
            "autostart": true
        }"#;
        let c: MenuConfig = serde_json::from_str(json).expect("parse host json");
        assert_eq!(c.port, 9001);
        assert_eq!(c.listen_mode, ListenMode::Lan);
        assert!(c.tailscale.enabled);
        assert_eq!(c.tailscale.hostname, "my-dev");
        assert_eq!(c.push_relay_url, DEFAULT_PUSH_RELAY_ADDRESS);
        assert!(c.autostart);
    }

    #[test]
    fn missing_fields_default() {
        // A bare object must fill in every field via serde defaults.
        let c: MenuConfig = serde_json::from_str("{}").expect("parse empty");
        assert_eq!(c.port, 7777);
        assert_eq!(c.listen_mode, ListenMode::Loopback);
        assert!(!c.tailscale.enabled);
        assert!(!c.rzv.enabled);
        assert_eq!(c.push_relay_url, DEFAULT_PUSH_RELAY_ADDRESS);
    }

    #[test]
    fn rzv_disabled_has_no_backend_or_pairing() {
        // Default (rzv off) takes the early-return path — no filesystem I/O.
        let built = c_default()
            .to_server_config(&tsnet())
            .expect("default maps");
        assert!(built.server.rendezvous.is_none());
        assert!(built.pairing_uri.is_none());
    }

    #[test]
    fn rzv_config_parses_from_host_json() {
        let json = r#"{"rzv":{"enabled":true,"relay":"relay.example:9999"}}"#;
        let c: MenuConfig = serde_json::from_str(json).expect("parse rzv");
        assert!(c.rzv.enabled);
        assert_eq!(c.rzv.relay, "relay.example:9999");
    }

    #[test]
    fn default_push_relay_maps_to_full_endpoint() {
        let built = c_default()
            .to_server_config(&tsnet())
            .expect("default maps");
        assert_eq!(
            built.server.push_relay_url.as_deref(),
            Some("https://motif-push-relay.slothease.com/v1/push")
        );
    }

    #[test]
    fn push_relay_url_normalizes_bare_hosts_and_allows_disable() {
        assert_eq!(
            normalize_push_relay_url("relay.example.com").as_deref(),
            Some("https://relay.example.com/v1/push")
        );
        assert_eq!(
            normalize_push_relay_url("https://relay.example.com/custom").as_deref(),
            Some("https://relay.example.com/custom")
        );
        assert_eq!(normalize_push_relay_url("   "), None);
    }

    fn c_default() -> MenuConfig {
        MenuConfig::default()
    }
}
