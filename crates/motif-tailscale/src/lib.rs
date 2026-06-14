//! Embedded Tailscale support for motif.
//!
//! With `--features bundled` this crate wraps the
//! [`libtailscale`](https://crates.io/crates/libtailscale) Rust binding,
//! which itself shells out to a vendored Go-built `libtailscale.a` (via
//! `libtailscale-sys`'s build.rs). Without the feature, every runtime call
//! returns `TsError::Unimplemented` so downstream crates compile without a
//! Go toolchain.
//!
//! The public surface (`TsServer`, `TsStream`, `TsListener`,
//! `TsOptions`, `TsError`) is identical between the two modes — only the
//! bodies change. That's what lets `motif-net` consume this crate without
//! conditional compilation past the feature gate it already has on the
//! tailscale path.

use std::path::PathBuf;

#[cfg(feature = "bundled")]
mod bundled;
#[cfg(not(feature = "bundled"))]
mod stub;

#[cfg(feature = "bundled")]
pub use bundled::{TsBackendStatus, TsListener, TsServer, TsStream};
#[cfg(not(feature = "bundled"))]
pub use stub::{TsBackendStatus, TsListener, TsServer, TsStream};

#[derive(Debug, thiserror::Error)]
pub enum TsError {
    #[error("Tailscale support is not implemented in this build (enable feature `bundled`)")]
    Unimplemented,
    #[error("libtailscale call failed: {0}")]
    Native(String),
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
}

#[derive(Debug, Clone)]
pub struct TsOptions {
    pub hostname: String,
    pub state_dir: PathBuf,
    pub authkey: Option<String>,
    pub control_url: Option<String>,
    pub ephemeral: bool,
}

#[derive(Debug, Clone)]
pub struct TsPeer {
    pub hostname: String,
    pub ip: String,
    pub os: String,
    pub online: bool,
}

/// Pull a device-auth URL out of a tsnet log line, normalized to `https://`.
///
/// Recognizes Tailscale's official `login.tailscale.com/a/…` URLs, and — when
/// `control_host` is set (a self-hosted Headscale control server) — auth URLs
/// on that host: Headscale's `/register/…` web flow, or any path on the host
/// when the line reads as an auth prompt ("…authenticate…").
///
/// tsnet sometimes logs the URL without a scheme or glued to a prefix (e.g.
/// `authURL=https://…`), and the desktop OS launcher only opens `http(s)://`
/// URLs — so the result is always rebuilt with an `https://` scheme from the
/// host onward. Pure string logic; available regardless of the `bundled`
/// feature so non-Go builds (and the embed crate's log-ring scrape) can reuse
/// it.
pub fn extract_auth_url(line: &str, control_host: Option<&str>) -> Option<String> {
    // Official Tailscale: interactive-auth URLs live under `/a/`.
    if let Some(u) = url_from_anchor(line, "login.tailscale.com/a/") {
        return Some(u);
    }
    // Custom control server (Headscale): the auth URL is on the configured
    // host. Match its `/register/` web flow, or any path on the host when the
    // line is clearly an auth prompt.
    let host = control_host.filter(|h| !h.is_empty())?;
    if let Some(u) = url_from_anchor(line, &format!("{host}/register/")) {
        return Some(u);
    }
    if line.to_ascii_lowercase().contains("authenticat") {
        return url_from_anchor(line, &format!("{host}/"));
    }
    None
}

/// Rebuild an `https://` URL from the first occurrence of `anchor` (a host+path
/// fragment) to the next whitespace.
fn url_from_anchor(line: &str, anchor: &str) -> Option<String> {
    let idx = line.find(anchor)?;
    let rest = &line[idx..];
    let end = rest.find(char::is_whitespace).unwrap_or(rest.len());
    Some(format!("https://{}", &rest[..end]))
}

/// Host (with port, without scheme/path) of a control URL, for matching auth
/// URLs against it. `https://hs.example.com:8080/x` → `hs.example.com:8080`.
/// Returns `None` for empty input.
pub fn host_of(url: &str) -> Option<String> {
    let s = url.trim();
    let after_scheme = s.find("://").map(|i| &s[i + 3..]).unwrap_or(s);
    let host = after_scheme.split('/').next().unwrap_or("");
    (!host.is_empty()).then(|| host.to_string())
}

#[cfg(test)]
mod auth_url_tests {
    use super::{extract_auth_url, host_of};

    #[test]
    fn official_tailscale() {
        // Normal line with scheme.
        assert_eq!(
            extract_auth_url(
                "To authenticate, visit: https://login.tailscale.com/a/abc123def now",
                None,
            )
            .as_deref(),
            Some("https://login.tailscale.com/a/abc123def")
        );
        // Scheme-less in the log → still produces a launchable https URL.
        assert_eq!(
            extract_auth_url("login.tailscale.com/a/xyz", None).as_deref(),
            Some("https://login.tailscale.com/a/xyz")
        );
        // Glued prefix (e.g. `authURL=`) → dropped.
        assert_eq!(
            extract_auth_url("control: authURL=https://login.tailscale.com/a/xyz", None)
                .as_deref(),
            Some("https://login.tailscale.com/a/xyz")
        );
        assert_eq!(extract_auth_url("nothing here", None), None);
    }

    #[test]
    fn headscale_custom_host() {
        let host = Some("headscale.example.com");
        // Headscale's `/register/` web flow on the configured control host.
        assert_eq!(
            extract_auth_url(
                "To authenticate, visit: https://headscale.example.com/register/nodekey:abcd",
                host,
            )
            .as_deref(),
            Some("https://headscale.example.com/register/nodekey:abcd")
        );
        // Any path on the control host when the line is an auth prompt.
        assert_eq!(
            extract_auth_url(
                "To authenticate, visit: https://headscale.example.com/o/auth?x=1",
                host,
            )
            .as_deref(),
            Some("https://headscale.example.com/o/auth?x=1")
        );
        // Without the control host configured, a non-Tailscale URL is ignored.
        assert_eq!(
            extract_auth_url("visit https://headscale.example.com/register/x", None),
            None
        );
        // Host configured but the line is neither `/register/` nor an auth
        // prompt → not mistaken for an auth URL.
        assert_eq!(
            extract_auth_url("GET https://headscale.example.com/health 200", host),
            None
        );
    }

    #[test]
    fn host_extraction() {
        assert_eq!(host_of("https://hs.example.com").as_deref(), Some("hs.example.com"));
        assert_eq!(
            host_of("https://hs.example.com:8080/path").as_deref(),
            Some("hs.example.com:8080")
        );
        assert_eq!(host_of("  https://hs.example.com/  ").as_deref(), Some("hs.example.com"));
        assert_eq!(host_of(""), None);
    }
}
