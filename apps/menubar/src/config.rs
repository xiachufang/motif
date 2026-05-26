//! Persistent menu-bar app settings (`config.json`) and the mapping onto
//! the server's [`ServerConfig`]. Stored under the platform config dir; the
//! token lives here (user-set in the settings window), so it's passed
//! straight into the embedded server — no separate token file.

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
}

impl Default for TsConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            hostname: String::new(),
            authkey: String::new(),
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
    /// Start the embedded server automatically when the app launches.
    #[serde(default)]
    pub autostart: bool,
    /// Register the app to launch at OS login (via tauri-plugin-autostart).
    #[serde(default)]
    pub launch_at_login: bool,
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
            autostart: false,
            launch_at_login: false,
        }
    }
}

impl MenuConfig {
    /// Read `config.json`, falling back to defaults on missing/corrupt files
    /// (missing fields default individually via `#[serde(default)]`).
    pub fn load(path: &Path) -> Self {
        match std::fs::read(path) {
            Ok(bytes) => serde_json::from_slice(&bytes).unwrap_or_else(|e| {
                tracing::warn!(error = %e, "config.json parse failed; using defaults");
                Self::default()
            }),
            Err(_) => Self::default(),
        }
    }

    pub fn save(&self, path: &Path) -> std::io::Result<()> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let json = serde_json::to_vec_pretty(self).expect("serialize MenuConfig");
        std::fs::write(path, json)
    }

    /// Translate into a [`ServerConfig`], applying the same guards the
    /// settings UI hints at. Returns a user-facing error string when the
    /// combination can't safely start.
    pub fn to_server_config(&self, tsnet_dir: &Path) -> Result<ServerConfig, String> {
        let listen = match self.listen_mode {
            ListenMode::Loopback => Some(SocketAddr::from((Ipv4Addr::LOCALHOST, self.port))),
            ListenMode::Lan => Some(SocketAddr::from((Ipv4Addr::UNSPECIFIED, self.port))),
            ListenMode::Off => None,
        };

        if listen.is_none() && !self.tailscale.enabled {
            return Err("Listener is Off and Tailscale is disabled — nothing to serve.".into());
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
            Some(TailscaleListenConfig {
                hostname: self.tailscale.hostname.trim().to_string(),
                state_dir: tsnet_dir.to_path_buf(),
                port: self.port,
                authkey,
                control_url: None,
                ephemeral: false,
            })
        } else {
            None
        };

        Ok(ServerConfig {
            listen,
            tailscale,
            token,
            cert: None,
            key: None,
            allow_insecure_no_auth,
        })
    }
}

/// Resolved filesystem locations for the app.
#[derive(Debug, Clone)]
pub struct AppPaths {
    pub config_file: PathBuf,
    pub tsnet_dir: PathBuf,
    pub log_dir: PathBuf,
}

/// Config under the platform config dir, runtime state under the data dir.
/// (On macOS both resolve under `~/Library/Application Support`.)
pub fn app_paths() -> AppPaths {
    let config_root = dirs::config_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("motif");
    let data_root = dirs::data_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("motif");
    AppPaths {
        config_file: config_root.join("config.json"),
        tsnet_dir: data_root.join("tsnet"),
        log_dir: data_root.join("logs"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tsnet() -> PathBuf {
        PathBuf::from("/tmp/motif-tsnet-test")
    }

    #[test]
    fn loopback_tokenless_ok() {
        let c = MenuConfig::default(); // loopback, auth off
        let sc = c.to_server_config(&tsnet()).expect("loopback should map");
        assert!(sc.listen.unwrap().ip().is_loopback());
        assert!(sc.token.is_none());
        assert!(sc.tailscale.is_none());
    }

    #[test]
    fn lan_without_token_allowed_insecure() {
        let mut c = MenuConfig::default();
        c.listen_mode = ListenMode::Lan;
        let sc = c.to_server_config(&tsnet()).expect("lan without token is allowed");
        assert!(sc.token.is_none());
        assert!(sc.allow_insecure_no_auth, "must opt into insecure for non-loopback no-auth");
    }

    #[test]
    fn lan_with_token_ok() {
        let mut c = MenuConfig::default();
        c.listen_mode = ListenMode::Lan;
        c.auth = AuthConfig { enabled: true, token: "secret".into() };
        let sc = c.to_server_config(&tsnet()).expect("lan+token should map");
        assert_eq!(sc.token.as_deref(), Some("secret"));
        assert!(!sc.listen.unwrap().ip().is_loopback());
    }

    #[test]
    fn auth_on_empty_token_rejected() {
        let mut c = MenuConfig::default();
        c.auth = AuthConfig { enabled: true, token: "  ".into() };
        assert!(c.to_server_config(&tsnet()).is_err());
    }

    #[test]
    fn off_requires_tailscale() {
        let mut c = MenuConfig::default();
        c.listen_mode = ListenMode::Off;
        assert!(c.to_server_config(&tsnet()).is_err());

        c.tailscale.enabled = true;
        let sc = c.to_server_config(&tsnet()).expect("off+tailscale should map");
        assert!(sc.listen.is_none());
        assert!(sc.tailscale.is_some());
    }

    #[test]
    fn config_roundtrips_through_json() {
        let dir = std::env::temp_dir().join(format!("motif-cfg-{}", std::process::id()));
        let path = dir.join("config.json");
        let mut c = MenuConfig::default();
        c.port = 9001;
        c.tailscale.enabled = true;
        c.tailscale.hostname = "my-dev".into();
        c.save(&path).expect("save");
        let back = MenuConfig::load(&path);
        assert_eq!(back.port, 9001);
        assert!(back.tailscale.enabled);
        assert_eq!(back.tailscale.hostname, "my-dev");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
