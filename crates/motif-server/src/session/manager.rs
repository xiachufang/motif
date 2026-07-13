//! `SessionManager` — keyed by user-provided session name.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use dashmap::mapref::entry::Entry;
use dashmap::DashMap;

use super::Session;

#[derive(Default)]
pub struct SessionManager {
    sessions: DashMap<String, Arc<Session>>,
}

#[derive(Debug, thiserror::Error)]
pub enum ManagerError {
    #[error("session '{0}' already exists")]
    AlreadyExists(String),
    #[error("session '{0}' not found")]
    NotFound(String),
    #[error("workdir does not exist or is not a directory: {0}")]
    BadWorkdir(PathBuf),
}

impl SessionManager {
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    pub fn create(&self, name: String, workdir: PathBuf) -> Result<Arc<Session>, ManagerError> {
        let workdir = expand_home(&workdir).unwrap_or(workdir);
        if !workdir.is_dir() {
            return Err(ManagerError::BadWorkdir(workdir));
        }
        // Canonicalize so it matches what the kernel reports for child cwds.
        // macOS /tmp → /private/tmp (and similar) is the load-bearing case:
        // without this, the cwd watcher's path "/private/tmp/foo" never falls
        // inside session workdir "/tmp/foo", and the file-tree-follows-PTY
        // logic on the client thinks every cwd update escapes the workdir.
        let workdir = workdir.canonicalize().unwrap_or(workdir);
        match self.sessions.entry(name.clone()) {
            Entry::Occupied(_) => Err(ManagerError::AlreadyExists(name)),
            Entry::Vacant(entry) => {
                let session = Session::new(name, workdir);
                entry.insert(Arc::clone(&session));
                Ok(session)
            }
        }
    }

    pub fn get(&self, name: &str) -> Option<Arc<Session>> {
        self.sessions.get(name).map(|r| r.clone())
    }

    pub fn destroy(&self, name: &str) -> Result<(), ManagerError> {
        let session = self
            .sessions
            .remove(name)
            .map(|(_, session)| session)
            .ok_or_else(|| ManagerError::NotFound(name.to_string()))?;
        session.shutdown();
        Ok(())
    }

    pub fn list(&self) -> Vec<Arc<Session>> {
        self.sessions.iter().map(|r| r.clone()).collect()
    }
}

/// Expand a leading `~` or `~/` against `$HOME`. Anything else is left alone.
/// `~user` (other-user expansion) is intentionally not supported — that's
/// a pure cosmetic feature and the security boundaries differ.
fn expand_home(p: &Path) -> Option<PathBuf> {
    let s = p.to_str()?;
    if s == "~" {
        return std::env::var_os("HOME").map(PathBuf::from);
    }
    if let Some(rest) = s.strip_prefix("~/") {
        let home = std::env::var_os("HOME")?;
        let mut pb = PathBuf::from(home);
        pb.push(rest);
        return Some(pb);
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn expands_tilde_alone() {
        let home = std::env::var("HOME").unwrap();
        assert_eq!(expand_home(Path::new("~")).unwrap(), PathBuf::from(home));
    }
    #[test]
    fn expands_tilde_slash_subpath() {
        let home = std::env::var("HOME").unwrap();
        assert_eq!(
            expand_home(Path::new("~/code/foo")).unwrap(),
            PathBuf::from(format!("{home}/code/foo")),
        );
    }
    #[test]
    fn leaves_absolute_alone() {
        assert!(expand_home(Path::new("/tmp/x")).is_none());
    }
    #[test]
    fn leaves_relative_alone() {
        assert!(expand_home(Path::new("foo/bar")).is_none());
    }
}
