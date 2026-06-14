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

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct AuthConfig {
    #[serde(default)]
    pub enabled: bool,
    /// User-set bearer token. Empty while `enabled` blocks start with a
    /// clear error so the user goes and sets/generates one.
    #[serde(default)]
    pub token: String,
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
    pub auth: AuthConfig,
    #[serde(default)]
    pub rzv: RzvConfig,
    /// Start the embedded server automatically when the app launches. The
    /// host (Flutter) acts on this; the embed crate just round-trips it.
    #[serde(default)]
    pub autostart: bool,
}

fn default_port() -> u16 {
    7777
}

impl Default for MenuConfig {
    fn default() -> Self {
        Self {
            listen_mode: ListenMode::default(),
            port: default_port(),
            tailscale: TsConfig::default(),
            auth: AuthConfig::default(),
            rzv: RzvConfig::default(),
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

        let (rendezvous, pairing_uri) = self.build_rzv()?;

        if listen.is_none() && !self.tailscale.enabled && rendezvous.is_none() {
            return Err(
                "Listener is Off, Tailscale is disabled, and no relay is set — nothing to serve."
                    .into(),
            );
        }

        let token = if self.auth.enabled {
            let t = self.auth.token.trim();
            if t.is_empty() {
                return Err("Auth is on but no token is set — enter or generate one.".into());
            }
            Some(t.to_string())
        } else {
            None
        };

        // LAN without a token is permitted by request. The server's
        // `validate()` refuses a non-loopback listener without auth unless we
        // explicitly opt in, so flip the override in exactly that case.
        let allow_insecure_no_auth =
            matches!(self.listen_mode, ListenMode::Lan) && token.is_none();

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
                tailscale,
                rendezvous,
                token,
                allow_insecure_no_auth,
                // The embedded server runs motifd on loopback/LAN for local use;
                // push notifications (which need a public relay) aren't wired
                // here.
                push_relay_url: None,
            },
            pairing_uri,
        })
    }

    /// Build the rendezvous backend (and its pairing link) when enabled. The
    /// pairing secret + identity cert are persisted under the same data dir the
    /// `motifd` CLI uses, so the QR is stable across restarts and end-to-end TLS
    /// is on (the relay only sees ciphertext).
    fn build_rzv(
        &self,
    ) -> Result<(Option<motif_server::RzvListenConfig>, Option<String>), String> {
        let relay = self.rzv.relay.trim();
        if !self.rzv.enabled || relay.is_empty() {
            return Ok((None, None));
        }

        let psk_path = motif_server::default_rzv_psk_path();
        let psk = motif_server::rzv::load_or_create_psk(&psk_path)
            .map_err(|e| format!("rzv pairing secret: {e}"))?;
        let token = motif_server::rzv::derive_token(&psk);

        let rzv_dir = psk_path
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_else(|| PathBuf::from("."));
        let identity = motif_server::rzv::load_or_create_identity(&rzv_dir)
            .map_err(|e| format!("rzv identity: {e}"))?;

        let name = motif_server::default_tailscale_hostname();
        let uri = motif_server::rzv::pair_uri(relay, &psk, Some(&identity.cert_sha256), Some(&name));

        let mut cfg = motif_server::RzvListenConfig::new(relay.to_string(), token);
        cfg.tls = Some(identity.server_config);
        Ok((Some(cfg), Some(uri)))
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
        let sc = c.to_server_config(&tsnet()).expect("loopback should map").server;
        assert!(sc.listen.unwrap().ip().is_loopback());
        assert!(sc.token.is_none());
        assert!(sc.tailscale.is_none());
    }

    #[test]
    fn lan_without_token_allowed_insecure() {
        let mut c = MenuConfig::default();
        c.listen_mode = ListenMode::Lan;
        let sc = c
            .to_server_config(&tsnet())
            .expect("lan without token is allowed")
            .server;
        assert!(sc.token.is_none());
        assert!(
            sc.allow_insecure_no_auth,
            "must opt into insecure for non-loopback no-auth"
        );
    }

    #[test]
    fn lan_with_token_ok() {
        let mut c = MenuConfig::default();
        c.listen_mode = ListenMode::Lan;
        c.auth = AuthConfig {
            enabled: true,
            token: "secret".into(),
        };
        let sc = c.to_server_config(&tsnet()).expect("lan+token should map").server;
        assert_eq!(sc.token.as_deref(), Some("secret"));
        assert!(!sc.listen.unwrap().ip().is_loopback());
    }

    #[test]
    fn auth_on_empty_token_rejected() {
        let mut c = MenuConfig::default();
        c.auth = AuthConfig {
            enabled: true,
            token: "  ".into(),
        };
        assert!(c.to_server_config(&tsnet()).is_err());
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
        assert!(c.auth.enabled);
        assert!(c.autostart);
    }

    #[test]
    fn missing_fields_default() {
        // A bare object must fill in every field via serde defaults.
        let c: MenuConfig = serde_json::from_str("{}").expect("parse empty");
        assert_eq!(c.port, 7777);
        assert_eq!(c.listen_mode, ListenMode::Loopback);
        assert!(!c.tailscale.enabled);
        assert!(!c.auth.enabled);
        assert!(!c.rzv.enabled);
    }

    #[test]
    fn rzv_disabled_has_no_backend_or_pairing() {
        // Default (rzv off) takes the early-return path — no filesystem I/O.
        let built = c_default().to_server_config(&tsnet()).expect("default maps");
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

    fn c_default() -> MenuConfig {
        MenuConfig::default()
    }
}
