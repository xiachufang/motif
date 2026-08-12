//! `SessionManager` — public user sessions plus internal hidden workspaces.

use std::path::PathBuf;
use std::sync::Arc;

use dashmap::mapref::entry::Entry;
use dashmap::DashMap;

use super::Session;

const INTERNAL_SESSION_PREFIX: &str = "__motif_internal_";

#[derive(Default)]
pub struct SessionManager {
    /// Sessions returned by `session.list`, keyed by user-provided name.
    sessions: DashMap<String, Arc<Session>>,
    /// Ordinary Session instances owned by server features such as Codex.
    /// They deliberately stay out of `session.list` and cannot be destroyed
    /// through the public `session.destroy` RPC.
    hidden_sessions: DashMap<String, Arc<Session>>,
}

#[derive(Debug, thiserror::Error)]
pub enum ManagerError {
    #[error("session '{0}' already exists")]
    AlreadyExists(String),
    #[error("session '{0}' not found")]
    NotFound(String),
    #[error("session names beginning with '__motif_internal_' are reserved")]
    ReservedName,
    #[error("workdir does not exist or is not a directory: {0}")]
    BadWorkdir(PathBuf),
}

impl SessionManager {
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    pub fn create(&self, name: String, workdir: PathBuf) -> Result<Arc<Session>, ManagerError> {
        if name.starts_with(INTERNAL_SESSION_PREFIX) {
            return Err(ManagerError::ReservedName);
        }
        let workdir = normalize_workdir(workdir)?;
        match self.sessions.entry(name.clone()) {
            Entry::Occupied(_) => Err(ManagerError::AlreadyExists(name)),
            Entry::Vacant(entry) => {
                let session = Session::new(name, workdir);
                entry.insert(Arc::clone(&session));
                Ok(session)
            }
        }
    }

    /// Create a normal Session that is attachable by its opaque name but is
    /// omitted from the user-facing catalog. The owner must retain that name
    /// and call [`destroy_hidden`] as part of its own lifecycle.
    pub fn create_hidden(&self, workdir: PathBuf) -> Result<Arc<Session>, ManagerError> {
        let workdir = normalize_workdir(workdir)?;
        loop {
            let name = format!("{INTERNAL_SESSION_PREFIX}{}", ulid::Ulid::new());
            match self.hidden_sessions.entry(name.clone()) {
                Entry::Occupied(_) => continue,
                Entry::Vacant(entry) => {
                    let session = Session::new(name, workdir);
                    entry.insert(Arc::clone(&session));
                    return Ok(session);
                }
            }
        }
    }

    pub fn shutdown_all(&self) {
        for session in self.all() {
            session.shutdown();
        }
    }

    /// Resolve both listed and hidden sessions. Attachments and feature RPCs
    /// use this path, so hidden workspaces reuse the complete Session stack.
    pub fn get(&self, name: &str) -> Option<Arc<Session>> {
        self.sessions
            .get(name)
            .or_else(|| self.hidden_sessions.get(name))
            .map(|entry| Arc::clone(entry.value()))
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

    pub fn destroy_hidden(&self, name: &str) -> bool {
        let Some((_, session)) = self.hidden_sessions.remove(name) else {
            return false;
        };
        session.shutdown();
        true
    }

    /// User-visible sessions only.
    pub fn list(&self) -> Vec<Arc<Session>> {
        self.sessions
            .iter()
            .map(|entry| Arc::clone(entry.value()))
            .collect()
    }

    fn all(&self) -> Vec<Arc<Session>> {
        self.sessions
            .iter()
            .chain(self.hidden_sessions.iter())
            .map(|entry| Arc::clone(entry.value()))
            .collect()
    }

    #[cfg(test)]
    pub(crate) fn hidden_count(&self) -> usize {
        self.hidden_sessions.len()
    }
}

fn normalize_workdir(workdir: PathBuf) -> Result<PathBuf, ManagerError> {
    let workdir = crate::paths::expand_tilde(&workdir).unwrap_or(workdir);
    if !workdir.is_dir() {
        return Err(ManagerError::BadWorkdir(workdir));
    }
    // Canonicalize so it matches what the kernel reports for child cwds.
    // macOS /tmp → /private/tmp (and similar) is the load-bearing case.
    Ok(workdir.canonicalize().unwrap_or(workdir))
}

#[cfg(test)]
mod tests {
    use std::path::Path;

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

    #[test]
    fn hidden_sessions_are_attachable_but_not_listed() {
        let dir = tempfile::tempdir().unwrap();
        let manager = SessionManager::new();
        let hidden = manager.create_hidden(dir.path().to_path_buf()).unwrap();

        assert!(manager.list().is_empty());
        assert!(Arc::ptr_eq(&manager.get(&hidden.name).unwrap(), &hidden));
        assert_eq!(manager.hidden_count(), 1);
        assert!(manager.destroy_hidden(&hidden.name));
        assert!(manager.get(&hidden.name).is_none());
    }

    #[test]
    fn internal_session_namespace_is_reserved() {
        let dir = tempfile::tempdir().unwrap();
        let manager = SessionManager::new();
        let error = match manager.create(
            "__motif_internal_user_value".into(),
            dir.path().to_path_buf(),
        ) {
            Ok(_) => panic!("reserved session name was accepted"),
            Err(error) => error,
        };

        assert!(matches!(error, ManagerError::ReservedName));
    }
}
