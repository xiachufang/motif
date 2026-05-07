//! Multi-PTY management for a Session.
//!
//! Each Pty holds:
//!   - the master pty handle (for resize)
//!   - a writer (sync; clients call `pty.write` rarely enough that brief lock
//!     contention is fine)
//!   - a 1MB ring buffer of recent stdout bytes for replay on attach
//!   - per-client (cols, rows) preferences and a "primary" client whose size
//!     drives the PTY master. Primary is set on creation, on `pty.write`, and
//!     when a client activates this PTY's view; passive observers (e.g. a TUI
//!     mirroring in a small tmux pane) don't shrink the PTY. If primary
//!     detaches, effective size falls back to the largest reported size so
//!     the PTY isn't stuck at a stale value.
//!
//! A dedicated OS thread reads from the master in chunks, appends to the ring,
//! and publishes `Event::PtyOutput` via the back-pointer to its Session.

use std::collections::{HashMap, VecDeque};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Weak};
use std::time::{SystemTime, UNIX_EPOCH};

use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
use dashmap::DashMap;
use motif_proto::common::{ClientId, PtyId, UnixMs};
use motif_proto::event::Event;
use motif_proto::pty::{PtyCreateParams, PtyInfo};
use motif_proto::terminal_query::QueryScanner;
use parking_lot::Mutex;
use portable_pty::{native_pty_system, ChildKiller, CommandBuilder, MasterPty, PtySize};

use crate::session::Session;

const RING_BYTES: usize    = 1024 * 1024; // 1 MB per PTY
const MAX_PTYS:   usize    = 32;
const READ_CHUNK: usize    = 8 * 1024;

pub struct Pty {
    pub id:         PtyId,
    pub cmd:        String,
    pub cwd:        PathBuf,
    pub created_at: UnixMs,
    /// OS pid of the spawned shell. Used by the cwd watcher.
    pub pid:        Option<u32>,

    master: Mutex<Box<dyn MasterPty + Send>>,
    writer: Mutex<Box<dyn Write + Send>>,
    killer: Mutex<Option<Box<dyn ChildKiller + Send + Sync>>>,
    state:  Mutex<PtyState>,
}

struct PtyState {
    cols:  u16,
    rows:  u16,
    /// Per-client (cols, rows) preferences. The primary's entry drives the
    /// master; non-primary entries are kept so we can recover a sensible size
    /// if the primary detaches.
    sizes: HashMap<ClientId, (u16, u16)>,
    /// Interactive owner of the PTY. None only after primary detaches.
    primary: Option<ClientId>,
    alive: bool,
    ring:  VecDeque<u8>,
    /// Last cwd we observed for the foreground process. Used by the watcher
    /// to dedupe; only transitions are broadcast as `pty.fg_changed`.
    last_cwd: Option<PathBuf>,
    /// Last foreground program name we observed (basename of the executable).
    /// Same dedupe story as `last_cwd`.
    last_fg_name: Option<String>,
}

impl Pty {
    pub fn info(&self) -> PtyInfo {
        let s = self.state.lock();
        PtyInfo {
            id:         self.id.clone(),
            cmd:        self.cmd.clone(),
            // Latest known cwd; falls back to the original cwd if the watcher
            // hasn't observed a change yet.
            cwd:        s.last_cwd.clone().unwrap_or_else(|| self.cwd.clone()),
            cols:       s.cols,
            rows:       s.rows,
            alive:      s.alive,
            created_at: self.created_at,
            fg_name:    s.last_fg_name.clone(),
        }
    }

    /// Returns a snapshot of the ring buffer for replay on attach.
    pub fn ring_snapshot(&self) -> Vec<u8> {
        let s = self.state.lock();
        s.ring.iter().copied().collect()
    }

    pub fn write_bytes(&self, data: &[u8]) -> std::io::Result<()> {
        let mut w = self.writer.lock();
        w.write_all(data)?;
        w.flush()
    }

    /// Returns Some(actually-applied size) if it changed.
    pub fn set_client_size(&self, client: ClientId, cols: u16, rows: u16) -> Option<(u16, u16)> {
        let mut s = self.state.lock();
        s.sizes.insert(client, (cols, rows));
        let (eff_c, eff_r) = compute_effective(&s.sizes, s.primary.as_ref())
            .unwrap_or((cols, rows));
        apply_size(&mut s, &self.master, eff_c, eff_r)
    }

    pub fn forget_client(&self, client: &ClientId) -> Option<(u16, u16)> {
        let mut s = self.state.lock();
        let had_size = s.sizes.remove(client).is_some();
        let was_primary = s.primary.as_ref() == Some(client);
        if !had_size && !was_primary {
            return None;
        }
        if was_primary {
            s.primary = None;
        }
        let (eff_c, eff_r) = compute_effective(&s.sizes, s.primary.as_ref())?;
        apply_size(&mut s, &self.master, eff_c, eff_r)
    }

    /// Mark `client` as the interactive owner. Returns the new effective size
    /// if it changed (caller should publish a PtyResize event).
    pub fn mark_primary(&self, client: ClientId) -> Option<(u16, u16)> {
        let mut s = self.state.lock();
        if s.primary.as_ref() == Some(&client) {
            return None;
        }
        s.primary = Some(client);
        let (eff_c, eff_r) = compute_effective(&s.sizes, s.primary.as_ref())?;
        apply_size(&mut s, &self.master, eff_c, eff_r)
    }

    pub fn kill(&self) {
        if let Some(mut k) = self.killer.lock().take() {
            let _ = k.kill();
        }
    }

    pub fn is_alive(&self) -> bool { self.state.lock().alive }
}

/// Pick the master size: primary's preference if known, else the largest
/// reported size (so a passive viewer can keep the PTY usable until someone
/// becomes primary). None only when `sizes` is empty AND there is no primary
/// — caller leaves the master size unchanged.
fn compute_effective(
    sizes:   &HashMap<ClientId, (u16, u16)>,
    primary: Option<&ClientId>,
) -> Option<(u16, u16)> {
    if let Some(p) = primary {
        if let Some(&sz) = sizes.get(p) {
            return Some(sz);
        }
    }
    sizes.values().copied().reduce(|(c1, r1), (c2, r2)| (c1.max(c2), r1.max(r2)))
}

/// Bump state + resize the master if the target differs from current.
fn apply_size(
    state:  &mut PtyState,
    master: &Mutex<Box<dyn MasterPty + Send>>,
    eff_c:  u16,
    eff_r:  u16,
) -> Option<(u16, u16)> {
    if (state.cols, state.rows) == (eff_c, eff_r) {
        return None;
    }
    state.cols = eff_c;
    state.rows = eff_r;
    let m = master.lock();
    let _ = m.resize(PtySize {
        cols: eff_c, rows: eff_r, pixel_width: 0, pixel_height: 0,
    });
    Some((eff_c, eff_r))
}

pub struct PtyPool {
    next_id:   parking_lot::Mutex<u64>,
    ptys:      DashMap<PtyId, Arc<Pty>>,
    /// Back-pointer to owning Session so the reader threads can publish events.
    /// Set after Session::new completes; weak to avoid cycles.
    session:   parking_lot::Mutex<Option<Weak<Session>>>,
}

impl PtyPool {
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            next_id: parking_lot::Mutex::new(0),
            ptys:    DashMap::new(),
            session: parking_lot::Mutex::new(None),
        })
    }

    pub(crate) fn set_session(&self, s: Weak<Session>) {
        *self.session.lock() = Some(s);
    }

    fn session(&self) -> Option<Arc<Session>> {
        self.session.lock().as_ref().and_then(Weak::upgrade)
    }

    pub fn list(&self) -> Vec<PtyInfo> {
        self.ptys.iter().map(|r| r.info()).collect()
    }

    pub fn get(&self, id: &str) -> Option<Arc<Pty>> {
        self.ptys.get(id).map(|r| r.clone())
    }

    pub fn count(&self) -> usize { self.ptys.len() }

    /// Spawn a new PTY. The reader thread starts immediately.
    pub fn create(
        &self,
        params: PtyCreateParams,
        owner_client: ClientId,
        default_cwd: &Path,
    ) -> Result<Arc<Pty>, PtyError> {
        if self.ptys.len() >= MAX_PTYS {
            return Err(PtyError::LimitReached);
        }

        let id = {
            let mut n = self.next_id.lock();
            *n += 1;
            format!("sh-{}", *n)
        };

        let cmd_str = params.cmd.clone().unwrap_or_else(default_shell);
        let cwd     = params.cwd.clone().unwrap_or_else(|| default_cwd.to_path_buf());
        let cols    = params.cols.max(1);
        let rows    = params.rows.max(1);

        let pty_system = native_pty_system();
        let pair = pty_system.openpty(PtySize {
            cols, rows, pixel_width: 0, pixel_height: 0,
        }).map_err(|e| PtyError::OpenFailed(e.to_string()))?;

        // Build child command.
        let mut cb = if cmd_str.contains(' ') {
            // Interpret as shell command — wrap in /bin/sh -lc.
            let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".into());
            let mut c = CommandBuilder::new(&shell);
            c.args(["-lc", &cmd_str]);
            c
        } else {
            CommandBuilder::new(&cmd_str)
        };
        cb.cwd(&cwd);
        for (k, v) in &params.env { cb.env(k, v); }

        let child = pair.slave.spawn_command(cb)
            .map_err(|e| PtyError::SpawnFailed(e.to_string()))?;
        let killer = child.clone_killer();
        let pid    = child.process_id();

        // Take writer + reader before we move master into Pty.
        let writer = pair.master.take_writer()
            .map_err(|e| PtyError::OpenFailed(e.to_string()))?;
        let reader = pair.master.try_clone_reader()
            .map_err(|e| PtyError::OpenFailed(e.to_string()))?;

        let mut sizes = HashMap::new();
        sizes.insert(owner_client.clone(), (cols, rows));

        let pty = Arc::new(Pty {
            id:         id.clone(),
            cmd:        cmd_str,
            cwd:        cwd.clone(),
            created_at: now_ms(),
            pid,
            master:     Mutex::new(pair.master),
            writer:     Mutex::new(writer),
            killer:     Mutex::new(Some(killer)),
            state:      Mutex::new(PtyState {
                cols, rows,
                sizes,
                primary: Some(owner_client),
                alive: true,
                ring:  VecDeque::with_capacity(RING_BYTES),
                last_cwd: Some(cwd.clone()),
                last_fg_name: None,
            }),
        });

        self.ptys.insert(id.clone(), pty.clone());

        // Reader thread.
        let pty_for_reader  = Arc::clone(&pty);
        let session_weak    = self.session.lock().clone();
        let thread_pty_id   = id.clone();
        std::thread::Builder::new()
            .name(format!("motif-pty-{}", thread_pty_id))
            .spawn(move || reader_loop(reader, pty_for_reader, session_weak, thread_pty_id, child))
            .map_err(|e| PtyError::OpenFailed(e.to_string()))?;

        // Cwd watcher (one tokio task per PTY). Polls the foreground process's
        // cwd every 1.5s; emits pty.cwd_changed only on a transition. Stops
        // when the PTY exits or the Session is dropped.
        spawn_cwd_watcher(Arc::clone(&pty), self.session.lock().clone());

        // Announce.
        if let Some(s) = self.session() {
            let info = pty.info();
            s.publish_event(|seq| Event::PtyCreated { info, seq });
        }

        Ok(pty)
    }

    pub fn kill(&self, id: &str) -> Result<(), PtyError> {
        let p = self.ptys.get(id).ok_or(PtyError::NotFound)?.clone();
        p.kill();
        Ok(())
    }

    /// Drop a Pty entry from the pool. Called by the reader thread once the
    /// child has exited and we've finished broadcasting pty.exited.
    pub fn remove(&self, id: &str) {
        self.ptys.remove(id);
    }

    /// Called when a client detaches; remove its size contributions and
    /// recompute effective sizes per PTY. Emits resize events for any change.
    pub fn forget_client_sizes(&self, client: &ClientId) {
        let session = self.session();
        for entry in self.ptys.iter() {
            if let Some((cols, rows)) = entry.forget_client(client) {
                if let Some(ref s) = session {
                    let pid = entry.id.clone();
                    s.publish_event(|seq| Event::PtyResize { pty_id: pid, cols, rows, seq });
                }
            }
        }
    }
}

fn reader_loop(
    mut reader: Box<dyn Read + Send>,
    pty:        Arc<Pty>,
    session:    Option<Weak<Session>>,
    pty_id:     PtyId,
    mut child:  Box<dyn portable_pty::Child + Send + Sync>,
) {
    let mut buf = vec![0u8; READ_CHUNK];
    // Strip terminal capability queries (DA1, OSC 11, CPR, …) from the
    // stream before they reach clients, AND answer them locally by writing
    // the canonical response back to the PTY master. Doing both on the
    // server side ensures:
    //   * xterm.js in the web client never sees the query and so won't
    //     auto-answer late (a late answer leaks into fish's line editor
    //     as fake keystrokes — `^[]11;…` typed into the prompt);
    //   * fish gets its DA1 reply at I/O speed instead of after a network
    //     round trip, so its 10s "Primary Device Attribute" timeout never
    //     fires even when no client is attached.
    let mut scanner = QueryScanner::new();
    loop {
        match reader.read(&mut buf) {
            Ok(0)  => break,
            Ok(n)  => {
                let scan = scanner.feed(&buf[..n]);
                if !scan.queries.is_empty() {
                    // OSC 10/11 (foreground/background colour) get answered
                    // with the client-reported palette when available, so
                    // theme-aware prompts see the user's actual terminal
                    // colours; everything else gets the canonical default.
                    let live_session = session.as_ref().and_then(|w| w.upgrade());
                    for q in &scan.queries {
                        let answer: Vec<u8> = live_session.as_ref()
                            .and_then(|s| s.osc_palette_response(q))
                            .unwrap_or_else(|| q.canonical_response());
                        // Best-effort: a transient write failure here just
                        // means fish waits its full timeout this once.
                        let _ = pty.write_bytes(&answer);
                    }
                }
                if scan.passthrough.is_empty() {
                    // Whole chunk was queries — nothing to ring or broadcast.
                    continue;
                }
                {
                    let mut s = pty.state.lock();
                    let drop_n = (s.ring.len() + scan.passthrough.len()).saturating_sub(RING_BYTES);
                    for _ in 0..drop_n { s.ring.pop_front(); }
                    s.ring.extend(&scan.passthrough);
                }
                let chunk = BASE64.encode(&scan.passthrough);
                if let Some(ref weak) = session {
                    if let Some(sess) = weak.upgrade() {
                        let pid = pty_id.clone();
                        sess.publish_event(|seq| Event::PtyOutput {
                            pty_id: pid, data_b64: chunk, seq,
                        });
                    }
                }
            }
            Err(_) => break,
        }
    }
    // Mark dead and announce exit.
    {
        let mut s = pty.state.lock();
        s.alive = false;
    }
    let exit_code = match child.try_wait() {
        Ok(Some(status)) => status.exit_code() as i32,
        _                => i32::MIN,
    };
    let exit_code = if exit_code == i32::MIN { None } else { Some(exit_code) };

    if let Some(ref weak) = session {
        if let Some(sess) = weak.upgrade() {
            // Drop the entry from the pool BEFORE the broadcast: clients that
            // call pty.list immediately after seeing pty.exited won't see a
            // ghost entry.
            sess.pty_pool.remove(&pty_id);
            let pid_for_event = pty_id.clone();
            sess.publish_event(|seq| Event::PtyExited { pty_id: pid_for_event, exit_code, seq });
            // And remove the corresponding tab/view so all clients see it
            // disappear. close_view_internal won't try to re-kill the PTY
            // (which would race with our own reader exit).
            sess.close_pty_view(&pty_id);
        }
    }
}

fn default_shell() -> String {
    std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".into())
}

fn spawn_cwd_watcher(pty: Arc<Pty>, session: Option<Weak<Session>>) {
    let Some(session) = session else { return };
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(std::time::Duration::from_millis(1500));
        // Drop the eager first-tick (interval fires immediately) — the cwd
        // recorded at create time is already correct, no need to re-broadcast.
        interval.tick().await;
        loop {
            interval.tick().await;
            if !pty.is_alive() { break; }
            let Some(s) = session.upgrade() else { break };

            // Pick the target pid for cwd lookup. Order of preference:
            //   1. The controlling tty's foreground process group leader.
            //      That's whatever process is currently in front of the user
            //      — a nested shell, vim, etc. — so `cd` inside it surfaces.
            //   2. The shell pid we originally spawned, as a fallback when
            //      portable-pty can't tell us the fg pgid (e.g. the shell
            //      called setsid, or platform doesn't expose it).
            //
            // We hold the master mutex only long enough to query the kernel
            // (tcgetpgrp under the hood); the cwd read is done after release
            // to keep contention with resize() calls minimal.
            let target_pid: Option<u32> = {
                let master = pty.master.lock();
                #[cfg(unix)]
                let fg = master.process_group_leader().map(|p| p as u32);
                #[cfg(not(unix))]
                let fg: Option<u32> = { let _ = &master; None };
                fg.or(pty.pid)
            };
            let Some(pid) = target_pid else { continue };
            let Some(cwd) = read_pid_cwd(pid) else { continue };
            let fg_name   = read_fg_name(pid);

            let changed = {
                let mut state = pty.state.lock();
                let cwd_changed  = state.last_cwd.as_ref() != Some(&cwd);
                let name_changed = state.last_fg_name != fg_name;
                if cwd_changed  { state.last_cwd     = Some(cwd.clone()); }
                if name_changed { state.last_fg_name = fg_name.clone(); }
                cwd_changed || name_changed
            };
            if changed {
                let pty_id = pty.id.clone();
                let cwd_for_event = cwd.clone();
                let name_for_event = fg_name.clone();
                s.publish_event(|seq| Event::PtyFgChanged {
                    pty_id,
                    cwd: cwd_for_event,
                    name: name_for_event,
                    seq,
                });
            }
        }
    });
}

#[cfg(target_os = "linux")]
fn read_pid_cwd(pid: u32) -> Option<PathBuf> {
    std::fs::read_link(format!("/proc/{}/cwd", pid)).ok()
}

#[cfg(target_os = "macos")]
fn read_pid_cwd(pid: u32) -> Option<PathBuf> {
    // Bind directly to `proc_pidinfo` with the PROC_PIDVNODEPATHINFO flavor;
    // that's what `lsof -p PID -d cwd` uses under the hood. We only read the
    // cdir path from the result.
    use std::ffi::CStr;
    use std::mem::MaybeUninit;
    use std::os::raw::{c_int, c_void};

    extern "C" {
        fn proc_pidinfo(
            pid: c_int,
            flavor: c_int,
            arg: u64,
            buffer: *mut c_void,
            buffersize: c_int,
        ) -> c_int;
    }

    const PROC_PIDVNODEPATHINFO: c_int = 9;
    const MAXPATHLEN: usize = 1024;

    // The struct layouts come from <sys/proc_info.h>. Sizes/types validated
    // against the macOS SDK; the kernel writes exactly this shape.
    #[repr(C)]
    struct VinfoStat {
        vst_dev:           u32,
        vst_mode:          u16,
        vst_nlink:         u16,
        vst_ino:           u64,
        vst_uid:           u32,
        vst_gid:           u32,
        vst_atime:         i64, vst_atimensec:     i64,
        vst_mtime:         i64, vst_mtimensec:     i64,
        vst_ctime:         i64, vst_ctimensec:     i64,
        vst_birthtime:     i64, vst_birthtimensec: i64,
        vst_size:          i64,
        vst_blocks:        i64,
        vst_blksize:       i32,
        vst_flags:         u32,
        vst_gen:           u32,
        vst_rdev:          u32,
        vst_qspare:        [i64; 2],
    }
    #[repr(C)] struct FsidT { val: [i32; 2] }
    #[repr(C)]
    struct VnodeInfo {
        vi_stat: VinfoStat,
        vi_type: i32,
        vi_pad:  i32,
        vi_fsid: FsidT,
    }
    #[repr(C)]
    struct VnodeInfoPath {
        vip_vi:   VnodeInfo,
        vip_path: [u8; MAXPATHLEN],
    }
    #[repr(C)]
    struct ProcVnodepathinfo {
        pvi_cdir: VnodeInfoPath,
        pvi_rdir: VnodeInfoPath,
    }

    let mut info: MaybeUninit<ProcVnodepathinfo> = MaybeUninit::zeroed();
    let size = std::mem::size_of::<ProcVnodepathinfo>() as c_int;
    let n = unsafe {
        proc_pidinfo(
            pid as c_int,
            PROC_PIDVNODEPATHINFO,
            0,
            info.as_mut_ptr() as *mut c_void,
            size,
        )
    };
    // proc_pidinfo returns the number of bytes written, 0 / -1 on error.
    if n <= 0 { return None; }
    let info = unsafe { info.assume_init() };
    let cstr = CStr::from_bytes_until_nul(&info.pvi_cdir.vip_path).ok()?;
    Some(PathBuf::from(cstr.to_str().ok()?))
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn read_pid_cwd(_pid: u32) -> Option<PathBuf> { None }

/// Best-effort name of a process: the basename of its executable. Used for
/// labelling tabs (cwd basename · fg name).
#[cfg(target_os = "linux")]
fn read_fg_name(pid: u32) -> Option<String> {
    // /proc/<pid>/comm is the kernel-reported short name (TASK_COMM_LEN=16).
    // Strip the trailing newline and reject empty results.
    let raw = std::fs::read_to_string(format!("/proc/{}/comm", pid)).ok()?;
    let s = raw.trim();
    if s.is_empty() { None } else { Some(s.to_string()) }
}

#[cfg(target_os = "macos")]
fn read_fg_name(pid: u32) -> Option<String> {
    use std::ffi::CStr;
    use std::os::raw::{c_char, c_int};

    extern "C" {
        // proc_pidpath fills `buffer` with the absolute executable path,
        // returns the length written (or 0 on failure).
        fn proc_pidpath(pid: c_int, buffer: *mut c_char, buffersize: u32) -> c_int;
    }
    const PROC_PIDPATHINFO_MAXSIZE: usize = 4096;

    let mut buf = vec![0u8; PROC_PIDPATHINFO_MAXSIZE];
    let n = unsafe {
        proc_pidpath(pid as c_int, buf.as_mut_ptr() as *mut c_char, buf.len() as u32)
    };
    if n <= 0 { return None; }
    buf.truncate(n as usize);
    let cstr = CStr::from_bytes_until_nul(&buf).ok().or_else(|| CStr::from_bytes_with_nul(&buf).ok())?;
    let path = cstr.to_str().ok()?;
    let base = std::path::Path::new(path).file_name()?.to_str()?;
    if base.is_empty() { None } else { Some(base.to_string()) }
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn read_fg_name(_pid: u32) -> Option<String> { None }

#[cfg(test)]
mod size_tests {
    use super::*;

    fn sizes(pairs: &[(&str, (u16, u16))]) -> HashMap<ClientId, (u16, u16)> {
        pairs.iter().map(|(k, v)| ((*k).to_string(), *v)).collect()
    }

    #[test]
    fn primary_drives_when_present() {
        let m = sizes(&[("web", (200, 60)), ("tui", (80, 20))]);
        let web = "web".to_string();
        assert_eq!(compute_effective(&m, Some(&web)), Some((200, 60)));
    }

    #[test]
    fn fallback_to_max_without_primary() {
        // No primary → biggest reported wins (per-axis max).
        let m = sizes(&[("a", (200, 60)), ("b", (80, 100))]);
        assert_eq!(compute_effective(&m, None), Some((200, 100)));
    }

    #[test]
    fn fallback_to_max_when_primary_has_no_size() {
        // Primary set but never sent pty.resize: don't shrink to a passive
        // viewer's smaller size, hold at the largest known.
        let m = sizes(&[("tui", (80, 20))]);
        let web = "web".to_string();
        assert_eq!(compute_effective(&m, Some(&web)), Some((80, 20)));
    }

    #[test]
    fn empty_sizes_with_no_primary_yields_none() {
        let m = sizes(&[]);
        assert_eq!(compute_effective(&m, None), None);
    }

    #[test]
    fn passive_observer_doesnt_shrink_primary() {
        // The dev-tmux scenario: web is primary at 200x60, TUI joins at
        // 80x20 — effective stays at primary's 200x60.
        let m = sizes(&[("web", (200, 60)), ("tui", (80, 20))]);
        let web = "web".to_string();
        assert_eq!(compute_effective(&m, Some(&web)), Some((200, 60)));
    }
}

#[cfg(test)]
mod cwd_tests {
    use super::*;

    #[test]
    fn read_pid_cwd_self_works() {
        // The self-PID's cwd should match what we get from std. Smoke test
        // for both Linux's /proc and macOS's proc_pidinfo path.
        let me = std::process::id();
        let observed = read_pid_cwd(me).expect("read_pid_cwd returned None for self PID");
        let expected = std::env::current_dir().unwrap();
        // Compare canonicalised forms — proc_pidinfo returns the canonical
        // path so symlinked test runners don't confuse the assertion.
        let observed_c = observed.canonicalize().unwrap_or(observed);
        let expected_c = expected.canonicalize().unwrap_or(expected);
        assert_eq!(observed_c, expected_c);
    }
}

fn now_ms() -> UnixMs {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

#[derive(Debug, thiserror::Error)]
pub enum PtyError {
    #[error("pty limit reached (max {})", MAX_PTYS)]
    LimitReached,
    #[error("pty not found")]
    NotFound,
    #[error("pty open failed: {0}")]
    OpenFailed(String),
    #[error("pty spawn failed: {0}")]
    SpawnFailed(String),
}
