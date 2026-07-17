//! `SessionManager` — keyed by user-provided session name.

#[cfg(test)]
use std::path::Path;
use std::path::PathBuf;
use std::sync::Arc;

use dashmap::mapref::entry::Entry;
use dashmap::DashMap;

use super::Session;

pub struct SessionManager {
    sessions: DashMap<String, Arc<Session>>,
    default_shell: Option<Arc<str>>,
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
        Self::with_default_shell(None)
    }

    pub fn with_default_shell(default_shell: Option<String>) -> Arc<Self> {
        Arc::new(Self {
            sessions: DashMap::new(),
            default_shell: default_shell.map(Arc::<str>::from),
        })
    }

    pub fn create(&self, name: String, workdir: PathBuf) -> Result<Arc<Session>, ManagerError> {
        let workdir = crate::paths::expand_tilde(&workdir).unwrap_or(workdir);
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
                let session = Session::new(name, workdir, self.default_shell.clone());
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn expands_tilde_alone() {
        let home = crate::paths::home_dir().unwrap();
        assert_eq!(crate::paths::expand_tilde(Path::new("~")).unwrap(), home);
    }
    #[test]
    fn expands_tilde_slash_subpath() {
        let home = crate::paths::home_dir().unwrap();
        assert_eq!(
            crate::paths::expand_tilde(Path::new("~/code/foo")).unwrap(),
            home.join("code").join("foo"),
        );
    }
    #[test]
    fn leaves_absolute_alone() {
        assert!(crate::paths::expand_tilde(Path::new("/tmp/x")).is_none());
    }
    #[test]
    fn leaves_relative_alone() {
        assert!(crate::paths::expand_tilde(Path::new("foo/bar")).is_none());
    }
}
