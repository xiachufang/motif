//! Lifecycle wrapper for the server-scoped `codex app-server` process.
//!
//! The child is deliberately bound to IPv4 loopback and has no app-server
//! authentication configured. Remote clients can only reach it through the
//! authenticated Motif `/codex` WebSocket endpoint.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::{IpAddr, Ipv4Addr, SocketAddr, TcpListener, TcpStream};
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use parking_lot::Mutex;
use tokio::sync::watch;

const READY_TIMEOUT: Duration = Duration::from_secs(10);
const READY_POLL: Duration = Duration::from_millis(75);

#[derive(Debug, thiserror::Error)]
pub enum CodexLaunchError {
    #[error("could not allocate a loopback port for codex app-server: {0}")]
    AllocatePort(std::io::Error),
    #[error("could not start 'codex app-server' (is codex installed and on PATH?): {0}")]
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
        let mut command = Command::new("codex");
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
        let (exit_tx, _) = watch::channel(false);
        Arc::new(Self {
            inner: Arc::new(Inner {
                address: SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 9),
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
