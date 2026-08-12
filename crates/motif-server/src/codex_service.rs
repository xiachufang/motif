//! One server-scoped Codex app-server and its thread workspace Sessions.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;

use parking_lot::Mutex;

use crate::codex_app_server::{
    CodexAppServer, CodexLaunchError, CodexLauncher, SystemCodexLauncher,
};
use crate::conn_registry::ConnRegistry;
use crate::session::manager::{ManagerError, SessionManager};
use crate::session::Session;

pub struct CodexService {
    operation: Mutex<()>,
    runtime: Mutex<Option<Arc<CodexAppServer>>>,
    thread_workspaces: Mutex<HashMap<String, String>>,
    manager: Arc<SessionManager>,
    conns: Arc<ConnRegistry>,
    launcher: Arc<dyn CodexLauncher>,
}

#[derive(Debug, thiserror::Error)]
pub enum CodexServiceError {
    #[error("thread id must not be empty")]
    EmptyThreadId,
    #[error(transparent)]
    Launch(#[from] CodexLaunchError),
    #[error(transparent)]
    Workspace(#[from] ManagerError),
}

impl CodexService {
    pub fn new(manager: Arc<SessionManager>, conns: Arc<ConnRegistry>) -> Arc<Self> {
        Arc::new(Self {
            operation: Mutex::new(()),
            runtime: Mutex::new(None),
            thread_workspaces: Mutex::new(HashMap::new()),
            manager,
            conns,
            launcher: Arc::new(SystemCodexLauncher),
        })
    }

    #[cfg(test)]
    pub(crate) fn new_with_launcher(
        manager: Arc<SessionManager>,
        conns: Arc<ConnRegistry>,
        launcher: Arc<dyn CodexLauncher>,
    ) -> Arc<Self> {
        Arc::new(Self {
            operation: Mutex::new(()),
            runtime: Mutex::new(None),
            thread_workspaces: Mutex::new(HashMap::new()),
            manager,
            conns,
            launcher,
        })
    }

    pub fn is_running(&self) -> bool {
        self.runtime
            .lock()
            .as_ref()
            .is_some_and(|runtime| runtime.is_alive())
    }

    /// Start lazily and return the one runtime owned by this server.
    pub fn start(&self) -> Result<Arc<CodexAppServer>, CodexServiceError> {
        let _operation = self.operation.lock();
        self.start_locked()
    }

    fn start_locked(&self) -> Result<Arc<CodexAppServer>, CodexServiceError> {
        let stale = {
            let mut slot = self.runtime.lock();
            if let Some(runtime) = slot.as_ref().filter(|runtime| runtime.is_alive()) {
                return Ok(Arc::clone(runtime));
            }
            slot.take()
        };
        if let Some(runtime) = stale {
            runtime.shutdown();
            self.cleanup_workspaces_locked();
        }
        let cwd = crate::paths::home_or_current_dir();
        let runtime = self.launcher.launch("motifd", &cwd)?;
        *self.runtime.lock() = Some(Arc::clone(&runtime));
        Ok(runtime)
    }

    /// Return the normal hidden Session belonging to a Codex thread. The
    /// first call fixes its workdir; reopening that thread restores its PTYs
    /// and views until Codex is stopped or restarted.
    pub fn ensure_thread_workspace(
        &self,
        thread_id: String,
        cwd: PathBuf,
    ) -> Result<Arc<Session>, CodexServiceError> {
        let thread_id = thread_id.trim().to_string();
        if thread_id.is_empty() {
            return Err(CodexServiceError::EmptyThreadId);
        }
        let _operation = self.operation.lock();
        self.start_locked()?;

        let mut workspaces = self.thread_workspaces.lock();
        if let Some(name) = workspaces.get(&thread_id) {
            if let Some(session) = self.manager.get(name) {
                return Ok(session);
            }
            workspaces.remove(&thread_id);
        }

        let session = self.manager.create_hidden(cwd)?;
        workspaces.insert(thread_id, session.name.clone());
        Ok(session)
    }

    /// Stop Codex and destroy every hidden thread Session it owns.
    pub fn stop(&self) -> Vec<String> {
        let _operation = self.operation.lock();
        self.stop_locked()
    }

    fn stop_locked(&self) -> Vec<String> {
        if let Some(runtime) = self.runtime.lock().take() {
            runtime.shutdown();
        }
        self.cleanup_workspaces_locked()
    }

    fn cleanup_workspaces_locked(&self) -> Vec<String> {
        let names: Vec<String> = self
            .thread_workspaces
            .lock()
            .drain()
            .map(|(_, name)| name)
            .collect();
        for name in &names {
            self.conns.remove_attached(name);
            self.manager.destroy_hidden(name);
        }
        names
    }

    /// Restart always starts a fresh app-server and intentionally discards all
    /// thread workspace state from the previous process lifetime.
    pub fn restart(&self) -> Result<(Arc<CodexAppServer>, Vec<String>), CodexServiceError> {
        let _operation = self.operation.lock();
        let closed = self.stop_locked();
        self.start_locked().map(|runtime| (runtime, closed))
    }
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use super::*;

    #[derive(Default)]
    struct FakeLauncher {
        launched: Mutex<Vec<Arc<CodexAppServer>>>,
    }

    impl CodexLauncher for FakeLauncher {
        fn launch(
            &self,
            _label: &str,
            _workdir: &Path,
        ) -> Result<Arc<CodexAppServer>, CodexLaunchError> {
            let runtime = CodexAppServer::fake();
            self.launched.lock().push(Arc::clone(&runtime));
            Ok(runtime)
        }
    }

    #[test]
    fn one_runtime_and_one_hidden_session_per_thread() {
        let launcher = Arc::new(FakeLauncher::default());
        let manager = SessionManager::new();
        let conns = ConnRegistry::new();
        let service =
            CodexService::new_with_launcher(Arc::clone(&manager), conns, launcher.clone());
        let first_dir = tempfile::tempdir().unwrap();
        let second_dir = tempfile::tempdir().unwrap();

        let first = service
            .ensure_thread_workspace("thread-a".into(), first_dir.path().into())
            .unwrap();
        let again = service
            .ensure_thread_workspace("thread-a".into(), second_dir.path().into())
            .unwrap();
        let second = service
            .ensure_thread_workspace("thread-b".into(), second_dir.path().into())
            .unwrap();

        assert!(Arc::ptr_eq(&first, &again));
        assert_ne!(first.id, second.id);
        assert_eq!(first.workdir, first_dir.path().canonicalize().unwrap());
        assert_eq!(second.workdir, second_dir.path().canonicalize().unwrap());
        assert_eq!(launcher.launched.lock().len(), 1);
        assert!(manager.list().is_empty());
        assert_eq!(manager.hidden_count(), 2);
    }

    #[test]
    fn stop_and_restart_clear_owned_sessions() {
        let launcher = Arc::new(FakeLauncher::default());
        let manager = SessionManager::new();
        let conns = ConnRegistry::new();
        let service = CodexService::new_with_launcher(
            Arc::clone(&manager),
            Arc::clone(&conns),
            launcher.clone(),
        );
        let dir = tempfile::tempdir().unwrap();
        let old = service
            .ensure_thread_workspace("thread-a".into(), dir.path().into())
            .unwrap();
        let (connection_id, entry) = conns.mint();
        let client_id = {
            let mut state = entry.state.lock();
            state.attached = Some(old.name.clone());
            state.attached_session_id = Some(old.id.clone());
            state.client_id.clone()
        };
        old.attach_client(client_id);

        service.restart().unwrap();

        assert!(old.is_destroyed());
        assert!(manager.get(&old.name).is_none());
        assert!(conns.get(&connection_id).is_none());
        assert_eq!(manager.hidden_count(), 0);
        assert_eq!(launcher.launched.lock().len(), 2);
        assert!(service.is_running());

        let _ = service.stop();
        assert!(!service.is_running());
    }

    #[test]
    fn replacing_an_exited_runtime_clears_old_thread_sessions() {
        let launcher = Arc::new(FakeLauncher::default());
        let manager = SessionManager::new();
        let conns = ConnRegistry::new();
        let service =
            CodexService::new_with_launcher(Arc::clone(&manager), conns, launcher.clone());
        let dir = tempfile::tempdir().unwrap();
        let old = service
            .ensure_thread_workspace("thread-a".into(), dir.path().into())
            .unwrap();
        launcher.launched.lock()[0].mark_exited_for_test();

        service.start().unwrap();

        assert!(old.is_destroyed());
        assert!(manager.get(&old.name).is_none());
        assert_eq!(launcher.launched.lock().len(), 2);
    }
}
