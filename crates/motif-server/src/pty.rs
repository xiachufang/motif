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
use std::time::{SystemTime, UNIX_EPOCH};

use bytes::Bytes;
use dashmap::DashMap;
use motif_proto::common::{ClientId, PtyId, UnixMs};
use motif_proto::event::Event;
use motif_proto::pty::{PtyCreateParams, PtyInfo};
use motif_proto::terminal_query::{QueryScanner, ScanItem};
use parking_lot::Mutex;
use portable_pty::{native_pty_system, ChildKiller, CommandBuilder, MasterPty, PtySize};
use tokio::sync::broadcast;

use crate::session::Session;

/// Per-PTY ring kept on the server for replay-on-reconnect. The new
/// protocol's `WS /pty/<id>?since=N` queries this ring; reader_loop
/// appends every chunk of master output. 2 MB matches what the user
/// asked for during protocol design — enough to absorb a few seconds
/// of busy `make` output, not so much that a few idle PTYs eat all
/// memory.
const RING_BYTES: usize = 2 * 1024 * 1024;
const MAX_PTYS: usize = 32;
const READ_CHUNK: usize = 8 * 1024;

/// Fan-out depth for per-PTY broadcast::Sender<Bytes>. Each `/pty/<id>`
/// subscriber holds one slot; lagged subscribers get `RecvError::Lagged`
/// and we close their socket (the new-protocol 4011 path can handle a
/// resync). 256 frames at READ_CHUNK = ~2 MB queued per slow consumer
/// before we cut them off.
const PTY_BROADCAST_CAPACITY: usize = 256;

pub struct Pty {
    pub id: PtyId,
    pub cmd: String,
    pub cwd: PathBuf,
    pub created_at: UnixMs,
    /// OS pid of the spawned shell. Used by the cwd watcher.
    pub pid: Option<u32>,

    master: Mutex<Box<dyn MasterPty + Send>>,
    writer: Mutex<Box<dyn Write + Send>>,
    killer: Mutex<Option<Box<dyn ChildKiller + Send + Sync>>>,
    pub(crate) state: Mutex<PtyState>,
    /// Fan-out of every master-output chunk to currently-attached
    /// `/pty/<id>` WS subscribers. Each subscriber gets its own
    /// receiver via [`Pty::subscribe_output`]. The Sender lives as
    /// long as the Pty; closing the Pty drops it, signalling EOF to
    /// receivers.
    output_tx: broadcast::Sender<Bytes>,
    /// v2 shell-integration. `Some` when motifd injected a bootstrap
    /// script; the contained tmpdir lives as long as the Pty does, so
    /// the rcfile copies stay on disk while the child shell sources
    /// them. Dropped (and removed) automatically when the Pty drops.
    _bootstrap: Option<crate::shell::Bootstrap>,
}

/// Per-PTY byte-indexed ring. `origin` is the absolute byte index of
/// `bytes[0]`; `total = origin + bytes.len()` is the next byte's index.
/// Both monotonic, never reset for the lifetime of the Pty.
///
/// Replay protocol: client connects with `?since=N`.
///   - `N == total`              → up to date, no replay.
///   - `origin <= N < total`     → replay `bytes[(N - origin)..]`.
///   - `N < origin`              → ring rolled past, signal 4011 (truncated).
///   - `N > total`               → client claims newer cursor than us; 4012 (stale).
pub(crate) struct PtyRing {
    pub bytes: VecDeque<u8>,
    pub origin: u64,
}

impl PtyRing {
    fn new() -> Self {
        Self {
            bytes: VecDeque::with_capacity(RING_BYTES.min(64 * 1024)),
            origin: 0,
        }
    }
    pub fn total(&self) -> u64 {
        self.origin + self.bytes.len() as u64
    }
    fn append(&mut self, data: &[u8]) {
        let drop_n = (self.bytes.len() + data.len()).saturating_sub(RING_BYTES);
        for _ in 0..drop_n {
            self.bytes.pop_front();
        }
        self.origin = self.origin.saturating_add(drop_n as u64);
        self.bytes.extend(data);
    }
}

/// Result of `Pty::snapshot_since` — what the /pty/<id> handler needs
/// to decide between replay-then-live, live-only, or close-with-code.
pub enum SinceOutcome {
    /// Client is up to date; nothing to replay.
    UpToDate { total: u64 },
    /// Replay these bytes then go live. `replay` is contiguous from
    /// `since` to `total`.
    Replay { replay: Vec<u8>, total: u64 },
    /// Client's `since` is older than the ring's `origin` — history
    /// has been overwritten. Handler should close with 4011.
    Truncated { ring_origin: u64, total: u64 },
    /// Client's `since` is newer than `total` — server restarted or
    /// the client is lying. Handler should close with 4012.
    Stale { total: u64 },
}

pub(crate) struct PtyState {
    pub cols: u16,
    pub rows: u16,
    /// Per-client (cols, rows) preferences. Only the primary's entry
    /// drives the master; non-primary entries are kept around so a
    /// `mark_primary` handover can immediately apply the new active
    /// client's already-reported size without an extra round trip.
    pub sizes: HashMap<ClientId, (u16, u16)>,
    /// Currently-active client (last writer / last view activator). None
    /// after the previous active client detaches and before someone new
    /// engages.
    pub primary: Option<ClientId>,
    pub alive: bool,
    pub ring: PtyRing,
}

impl Pty {
    pub fn info(&self) -> PtyInfo {
        let s = self.state.lock();
        PtyInfo {
            id: self.id.clone(),
            cmd: self.cmd.clone(),
            // cwd is the spawn cwd; live updates flow via shell-integration markers on
            // /pty/<id> and are tracked client-side.
            cwd: self.cwd.clone(),
            cols: s.cols,
            rows: s.rows,
            alive: s.alive,
            created_at: self.created_at,
        }
    }

    /// Returns a snapshot of the ring buffer for replay on attach.
    /// (Legacy /ws path uses this; new /pty/<id> path goes through
    /// `snapshot_since` for byte-indexed replay.)
    pub fn ring_snapshot(&self) -> Vec<u8> {
        let s = self.state.lock();
        s.ring.bytes.iter().copied().collect()
    }

    /// Byte-indexed replay query for the new `/pty/<id>?since=N` path.
    /// See [`SinceOutcome`] for the four cases the handler distinguishes.
    pub fn snapshot_since(&self, since: u64) -> SinceOutcome {
        let s = self.state.lock();
        let total = s.ring.total();
        let origin = s.ring.origin;
        if since > total {
            return SinceOutcome::Stale { total };
        }
        if since < origin {
            return SinceOutcome::Truncated {
                ring_origin: origin,
                total,
            };
        }
        if since == total {
            return SinceOutcome::UpToDate { total };
        }
        let skip = (since - origin) as usize;
        let replay: Vec<u8> = s.ring.bytes.iter().skip(skip).copied().collect();
        SinceOutcome::Replay { replay, total }
    }

    /// Subscribe to live master output. Each `/pty/<id>` WS handler
    /// takes one of these and forwards binary frames to its client.
    /// Receiver dropped when the WS closes — no GC needed on the Pty.
    pub fn subscribe_output(&self) -> broadcast::Receiver<Bytes> {
        self.output_tx.subscribe()
    }

    /// Cheap helper for callers that just want the absolute byte
    /// index of "next byte the master will produce". Used by
    /// `/pty/<id>` connect-without-`since` to set the live cursor
    /// without taking a slice.
    pub fn snapshot_since_total(&self) -> u64 {
        self.state.lock().ring.total()
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
        let (eff_c, eff_r) =
            compute_effective(&s.sizes, s.primary.as_ref()).unwrap_or((cols, rows));
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

    pub fn is_alive(&self) -> bool {
        self.state.lock().alive
    }
}

/// Three-segment view of a finalized block. Retained as a type so any
/// remaining references compile until block-history tracking moves to
/// clients in Phase 5b.
#[allow(dead_code)]
pub struct BlockSegments {
    pub prompt: Vec<u8>,
    pub prompt_truncated: bool,
    pub command: Vec<u8>,
    pub command_truncated: bool,
    pub output: Vec<u8>,
    pub output_truncated: bool,
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
    sizes: &HashMap<ClientId, (u16, u16)>,
    primary: Option<&ClientId>,
) -> Option<(u16, u16)> {
    primary.and_then(|p| sizes.get(p).copied())
}

/// Bump state + resize the master if the target differs from current.
fn apply_size(
    state: &mut PtyState,
    master: &Mutex<Box<dyn MasterPty + Send>>,
    eff_c: u16,
    eff_r: u16,
) -> Option<(u16, u16)> {
    if (state.cols, state.rows) == (eff_c, eff_r) {
        return None;
    }
    state.cols = eff_c;
    state.rows = eff_r;
    let m = master.lock();
    let _ = m.resize(PtySize {
        cols: eff_c,
        rows: eff_r,
        pixel_width: 0,
        pixel_height: 0,
    });
    Some((eff_c, eff_r))
}

pub struct PtyPool {
    next_id: parking_lot::Mutex<u64>,
    ptys: DashMap<PtyId, Arc<Pty>>,
    /// Back-pointer to owning Session so the reader threads can publish events.
    /// Set after Session::new completes; weak to avoid cycles.
    session: parking_lot::Mutex<Option<Weak<Session>>>,
}

impl PtyPool {
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            next_id: parking_lot::Mutex::new(0),
            ptys: DashMap::new(),
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

    pub fn count(&self) -> usize {
        self.ptys.len()
    }

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
        let cwd = params
            .cwd
            .clone()
            .unwrap_or_else(|| default_cwd.to_path_buf());
        let cols = params.cols.max(1);
        let rows = params.rows.max(1);

        let pty_system = native_pty_system();
        let pair = pty_system
            .openpty(PtySize {
                cols,
                rows,
                pixel_width: 0,
                pixel_height: 0,
            })
            .map_err(|e| PtyError::OpenFailed(e.to_string()))?;

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
        for (k, v) in &params.env {
            cb.env(k, v);
        }

        // v2 shell integration: detect shell from the spawn cmd, write
        // bootstrap scripts to a per-PTY tmpdir, and inject the right
        // flags / env into the CommandBuilder. The Bootstrap value owns
        // the tmpdir and is moved into the Pty struct so the scripts
        // stay on disk for the child's lifetime.
        let detected_kind = crate::shell::detect(&cmd_str);
        let bootstrap = crate::shell::Bootstrap::prepare(detected_kind, &id);
        if let Some(ref bs) = bootstrap {
            bs.apply_to(&mut cb);
        }
        let child = pair
            .slave
            .spawn_command(cb)
            .map_err(|e| PtyError::SpawnFailed(e.to_string()))?;
        let killer = child.clone_killer();
        let pid = child.process_id();

        // Take writer + reader before we move master into Pty.
        let writer = pair
            .master
            .take_writer()
            .map_err(|e| PtyError::OpenFailed(e.to_string()))?;
        let reader = pair
            .master
            .try_clone_reader()
            .map_err(|e| PtyError::OpenFailed(e.to_string()))?;

        let mut sizes = HashMap::new();
        sizes.insert(owner_client.clone(), (cols, rows));

        let (output_tx, _) = broadcast::channel::<Bytes>(PTY_BROADCAST_CAPACITY);
        let pty = Arc::new(Pty {
            id: id.clone(),
            cmd: cmd_str,
            cwd: cwd.clone(),
            created_at: now_ms(),
            pid,
            master: Mutex::new(pair.master),
            writer: Mutex::new(writer),
            killer: Mutex::new(Some(killer)),
            state: Mutex::new(PtyState {
                cols,
                rows,
                sizes,
                primary: Some(owner_client),
                alive: true,
                ring: PtyRing::new(),
            }),
            output_tx,
            _bootstrap: bootstrap,
        });

        self.ptys.insert(id.clone(), pty.clone());

        // Reader thread.
        let pty_for_reader = Arc::clone(&pty);
        let session_weak = self.session.lock().clone();
        let thread_pty_id = id.clone();
        std::thread::Builder::new()
            .name(format!("motif-pty-{}", thread_pty_id))
            .spawn(move || reader_loop(reader, pty_for_reader, session_weak, thread_pty_id, child))
            .map_err(|e| PtyError::OpenFailed(e.to_string()))?;

        // (Cwd watcher / bootstrap timeout / shell-integration state
        // machine all moved client-side in Phase 5b. Server only
        // streams bytes; shell-integration parsing happens on the
        // /pty/<id> consumer.)

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
                    s.publish_event(|seq| Event::PtyResize {
                        pty_id: pid,
                        cols,
                        rows,
                        seq,
                    });
                }
            }
        }
    }
}

fn reader_loop(
    mut reader: Box<dyn Read + Send>,
    pty: Arc<Pty>,
    session: Option<Weak<Session>>,
    pty_id: PtyId,
    mut child: Box<dyn portable_pty::Child + Send + Sync>,
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
            Ok(0) => break,
            Ok(n) => {
                let scan = scanner.feed(&buf[..n]);
                let live_session = session.as_ref().and_then(|w| w.upgrade());
                // Walk items in arrival order so the BlockState is in
                // the right state when each passthrough chunk is
                // recorded — command-start must move us to Running before the
                // command's stdout flows past, and command-end must
                // finalize *after* the trailing output.
                for item in scan.items {
                    match item {
                        ScanItem::Query { kind, raw } => {
                            if kind.is_shell_integration() {
                                // Server no longer parses shell-integration
                                // OSC; clients do it themselves off the
                                // /pty/<id> stream. Pass the raw bytes
                                // through so client-side parsers see them.
                                {
                                    let mut s = pty.state.lock();
                                    s.ring.append(&raw);
                                }
                                let _ = pty.output_tx.send(Bytes::copy_from_slice(&raw));
                            } else {
                                // Capability query — write canonical or
                                // client-palette response back to the
                                // PTY master. Bytes stay server-side so
                                // late xterm.js auto-answers don't leak
                                // into fish's line editor as fake input.
                                let answer: Option<Vec<u8>> = live_session
                                    .as_ref()
                                    .and_then(|s| s.osc_palette_response(&kind))
                                    .map(Some)
                                    .unwrap_or_else(|| kind.canonical_response());
                                if let Some(bytes) = answer {
                                    let _ = pty.write_bytes(&bytes);
                                }
                            }
                        }
                        ScanItem::Bytes(bytes) => {
                            {
                                let mut s = pty.state.lock();
                                s.ring.append(&bytes);
                            }
                            // New protocol fan-out. Cheap-clone via Bytes;
                            // broadcast::Sender drops the frame for any
                            // subscriber that's > PTY_BROADCAST_CAPACITY
                            // frames behind. Slow subscribers get a
                            // `Lagged` on `recv()` and the WS handler
                            // closes them with a truncate code.
                            let _ = pty.output_tx.send(Bytes::copy_from_slice(&bytes));
                        }
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
        _ => i32::MIN,
    };
    let exit_code = if exit_code == i32::MIN {
        None
    } else {
        Some(exit_code)
    };

    if let Some(ref weak) = session {
        if let Some(sess) = weak.upgrade() {
            // Drop the entry from the pool BEFORE the broadcast: clients that
            // call pty.list immediately after seeing pty.exited won't see a
            // ghost entry.
            sess.pty_pool.remove(&pty_id);
            let pid_for_event = pty_id.clone();
            sess.publish_event(|seq| Event::PtyExited {
                pty_id: pid_for_event,
                exit_code,
                seq,
            });
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

fn now_ms() -> UnixMs {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

#[derive(thiserror::Error, Debug)]
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
