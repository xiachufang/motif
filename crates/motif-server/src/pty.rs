//! Multi-PTY management for a Session.
//!
//! Each Pty holds:
//!   - the master pty handle (for resize)
//!   - a writer (sync; stdin frames arrive rarely enough that brief lock
//!     contention is fine)
//!   - a 2MB ring buffer of recent stdout bytes for replay on attach
//!   - per-client (cols, rows) preferences. The master follows the
//!     currently-active client's size: `primary` is set on creation, on
//!     PTY input (any `/pty/<id>` stdin frame), and on `view.activate`, so
//!     whoever is most recently typing or focusing the tab decides the grid.
//!     Non-primary clients'
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
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{sync_channel, Receiver as MpscReceiver, SyncSender};
use std::sync::{Arc, Weak};
use std::time::{SystemTime, UNIX_EPOCH};

use bytes::Bytes;
use dashmap::DashMap;
use libghostty_vt::fmt::{Format, Formatter, FormatterOptions};
use libghostty_vt::terminal::Mode;
use libghostty_vt::{Terminal, TerminalOptions};
use motif_proto::common::{ClientId, PtyId, UnixMs};
use motif_proto::event::Event;
use motif_proto::pty::{PtyCreateParams, PtyInfo, ShellKind};
use motif_proto::terminal_query::{QueryKind, QueryScanner, ScanItem};
use parking_lot::Mutex;
use portable_pty::{native_pty_system, ChildKiller, CommandBuilder, MasterPty, PtySize};
use tokio::sync::{broadcast, oneshot};

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

/// Worst-case size of a cold-attach VT snapshot, used to size `RING_ORIGIN_BASE`.
/// `formatter_vt_snapshot` serializes the whole scrollback + active screen as
/// per-cell VT, so the bound is (scrollback + a generous screen height) rows ×
/// max width × worst-case bytes per cell. Per-cell worst case is a full SGR run
/// (`ESC[0;1;3;4;5;7;9;38;2;r;g;b;48;2;r;g;b;58;2;r;g;b m`) plus a 4-byte UTF-8
/// grapheme — ~96 bytes; round to 128. Width is capped generously (no real
/// surface is near 1024 cols). A ×4 margin covers the prelude/postlude and any
/// estimate slack.
const MAX_SNAPSHOT_BYTES: u64 =
    (MAX_SCROLLBACK as u64 + 1024) * 1024 /* cols */ * 128 /* bytes/cell */ * 4 /* margin */;

/// Starting value for a ring's absolute byte counter (`origin`/`total`), instead
/// of 0. A cold-attach VT snapshot reports its resume offset as `total -
/// snapshot.len()` so a byte-counting client lands exactly on `total`; when the
/// snapshot is larger than the bytes written so far (common early on — a few
/// bytes can paint a full styled screen that re-serializes to kilobytes) that
/// subtraction would underflow from 0. Basing the counter at `MAX_SNAPSHOT_BYTES`
/// guarantees `total >= snapshot.len()` always. The value (~1.6 GiB) is trivially
/// within u64 and JS `Number.MAX_SAFE_INTEGER`; byte offsets are opaque cursors
/// to every client, nothing assumes they start at 0.
const RING_ORIGIN_BASE: u64 = MAX_SNAPSHOT_BYTES;

/// Lines of scrollback the per-PTY headless emulator (libghostty-vt) keeps
/// for the VT snapshot served on a cold/truncated `/pty/<id>` connect.
const MAX_SCROLLBACK: usize = 2000;

/// Warm-resume crossover: only when the would-be byte delta `[since, total)`
/// exceeds this do we also render a VT snapshot and send whichever is smaller.
/// A delta below this is sent as-is — the bytes are cheap and rendering a
/// snapshot to maybe-not-even-win isn't worth the CPU. Above it, a churny PTY
/// (progress bars, a redrawing full-screen TUI) can make the delta many times
/// the snapshot, which collapses the churn to its rendered result.
const SNAPSHOT_VS_DELTA_THRESHOLD: usize = 256 * 1024;

/// Depth of the reader→emulator command channel. Bounded so a slow emulator
/// applies backpressure to the PTY reader (and thus the OS pty buffer / the
/// program) instead of growing unboundedly. ~256 chunks at READ_CHUNK ≈ 2 MB.
const EMU_CHANNEL_CAPACITY: usize = 256;

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
    /// Command channel to this PTY's dedicated **emulator thread**, which
    /// owns the byte ring, the live `broadcast::Sender`, AND a headless
    /// `libghostty_vt::Terminal` (which is `!Send`, so it can never leave that
    /// one thread). All output fan-out, replay/snapshot, and resize go through
    /// here so they stay serialized with `vt_write` on a single thread — see
    /// [`emulator_loop`]. `SyncSender` gives backpressure to the reader.
    emu_tx: SyncSender<EmuCmd>,
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
///   - `origin <= N <= total`    → replay a raw byte delta, unless a VT
///     snapshot is smaller for a large delta.
///   - `None`, `N < origin`, or `N > total` → serve a VT snapshot of the
///     current screen+scrollback instead of closing the socket.
pub(crate) struct PtyRing {
    pub bytes: VecDeque<u8>,
    pub origin: u64,
}

impl PtyRing {
    fn new() -> Self {
        Self {
            bytes: VecDeque::with_capacity(RING_BYTES.min(64 * 1024)),
            origin: RING_ORIGIN_BASE,
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

/// Commands sent to a PTY's [`emulator_loop`] thread. That thread owns the
/// `!Send` `Terminal`, the byte ring, and the live `broadcast::Sender`, so
/// every mutation/query is serialized here.
enum EmuCmd {
    /// A chunk of master output: feed the emulator, append the ring, broadcast.
    Feed(Bytes),
    /// The effective grid changed; resize the headless terminal to match.
    Resize { cols: u16, rows: u16 },
    /// A `/pty/<id>` client wants to (re)attach. The reply carries the bytes to
    /// send before going live plus the live receiver, taken atomically on the
    /// emulator thread so no output is lost or duplicated across the boundary.
    Subscribe {
        since: Option<u64>,
        reply: oneshot::Sender<SubscribeReply>,
    },
    /// CPR (`ESC [ 6 n`) answer. Read the headless terminal's real cursor
    /// position and reply with `ESC [ row ; col R`. Routed through this
    /// ordered channel so it's processed *after* every preceding `Feed`,
    /// i.e. the cursor reflects exactly the bytes seen before the query.
    AnswerCpr { reply: oneshot::Sender<Vec<u8>> },
}

/// Reply to [`EmuCmd::Subscribe`]. The client adopts `start` as its byte
/// cursor, renders `replay`, then consumes live frames from `rx`.
///
/// `replay` is **either**:
///   - a raw byte delta `[since, total)` for a warm incremental resume
///     (`since` lands inside the ring) whose delta is small, `start == since`; or
///   - a full VT **snapshot** (current screen + scrollback + mode/cursor
///     prelude) — for a cold / truncated / stale cursor, OR a warm cursor whose
///     byte delta would be larger than the snapshot — `start == total - len`.
/// The client treats both identically — bytes to feed into its terminal — so
/// the distinction stays internal to [`emulator_loop`]. The snapshot prelude
/// clears the client's surface (scrollback included), so it lands correctly
/// whether the client is fresh or warm.
pub struct SubscribeReply {
    /// Absolute byte offset the client adopts as its resume cursor, chosen so
    /// that after the client counts the `replay` bytes it lands exactly on the
    /// ring `total` (where the live stream resumes). For a warm delta that's
    /// the requested `since`; for a synthetic snapshot it's `total - replay.len()`
    /// (a base offset on the ring keeps that from underflowing). This lets every
    /// client keep the same dead-simple accounting — `cursor = start; cursor +=
    /// each frame` — for both replay kinds, with no snapshot flag on the wire.
    pub start: u64,
    pub replay: Vec<u8>,
    pub rx: broadcast::Receiver<Bytes>,
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
    /// Command currently executing, tracked server-side from shell-integration
    /// OSC 7777 C/D markers so a cold-attaching client (which only gets a VT
    /// snapshot, no markers) can still learn what is running. `None` at a
    /// prompt or when the shell has no integration.
    pub running_command: Option<String>,
    /// Live working directory, tracked server-side from shell-integration OSC 7
    /// / OSC 7777 `Cwd=` markers. Seeded with the spawn cwd; updated as the
    /// shell `cd`s. Surfaced in [`PtyInfo`] so a cold-attaching client (which
    /// only gets a VT snapshot, no markers) recovers the real cwd, and so the
    /// session fswatcher can follow the active PTY's directory.
    pub cwd: PathBuf,
}

impl Pty {
    pub fn info(&self) -> PtyInfo {
        let s = self.state.lock();
        PtyInfo {
            id: self.id.clone(),
            cmd: self.cmd.clone(),
            // Live cwd, tracked server-side from shell-integration OSC 7 markers
            // (seeded with the spawn cwd). Carrying it here lets a cold-attaching
            // client — which only gets a VT snapshot, no markers — recover the
            // real directory after a `cd`.
            cwd: s.cwd.clone(),
            cols: s.cols,
            rows: s.rows,
            alive: s.alive,
            created_at: self.created_at,
            running_command: s.running_command.clone(),
        }
    }

    /// (Re)attach a `/pty/<id>` client. Routes through the emulator thread so
    /// the replay decision (byte-delta vs. VT snapshot), the byte cursor, and
    /// the live `broadcast::Receiver` are taken atomically with `vt_write` on a
    /// single thread — no output can fall between them.
    ///
    /// `since`:
    ///   - `Some(n)` inside the ring → raw delta `[n, total)`, `start = n` —
    ///     UNLESS that delta exceeds [`SNAPSHOT_VS_DELTA_THRESHOLD`] and a VT
    ///     snapshot of the current state is smaller, in which case the snapshot
    ///     is sent instead (`start = total - snapshot.len()`).
    ///   - `None` (tail), `n < origin` (truncated), or `n > total` (stale) →
    ///     a full VT snapshot of the current screen+scrollback,
    ///     `start = total - snapshot.len()`.
    ///
    /// Returns `None` if the emulator thread is gone (PTY already exited).
    pub async fn subscribe(&self, since: Option<u64>) -> Option<SubscribeReply> {
        let (tx, rx) = oneshot::channel();
        // Non-blocking unless the bounded channel is full (slow emulator);
        // a failed send means the emulator thread has exited.
        if self
            .emu_tx
            .send(EmuCmd::Subscribe { since, reply: tx })
            .is_err()
        {
            return None;
        }
        rx.await.ok()
    }

    pub fn write_bytes(&self, data: &[u8]) -> std::io::Result<()> {
        let mut w = self.writer.lock();
        w.write_all(data)?;
        w.flush()
    }

    /// CPR (`ESC [ 6 n`) response bytes, answered from the headless emulator's
    /// real cursor position rather than a fixed sentinel. Synchronously asks
    /// the emulator thread (ordered behind every prior `Feed`, so the cursor
    /// is as of the bytes seen before this query). Falls back to the static
    /// `ESC [ 1 ; 1 R` if the emulator thread is gone or doesn't reply — same
    /// behaviour as before this fix.
    fn cpr_response(&self) -> Vec<u8> {
        let fallback = || {
            QueryKind::Cpr
                .canonical_response()
                .unwrap_or_else(|| b"\x1b[1;1R".to_vec())
        };
        let (tx, rx) = oneshot::channel();
        if self.emu_tx.send(EmuCmd::AnswerCpr { reply: tx }).is_err() {
            return fallback();
        }
        rx.blocking_recv().unwrap_or_else(|_| fallback())
    }

    /// Returns Some(actually-applied size) if it changed.
    pub fn set_client_size(&self, client: ClientId, cols: u16, rows: u16) -> Option<(u16, u16)> {
        let mut s = self.state.lock();
        s.sizes.insert(client, (cols, rows));
        let (eff_c, eff_r) =
            compute_effective(&s.sizes, s.primary.as_ref()).unwrap_or((cols, rows));
        apply_size(&mut s, &self.master, &self.emu_tx, eff_c, eff_r)
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
        apply_size(&mut s, &self.master, &self.emu_tx, eff_c, eff_r)
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
        apply_size(&mut s, &self.master, &self.emu_tx, eff_c, eff_r)
    }

    pub fn kill(&self) {
        if let Some(mut k) = self.killer.lock().take() {
            let _ = k.kill();
        }
    }

    pub fn is_alive(&self) -> bool {
        self.state.lock().alive
    }

    /// Hand a chunk of master output to the emulator thread, which feeds the
    /// headless terminal, appends the ring, and broadcasts to live subscribers
    /// (all serialized there). Blocks the reader thread if the bounded command
    /// channel is full (backpressure); a closed channel (emulator gone) drops
    /// the chunk silently — the PTY is exiting.
    fn feed(&self, data: &[u8]) {
        let _ = self.emu_tx.send(EmuCmd::Feed(Bytes::copy_from_slice(data)));
    }
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

/// Bump state + resize the master if the target differs from current. Also
/// mirrors the new grid into the headless emulator so its snapshot reflows to
/// match what the program now renders at.
fn apply_size(
    state: &mut PtyState,
    master: &Mutex<Box<dyn MasterPty + Send>>,
    emu_tx: &SyncSender<EmuCmd>,
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
    let _ = emu_tx.send(EmuCmd::Resize {
        cols: eff_c,
        rows: eff_r,
    });
    Some((eff_c, eff_r))
}

pub struct PtyPool {
    next_id: parking_lot::Mutex<u64>,
    ptys: DashMap<PtyId, Arc<Pty>>,
    /// Serializes PTY creation against Session shutdown. Without this lock a
    /// destroy could snapshot/kill the pool while a concurrent `pty.create`
    /// inserts a new child immediately afterward.
    lifecycle: parking_lot::Mutex<()>,
    closed: AtomicBool,
    /// Back-pointer to owning Session so the reader threads can publish events.
    /// Set after Session::new completes; weak to avoid cycles.
    session: parking_lot::Mutex<Option<Weak<Session>>>,
}

impl PtyPool {
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            next_id: parking_lot::Mutex::new(0),
            ptys: DashMap::new(),
            lifecycle: parking_lot::Mutex::new(()),
            closed: AtomicBool::new(false),
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
        let _lifecycle = self.lifecycle.lock();
        if self.closed.load(Ordering::Acquire) {
            return Err(PtyError::ShuttingDown);
        }
        if self.ptys.len() >= MAX_PTYS {
            return Err(PtyError::LimitReached);
        }

        let id = {
            let mut n = self.next_id.lock();
            *n += 1;
            format!("sh-{}", *n)
        };

        let is_default_cmd = params.cmd.is_none();
        let cmd_str = params.cmd.clone().unwrap_or_else(default_shell);
        let detected_kind = crate::shell::detect(&cmd_str);
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
        if should_launch_default_zsh_as_login_shell(is_default_cmd, detected_kind, &cmd_str) {
            cb.arg("-l");
        }
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
        let bootstrap = crate::shell::Bootstrap::prepare(detected_kind, &id);
        if let Some(ref bs) = bootstrap {
            bs.apply_to(&mut cb);
        }
        // Inject the owning session's name so the Claude Code notify hook can
        // tell motifd which session it fired in (for live-event routing +
        // notification deep-linking). MOTIF_HOOK_SOCK itself is inherited from
        // motifd's process env on Unix. Best-effort: skip if the back-pointer
        // isn't wired yet.
        if let Some(sess) = self.session() {
            cb.env("MOTIF_SESSION_NAME", &sess.name);
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

        // Per-PTY emulator thread: owns the byte ring, the live broadcast
        // Sender, and the `!Send` headless Terminal. Reader → Feed → here.
        let (emu_tx, emu_rx) = sync_channel::<EmuCmd>(EMU_CHANNEL_CAPACITY);
        {
            let emu_pty_id = id.clone();
            std::thread::Builder::new()
                .name(format!("motif-emu-{}", emu_pty_id))
                .spawn(move || emulator_loop(emu_rx, cols, rows))
                .map_err(|e| PtyError::OpenFailed(e.to_string()))?;
        }

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
                running_command: None,
                cwd: cwd.clone(),
            }),
            emu_tx,
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

    /// Stop accepting new PTYs and terminate every child currently owned by
    /// this pool. Reader threads remove their entries after observing EOF.
    pub fn shutdown(&self) {
        let _lifecycle = self.lifecycle.lock();
        if self.closed.swap(true, Ordering::AcqRel) {
            return;
        }
        let ptys: Vec<Arc<Pty>> = self.ptys.iter().map(|entry| entry.clone()).collect();
        for pty in ptys {
            pty.kill();
        }
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
                    s.publish_pty_resize(entry.id.clone(), cols, rows);
                }
            }
        }
    }
}

/// Advance the per-PTY running-command tracker for one shell-integration
/// marker. `running` is the authoritative state surfaced in [`PtyInfo`];
/// `pending` carries the explicit command text (OSC 7777;E) seen just before a
/// command-start marker (OSC 7777;C), since fish emits the text separately and
/// slightly earlier. Non-command markers (prompt start/end, cwd, context) leave
/// both untouched.
fn track_running_command(
    running: &mut Option<String>,
    pending: &mut Option<String>,
    kind: &QueryKind,
) {
    match kind {
        QueryKind::Osc7770Cmd { text } => *pending = Some(text.clone()),
        QueryKind::Osc133CmdStart { cmdline_url } => {
            *running = Some(
                cmdline_url
                    .clone()
                    .or_else(|| pending.take())
                    .unwrap_or_default(),
            );
        }
        QueryKind::Osc133CmdEnd { .. } => {
            *running = None;
            *pending = None;
        }
        _ => {}
    }
}

/// Update the tracked cwd from one shell-integration marker. Returns `true` if
/// it changed (the caller re-points the session fswatcher). Only OSC 7 / OSC
/// 7777 `Cwd=` markers move it — both parse to [`QueryKind::Osc7Cwd`]; other
/// markers leave it untouched. A marker repeating the current cwd (the common
/// case — shells emit OSC 7 on every prompt) returns `false`, so we don't
/// thrash the watcher.
fn track_cwd(cwd: &mut PathBuf, kind: &QueryKind) -> bool {
    match kind {
        QueryKind::Osc7Cwd { path } if path != cwd => {
            *cwd = path.clone();
            true
        }
        _ => false,
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
    // Explicit command text (OSC 7777;E) arrives just before the command-start
    // marker (7777;C); stash it here so the C transition can name the command.
    let mut pending_cmd: Option<String> = None;
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
                                // Clients still parse shell-integration OSC off
                                // the /pty/<id> stream themselves, so pass the
                                // raw bytes through verbatim. But also track the
                                // running command server-side: a cold-attaching
                                // client only gets a VT snapshot (no markers),
                                // so this is the only way it can learn what is
                                // currently executing. Likewise track the cwd
                                // from OSC 7 markers so cold attach recovers the
                                // real directory and the fswatcher can follow it.
                                let cwd_changed = {
                                    let mut s = pty.state.lock();
                                    track_running_command(
                                        &mut s.running_command,
                                        &mut pending_cmd,
                                        &kind,
                                    );
                                    track_cwd(&mut s.cwd, &kind)
                                };
                                // Re-point the session fswatcher (only acts if
                                // this PTY is the active view). Done outside the
                                // state lock.
                                if cwd_changed {
                                    if let Some(sess) = live_session.as_ref() {
                                        sess.note_pty_cwd_changed(&pty_id);
                                    }
                                }
                                pty.feed(&raw);
                            } else if matches!(kind, QueryKind::Cpr) {
                                // Cursor Position Report must reflect the real
                                // cursor, not a fixed sentinel: full-screen TUIs
                                // (claude/Ink) use CPR for cursor tracking and
                                // width probing, so a constant 1;1 mangles their
                                // layout. Answer from the headless emulator's
                                // live position (ordered behind the bytes fed
                                // above). Bytes stay server-side, same as the
                                // other capability queries.
                                let _ = pty.write_bytes(&pty.cpr_response());
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
                            // New protocol fan-out, via the emulator thread:
                            // it feeds the headless terminal, appends the ring,
                            // and broadcasts. The bounded command channel drops
                            // frames for no one — instead a slow emulator blocks
                            // this reader (backpressure to the OS pty buffer).
                            // Live WS subscribers that fall > PTY_BROADCAST_CAPACITY
                            // behind still get a `Lagged` and are closed by the
                            // WS handler.
                            pty.feed(&bytes);
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
            // Drop any in-flight resize for this PTY so it can't flush after the
            // exit and resurrect geometry for a tab that's gone.
            sess.cancel_coalesced_resize(&pty_id);
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

/// Per-PTY emulator thread. Owns the byte ring, the live `broadcast::Sender`,
/// and a headless `libghostty_vt::Terminal` (`!Send`/`!Sync` — must stay on
/// this one thread). Handles `Feed`/`Resize`/`Subscribe` in arrival order, so a
/// `Subscribe` observes ring + terminal state exactly as of the feeds before
/// it and the live receiver it returns begins right after — nothing falls
/// between the snapshot/delta and the live stream. Exits when every sender
/// (the `Pty` and its reader thread) has dropped.
/// Build a headless emulator terminal as a passive observer: it never writes
/// query responses back into the PTY (the reader's QueryScanner already answers
/// capability queries). Returns `None` if libghostty can't allocate it — the
/// caller then degrades to byte-delta replay only (no cold-attach snapshot).
fn new_emulator_terminal(cols: u16, rows: u16) -> Option<Terminal<'static, 'static>> {
    // Deliberately register NO effect handlers. libghostty-vt's `on_*`
    // registration hands the C side a pointer to `self.vtable` (a field inside
    // this `Terminal`) as the callback userdata — but we move the `Terminal`
    // out of here, into `emulator_loop`'s local, and again on every resize
    // rebuild (`term = fresh`). Each move relocates `vtable`, leaving the C
    // side holding a dangling userdata pointer. A query that triggers a pty
    // write (e.g. DECRQM `ESC[?…$p` → sendModeReport) would then dereference
    // it inside `vt_write` and SIGBUS. We don't need the callback anyway: the
    // reader's QueryScanner answers capability queries server-side, and
    // unhandled pty-write effects are silently ignored (which is what we want).
    Terminal::new(TerminalOptions {
        cols,
        rows,
        max_scrollback: MAX_SCROLLBACK,
    })
    .ok()
}

fn emulator_loop(rx: MpscReceiver<EmuCmd>, cols: u16, rows: u16) {
    let (output_tx, _) = broadcast::channel::<Bytes>(PTY_BROADCAST_CAPACITY);
    let mut ring = PtyRing::new();
    let mut cur_cols = cols;
    // If the headless terminal can't be created we still serve byte deltas;
    // only the cold-attach VT snapshot degrades (to empty).
    let mut term = new_emulator_terminal(cols, rows);

    // Carry-over slot for one command pulled off the channel during resize
    // coalescing (see the `Resize` arm). std's mpsc can't un-receive, so the
    // non-`Resize` command that ends a coalesced burst is stashed here and
    // processed next instead of blocking on `recv`.
    let mut pending: Option<EmuCmd> = None;
    loop {
        let cmd = match pending.take() {
            Some(c) => c,
            None => match rx.recv() {
                Ok(c) => c,
                Err(_) => break,
            },
        };
        match cmd {
            EmuCmd::Feed(bytes) => {
                if let Some(t) = term.as_mut() {
                    t.vt_write(&bytes);
                }
                ring.append(&bytes);
                let _ = output_tx.send(bytes);
            }
            EmuCmd::Resize { mut cols, mut rows } => {
                // Coalesce a burst of resizes. A web client dragging the window
                // edge emits a `Resize` per character-cell the grid crosses;
                // each *column* change below rebuilds the terminal and replays
                // the whole ring (up to 2 MB), so an un-collapsed burst pins
                // this thread and — because `Feed` shares this bounded channel —
                // back-pressures the PTY reader into a stall. Drain `Resize`
                // commands already queued behind this one, keeping only the last
                // target, so a drag does a single rebuild at the final size. The
                // first non-`Resize` we peek is stashed in `pending` (we can't
                // un-receive it) and handled next, preserving the ordering
                // `Feed`/`Subscribe`/`AnswerCpr` depend on.
                while let Ok(next) = rx.try_recv() {
                    match next {
                        EmuCmd::Resize { cols: c, rows: r } => {
                            cols = c;
                            rows = r;
                        }
                        other => {
                            pending = Some(other);
                            break;
                        }
                    }
                }
                if cols == cur_cols {
                    // Rows-only change: ghostty's row resize is safe.
                    if let Some(t) = term.as_mut() {
                        let _ = t.resize(cols, rows, 0, 0);
                    }
                } else {
                    // Column change: ghostty's `PageList.resizeCols` integer-
                    // overflows (and hard-aborts the process — a Zig panic is
                    // not a catchable Rust unwind) when shrinking columns with a
                    // large scrollback. Sidestep that reflow path entirely by
                    // rebuilding the terminal at the new width and replaying the
                    // ring — laying content out by feeding is overflow-proof and
                    // reflows scrollback to the new width correctly.
                    let mut fresh = new_emulator_terminal(cols, rows);
                    if let Some(t) = fresh.as_mut() {
                        let bytes: Vec<u8> = ring.bytes.iter().copied().collect();
                        t.vt_write(&bytes);
                    }
                    term = fresh;
                    cur_cols = cols;
                }
            }
            EmuCmd::Subscribe { since, reply } => {
                let total = ring.total();
                let origin = ring.origin;
                let (start, replay) = match since {
                    // Warm incremental resume. Normally a raw byte delta
                    // `[s, total)` with start == s, so the client counting the
                    // delta lands on `total`. But when that delta is large, a VT
                    // snapshot can be far smaller (it collapses redraw churn to
                    // the rendered screen), so build it and send whichever is
                    // fewer bytes. The snapshot's prelude clears the client's
                    // surface — scrollback included — so it lands correctly over
                    // the warm client's existing state, exactly like a cold one.
                    Some(s) if s >= origin && s <= total => {
                        let skip = (s - origin) as usize;
                        let delta_len = ring.bytes.len() - skip; // == total - s
                        let snap = if delta_len > SNAPSHOT_VS_DELTA_THRESHOLD {
                            term.as_ref().map(formatter_vt_snapshot)
                        } else {
                            None
                        };
                        match snap {
                            Some(snap) if !snap.is_empty() && snap.len() < delta_len => {
                                (total.saturating_sub(snap.len() as u64), snap)
                            }
                            _ => (
                                s,
                                ring.bytes.iter().skip(skip).copied().collect::<Vec<u8>>(),
                            ),
                        }
                    }
                    // Cold (None) / truncated (s<origin) / stale (s>total):
                    // full VT snapshot. The snapshot is SYNTHETIC (not ring
                    // bytes), but the client counts every frame it receives, so
                    // report start = total - snapshot.len(): after counting the
                    // snapshot the cursor lands on `total` and the next resume is
                    // a warm delta. `RING_ORIGIN_BASE` keeps this from
                    // underflowing when the snapshot is larger than `total`.
                    _ => {
                        let snap = term.as_ref().map(formatter_vt_snapshot).unwrap_or_default();
                        (total.saturating_sub(snap.len() as u64), snap)
                    }
                };
                let _ = reply.send(SubscribeReply {
                    start,
                    replay,
                    rx: output_tx.subscribe(),
                });
            }
            EmuCmd::AnswerCpr { reply } => {
                // CPR is 1-indexed active-area coords; cursor_x/cursor_y are
                // 0-indexed (same convention the snapshot postlude uses to
                // re-issue `ESC[H`). Fall back to home if the terminal failed
                // to build or the C API errors.
                let bytes = match term.as_ref() {
                    Some(t) => {
                        let cx = t.cursor_x().unwrap_or(0);
                        let cy = t.cursor_y().unwrap_or(0);
                        format!("\x1b[{};{}R", cy + 1, cx + 1).into_bytes()
                    }
                    None => b"\x1b[1;1R".to_vec(),
                };
                let _ = reply.send(bytes);
            }
        }
    }
}

/// Serialize the emulator's current screen + scrollback into a self-contained
/// VT byte stream that, fed to a fresh client terminal, reproduces the visible
/// state and leaves it correctly set up for the subsequent live byte stream.
///
/// Shape: mode/cursor **prelude** → content (`Format::Vt`, per-cell SGR, incl.
/// scrollback) → mode/cursor **postlude**. The Formatter emits content only, so
/// terminal modes (alt-screen, DECCKM, mouse, bracketed paste, …), the cursor
/// position, and its visibility are read back via the C API and re-issued here.
fn formatter_vt_snapshot(term: &Terminal) -> Vec<u8> {
    // Entire active screen + scrollback. With no selection configured, the
    // Formatter covers the whole terminal.
    let content = match Formatter::new(
        term,
        FormatterOptions::new()
            .with_format(Format::Vt)
            .with_trim(false)
            .with_unwrap(false),
    ) {
        Ok(mut f) => {
            let len = f.format_len().unwrap_or(0);
            let mut buf = vec![0u8; len];
            match f.format_buf(&mut buf) {
                Ok(n) => {
                    buf.truncate(n);
                    buf
                }
                Err(_) => Vec::new(),
            }
        }
        Err(_) => Vec::new(),
    };

    let alt = term.mode(Mode::ALT_SCREEN_SAVE).unwrap_or(false);
    let mut out: Vec<u8> = Vec::with_capacity(content.len() + 96);

    // ── Prelude: known, matching state before painting ──
    out.extend_from_slice(b"\x1b[!p"); // DECSTR soft reset (modes/SGR/margins → defaults)
    out.extend_from_slice(if alt { b"\x1b[?1049h" } else { b"\x1b[?1049l" });
    // home + clear screen + clear scrollback (3J) + reset SGR. The 3J makes the
    // snapshot self-contained over ANY prior client surface: fed to a warm
    // client that still holds scrollback up to its old cursor, it wipes that
    // first so the repaint below can't duplicate it. (No-op on a fresh/cold
    // terminal.) On the primary screen 3J clears the primary scrollback we're
    // about to repaint; under alt-screen it no-ops, leaving the primary
    // scrollback beneath untouched — which is what we want there.
    out.extend_from_slice(b"\x1b[H\x1b[2J\x1b[3J\x1b[0m");

    // ── Content (current screen + scrollback) ──
    out.extend_from_slice(&content);

    // ── Re-pad the active screen's trimmed trailing blank rows ──
    // The Formatter drops trailing blank rows of the active screen (even with
    // `trim:false`). When the content has scrolled, feeding it bottom-aligns the
    // last *non-blank* row to the screen's bottom, so the whole active screen
    // lands `K` rows too low (K = trimmed trailing blanks) while the absolute
    // cursor restore below does not move — the client's cursor ends up K rows
    // above where it belongs. This bites full-screen TUIs that render relative
    // to the cursor (e.g. claude/Ink): the first keystroke lands on the wrong
    // row. Emit K newlines so the content scrolls up into its true position and
    // the cursor restore lands correctly. `content_rows = scrollback + (rows-K)`,
    // so `K = scrollback + rows - content_rows`.
    let rows = term.rows().unwrap_or(0) as usize;
    let scrollback = term.scrollback_rows().unwrap_or(0);
    let content_rows = if content.is_empty() {
        0
    } else {
        content.iter().filter(|&&b| b == b'\n').count() + 1
    };
    let trailing_blank = (scrollback + rows).saturating_sub(content_rows);
    for _ in 0..trailing_blank {
        out.extend_from_slice(b"\r\n");
    }

    // ── Postlude: restore the modes a live TUI/shell stream depends on ──
    let modes: [(Mode, &[u8], &[u8]); 8] = [
        (Mode::DECCKM, b"\x1b[?1h", b"\x1b[?1l"),
        (Mode::WRAPAROUND, b"\x1b[?7h", b"\x1b[?7l"),
        (Mode::BRACKETED_PASTE, b"\x1b[?2004h", b"\x1b[?2004l"),
        (Mode::NORMAL_MOUSE, b"\x1b[?1000h", b"\x1b[?1000l"),
        (Mode::BUTTON_MOUSE, b"\x1b[?1002h", b"\x1b[?1002l"),
        (Mode::ANY_MOUSE, b"\x1b[?1003h", b"\x1b[?1003l"),
        (Mode::SGR_MOUSE, b"\x1b[?1006h", b"\x1b[?1006l"),
        (Mode::FOCUS_EVENT, b"\x1b[?1004h", b"\x1b[?1004l"),
    ];
    for (mode, on_seq, off_seq) in modes {
        let on = term.mode(mode).unwrap_or(false);
        out.extend_from_slice(if on { on_seq } else { off_seq });
    }

    // Cursor position (1-indexed, active-area coords) + visibility.
    if let (Ok(cx), Ok(cy)) = (term.cursor_x(), term.cursor_y()) {
        out.extend_from_slice(format!("\x1b[{};{}H", cy + 1, cx + 1).as_bytes());
    }
    out.extend_from_slice(match term.is_cursor_visible() {
        Ok(false) => b"\x1b[?25l",
        _ => b"\x1b[?25h",
    });

    out
}

fn default_shell() -> String {
    std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".into())
}

fn should_launch_default_zsh_as_login_shell(
    is_default_cmd: bool,
    kind: ShellKind,
    cmd: &str,
) -> bool {
    cfg!(target_os = "macos")
        && is_default_cmd
        && matches!(kind, ShellKind::Zsh)
        && !cmd.contains(' ')
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
    #[error("session is shutting down")]
    ShuttingDown,
    #[error("pty open failed: {0}")]
    OpenFailed(String),
    #[error("pty spawn failed: {0}")]
    SpawnFailed(String),
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::sync::broadcast::error::TryRecvError;

    fn spawn_emu(cols: u16, rows: u16) -> SyncSender<EmuCmd> {
        let (tx, rx) = sync_channel::<EmuCmd>(EMU_CHANNEL_CAPACITY);
        std::thread::spawn(move || emulator_loop(rx, cols, rows));
        tx
    }

    fn feed(tx: &SyncSender<EmuCmd>, b: &[u8]) {
        tx.send(EmuCmd::Feed(Bytes::copy_from_slice(b))).unwrap();
    }

    /// Blocking subscribe for tests. Feed and Subscribe share one ordered
    /// channel, so every feed sent before this call is already reflected when
    /// the reply arrives — which also makes it a barrier (see `flush`).
    fn subscribe(tx: &SyncSender<EmuCmd>, since: Option<u64>) -> SubscribeReply {
        let (rtx, rrx) = oneshot::channel();
        tx.send(EmuCmd::Subscribe { since, reply: rtx }).unwrap();
        rrx.blocking_recv().unwrap()
    }

    /// Barrier: when this returns, every prior Feed has been processed and
    /// broadcast by the emulator thread.
    fn flush(tx: &SyncSender<EmuCmd>) {
        let _ = subscribe(tx, Some(0));
    }

    fn find(haystack: &[u8], needle: &[u8]) -> bool {
        haystack.windows(needle.len()).any(|w| w == needle)
    }

    #[test]
    fn track_running_command_follows_explicit_then_start_then_end() {
        let mut running: Option<String> = None;
        let mut pending: Option<String> = None;

        // Prompt markers don't change anything.
        track_running_command(&mut running, &mut pending, &QueryKind::Osc133PromptStart);
        track_running_command(&mut running, &mut pending, &QueryKind::Osc133PromptEnd);
        assert_eq!(running, None);

        // Explicit command text (7777;E) arrives, then command start (7777;C)
        // promotes it to the running command.
        track_running_command(
            &mut running,
            &mut pending,
            &QueryKind::Osc7770Cmd {
                text: "cargo build".to_string(),
            },
        );
        assert_eq!(running, None, "E alone must not mark running");
        track_running_command(
            &mut running,
            &mut pending,
            &QueryKind::Osc133CmdStart { cmdline_url: None },
        );
        assert_eq!(running.as_deref(), Some("cargo build"));
        assert_eq!(pending, None, "pending text consumed by start");

        // Command end (7777;D) clears it.
        track_running_command(
            &mut running,
            &mut pending,
            &QueryKind::Osc133CmdEnd { exit: Some(0) },
        );
        assert_eq!(running, None);
    }

    #[test]
    fn track_running_command_prefers_cmdline_url_over_pending() {
        let mut running: Option<String> = None;
        let mut pending: Option<String> = Some("stale".to_string());
        // fish's native 133;C carries the authoritative commandline.
        track_running_command(
            &mut running,
            &mut pending,
            &QueryKind::Osc133CmdStart {
                cmdline_url: Some("git status".to_string()),
            },
        );
        assert_eq!(running.as_deref(), Some("git status"));
    }

    #[test]
    fn track_cwd_follows_osc7_and_dedups() {
        let mut cwd = PathBuf::from("/home/me");

        // A new cwd is taken and reported as changed.
        assert!(track_cwd(
            &mut cwd,
            &QueryKind::Osc7Cwd {
                path: "/tmp/foo".into()
            }
        ));
        assert_eq!(cwd, PathBuf::from("/tmp/foo"));

        // The same cwd again (shells emit OSC 7 every prompt) is a no-op — the
        // caller must not thrash the fswatcher.
        assert!(!track_cwd(
            &mut cwd,
            &QueryKind::Osc7Cwd {
                path: "/tmp/foo".into()
            }
        ));
        assert_eq!(cwd, PathBuf::from("/tmp/foo"));

        // A different cwd changes again.
        assert!(track_cwd(
            &mut cwd,
            &QueryKind::Osc7Cwd {
                path: "/tmp/bar".into()
            }
        ));
        assert_eq!(cwd, PathBuf::from("/tmp/bar"));

        // Non-cwd shell-integration markers leave it untouched.
        assert!(!track_cwd(&mut cwd, &QueryKind::Osc133PromptStart));
        assert!(!track_cwd(
            &mut cwd,
            &QueryKind::Osc7770Cmd {
                text: "ls".to_string()
            },
        ));
        assert!(!track_cwd(
            &mut cwd,
            &QueryKind::Osc133CmdEnd { exit: Some(0) },
        ));
        assert_eq!(cwd, PathBuf::from("/tmp/bar"));
    }

    #[test]
    fn warm_resume_prefers_snapshot_when_delta_is_larger() {
        // A churny PTY: a progress line rewritten in place ~20k times. The raw
        // ring delta is ~1 MB, but the rendered screen is a single line — so a
        // VT snapshot is tiny. A warm resume from the very first byte must get
        // the snapshot, not the megabyte delta.
        let tx = spawn_emu(80, 24);
        let mut raw_len = 0usize;
        for i in 0..20_000u32 {
            let line = format!("\rprogress: {i:>6} ................................");
            raw_len += line.len();
            feed(&tx, line.as_bytes());
        }
        assert!(
            raw_len > SNAPSHOT_VS_DELTA_THRESHOLD,
            "test must exceed the threshold"
        );
        assert!(
            raw_len < RING_BYTES,
            "kept under the ring so origin stays at base"
        );

        // `since == RING_ORIGIN_BASE` is the ring's very start: a warm cursor
        // whose delta is the whole ring.
        let reply = subscribe(&tx, Some(RING_ORIGIN_BASE));
        assert!(
            reply.replay.len() < raw_len / 4,
            "expected the small snapshot, got {} bytes vs ~{raw_len} raw delta",
            reply.replay.len()
        );
        assert!(
            find(&reply.replay, b"\x1b[3J"),
            "snapshot must carry the scrollback-clearing prelude"
        );
        // Snapshot cursor accounting: counting the replay lands on `total`.
        assert_ne!(
            reply.start, RING_ORIGIN_BASE,
            "snapshot start != warm since"
        );
    }

    #[test]
    fn warm_resume_keeps_small_delta_raw() {
        // A small warm delta stays a raw byte delta — no snapshot, start == since.
        let tx = spawn_emu(80, 24);
        feed(&tx, b"hello world\r\n");
        let reply = subscribe(&tx, Some(RING_ORIGIN_BASE));
        assert_eq!(
            reply.start, RING_ORIGIN_BASE,
            "small delta resumes at `since`"
        );
        assert!(
            !find(&reply.replay, b"\x1b[3J"),
            "small delta must be raw bytes, not a snapshot"
        );
        assert!(
            find(&reply.replay, b"hello world"),
            "delta carries the raw bytes"
        );
    }

    #[test]
    fn snapshot_repads_trimmed_trailing_blank_rows() {
        // Regression for the cold-replay cursor off-by-one. The libghostty
        // Formatter drops the active screen's trailing blank rows (even with
        // `trim:false`). When content has scrolled, feeding the snapshot
        // bottom-aligns the last *non-blank* row to the screen bottom, shifting
        // the active screen down by the number of trimmed rows while the
        // absolute cursor restore does not move — so a full-screen TUI that
        // renders relative to the cursor (claude/Ink) drew its next keystroke on
        // the wrong row. `formatter_vt_snapshot` re-pads those rows; a faithful
        // snapshot must round-trip to the SAME scrollback depth and cursor row.
        let mut term = new_emulator_terminal(54, 35).unwrap();
        for i in 0..200u32 {
            term.vt_write(format!("line{i}\r\n").as_bytes()); // overflow → scrollback
        }
        // Cursor mid-screen, erase to end → real trailing blank rows below it.
        term.vt_write(b"\x1b[20;5H\x1b[J");
        let orig_cy = term.cursor_y().unwrap();
        let orig_sb = term.scrollback_rows().unwrap();
        assert!(orig_cy < 34, "test needs blank rows below the cursor");
        assert!(orig_sb > 0, "test needs content to have scrolled");

        let snap = formatter_vt_snapshot(&term);
        let mut echo = new_emulator_terminal(54, 35).unwrap();
        echo.vt_write(&snap);

        // Without the re-pad, the trimmed blank rows make `echo` scroll fewer
        // lines (smaller scrollback) and land the content a row too low.
        assert_eq!(
            echo.cursor_y().unwrap(),
            orig_cy,
            "cursor row drifted across snapshot"
        );
        assert_eq!(
            echo.scrollback_rows().unwrap(),
            orig_sb,
            "trailing blank rows lost → active screen shifted relative to the cursor",
        );
    }

    /// Blocking CPR query for tests. Ordered behind every prior Feed, so the
    /// reply reflects the cursor as of the bytes fed before this call.
    fn answer_cpr(tx: &SyncSender<EmuCmd>) -> Vec<u8> {
        let (rtx, rrx) = oneshot::channel();
        tx.send(EmuCmd::AnswerCpr { reply: rtx }).unwrap();
        rrx.blocking_recv().unwrap()
    }

    #[test]
    fn snapshot_roundtrip_is_faithful_with_trailing_blank_rows() {
        // Tall content that scrolls, then cursor parked mid-screen with BLANK
        // rows below it (the claude/TUI shape). If the snapshot trims trailing
        // blank rows but still emits an absolute cursor, the active screen lands
        // bottom-aligned instead of top-aligned → vertical drift. Detect it by
        // round-tripping: feed the snapshot into a fresh emulator of the same
        // size; a faithful snapshot reproduces the same state (same cursor, same
        // re-snapshot bytes).
        let orig = spawn_emu(20, 8);
        for i in 0..20u32 {
            feed(&orig, format!("line{i:02}\r\n").as_bytes());
        }
        feed(&orig, b"\x1b[3;5H\x1b[J"); // cursor row3 col5, erase to end of screen
        let snap = subscribe(&orig, None).replay;

        let echo = spawn_emu(20, 8);
        feed(&echo, &snap);

        assert_eq!(
            answer_cpr(&echo),
            answer_cpr(&orig),
            "cursor drifted after replaying the snapshot"
        );
        assert_eq!(
            subscribe(&echo, None).replay,
            snap,
            "re-snapshot differs → the snapshot is not a faithful reconstruction"
        );
    }

    #[test]
    fn cpr_reports_real_cursor_position() {
        let tx = spawn_emu(80, 24);
        // CUP to row 5, col 10 (1-indexed), then query CPR. The emulator
        // tracks the cursor, so the reply must echo that position — not the
        // old fixed 1;1 sentinel.
        feed(&tx, b"\x1b[5;10H");
        assert_eq!(answer_cpr(&tx), b"\x1b[5;10R");
    }

    #[test]
    fn cpr_on_fresh_terminal_is_home() {
        let tx = spawn_emu(80, 24);
        assert_eq!(answer_cpr(&tx), b"\x1b[1;1R");
    }

    #[test]
    fn decrqm_query_does_not_crash_emulator() {
        // DECRQM (`ESC[?2026$p`, sync-output mode probe) drives libghostty's
        // sendModeReport → pty-write effect. With an `on_pty_write` handler
        // registered on a moved `Terminal`, that path dereferenced a dangling
        // vtable userdata pointer and SIGBUS'd the emulator thread. We now
        // register no handlers, so the report is silently ignored. Feeding it
        // then getting a live subscribe reply proves the thread survived.
        let tx = spawn_emu(80, 24);
        feed(&tx, b"\x1b[?2026$p");
        feed(&tx, b"hello");
        let r = subscribe(&tx, None);
        assert!(find(&r.replay, b"hello"));
    }

    #[test]
    fn warm_delta_replays_tail_then_streams_live_once() {
        let tx = spawn_emu(80, 24);
        feed(&tx, b"abcdef");
        let r = subscribe(&tx, Some(RING_ORIGIN_BASE + 2));
        assert_eq!(r.start, RING_ORIGIN_BASE + 2);
        assert_eq!(r.replay, b"cdef");

        let mut rx = r.rx;
        assert!(matches!(rx.try_recv(), Err(TryRecvError::Empty)));
        feed(&tx, b"gh");
        flush(&tx); // ensure "gh" was processed + broadcast
        assert_eq!(&rx.try_recv().unwrap()[..], b"gh");
        assert!(matches!(rx.try_recv(), Err(TryRecvError::Empty)));
    }

    #[test]
    fn up_to_date_cursor_has_empty_delta() {
        let tx = spawn_emu(80, 24);
        feed(&tx, b"abc");
        let r = subscribe(&tx, Some(RING_ORIGIN_BASE + 3));
        assert_eq!(r.start, RING_ORIGIN_BASE + 3);
        assert!(r.replay.is_empty());
    }

    #[test]
    fn stale_cursor_falls_back_to_snapshot() {
        let tx = spawn_emu(80, 24);
        feed(&tx, b"abc");
        let total = RING_ORIGIN_BASE + 3;
        // since > total → cold path: snapshot, with start chosen so counting the
        // snapshot bytes lands the client's cursor on `total`.
        let r = subscribe(&tx, Some(total + 100));
        assert!(!r.replay.is_empty());
        assert_eq!(r.start + r.replay.len() as u64, total);
    }

    #[test]
    fn snapshot_then_resume_is_warm_not_another_snapshot() {
        // Tab-switch regression: a client that counts every byte it receives
        // must, after a cold snapshot, land its cursor exactly on `total` so the
        // next resume is a warm delta. Previously the snapshot reported
        // start=total, so counting the snapshot bytes overshot total → every
        // reactivate was classified stale → perpetual full-screen snapshots
        // (which scrambled the cursor on tab switch).
        let tx = spawn_emu(80, 24);
        feed(&tx, b"hello world");
        flush(&tx);
        let r1 = subscribe(&tx, None); // cold → snapshot
        assert!(!r1.replay.is_empty());
        // Emulate the client's accounting: adopt start, then count rendered bytes.
        let client_cursor = r1.start + r1.replay.len() as u64;

        // More output arrives while the tab is "inactive".
        feed(&tx, b" more");
        flush(&tx);

        // Reactivate with the landed cursor: must be a warm delta of just the
        // new bytes, not another snapshot.
        let r2 = subscribe(&tx, Some(client_cursor));
        assert_eq!(r2.start, client_cursor);
        assert_eq!(r2.replay, b" more");
    }

    #[test]
    fn column_shrink_with_scrollback_does_not_crash() {
        // Regression: ghostty's PageList.resizeCols integer-overflows (and
        // hard-aborts the process) when shrinking columns with a large
        // scrollback. The emulator rebuilds from the ring on column change to
        // avoid that reflow path. If the bug regressed, this test aborts the
        // whole test process rather than failing — that's the intended alarm.
        let tx = spawn_emu(80, 24);
        for i in 0..5000u32 {
            feed(&tx, format!("line {i}\r\n").as_bytes());
        }
        tx.send(EmuCmd::Resize { cols: 40, rows: 20 }).unwrap();
        let r = subscribe(&tx, None);
        assert!(!r.replay.is_empty());
        // Scrollback survives the rebuild (most-recent line is present).
        assert!(
            find(&r.replay, b"line 4999"),
            "snapshot lost recent scrollback after reflow"
        );
    }

    #[test]
    fn cold_attach_snapshot_includes_scrollback_and_collapses_churn() {
        let tx = spawn_emu(80, 24);
        let mut fed = 0usize;
        // 200 distinct lines → scrollback (well past 24 visible rows).
        for i in 0..200u32 {
            let line = format!("scrollback line {i}\r\n");
            fed += line.len();
            feed(&tx, line.as_bytes());
        }
        // In-place redraw churn on a single line.
        for i in 0..4000u32 {
            let p = format!("\rprogress {i}");
            fed += p.len();
            feed(&tx, p.as_bytes());
        }

        let r = subscribe(&tx, None);
        // Cold attach → snapshot. start is chosen so that after the client
        // counts the snapshot bytes its cursor lands on `total` (= base + fed),
        // making the next resume a warm delta.
        assert_eq!(
            r.start + r.replay.len() as u64,
            RING_ORIGIN_BASE + fed as u64
        );
        assert!(!r.replay.is_empty());
        // Redraw churn collapses: the snapshot is a tiny fraction of fed bytes.
        assert!(
            r.replay.len() < fed / 10,
            "snapshot {} not << fed {}",
            r.replay.len(),
            fed
        );
        // Scrollback is captured: the oldest line survives into the snapshot.
        assert!(
            find(&r.replay, b"scrollback line 0"),
            "snapshot should contain the oldest scrollback line"
        );
    }

    #[test]
    fn burst_resizes_coalesce_to_last_without_dropping_commands() {
        // A drag emits many `Resize`s back-to-back; the emulator coalesces a
        // queued burst to its last target (one rebuild) and must NOT drop the
        // non-`Resize` command that ends the burst. Queue several resizes then
        // a Feed, all without yielding, so they're all sitting in the channel
        // when the emulator wakes. The final width must be the last resize's,
        // and the trailing Feed must survive into the snapshot.
        let tx = spawn_emu(80, 24);
        feed(&tx, b"before-resize\r\n");
        // All sent before the emulator can drain them → one coalesced burst.
        for w in [70u16, 60, 50, 40] {
            tx.send(EmuCmd::Resize { cols: w, rows: 24 }).unwrap();
        }
        feed(&tx, b"after-resize\r\n");

        // `subscribe` is ordered behind everything above, so by the time it
        // replies the burst has been coalesced and the trailing feed applied.
        let r = subscribe(&tx, None);
        // The post-burst Feed wasn't swallowed by coalescing.
        assert!(
            find(&r.replay, b"after-resize"),
            "the command ending a coalesced resize burst was dropped"
        );
        // Content from before the burst survived the single rebuild+replay.
        assert!(find(&r.replay, b"before-resize"));
    }
}
