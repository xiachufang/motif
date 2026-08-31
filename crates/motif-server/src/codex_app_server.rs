//! Lifecycle wrapper for the server-scoped `codex app-server` process.
//!
//! The child is deliberately bound to IPv4 loopback and has no app-server
//! authentication configured. Remote clients can only reach it through the
//! authenticated Motif `/codex` WebSocket endpoint.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::{IpAddr, Ipv4Addr, SocketAddr, TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use parking_lot::Mutex;
use tokio::sync::watch;

const READY_TIMEOUT: Duration = Duration::from_secs(10);
const READY_POLL: Duration = Duration::from_millis(75);
const SHUTDOWN_GRACE: Duration = Duration::from_millis(500);
const SHUTDOWN_KILL_GRACE: Duration = Duration::from_millis(250);
const CODEX_PATH_ENV: &str = "MOTIFD_CODEX_PATH";
#[cfg(unix)]
const CODEX_INSTALL_URL: &str = "https://chatgpt.com/codex/install.sh";
#[cfg(windows)]
const CODEX_INSTALL_URL: &str = "https://chatgpt.com/codex/install.ps1";
const INSTALL_ERROR_DETAIL_LIMIT: usize = 2_000;

// Unix has no portable parent-death signal (and macOS has no equivalent of
// Linux's PR_SET_PDEATHSIG). Run Codex under a tiny process-group leader whose
// stdin is a lifetime pipe owned by motifd. If motifd exits without running
// Drop, the pipe reaches EOF and the guard terminates the complete group.
//
// Codex itself receives /dev/null as stdin; only the guard may consume the
// lifetime pipe. Positional arguments carry the executable and its arguments,
// so no user-controlled path is interpolated into this script.
#[cfg(unix)]
const UNIX_CHILD_GUARD: &str = r#"
guard_pid=$$
app_pid=
watch_pid=

graceful_group() {
    trap '' HUP INT TERM
    if [ -n "$app_pid" ]; then
        kill -TERM -- "-$guard_pid" 2>/dev/null || true
        wait "$app_pid" 2>/dev/null || true
    fi
    exit 143
}

orphaned_group() {
    trap '' HUP INT TERM USR1
    if [ -n "$app_pid" ]; then
        kill -TERM -- "-$guard_pid" 2>/dev/null || true
        (
            sleep 0.5
            kill -KILL -- "-$guard_pid" 2>/dev/null || true
        ) &
        killer_pid=$!
        wait "$app_pid" 2>/dev/null || true
        kill -KILL "$killer_pid" 2>/dev/null || true
    fi
    exit 143
}

trap graceful_group HUP INT TERM
trap orphaned_group USR1
# POSIX shells attach /dev/null to an asynchronous command's stdin when job
# control is disabled. Preserve motifd's lifetime pipe on a separate fd before
# starting either background job, otherwise the watcher observes EOF at once.
exec 3<&0
"$@" 3<&- </dev/null &
app_pid=$!
(
    IFS= read -r _ <&3 || true
    kill -USR1 "$guard_pid" 2>/dev/null || true
) &
watch_pid=$!
exec 3<&-

wait "$app_pid"
status=$?
kill -KILL "$watch_pid" 2>/dev/null || true
wait "$watch_pid" 2>/dev/null || true
exit "$status"
"#;

#[derive(Debug, thiserror::Error)]
pub enum CodexLaunchError {
    #[error("could not allocate a loopback port for codex app-server: {0}")]
    AllocatePort(std::io::Error),
    #[error("{CODEX_PATH_ENV} does not identify an executable Codex CLI: {0}")]
    ConfiguredCodexNotFound(String),
    #[error(
        "could not find an executable Codex CLI; install Codex or set {CODEX_PATH_ENV}. Searched the ChatGPT desktop app, PATH, and: {0}"
    )]
    CodexNotFound(String),
    #[error("could not install the Codex CLI automatically: {0}")]
    Install(String),
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
pub struct SystemCodexLauncher {
    auto_install: bool,
}

impl SystemCodexLauncher {
    pub fn new(auto_install: bool) -> Self {
        Self { auto_install }
    }
}

impl CodexLauncher for SystemCodexLauncher {
    fn launch(
        &self,
        service_label: &str,
        workdir: &Path,
    ) -> Result<Arc<CodexAppServer>, CodexLaunchError> {
        CodexAppServer::launch_with_auto_install(service_label, workdir, self.auto_install)
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
    registration: Mutex<Option<crate::codex_process_registry::Registration>>,
    #[cfg(windows)]
    job: Mutex<Option<crate::windows_job::ProcessJob>>,
}

impl CodexAppServer {
    pub fn launch(service_label: &str, workdir: &Path) -> Result<Arc<Self>, CodexLaunchError> {
        Self::launch_with_auto_install(service_label, workdir, false)
    }

    fn launch_with_auto_install(
        service_label: &str,
        workdir: &Path,
        auto_install: bool,
    ) -> Result<Arc<Self>, CodexLaunchError> {
        let listener =
            TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).map_err(CodexLaunchError::AllocatePort)?;
        let port = listener
            .local_addr()
            .map_err(CodexLaunchError::AllocatePort)?
            .port();
        drop(listener);

        let address = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), port);
        let listen = format!("ws://{address}");
        let codex = resolve_codex_program_for_launch(auto_install)?;
        let mut command = codex_command(&codex);
        command
            .arg("app-server")
            .arg("--listen")
            .arg(&listen)
            .current_dir(workdir)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        #[cfg(unix)]
        {
            use std::os::unix::process::CommandExt;
            command.stdin(Stdio::piped()).process_group(0);
        }
        #[cfg(not(unix))]
        command.stdin(Stdio::null());

        let mut child = command.spawn().map_err(CodexLaunchError::Spawn)?;
        let pid = child.id();
        #[cfg(windows)]
        let job = match crate::windows_job::ProcessJob::assign(pid) {
            Ok(job) => Some(job),
            Err(error) => {
                terminate_child(&mut child, pid);
                return Err(CodexLaunchError::Setup(error));
            }
        };
        let registration = match crate::codex_process_registry::register(pid, address) {
            Ok(registration) => Some(registration),
            Err(error) => {
                tracing::warn!(pid, %error, "could not persist Codex process ownership record");
                None
            }
        };
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

        wait_ready(&mut child, address).inspect_err(|_| {
            terminate_child(&mut child, pid);
        })?;

        let (exit_tx, _) = watch::channel(false);
        let inner = Arc::new(Inner {
            address,
            pid: Some(pid),
            child: Mutex::new(Some(child)),
            exited: AtomicBool::new(false),
            stopping: AtomicBool::new(false),
            exit_tx,
            registration: Mutex::new(registration),
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
                registration: Mutex::new(None),
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

    // ChatGPT and Motif share the same Codex thread storage by default. The
    // desktop app can bundle a newer protocol than a separately installed CLI,
    // so prefer its binary before consulting PATH and standalone locations.
    let chatgpt_candidates = chatgpt_bundled_codex_candidates();
    let standalone_candidates = common_codex_candidates();
    resolve_unconfigured_codex_program(
        &chatgpt_candidates,
        || which::which("codex").ok(),
        &standalone_candidates,
    )
    .ok_or_else(|| {
        CodexLaunchError::CodexNotFound(
            chatgpt_candidates
                .iter()
                .chain(&standalone_candidates)
                .map(|path| path.display().to_string())
                .collect::<Vec<_>>()
                .join(", "),
        )
    })
}

fn resolve_unconfigured_codex_program(
    chatgpt_candidates: &[PathBuf],
    path_lookup: impl FnOnce() -> Option<PathBuf>,
    standalone_candidates: &[PathBuf],
) -> Option<PathBuf> {
    find_executable(chatgpt_candidates.iter().cloned())
        .or_else(path_lookup)
        .or_else(|| find_executable(standalone_candidates.iter().cloned()))
}

fn resolve_codex_program_for_launch(auto_install: bool) -> Result<PathBuf, CodexLaunchError> {
    resolve_codex_program_with_installer(auto_install, resolve_codex_program, install_codex)
}

fn resolve_codex_program_with_installer(
    auto_install: bool,
    mut resolve: impl FnMut() -> Result<PathBuf, CodexLaunchError>,
    install: impl FnOnce() -> Result<(), CodexLaunchError>,
) -> Result<PathBuf, CodexLaunchError> {
    match resolve() {
        Ok(program) => return Ok(program),
        Err(error @ CodexLaunchError::ConfiguredCodexNotFound(_)) => return Err(error),
        Err(error @ CodexLaunchError::CodexNotFound(_)) if !auto_install => return Err(error),
        Err(CodexLaunchError::CodexNotFound(_)) => {}
        Err(error) => return Err(error),
    }

    tracing::info!(
        installer = CODEX_INSTALL_URL,
        "Codex CLI missing; starting silent install"
    );
    install()?;

    match resolve() {
        Ok(program) => {
            tracing::info!(program = %program.display(), "Codex CLI installed successfully");
            Ok(program)
        }
        Err(CodexLaunchError::CodexNotFound(searched)) => Err(CodexLaunchError::Install(format!(
            "the official installer completed, but no executable was found; searched: {searched}"
        ))),
        Err(error) => Err(error),
    }
}

#[cfg(unix)]
fn install_codex() -> Result<(), CodexLaunchError> {
    let home = crate::paths::home_dir().ok_or_else(|| {
        CodexLaunchError::Install("could not determine the current user's home directory".into())
    })?;
    let install_dir = non_empty_env("CODEX_INSTALL_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| home.join(".local/bin"));
    let temp = tempfile::tempdir()
        .map_err(|error| CodexLaunchError::Install(format!("temporary directory: {error}")))?;
    let script = temp.path().join("install-codex.sh");
    let curl = find_executable([
        PathBuf::from("curl"),
        PathBuf::from("/usr/bin/curl"),
        PathBuf::from("/bin/curl"),
        PathBuf::from("/usr/local/bin/curl"),
    ])
    .ok_or_else(|| {
        CodexLaunchError::Install("curl is required to download OpenAI's official installer".into())
    })?;

    let mut download = Command::new(curl);
    download
        .arg("--fail")
        .arg("--silent")
        .arg("--show-error")
        .arg("--location")
        .arg("--connect-timeout")
        .arg("10")
        .arg("--max-time")
        .arg("60")
        .arg("--output")
        .arg(&script)
        .arg(CODEX_INSTALL_URL);
    run_install_command(download, "downloading OpenAI's installer")?;

    let mut installer = Command::new("/bin/sh");
    installer
        .arg(&script)
        .env("HOME", home)
        .env("CODEX_INSTALL_DIR", install_dir)
        .env("CODEX_NON_INTERACTIVE", "1");
    run_install_command(installer, "running OpenAI's installer")
}

#[cfg(windows)]
fn install_codex() -> Result<(), CodexLaunchError> {
    let powershell = find_executable([PathBuf::from("pwsh.exe"), PathBuf::from("powershell.exe")])
        .ok_or_else(|| {
            CodexLaunchError::Install("PowerShell is required to run OpenAI's installer".into())
        })?;
    let temp = tempfile::tempdir()
        .map_err(|error| CodexLaunchError::Install(format!("temporary directory: {error}")))?;
    let script = temp.path().join("install-codex.ps1");

    let mut download = Command::new(&powershell);
    download
        .arg("-NoLogo")
        .arg("-NoProfile")
        .arg("-NonInteractive")
        .arg("-ExecutionPolicy")
        .arg("Bypass")
        .arg("-Command")
        .arg("Invoke-WebRequest -UseBasicParsing -Uri $env:MOTIF_CODEX_INSTALLER_URL -OutFile $env:MOTIF_CODEX_INSTALLER_PATH")
        .env("MOTIF_CODEX_INSTALLER_URL", CODEX_INSTALL_URL)
        .env("MOTIF_CODEX_INSTALLER_PATH", &script);
    run_install_command(download, "downloading OpenAI's installer")?;

    let mut installer = Command::new(powershell);
    installer
        .arg("-NoLogo")
        .arg("-NoProfile")
        .arg("-NonInteractive")
        .arg("-ExecutionPolicy")
        .arg("Bypass")
        .arg("-File")
        .arg(script)
        .env("CODEX_NON_INTERACTIVE", "1");
    run_install_command(installer, "running OpenAI's installer")
}

fn run_install_command(mut command: Command, stage: &str) -> Result<(), CodexLaunchError> {
    command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let output = command
        .output()
        .map_err(|error| CodexLaunchError::Install(format!("{stage}: {error}")))?;
    if output.status.success() {
        Ok(())
    } else {
        Err(install_command_failure(stage, &output))
    }
}

fn install_command_failure(stage: &str, output: &Output) -> CodexLaunchError {
    let detail = if output.stderr.is_empty() {
        &output.stdout
    } else {
        &output.stderr
    };
    let detail = String::from_utf8_lossy(detail);
    let detail = detail
        .chars()
        .filter(|character| !character.is_control() || matches!(character, '\n' | '\r' | '\t'))
        .take(INSTALL_ERROR_DETAIL_LIMIT)
        .collect::<String>()
        .trim()
        .to_string();
    let suffix = if detail.is_empty() {
        String::new()
    } else {
        format!(": {detail}")
    };
    CodexLaunchError::Install(format!("{stage} failed with {}{suffix}", output.status))
}

fn find_executable(candidates: impl IntoIterator<Item = PathBuf>) -> Option<PathBuf> {
    candidates
        .into_iter()
        .find_map(|candidate| which::which(candidate).ok())
}

fn push_unique_path(candidates: &mut Vec<PathBuf>, candidate: PathBuf) {
    if !candidates.contains(&candidate) {
        candidates.push(candidate);
    }
}

fn push_codex_candidates_in(candidates: &mut Vec<PathBuf>, directory: PathBuf) {
    for name in codex_executable_names() {
        push_unique_path(candidates, directory.join(name));
    }
}

#[cfg(any(target_os = "linux", windows))]
fn push_launcher_relative_codex_candidates(candidates: &mut Vec<PathBuf>, launcher: &Path) {
    let mut launchers = vec![launcher.to_path_buf()];
    if let Ok(canonical) = std::fs::canonicalize(launcher) {
        push_unique_path(&mut launchers, canonical);
    }

    for launcher in launchers {
        let Some(directory) = launcher.parent() else {
            continue;
        };
        push_codex_candidates_in(candidates, directory.join("resources"));
        push_codex_candidates_in(candidates, directory.join("Resources"));
        if let Some(parent) = directory.parent() {
            push_codex_candidates_in(candidates, parent.join("resources"));
            push_codex_candidates_in(candidates, parent.join("Resources"));
        }
    }
}

#[cfg(target_os = "macos")]
fn chatgpt_bundled_codex_candidates() -> Vec<PathBuf> {
    let mut candidates = Vec::new();
    push_codex_candidates_in(
        &mut candidates,
        PathBuf::from("/Applications/ChatGPT.app/Contents/Resources"),
    );
    if let Some(home) = crate::paths::home_dir() {
        push_codex_candidates_in(
            &mut candidates,
            home.join("Applications/ChatGPT.app/Contents/Resources"),
        );
    }
    candidates
}

#[cfg(target_os = "linux")]
fn chatgpt_bundled_codex_candidates() -> Vec<PathBuf> {
    let mut candidates = Vec::new();
    if let Ok(launcher) = which::which("chatgpt") {
        push_launcher_relative_codex_candidates(&mut candidates, &launcher);
    }

    for directory in [
        "/opt/chatgpt/resources",
        "/opt/ChatGPT/resources",
        "/usr/lib/chatgpt/resources",
        "/usr/lib/ChatGPT/resources",
        "/usr/lib64/chatgpt/resources",
        "/usr/share/chatgpt/resources",
    ] {
        push_codex_candidates_in(&mut candidates, PathBuf::from(directory));
    }
    candidates
}

#[cfg(windows)]
fn chatgpt_bundled_codex_candidates() -> Vec<PathBuf> {
    let mut candidates = Vec::new();
    for launcher_name in ["ChatGPT.exe", "ChatGPT"] {
        if let Ok(launcher) = which::which(launcher_name) {
            push_launcher_relative_codex_candidates(&mut candidates, &launcher);
        }
    }

    for env_name in ["LOCALAPPDATA", "ProgramFiles", "ProgramW6432"] {
        let Some(root) = non_empty_env(env_name).map(PathBuf::from) else {
            continue;
        };
        for relative in [
            "Programs/ChatGPT/resources",
            "Programs/OpenAI/ChatGPT/resources",
            "ChatGPT/resources",
            "OpenAI/ChatGPT/resources",
        ] {
            push_codex_candidates_in(&mut candidates, root.join(relative));
        }
    }

    append_windows_store_chatgpt_candidates(&mut candidates);
    candidates
}

#[cfg(windows)]
fn append_windows_store_chatgpt_candidates(candidates: &mut Vec<PathBuf>) {
    let mut roots = Vec::new();
    for env_name in ["ProgramFiles", "ProgramW6432"] {
        let Some(root) = non_empty_env(env_name).map(PathBuf::from) else {
            continue;
        };
        push_unique_path(&mut roots, root.join("WindowsApps"));
    }

    for root in roots {
        let Ok(entries) = std::fs::read_dir(root) else {
            continue;
        };
        let mut entries = entries.filter_map(Result::ok).collect::<Vec<_>>();
        entries.sort_by_key(|entry| std::cmp::Reverse(entry.file_name()));
        for entry in entries {
            let package_name = entry.file_name().to_string_lossy().to_ascii_lowercase();
            if !package_name.contains("chatgpt") {
                continue;
            }
            push_codex_candidates_in(candidates, entry.path().join("app/resources"));
            push_codex_candidates_in(candidates, entry.path().join("resources"));
        }
    }
}

#[cfg(not(any(target_os = "macos", target_os = "linux", windows)))]
fn chatgpt_bundled_codex_candidates() -> Vec<PathBuf> {
    Vec::new()
}

fn common_codex_candidates() -> Vec<PathBuf> {
    let mut dirs = Vec::new();

    // The official standalone installer uses CODEX_INSTALL_DIR when set. Its
    // Unix default is ~/.local/bin; the Windows default is appended below.
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
            dirs.push(local_app_data.join("Programs/OpenAI/Codex/bin"));
            dirs.push(local_app_data.join("Programs/Codex"));
        }
    }

    let mut candidates = Vec::new();
    for dir in dirs {
        for name in codex_executable_names() {
            push_unique_path(&mut candidates, dir.join(name));
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
    #[cfg(unix)]
    {
        let mut command = Command::new("/bin/sh");
        command
            .arg("-c")
            .arg(UNIX_CHILD_GUARD)
            .arg("motif-codex-guard")
            .arg(program);
        return command;
    }

    #[cfg(windows)]
    if program
        .extension()
        .is_some_and(|extension| extension.eq_ignore_ascii_case("cmd"))
    {
        let mut command = Command::new("cmd.exe");
        command.arg("/d").arg("/s").arg("/c").arg(program);
        return command;
    }

    #[allow(unreachable_code)]
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
        let terminated = match (self.pid, self.child.lock().as_mut()) {
            (Some(pid), Some(child)) => terminate_child(child, pid),
            _ => true,
        };
        self.mark_exited(terminated);
    }

    fn mark_exited(&self, remove_registration: bool) {
        if !self.exited.swap(true, Ordering::AcqRel) {
            self.exit_tx.send_replace(true);
        }
        if remove_registration {
            self.registration.lock().take();
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
                    inner.mark_exited(true);
                    if inner.stopping.load(Ordering::Acquire) {
                        tracing::info!(service = %service_label, %status, "codex app-server stopped");
                    } else {
                        tracing::warn!(service = %service_label, %status, "codex app-server exited");
                    }
                    return;
                }
                Ok(None) => std::thread::sleep(Duration::from_millis(100)),
                Err(error) => {
                    // Keep the ownership record when the status check itself
                    // fails: the next motifd start can still validate and reap
                    // a child that may have survived.
                    inner.mark_exited(false);
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

fn terminate_child(child: &mut Child, pid: u32) -> bool {
    #[cfg(unix)]
    unsafe {
        // The child starts a fresh process group, so a negative pid covers
        // every descendant spawned by app-server.
        libc::kill(-(pid as i32), libc::SIGTERM);
    }
    let root_exited = wait_for_child(child, SHUTDOWN_GRACE);
    #[cfg(unix)]
    {
        if process_group_exists(pid) {
            unsafe {
                // Kill the whole group, not just the app-server root: a
                // descendant that ignored SIGTERM must not survive motifd.
                libc::kill(-(pid as i32), libc::SIGKILL);
            }
        }
        let root_reaped = if root_exited {
            true
        } else {
            let _ = child.kill();
            child.wait().is_ok()
        };
        root_reaped && wait_for_process_group(pid, SHUTDOWN_KILL_GRACE)
    }
    #[cfg(not(unix))]
    {
        if root_exited {
            true
        } else {
            let _ = child.kill();
            child.wait().is_ok()
        }
    }
}

fn wait_for_child(child: &mut Child, timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        match child.try_wait() {
            Ok(Some(_)) => return true,
            Ok(None) => std::thread::sleep(Duration::from_millis(25)),
            Err(_) => return false,
        }
    }
    false
}

#[cfg(unix)]
fn process_group_exists(pid: u32) -> bool {
    let result = unsafe { libc::kill(-(pid as libc::pid_t), 0) };
    result == 0 || std::io::Error::last_os_error().raw_os_error() != Some(libc::ESRCH)
}

#[cfg(unix)]
fn wait_for_process_group(pid: u32, timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if !process_group_exists(pid) {
            return true;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    !process_group_exists(pid)
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
    use std::sync::atomic::{AtomicUsize, Ordering as AtomicOrdering};

    use super::*;

    #[test]
    fn auto_install_runs_only_after_an_unconfigured_lookup_miss() {
        let resolves = AtomicUsize::new(0);
        let installs = AtomicUsize::new(0);
        let expected = PathBuf::from("/installed/codex");

        let actual = resolve_codex_program_with_installer(
            true,
            || {
                if resolves.fetch_add(1, AtomicOrdering::SeqCst) == 0 {
                    Err(CodexLaunchError::CodexNotFound("candidate".into()))
                } else {
                    Ok(expected.clone())
                }
            },
            || {
                installs.fetch_add(1, AtomicOrdering::SeqCst);
                Ok(())
            },
        )
        .unwrap();

        assert_eq!(actual, expected);
        assert_eq!(resolves.load(AtomicOrdering::SeqCst), 2);
        assert_eq!(installs.load(AtomicOrdering::SeqCst), 1);
    }

    #[test]
    fn explicit_codex_path_failure_never_triggers_auto_install() {
        let installs = AtomicUsize::new(0);

        let error = resolve_codex_program_with_installer(
            true,
            || Err(CodexLaunchError::ConfiguredCodexNotFound("custom".into())),
            || {
                installs.fetch_add(1, AtomicOrdering::SeqCst);
                Ok(())
            },
        )
        .unwrap_err();

        assert!(matches!(
            error,
            CodexLaunchError::ConfiguredCodexNotFound(_)
        ));
        assert_eq!(installs.load(AtomicOrdering::SeqCst), 0);
    }

    #[test]
    fn disabled_auto_install_preserves_missing_cli_error() {
        let installs = AtomicUsize::new(0);

        let error = resolve_codex_program_with_installer(
            false,
            || Err(CodexLaunchError::CodexNotFound("candidate".into())),
            || {
                installs.fetch_add(1, AtomicOrdering::SeqCst);
                Ok(())
            },
        )
        .unwrap_err();

        assert!(matches!(error, CodexLaunchError::CodexNotFound(_)));
        assert_eq!(installs.load(AtomicOrdering::SeqCst), 0);
    }

    #[cfg(unix)]
    #[test]
    fn prefers_chatgpt_bundled_codex_before_path_and_standalone_candidates() {
        use std::os::unix::fs::PermissionsExt;

        let temp = tempfile::tempdir().unwrap();
        let bundled = temp.path().join("chatgpt-codex");
        let standalone = temp.path().join("standalone-codex");
        for executable in [&bundled, &standalone] {
            fs::write(executable, "#!/bin/sh\n").unwrap();
            fs::set_permissions(executable, fs::Permissions::from_mode(0o755)).unwrap();
        }
        let path_lookups = AtomicUsize::new(0);

        let actual = resolve_unconfigured_codex_program(
            std::slice::from_ref(&bundled),
            || {
                path_lookups.fetch_add(1, AtomicOrdering::SeqCst);
                Some(standalone.clone())
            },
            std::slice::from_ref(&standalone),
        );

        assert_eq!(actual, Some(bundled));
        assert_eq!(path_lookups.load(AtomicOrdering::SeqCst), 0);
    }

    #[cfg(unix)]
    #[test]
    fn path_codex_precedes_standalone_fallback_when_chatgpt_is_missing() {
        use std::os::unix::fs::PermissionsExt;

        let temp = tempfile::tempdir().unwrap();
        let missing_bundled = temp.path().join("missing-chatgpt-codex");
        let path_codex = temp.path().join("path-codex");
        let standalone = temp.path().join("standalone-codex");
        for executable in [&path_codex, &standalone] {
            fs::write(executable, "#!/bin/sh\n").unwrap();
            fs::set_permissions(executable, fs::Permissions::from_mode(0o755)).unwrap();
        }

        let actual = resolve_unconfigured_codex_program(
            &[missing_bundled],
            || Some(path_codex.clone()),
            std::slice::from_ref(&standalone),
        );

        assert_eq!(actual, Some(path_codex));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn chatgpt_candidates_prefer_the_system_macos_application() {
        assert_eq!(
            chatgpt_bundled_codex_candidates().first(),
            Some(&PathBuf::from(
                "/Applications/ChatGPT.app/Contents/Resources/codex"
            ))
        );
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn chatgpt_candidates_include_linux_package_layouts() {
        let candidates = chatgpt_bundled_codex_candidates();

        assert!(candidates.contains(&PathBuf::from("/opt/chatgpt/resources/codex")));
        assert!(candidates.contains(&PathBuf::from("/usr/lib/chatgpt/resources/codex")));
    }

    #[cfg(windows)]
    #[test]
    fn chatgpt_candidates_include_windows_per_user_package_layout() {
        let local_app_data = non_empty_env("LOCALAPPDATA")
            .map(PathBuf::from)
            .expect("Windows provides LOCALAPPDATA");
        let candidates = chatgpt_bundled_codex_candidates();

        assert!(candidates.contains(&local_app_data.join("Programs/ChatGPT/resources/codex.exe")));
        assert!(candidates
            .contains(&local_app_data.join("Programs/OpenAI/ChatGPT/resources/codex.exe")));
    }

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

    #[cfg(unix)]
    #[test]
    fn terminate_child_kills_the_dedicated_process_group() {
        use std::os::unix::process::CommandExt;

        let mut command = Command::new("/bin/sh");
        command
            .arg("-c")
            // Both the shell and its child ignore the graceful signal, forcing
            // terminate_child to exercise its whole-group SIGKILL fallback.
            .arg("trap '' TERM; sleep 30 & wait")
            .process_group(0);
        let mut child = command.spawn().unwrap();
        let pid = child.id();
        std::thread::sleep(Duration::from_millis(100));

        assert!(terminate_child(&mut child, pid));
        assert!(!process_group_exists(pid));
    }

    #[cfg(unix)]
    #[test]
    fn lifetime_pipe_kills_group_when_owner_disappears() {
        use std::os::unix::process::CommandExt;

        let mut command = codex_command(Path::new("/bin/sh"));
        command
            .arg("-c")
            // Ignore TERM so the guard must exercise its group-wide KILL
            // fallback after the lifetime pipe closes.
            .arg("trap '' TERM; sleep 30 & wait")
            .stdin(Stdio::piped())
            .process_group(0);
        let mut child = command.spawn().unwrap();
        let pid = child.id();
        std::thread::sleep(Duration::from_millis(100));

        assert!(
            child.try_wait().unwrap().is_none(),
            "guard must stay alive while its owner keeps the lifetime pipe open"
        );
        drop(child.stdin.take());
        assert!(wait_for_child(&mut child, Duration::from_secs(2)));
        assert!(wait_for_process_group(pid, Duration::from_secs(1)));
    }
}
