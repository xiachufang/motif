//! `SessionManager` — keyed by user-provided session name.

use std::collections::HashSet;
#[cfg(test)]
use std::path::Path;
use std::path::PathBuf;
use std::sync::Arc;

use dashmap::mapref::entry::Entry;
use dashmap::DashMap;
use motif_proto::session::SessionType;
use parking_lot::Mutex;

use super::Session;
use crate::codex_app_server::{CodexLauncher, SystemCodexLauncher};

pub struct SessionManager {
    sessions: DashMap<String, Arc<Session>>,
    creating: Mutex<HashSet<String>>,
    codex_launcher: Arc<dyn CodexLauncher>,
}

impl Default for SessionManager {
    fn default() -> Self {
        Self {
            sessions: DashMap::new(),
            creating: Mutex::new(HashSet::new()),
            codex_launcher: Arc::new(SystemCodexLauncher),
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub enum ManagerError {
    #[error("session '{0}' already exists")]
    AlreadyExists(String),
    #[error("session '{0}' not found")]
    NotFound(String),
    #[error("workdir does not exist or is not a directory: {0}")]
    BadWorkdir(PathBuf),
    #[error("terminal sessions require a workdir")]
    MissingWorkdir,
    #[error("failed to start codex session: {0}")]
    CodexStart(#[from] crate::codex_app_server::CodexLaunchError),
}

impl SessionManager {
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    #[cfg(test)]
    fn new_with_launcher(codex_launcher: Arc<dyn CodexLauncher>) -> Arc<Self> {
        Arc::new(Self {
            sessions: DashMap::new(),
            creating: Mutex::new(HashSet::new()),
            codex_launcher,
        })
    }

    pub fn create(
        &self,
        name: String,
        workdir: Option<PathBuf>,
        session_type: SessionType,
    ) -> Result<Arc<Session>, ManagerError> {
        let workdir = match (session_type, workdir) {
            (SessionType::Terminal, Some(workdir)) => workdir,
            (SessionType::Terminal, None) => return Err(ManagerError::MissingWorkdir),
            (SessionType::Codex, Some(workdir)) => workdir,
            (SessionType::Codex, None) => crate::paths::home_or_current_dir(),
        };
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

        {
            let mut creating = self.creating.lock();
            if self.sessions.contains_key(&name) || !creating.insert(name.clone()) {
                return Err(ManagerError::AlreadyExists(name));
            }
        }

        let result = (|| {
            let session = match session_type {
                SessionType::Terminal => Session::new(name.clone(), workdir),
                SessionType::Codex => {
                    let runtime = self.codex_launcher.launch(&name, &workdir)?;
                    Session::new_codex(name.clone(), workdir, runtime)
                }
            };
            match self.sessions.entry(name.clone()) {
                Entry::Occupied(_) => Err(ManagerError::AlreadyExists(name.clone())),
                Entry::Vacant(entry) => {
                    entry.insert(Arc::clone(&session));
                    Ok(session)
                }
            }
        })();
        self.creating.lock().remove(&name);
        result
    }

    pub fn shutdown_all(&self) {
        for session in self.list() {
            session.shutdown();
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
    use crate::codex_app_server::{CodexAppServer, CodexLaunchError};

    #[derive(Default)]
    struct FakeLauncher {
        fail: bool,
        launched: Mutex<Vec<Arc<CodexAppServer>>>,
    }

    impl CodexLauncher for FakeLauncher {
        fn launch(
            &self,
            _session_name: &str,
            _workdir: &Path,
        ) -> Result<Arc<CodexAppServer>, CodexLaunchError> {
            if self.fail {
                return Err(CodexLaunchError::EarlyExit(" (fake failure)".into()));
            }
            let runtime = CodexAppServer::fake();
            self.launched.lock().push(Arc::clone(&runtime));
            Ok(runtime)
        }
    }

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
    fn creates_terminal_sessions_without_launching_codex() {
        let dir = tempfile::tempdir().unwrap();
        let manager = SessionManager::new();
        let session = manager
            .create(
                "shell".to_string(),
                Some(dir.path().to_path_buf()),
                SessionType::Terminal,
            )
            .unwrap();

        assert_eq!(session.info().r#type, SessionType::Terminal);
        assert!(session.codex_app_server().is_none());
        assert!(matches!(
            manager.create(
                "shell".to_string(),
                Some(dir.path().to_path_buf()),
                SessionType::Terminal,
            ),
            Err(ManagerError::AlreadyExists(_))
        ));
    }

    #[test]
    fn codex_start_failure_does_not_insert_session() {
        let dir = tempfile::tempdir().unwrap();
        let manager = SessionManager::new_with_launcher(Arc::new(FakeLauncher {
            fail: true,
            ..FakeLauncher::default()
        }));

        assert!(matches!(
            manager.create(
                "agent".to_string(),
                Some(dir.path().to_path_buf()),
                SessionType::Codex,
            ),
            Err(ManagerError::CodexStart(_))
        ));
        assert!(manager.get("agent").is_none());
    }

    #[test]
    fn codex_exit_is_retained_and_destroy_stops_runtime() {
        let dir = tempfile::tempdir().unwrap();
        let launcher = Arc::new(FakeLauncher::default());
        let manager = SessionManager::new_with_launcher(launcher.clone());
        let session = manager
            .create(
                "agent".to_string(),
                Some(dir.path().to_path_buf()),
                SessionType::Codex,
            )
            .unwrap();
        let runtime = launcher.launched.lock().first().cloned().unwrap();

        assert_eq!(session.info().r#type, SessionType::Codex);
        runtime.mark_exited_for_test();
        assert!(!runtime.is_alive());
        assert!(manager.get("agent").is_some(), "failed session is retained");

        manager.destroy("agent").unwrap();
        assert!(runtime.is_stopping_for_test());
        assert!(manager.get("agent").is_none());
    }

    #[test]
    fn shutdown_all_stops_codex_runtime() {
        let dir = tempfile::tempdir().unwrap();
        let launcher = Arc::new(FakeLauncher::default());
        let manager = SessionManager::new_with_launcher(launcher.clone());
        manager
            .create(
                "agent".to_string(),
                Some(dir.path().to_path_buf()),
                SessionType::Codex,
            )
            .unwrap();
        let runtime = launcher.launched.lock().first().cloned().unwrap();

        manager.shutdown_all();
        assert!(runtime.is_stopping_for_test());
    }

    #[test]
    fn codex_session_does_not_require_a_workdir() {
        let launcher = Arc::new(FakeLauncher::default());
        let manager = SessionManager::new_with_launcher(launcher);
        let session = manager
            .create("agent".to_string(), None, SessionType::Codex)
            .unwrap();

        assert_eq!(session.session_type, SessionType::Codex);
        assert!(session.workdir.is_dir());
    }

    #[test]
    fn terminal_session_still_requires_a_workdir() {
        let manager = SessionManager::new();
        assert!(matches!(
            manager.create("shell".to_string(), None, SessionType::Terminal),
            Err(ManagerError::MissingWorkdir)
        ));
    }
}
