//! Platform-aware locations used by motifd.
//!
//! Unix builds retain the historical XDG / `~/.local/share` layout. Windows
//! uses the user's profile and local application-data directory instead of
//! assuming that `HOME`, `/`, or `/tmp` exist.

use std::path::{Path, PathBuf};

pub(crate) fn home_dir() -> Option<PathBuf> {
    #[cfg(windows)]
    {
        std::env::var_os("USERPROFILE")
            .filter(|v| !v.is_empty())
            .map(PathBuf::from)
            .or_else(dirs::home_dir)
            .or_else(|| {
                std::env::var_os("HOME")
                    .filter(|v| !v.is_empty())
                    .map(PathBuf::from)
            })
    }

    #[cfg(not(windows))]
    {
        std::env::var_os("HOME")
            .filter(|v| !v.is_empty())
            .map(PathBuf::from)
            .or_else(dirs::home_dir)
    }
}

/// Base directory for persistent motifd state.
pub(crate) fn data_dir() -> Option<PathBuf> {
    if let Some(dir) = std::env::var_os("XDG_DATA_HOME").filter(|v| !v.is_empty()) {
        return Some(PathBuf::from(dir));
    }

    #[cfg(windows)]
    {
        dirs::data_local_dir().or_else(dirs::data_dir)
    }

    #[cfg(not(windows))]
    {
        home_dir().map(|home| home.join(".local").join("share"))
    }
}

/// Expand `~`, `~/...`, and (on Windows clients) `~\...` without invoking a
/// shell. `~user` is intentionally unsupported.
pub(crate) fn expand_tilde(path: &Path) -> Option<PathBuf> {
    let s = path.to_str()?;
    if s == "~" {
        return home_dir();
    }
    let rest = s.strip_prefix("~/").or_else(|| s.strip_prefix("~\\"))?;
    Some(home_dir()?.join(rest))
}

pub(crate) fn home_or_current_dir() -> PathBuf {
    home_dir()
        .or_else(|| std::env::current_dir().ok())
        .unwrap_or_else(|| PathBuf::from("."))
}

/// Per-user runtime directory for short-lived files such as shell bootstrap
/// scripts and Unix sockets.
pub(crate) fn runtime_dir(component: &str) -> PathBuf {
    #[cfg(not(windows))]
    if let Some(dir) = std::env::var_os("XDG_RUNTIME_DIR").filter(|v| !v.is_empty()) {
        return PathBuf::from(dir).join(component);
    }
    std::env::temp_dir().join(component)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tilde_expansion_uses_platform_home() {
        let home = home_dir().expect("test user has a home directory");
        assert_eq!(expand_tilde(Path::new("~")), Some(home.clone()));
        assert_eq!(expand_tilde(Path::new("~/code")), Some(home.join("code")));
        assert!(expand_tilde(Path::new("~someone/code")).is_none());
    }

    #[test]
    fn runtime_dir_has_component_suffix() {
        assert!(runtime_dir("motif-test").ends_with("motif-test"));
    }
}
