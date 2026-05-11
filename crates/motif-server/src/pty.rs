//! Multi-PTY management for a Session.
//!
//! Each Pty holds:
//!   - the master pty handle (for resize)
//!   - a writer (sync; clients call `pty.write` rarely enough that brief lock
//!     contention is fine)
//!   - a 1MB ring buffer of recent stdout bytes for replay on attach
//!   - per-client (cols, rows) preferences. The master follows the
//!     currently-active client's size: `primary` is set on creation, on
//!     `pty.write`, and on `view.activate`, so whoever is most recently
//!     typing or focusing the tab decides the grid. Non-primary clients'
//!     sizes are stashed but ignored, and if the active client hasn't
//!     reported a size yet (just marked, no `pty.resize` in flight) the
//!     master is left at its last value rather than falling back to a
//!     passive viewer's dimensions.
//!
//! A dedicated OS thread reads from the master in chunks, appends to the ring,
//! and publishes `Event::PtyOutput` via the back-pointer to its Session.

use std::collections::{HashMap, VecDeque};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Weak};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use dashmap::DashMap;
use motif_proto::common::{ClientId, PtyId, UnixMs};
use motif_proto::event::Event;
use motif_proto::pty::{PtyCreateParams, PtyInfo};
use motif_proto::terminal_query::{QueryScanner, ScanItem};
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
    /// v2 shell-integration. `Some` when motifd injected a bootstrap
    /// script; the contained tmpdir lives as long as the Pty does, so
    /// the rcfile copies stay on disk while the child shell sources
    /// them. Dropped (and removed) automatically when the Pty drops.
    _bootstrap: Option<crate::shell::Bootstrap>,
}

struct PtyState {
    cols:  u16,
    rows:  u16,
    /// Per-client (cols, rows) preferences. Only the primary's entry
    /// drives the master; non-primary entries are kept around so a
    /// `mark_primary` handover can immediately apply the new active
    /// client's already-reported size without an extra round trip.
    sizes: HashMap<ClientId, (u16, u16)>,
    /// Currently-active client (last writer / last view activator). None
    /// after the previous active client detaches and before someone new
    /// engages.
    primary: Option<ClientId>,
    alive: bool,
    ring:  VecDeque<u8>,
    /// Last cwd we observed for the shell process. Used by the watcher to
    /// dedupe; only transitions are broadcast as `pty.cwd_changed`.
    last_cwd: Option<PathBuf>,
    /// v2 shell-integration block state machine. Driven by OSC markers
    /// in the reader loop; see [`crate::shell::state`].
    shell: crate::shell::ShellState,
    /// Per-PTY ring buffer of finished blocks for `pty.list_blocks` /
    /// `pty.get_block_output` backfill.
    block_store: crate::shell::BlockStore,
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

    /// Snapshot of the BlockStore. Wraps the lock + clone so callers
    /// (RPC handlers) don't have to know about the inner state machine.
    pub fn list_blocks(
        &self,
        before: Option<&motif_proto::common::BlockId>,
        limit:  usize,
    ) -> Vec<motif_proto::pty::BlockSummary> {
        self.state.lock().block_store.list(before, limit)
    }

    /// Fetch all three byte segments (prompt + command + output) plus
    /// per-segment truncated flags for a recorded block. `None` means
    /// the block id is not in this PTY's BlockStore (rolled out, or
    /// never existed).
    pub fn get_block_output(
        &self,
        id: &motif_proto::common::BlockId,
    ) -> Option<BlockSegments> {
        self.state.lock().block_store.get(id).map(|b| BlockSegments {
            prompt:            b.prompt.clone(),
            prompt_truncated:  b.prompt_truncated,
            command:           b.command.clone(),
            command_truncated: b.command_truncated,
            output:            b.output.clone(),
            output_truncated:  b.output_truncated,
        })
    }
}

/// Three-segment view of a finalized block; returned from
/// `Pty::get_block_output` and serialized into
/// `motif_proto::pty::GetBlockOutputResult` by the RPC handler.
pub struct BlockSegments {
    pub prompt:            Vec<u8>,
    pub prompt_truncated:  bool,
    pub command:           Vec<u8>,
    pub command_truncated: bool,
    pub output:            Vec<u8>,
    pub output_truncated:  bool,
}

/// Pick the master size: the currently-active client's reported size, or
/// `None` if there's no active client (caller leaves the master alone)
/// or the active client hasn't sent a `pty.resize` yet (we don't want to
/// snap the master to a passive viewer's smaller dimensions while the
/// new primary is still mid-handover). Non-primary clients' sizes don't
/// influence the result — they sit in `sizes` so that the next
/// `mark_primary` flip can apply immediately if the new active client
/// has already reported.
fn compute_effective(
    sizes:   &HashMap<ClientId, (u16, u16)>,
    primary: Option<&ClientId>,
) -> Option<(u16, u16)> {
    primary.and_then(|p| sizes.get(p).copied())
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
        // Ensure terminfo-based tools (`clear`, `tput`, `less`, ncurses)
        // have something sensible to look up. portable-pty inherits the
        // server process env on Unix, but motifd may have been launched
        // from a non-interactive context (CI, launchd) where TERM isn't
        // set. xterm.js advertises xterm-256color compatibility.
        cb.env("TERM", "xterm-256color");
        for (k, v) in &params.env { cb.env(k, v); }

        // v2 shell integration: detect shell from the spawn cmd, write
        // bootstrap scripts to a per-PTY tmpdir, and inject the right
        // flags / env into the CommandBuilder. The Bootstrap value owns
        // the tmpdir and is moved into the Pty struct so the scripts
        // stay on disk for the child's lifetime.
        let detected_kind = crate::shell::detect(&cmd_str);
        let bootstrap = crate::shell::Bootstrap::prepare(detected_kind, &id);
        if let Some(ref bs) = bootstrap { bs.apply_to(&mut cb); }
        // The state machine carries the detected kind even when bootstrap
        // is None (env-disabled / unknown shell) so the 5s timeout can
        // emit `shell: "unknown"` without lying about which shell was
        // attempted.
        let shell_kind = if bootstrap.is_some() { detected_kind } else { motif_proto::pty::ShellKind::Unknown };

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
                shell: crate::shell::ShellState::new(
                    shell_kind,
                    Instant::now(),
                    Some(cwd.clone()),
                ),
                block_store: crate::shell::BlockStore::new(
                    block_cap_count_env(),
                    block_cap_bytes_env(),
                ),
            }),
            _bootstrap: bootstrap,
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

        // 5s bootstrap timeout: if no OSC 133 marker arrives in that
        // window, mark the shell as Unknown so clients stop waiting for
        // block events. Covers MOTIF_SHELL_INTEGRATION=0, /bin/sh, and
        // bootstrap-injection failures.
        spawn_bootstrap_timeout(Arc::clone(&pty), self.session.lock().clone());

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
                let live_session = session.as_ref().and_then(|w| w.upgrade());
                // Walk items in arrival order so the BlockState is in
                // the right state when each passthrough chunk is
                // recorded — `133;C` must move us to Running before the
                // command's stdout flows past, and `133;D` must
                // finalize *after* the trailing output.
                for item in scan.items {
                    match item {
                        ScanItem::Query(q) => {
                            if q.is_shell_integration() {
                                let evs = pty.state.lock().shell.on_osc(&q);
                                for ev in evs {
                                    dispatch_shell_event(&pty, &session, ev);
                                }
                            } else {
                                // Capability query — write canonical or
                                // client-palette response back to the
                                // PTY master.
                                let answer: Option<Vec<u8>> = live_session.as_ref()
                                    .and_then(|s| s.osc_palette_response(&q))
                                    .map(Some)
                                    .unwrap_or_else(|| q.canonical_response());
                                if let Some(bytes) = answer {
                                    let _ = pty.write_bytes(&bytes);
                                }
                            }
                        }
                        ScanItem::Bytes(bytes) => {
                            let (block_id, scope) = {
                                let mut s = pty.state.lock();
                                let drop_n = (s.ring.len() + bytes.len()).saturating_sub(RING_BYTES);
                                for _ in 0..drop_n { s.ring.pop_front(); }
                                s.ring.extend(&bytes);
                                s.shell.record_output(&bytes);
                                (s.shell.active_block_id().cloned(), s.shell.active_scope())
                            };
                            if let Some(ref weak) = session {
                                if let Some(sess) = weak.upgrade() {
                                    let pid = pty_id.clone();
                                    let data = bytes.clone();
                                    sess.publish_event(|seq| Event::PtyOutput {
                                        pty_id: pid, data, block_id, scope, seq,
                                    });
                                }
                            }
                        }
                    }
                }
            }
            Err(_) => break,
        }
    }
    // Force-finalize any in-flight block so its output isn't lost.
    if let Some(ev) = pty.state.lock().shell.on_exit() {
        dispatch_shell_event(&pty, &session, ev);
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

/// BlockStore entry-count cap, override via `MOTIF_BLOCK_CAP_COUNT`.
fn block_cap_count_env() -> usize {
    std::env::var("MOTIF_BLOCK_CAP_COUNT")
        .ok().and_then(|s| s.parse().ok())
        .unwrap_or(crate::shell::DEFAULT_CAP_COUNT)
}

/// BlockStore total-bytes cap, override via `MOTIF_BLOCK_CAP_BYTES`.
fn block_cap_bytes_env() -> u64 {
    std::env::var("MOTIF_BLOCK_CAP_BYTES")
        .ok().and_then(|s| s.parse().ok())
        .unwrap_or(crate::shell::DEFAULT_CAP_TOTAL_BYTES)
}

/// Translate a `ShellEvent` (BlockState output) into broadcast events
/// and BlockStore writes. Called inline from `reader_loop` after the
/// per-OSC state lock is dropped, so we never hold the state lock
/// across `Session::publish_event`.
fn dispatch_shell_event(
    pty:     &Arc<Pty>,
    session: &Option<Weak<Session>>,
    ev:      crate::shell::ShellEvent,
) {
    let Some(sess) = session.as_ref().and_then(|w| w.upgrade()) else { return };
    use crate::shell::ShellEvent;
    match ev {
        ShellEvent::Bootstrapped => {
            let kind = pty.state.lock().shell.kind;
            let pty_id = pty.id.clone();
            sess.publish_event(|seq| Event::PtyShellBootstrapped {
                pty_id, shell: kind, seq,
            });
        }
        ShellEvent::PromptStarted { block_id } => {
            let pty_id = pty.id.clone();
            sess.publish_event(|seq| Event::PtyPromptStarted { pty_id, block_id, seq });
        }
        ShellEvent::PromptEnded { block_id } => {
            let pty_id = pty.id.clone();
            sess.publish_event(|seq| Event::PtyPromptEnded { pty_id, block_id, seq });
        }
        ShellEvent::CommandStarted { id, text, cwd, started_at } => {
            let pty_id = pty.id.clone();
            sess.publish_event(|seq| Event::PtyCommandStarted {
                pty_id, block_id: id, text, cwd, started_at, seq,
            });
        }
        ShellEvent::CommandFinished {
            id, cmd, cwd, started_at, finished_at, exit,
            prompt, prompt_truncated,
            command, command_truncated,
            output, output_truncated,
        } => {
            // Broadcast first (clients refresh UI immediately), then
            // append to the BlockStore for backfill RPCs. Order matters
            // only if a client races a `pty.list_blocks` against the
            // `command_finished` they just received — append before
            // unlocking lets them see the finished block.
            let pty_id_e = pty.id.clone();
            let id_for_event = id.clone();
            sess.publish_event(|seq| Event::PtyCommandFinished {
                pty_id: pty_id_e, block_id: id_for_event,
                exit_code: exit, finished_at, seq,
            });
            let mut s = pty.state.lock();
            s.block_store.append(crate::shell::Block {
                id, cwd, cmd, started_at, finished_at,
                exit_code: exit,
                prompt,  prompt_truncated,
                command, command_truncated,
                output,  output_truncated,
            });
        }
        ShellEvent::Context { ctx } => {
            let pty_id = pty.id.clone();
            sess.publish_event(|seq| Event::PtyShellContext {
                pty_id, ctx, seq,
            });
        }
        ShellEvent::CwdChanged { cwd } => {
            // OSC 7 path: mirror the pid-poll-driven cwd dedupe in
            // `spawn_cwd_watcher` so back-to-back OSC 7 + watcher pulse
            // doesn't double-broadcast.
            let changed = {
                let mut s = pty.state.lock();
                let ch = s.last_cwd.as_ref() != Some(&cwd);
                if ch { s.last_cwd = Some(cwd.clone()); }
                ch
            };
            if changed {
                let pty_id = pty.id.clone();
                sess.publish_event(|seq| Event::PtyCwdChanged {
                    pty_id: pty_id.clone(), cwd, seq,
                });
                sess.note_pty_cwd_changed(&pty_id);
            }
        }
    }
}

/// 5s post-spawn deadline. If we still haven't seen an OSC 133 marker
/// by then, mark the PTY's shell as `Unknown` so clients (status bars,
/// block UIs) stop waiting. Covers `MOTIF_SHELL_INTEGRATION=0`,
/// /bin/sh / dash, and bootstrap injection failures.
fn spawn_bootstrap_timeout(pty: Arc<Pty>, session: Option<Weak<Session>>) {
    tokio::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_secs(5)).await;
        if !pty.is_alive() { return; }
        let ev = pty.state.lock().shell.note_bootstrap_timeout();
        if let Some(ev) = ev {
            dispatch_shell_event(&pty, &session, ev);
        }
    });
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

            // Read the shell's own cwd. We deliberately don't follow the
            // controlling tty's foreground pgid — chasing vim/htop's cwd
            // adds platform code (proc_bsdinfo.e_tpgid / /proc/PID/stat
            // tpgid) and corner-case complexity (vim's `:cd` etc.) for a
            // payoff users rarely notice. The shell-integration path
            // (OSC 7 from a chpwd/precmd hook) gives precise cwd updates
            // when bootstrap is on; this watcher is the fallback.
            let Some(shell_pid) = pty.pid else { continue };
            let Some(cwd) = read_pid_cwd(shell_pid) else { continue };

            let changed = {
                let mut state = pty.state.lock();
                let cwd_changed = state.last_cwd.as_ref() != Some(&cwd);
                if cwd_changed { state.last_cwd = Some(cwd.clone()); }
                cwd_changed
            };
            if changed {
                let pty_id = pty.id.clone();
                let cwd_for_event = cwd.clone();
                let pty_id_for_hook = pty_id.clone();
                s.publish_event(|seq| Event::PtyCwdChanged {
                    pty_id,
                    cwd: cwd_for_event,
                    seq,
                });
                s.note_pty_cwd_changed(&pty_id_for_hook);
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

#[cfg(test)]
mod size_tests {
    use super::*;

    fn sizes(pairs: &[(&str, (u16, u16))]) -> HashMap<ClientId, (u16, u16)> {
        pairs.iter().map(|(k, v)| ((*k).to_string(), *v)).collect()
    }

    #[test]
    fn primary_drives_master_when_size_is_known() {
        // Active client wins: web's 200x60 is what claude paints to,
        // even though tui is also attached at 80x20.
        let m = sizes(&[("web", (200, 60)), ("tui", (80, 20))]);
        let web = "web".to_string();
        assert_eq!(compute_effective(&m, Some(&web)), Some((200, 60)));
    }

    #[test]
    fn handover_to_new_primary_uses_their_already_reported_size() {
        // mark_primary(tui) after tui has already sent pty.resize: the
        // new active client's stashed size applies immediately, without
        // a fresh round trip.
        let m = sizes(&[("web", (200, 60)), ("tui", (80, 20))]);
        let tui = "tui".to_string();
        assert_eq!(compute_effective(&m, Some(&tui)), Some((80, 20)));
    }

    #[test]
    fn primary_marked_but_no_size_yields_none() {
        // mark_primary(web) just landed (e.g., from pty.write), but web
        // hasn't reported a size yet. We deliberately return None so
        // the caller leaves the master pinned — falling through to a
        // passive viewer's smaller dimensions would make claude redraw
        // at the wrong size for ~one round trip.
        let m = sizes(&[("tui", (80, 20))]);
        let web = "web".to_string();
        assert_eq!(compute_effective(&m, Some(&web)), None);
    }

    #[test]
    fn no_primary_yields_none() {
        // Right after the active client detaches and before anyone new
        // types or activates a tab. Master holds its last value until
        // somebody engages.
        let m = sizes(&[("tui", (80, 20))]);
        assert_eq!(compute_effective(&m, None), None);
    }

    #[test]
    fn empty_sizes_yields_none() {
        let m = sizes(&[]);
        assert_eq!(compute_effective(&m, None), None);
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
