//! Persistent ownership records for Motif-managed Codex app-server processes.
//!
//! Unix does not terminate a child merely because its parent exits.  A clean
//! motifd shutdown kills the app-server process group directly; these records
//! cover the remaining crash/SIGKILL case by letting the next motifd instance
//! identify and reap only children whose recorded owner is no longer alive.

use std::ffi::{OsStr, OsString};
use std::fs;
use std::io::{self, Write};
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use sysinfo::{Pid, Process, System};

const RECORD_VERSION: u8 = 1;
const REGISTRATION_DISCOVERY_TIMEOUT: Duration = Duration::from_millis(250);
const TERM_GRACE: Duration = Duration::from_millis(500);
const KILL_GRACE: Duration = Duration::from_millis(250);

#[derive(Debug, Serialize, Deserialize)]
struct ProcessRecord {
    version: u8,
    owner_pid: u32,
    owner_started_at: u64,
    child_pid: u32,
    child_started_at: u64,
    listen: SocketAddr,
}

/// Removes the ownership record when the managed child has actually exited.
pub(crate) struct Registration {
    path: PathBuf,
}

impl Drop for Registration {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

pub(crate) fn register(child_pid: u32, listen: SocketAddr) -> io::Result<Registration> {
    let owner_pid = std::process::id();
    let (owner_started_at, child_started_at) = process_start_times(owner_pid, child_pid)?;
    let record = ProcessRecord {
        version: RECORD_VERSION,
        owner_pid,
        owner_started_at,
        child_pid,
        child_started_at,
        listen,
    };
    let directory = registry_dir();
    ensure_private_directory(&directory)?;
    write_record(&directory, &record)
}

/// Best-effort startup cleanup. Only registered processes are considered, and
/// they are killed only after both the dead owner and child identity have been
/// validated.
pub(crate) fn cleanup_orphans() {
    let system = System::new_all();
    cleanup_registered_orphans(&system);
}

fn cleanup_registered_orphans(system: &System) {
    let directory = registry_dir();
    let Ok(entries) = fs::read_dir(&directory) else {
        return;
    };

    for entry in entries.filter_map(Result::ok) {
        let path = entry.path();
        if path.extension() != Some(OsStr::new("json")) {
            continue;
        }
        let record = match fs::read(&path)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<ProcessRecord>(&bytes).ok())
        {
            Some(record) if record.version == RECORD_VERSION => record,
            _ => {
                tracing::debug!(path = %path.display(), "removing invalid Codex process record");
                let _ = fs::remove_file(&path);
                continue;
            }
        };

        if same_process(system, record.owner_pid, record.owner_started_at) {
            continue;
        }

        let Some(process) = system.process(Pid::from_u32(record.child_pid)) else {
            let _ = fs::remove_file(&path);
            continue;
        };
        if !same_process(system, record.child_pid, record.child_started_at)
            || !same_user(process)
            || motif_listen_address(process.cmd()) != Some(record.listen)
            || !is_dedicated_process_group(record.child_pid)
        {
            // The pid has been reused or the record was tampered with.  Never
            // signal a process unless every recorded identity check matches.
            tracing::warn!(
                pid = record.child_pid,
                path = %path.display(),
                "discarding stale Codex process record without signaling pid"
            );
            let _ = fs::remove_file(&path);
            continue;
        }

        if terminate_process_tree(record.child_pid) {
            tracing::info!(pid = record.child_pid, "cleaned orphaned Codex app-server");
            let _ = fs::remove_file(&path);
        } else {
            tracing::warn!(
                pid = record.child_pid,
                path = %path.display(),
                "could not clean orphaned Codex app-server; keeping ownership record"
            );
        }
    }
}

fn process_start_time(system: &System, pid: u32) -> Option<u64> {
    system
        .process(Pid::from_u32(pid))
        .map(Process::start_time)
        .filter(|started_at| *started_at != 0)
}

fn process_start_times(owner_pid: u32, child_pid: u32) -> io::Result<(u64, u64)> {
    let deadline = Instant::now() + REGISTRATION_DISCOVERY_TIMEOUT;
    loop {
        let system = System::new_all();
        if let (Some(owner), Some(child)) = (
            process_start_time(&system, owner_pid),
            process_start_time(&system, child_pid),
        ) {
            return Ok((owner, child));
        }
        if Instant::now() >= deadline {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                format!("could not inspect owner pid {owner_pid} and Codex pid {child_pid}"),
            ));
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

fn same_process(system: &System, pid: u32, started_at: u64) -> bool {
    system
        .process(Pid::from_u32(pid))
        .is_some_and(|process| process.start_time() == started_at)
}

fn motif_listen_address(command: &[OsString]) -> Option<SocketAddr> {
    let args = command
        .iter()
        .map(|arg| arg.to_string_lossy())
        .collect::<Vec<_>>();
    args.iter()
        .any(|arg| arg.as_ref() == "app-server")
        .then_some(())?;
    let listen_index = args.iter().position(|arg| arg.as_ref() == "--listen")?;
    let raw = args.get(listen_index + 1)?.strip_prefix("ws://")?;
    let address: SocketAddr = raw.parse().ok()?;
    (address.ip() == IpAddr::V4(Ipv4Addr::LOCALHOST)).then_some(address)
}

fn registry_dir() -> PathBuf {
    crate::paths::runtime_dir("motifd").join("codex-app-servers")
}

fn ensure_private_directory(path: &Path) -> io::Result<()> {
    fs::create_dir_all(path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

fn write_record(directory: &Path, record: &ProcessRecord) -> io::Result<Registration> {
    let path = directory.join(format!(
        "{}-{}-{}.json",
        record.owner_pid,
        record.child_pid,
        ulid::Ulid::new()
    ));
    let mut temporary = tempfile::NamedTempFile::new_in(directory)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        temporary
            .as_file()
            .set_permissions(fs::Permissions::from_mode(0o600))?;
    }
    serde_json::to_writer(&mut temporary, record).map_err(io::Error::other)?;
    temporary.flush()?;
    temporary.persist(&path).map_err(|error| error.error)?;
    Ok(Registration { path })
}

#[cfg(unix)]
fn same_user(process: &Process) -> bool {
    process
        .user_id()
        .is_some_and(|uid| **uid == unsafe { libc::getuid() })
}

#[cfg(not(unix))]
fn same_user(_process: &Process) -> bool {
    true
}

#[cfg(unix)]
fn is_dedicated_process_group(pid: u32) -> bool {
    unsafe { libc::getpgid(pid as libc::pid_t) == pid as libc::pid_t }
}

#[cfg(not(unix))]
fn is_dedicated_process_group(_pid: u32) -> bool {
    true
}

#[cfg(unix)]
fn terminate_process_tree(pid: u32) -> bool {
    if !signal_process_group(pid, libc::SIGTERM) {
        return !process_exists(pid);
    }
    if wait_until_gone(pid, TERM_GRACE) {
        return true;
    }
    let _ = signal_process_group(pid, libc::SIGKILL);
    wait_until_gone(pid, KILL_GRACE)
}

#[cfg(not(unix))]
fn terminate_process_tree(pid: u32) -> bool {
    let system = System::new_all();
    let Some(process) = system.process(Pid::from_u32(pid)) else {
        return true;
    };
    process.kill() && wait_until_gone(pid, KILL_GRACE)
}

#[cfg(unix)]
fn signal_process_group(pid: u32, signal: libc::c_int) -> bool {
    let result = unsafe { libc::kill(-(pid as libc::pid_t), signal) };
    result == 0 || io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH)
}

#[cfg(unix)]
fn process_exists(pid: u32) -> bool {
    let result = unsafe { libc::kill(pid as libc::pid_t, 0) };
    result == 0 || io::Error::last_os_error().raw_os_error() != Some(libc::ESRCH)
}

#[cfg(not(unix))]
fn process_exists(pid: u32) -> bool {
    System::new_all().process(Pid::from_u32(pid)).is_some()
}

fn wait_until_gone(pid: u32, timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if !process_exists(pid) {
            return true;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    !process_exists(pid)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn command(args: &[&str]) -> Vec<OsString> {
        args.iter().map(OsString::from).collect()
    }

    #[test]
    fn recognizes_only_motif_loopback_listener_shape() {
        assert_eq!(
            motif_listen_address(&command(&[
                "/opt/homebrew/bin/codex",
                "app-server",
                "--listen",
                "ws://127.0.0.1:61145",
            ])),
            Some("127.0.0.1:61145".parse().unwrap())
        );
        assert_eq!(
            motif_listen_address(&command(&[
                "/bin/sh",
                "-c",
                "guard script",
                "motif-codex-guard",
                "/opt/homebrew/bin/codex",
                "app-server",
                "--listen",
                "ws://127.0.0.1:61145",
            ])),
            Some("127.0.0.1:61145".parse().unwrap())
        );
        assert_eq!(
            motif_listen_address(&command(&[
                "codex",
                "-c",
                "features.code_mode_host=true",
                "app-server",
                "--analytics-default-enabled",
            ])),
            None
        );
        assert_eq!(
            motif_listen_address(&command(&[
                "codex",
                "app-server",
                "--listen",
                "ws://0.0.0.0:61145",
            ])),
            None
        );
    }

    #[test]
    fn writes_atomic_private_registration_record() {
        let directory = tempfile::tempdir().unwrap();
        let record = ProcessRecord {
            version: RECORD_VERSION,
            owner_pid: 10,
            owner_started_at: 20,
            child_pid: 30,
            child_started_at: 40,
            listen: "127.0.0.1:5555".parse().unwrap(),
        };
        let registration = write_record(directory.path(), &record).unwrap();
        let decoded: ProcessRecord =
            serde_json::from_slice(&fs::read(&registration.path).unwrap()).unwrap();
        assert_eq!(decoded.child_pid, 30);
        let path = registration.path.clone();
        drop(registration);
        assert!(!path.exists());
    }
}
