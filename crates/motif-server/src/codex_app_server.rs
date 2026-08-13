//! Lifecycle wrapper for the server-scoped `codex app-server` process.
//!
//! The child is deliberately bound to IPv4 loopback and has no app-server
//! authentication configured. Remote clients can only reach it through the
//! authenticated Motif `/codex` WebSocket endpoint.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::{IpAddr, Ipv4Addr, SocketAddr, TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use parking_lot::Mutex;
use tokio::sync::watch;

const READY_TIMEOUT: Duration = Duration::from_secs(10);
const READY_POLL: Duration = Duration::from_millis(75);
const CODEX_PATH_ENV: &str = "MOTIFD_CODEX_PATH";

#[derive(Debug, thiserror::Error)]
pub enum CodexLaunchError {
    #[error("could not allocate a loopback port for codex app-server: {0}")]
    AllocatePort(std::io::Error),
    #[error("{CODEX_PATH_ENV} does not identify an executable Codex CLI: {0}")]
    ConfiguredCodexNotFound(String),
    #[error(
        "could not find an executable Codex CLI; install Codex or set {CODEX_PATH_ENV}. Searched PATH and: {0}"
    )]
    CodexNotFound(String),
    #[error("could not start 'codex app-server': {0}")]
    Spawn(std::io::Error),
    #[error("codex app-server process setup failed: {0}")]
    Setup(std::io::Error),
    #[error("codex app-server exited before becoming ready{0}")]
    EarlyExit(String),
    #[error("codex app-server did not become ready within 10 seconds")]
    ReadyTimeout,
}

pub trait CodexLauncher: Send + Sync {
    fn launch(
        &self,
        service_label: &str,
        workdir: &Path,
    ) -> Result<Arc<CodexAppServer>, CodexLaunchError>;
}

#[derive(Default)]
pub struct SystemCodexLauncher;

impl CodexLauncher for SystemCodexLauncher {
    fn launch(
        &self,
        service_label: &str,
        workdir: &Path,
    ) -> Result<Arc<CodexAppServer>, CodexLaunchError> {
        CodexAppServer::launch(service_label, workdir)
    }
}

pub struct CodexAppServer {
    inner: Arc<Inner>,
}

struct Inner {
    address: SocketAddr,
    pid: Option<u32>,
    child: Mutex<Option<Child>>,
    exited: AtomicBool,
    stopping: AtomicBool,
    exit_tx: watch::Sender<bool>,
    #[cfg(windows)]
    job: Mutex<Option<crate::windows_job::ProcessJob>>,
}

impl CodexAppServer {
    pub fn launch(service_label: &str, workdir: &Path) -> Result<Arc<Self>, CodexLaunchError> {
        let listener =
            TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).map_err(CodexLaunchError::AllocatePort)?;
        let port = listener
            .local_addr()
            .map_err(CodexLaunchError::AllocatePort)?
            .port();
        drop(listener);

        let address = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), port);
        let listen = format!("ws://{address}");
        let codex = resolve_codex_program()?;
        let mut command = codex_command(&codex);
        command
            .arg("app-server")
            .arg("--listen")
            .arg(&listen)
            .current_dir(workdir)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        #[cfg(unix)]
        {
            use std::os::unix::process::CommandExt;
            command.process_group(0);
        }

        let mut child = command.spawn().map_err(CodexLaunchError::Spawn)?;
        let pid = child.id();
        tracing::info!(
            service = service_label,
            program = %codex.display(),
            pid,
            "codex app-server spawned"
        );
        let stdout = child.stdout.take();
        let stderr = child.stderr.take();
        drain_output(stdout, service_label.to_string(), "stdout");
        drain_output(stderr, service_label.to_string(), "stderr");

        #[cfg(windows)]
        let job = match crate::windows_job::ProcessJob::assign(pid) {
            Ok(job) => Some(job),
            Err(error) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(CodexLaunchError::Setup(error));
            }
        };

        wait_ready(&mut child, address).map_err(|error| {
            terminate_child(&mut child, pid);
            error
        })?;

        let (exit_tx, _) = watch::channel(false);
        let inner = Arc::new(Inner {
            address,
            pid: Some(pid),
            child: Mutex::new(Some(child)),
            exited: AtomicBool::new(false),
            stopping: AtomicBool::new(false),
            exit_tx,
            #[cfg(windows)]
            job: Mutex::new(job),
        });
        spawn_monitor(Arc::clone(&inner), service_label.to_string());
        tracing::info!(service = service_label, pid, %address, "codex app-server ready");
        Ok(Arc::new(Self { inner }))
    }

    pub fn address(&self) -> SocketAddr {
        self.inner.address
    }

    pub fn is_alive(&self) -> bool {
        !self.inner.exited.load(Ordering::Acquire)
    }

    pub fn subscribe_exit(&self) -> watch::Receiver<bool> {
        self.inner.exit_tx.subscribe()
    }

    pub fn shutdown(&self) {
        self.inner.shutdown();
    }

    #[cfg(test)]
    pub(crate) fn fake() -> Arc<Self> {
        Self::fake_at(SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 9))
    }

    #[cfg(test)]
    pub(crate) fn fake_at(address: SocketAddr) -> Arc<Self> {
        let (exit_tx, _) = watch::channel(false);
        Arc::new(Self {
            inner: Arc::new(Inner {
                address,
                pid: None,
                child: Mutex::new(None),
                exited: AtomicBool::new(false),
                stopping: AtomicBool::new(false),
                exit_tx,
                #[cfg(windows)]
                job: Mutex::new(None),
            }),
        })
    }

    #[cfg(test)]
    pub(crate) fn mark_exited_for_test(&self) {
        self.inner.exited.store(true, Ordering::Release);
        self.inner.exit_tx.send_replace(true);
    }
}

fn resolve_codex_program() -> Result<PathBuf, CodexLaunchError> {
    if let Some(configured) = non_empty_env(CODEX_PATH_ENV) {
        return find_executable(std::iter::once(PathBuf::from(&configured))).ok_or_else(|| {
            CodexLaunchError::ConfiguredCodexNotFound(
                PathBuf::from(configured).display().to_string(),
            )
        });
    }

    if let Ok(program) = which::which("codex") {
        return Ok(program);
    }

    let candidates = common_codex_candidates();
    find_executable(candidates.iter().cloned()).ok_or_else(|| {
        CodexLaunchError::CodexNotFound(
            candidates
                .iter()
                .map(|path| path.display().to_string())
                .collect::<Vec<_>>()
                .join(", "),
        )
    })
}

fn find_executable(candidates: impl IntoIterator<Item = PathBuf>) -> Option<PathBuf> {
    candidates
        .into_iter()
        .find_map(|candidate| which::which(candidate).ok())
}

fn common_codex_candidates() -> Vec<PathBuf> {
    let mut dirs = Vec::new();

    // The official standalone installer uses CODEX_INSTALL_DIR when set and
    // otherwise installs the user-facing executable under ~/.local/bin.
    push_env_dir(&mut dirs, "CODEX_INSTALL_DIR", false);
    push_env_dir(&mut dirs, "NVM_BIN", false);
    push_env_dir(&mut dirs, "PNPM_HOME", false);
    push_env_dir(&mut dirs, "NPM_CONFIG_PREFIX", true);
    push_env_dir(&mut dirs, "BUN_INSTALL", true);
    push_env_dir(&mut dirs, "HOMEBREW_PREFIX", true);

    if let Some(home) = crate::paths::home_dir() {
        dirs.extend([
            home.join(".local/bin"),
            home.join(".volta/bin"),
            home.join(".npm-global/bin"),
            home.join(".asdf/shims"),
            home.join(".local/share/mise/shims"),
            home.join(".bun/bin"),
            home.join("Library/pnpm"),
            home.join(".local/share/pnpm"),
            home.join(".nvm/current/bin"),
            home.join(".local/share/fnm/aliases/default/bin"),
        ]);
        append_version_manager_dirs(&mut dirs, &home.join(".nvm/versions/node"), "bin");
        append_version_manager_dirs(
            &mut dirs,
            &home.join(".local/share/fnm/node-versions"),
            "installation/bin",
        );
    }

    #[cfg(unix)]
    dirs.extend([
        PathBuf::from("/opt/homebrew/bin"),
        PathBuf::from("/home/linuxbrew/.linuxbrew/bin"),
        PathBuf::from("/usr/local/bin"),
        PathBuf::from("/usr/bin"),
    ]);

    #[cfg(windows)]
    {
        if let Some(app_data) = non_empty_env("APPDATA") {
            dirs.push(PathBuf::from(app_data).join("npm"));
        }
        if let Some(local_app_data) = non_empty_env("LOCALAPPDATA") {
            let local_app_data = PathBuf::from(local_app_data);
            dirs.push(local_app_data.join("Microsoft/WinGet/Links"));
            dirs.push(local_app_data.join("Programs/Codex"));
        }
    }

    let mut candidates = Vec::new();
    for dir in dirs {
        for name in codex_executable_names() {
            let candidate = dir.join(name);
            if !candidates.contains(&candidate) {
                candidates.push(candidate);
            }
        }
    }
    candidates
}

fn push_env_dir(dirs: &mut Vec<PathBuf>, name: &str, append_bin: bool) {
    let Some(value) = non_empty_env(name) else {
        return;
    };
    let dir = PathBuf::from(value);
    dirs.push(if append_bin { dir.join("bin") } else { dir });
}

fn append_version_manager_dirs(dirs: &mut Vec<PathBuf>, root: &Path, suffix: &str) {
    let Ok(entries) = std::fs::read_dir(root) else {
        return;
    };
    let mut entries = entries.filter_map(Result::ok).collect::<Vec<_>>();
    entries.sort_by_key(|entry| std::cmp::Reverse(entry.file_name()));
    dirs.extend(entries.into_iter().map(|entry| entry.path().join(suffix)));
}

fn non_empty_env(name: &str) -> Option<std::ffi::OsString> {
    std::env::var_os(name).filter(|value| !value.is_empty())
}

#[cfg(windows)]
fn codex_executable_names() -> &'static [&'static str] {
    &["codex.exe", "codex.cmd", "codex"]
}

#[cfg(not(windows))]
fn codex_executable_names() -> &'static [&'static str] {
    &["codex"]
}

fn codex_command(program: &Path) -> Command {
    #[cfg(windows)]
    if program
        .extension()
        .is_some_and(|extension| extension.eq_ignore_ascii_case("cmd"))
    {
        let mut command = Command::new("cmd.exe");
        command.arg("/d").arg("/s").arg("/c").arg(program);
        return command;
    }

    Command::new(program)
}

impl Drop for CodexAppServer {
    fn drop(&mut self) {
        self.shutdown();
    }
}

impl Inner {
    fn shutdown(&self) {
        if self.stopping.swap(true, Ordering::AcqRel) {
            return;
        }
        #[cfg(windows)]
        if let Some(job) = self.job.lock().as_ref() {
            job.terminate();
        }
        #[cfg(unix)]
        if let Some(pid) = self.pid {
            unsafe {
                // The child starts a fresh process group, so a negative pid
                // covers every descendant spawned by app-server.
                libc::kill(-(pid as i32), libc::SIGTERM);
            }
        }
        if let Some(child) = self.child.lock().as_mut() {
            let _ = child.kill();
        }
    }
}

fn spawn_monitor(inner: Arc<Inner>, service_label: String) {
    std::thread::Builder::new()
        .name(format!("codex-monitor-{service_label}"))
        .spawn(move || loop {
            let result = {
                let mut child = inner.child.lock();
                let Some(child) = child.as_mut() else {
                    return;
                };
                child.try_wait()
            };
            match result {
                Ok(Some(status)) => {
                    inner.exited.store(true, Ordering::Release);
                    inner.exit_tx.send_replace(true);
                    tracing::warn!(service = %service_label, %status, "codex app-server exited");
                    return;
                }
                Ok(None) => std::thread::sleep(Duration::from_millis(100)),
                Err(error) => {
                    inner.exited.store(true, Ordering::Release);
                    inner.exit_tx.send_replace(true);
                    tracing::warn!(service = %service_label, %error, "codex app-server status check failed");
                    return;
                }
            }
        })
        .expect("spawn codex process monitor");
}

fn wait_ready(child: &mut Child, address: SocketAddr) -> Result<(), CodexLaunchError> {
    let deadline = Instant::now() + READY_TIMEOUT;
    while Instant::now() < deadline {
        if let Some(status) = child.try_wait().map_err(CodexLaunchError::Spawn)? {
            let suffix = status
                .code()
                .map(|code| format!(" (exit code {code})"))
                .unwrap_or_else(|| " (terminated by signal)".to_string());
            return Err(CodexLaunchError::EarlyExit(suffix));
        }
        if readyz(address) {
            return Ok(());
        }
        std::thread::sleep(READY_POLL);
    }
    Err(CodexLaunchError::ReadyTimeout)
}

fn readyz(address: SocketAddr) -> bool {
    let Ok(mut stream) = TcpStream::connect_timeout(&address, Duration::from_millis(150)) else {
        return false;
    };
    let _ = stream.set_read_timeout(Some(Duration::from_millis(250)));
    let request = format!("GET /readyz HTTP/1.1\r\nHost: {address}\r\nConnection: close\r\n\r\n");
    if stream.write_all(request.as_bytes()).is_err() {
        return false;
    }
    let mut response = [0u8; 64];
    let Ok(n) = stream.read(&mut response) else {
        return false;
    };
    response[..n].starts_with(b"HTTP/1.1 200") || response[..n].starts_with(b"HTTP/1.0 200")
}

fn terminate_child(child: &mut Child, pid: u32) {
    #[cfg(unix)]
    unsafe {
        libc::kill(-(pid as i32), libc::SIGTERM);
    }
    let _ = child.kill();
    let _ = child.wait();
}

fn drain_output<R: Read + Send + 'static>(
    reader: Option<R>,
    service_label: String,
    stream: &'static str,
) {
    let Some(reader) = reader else { return };
    let _ = std::thread::Builder::new()
        .name(format!("codex-{stream}-{service_label}"))
        .spawn(move || {
            for line in BufReader::new(reader).lines() {
                match line {
                    Ok(line) => tracing::info!(target: "motif::codex", service = %service_label, stream, message = %line),
                    Err(error) => {
                        tracing::debug!(target: "motif::codex", service = %service_label, stream, %error, "codex output drain ended");
                        break;
                    }
                }
            }
        });
}

#[cfg(test)]
mod tests {
    #[cfg(unix)]
    use std::fs;

    use super::*;

    #[test]
    fn common_candidates_include_standalone_user_install_location() {
        let home = crate::paths::home_dir().unwrap();
        let expected = home.join(".local/bin").join(codex_executable_names()[0]);

        assert!(common_codex_candidates().contains(&expected));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn common_candidates_include_both_homebrew_prefixes() {
        let candidates = common_codex_candidates();

        assert!(candidates.contains(&PathBuf::from("/opt/homebrew/bin/codex")));
        assert!(candidates.contains(&PathBuf::from("/usr/local/bin/codex")));
    }

    #[cfg(unix)]
    #[test]
    fn finds_executable_from_fallback_candidates_in_order() {
        use std::os::unix::fs::PermissionsExt;

        let temp = tempfile::tempdir().unwrap();
        let missing = temp.path().join("missing-codex");
        let executable = temp.path().join("codex");
        fs::write(&executable, "#!/bin/sh\n").unwrap();
        fs::set_permissions(&executable, fs::Permissions::from_mode(0o755)).unwrap();

        assert_eq!(
            find_executable([missing, executable.clone()]),
            Some(executable)
        );
    }

    #[cfg(unix)]
    #[test]
    fn rejects_non_executable_fallback_file() {
        use std::os::unix::fs::PermissionsExt;

        let temp = tempfile::tempdir().unwrap();
        let file = temp.path().join("codex");
        fs::write(&file, "not executable\n").unwrap();
        fs::set_permissions(&file, fs::Permissions::from_mode(0o644)).unwrap();

        assert_eq!(find_executable([file]), None);
    }
}
