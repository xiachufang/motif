//! Per-session state: subscribers, event bus, ring buffer, PTY pool.

pub mod manager;

use std::collections::{HashMap, HashSet, VecDeque};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Weak};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use motif_proto::common::{ClientId, PtyId, Seq, SessionId, UnixMs};
use motif_proto::event::Event;
use motif_proto::remote_port::RemotePortMapping;
use motif_proto::session::{ClientInfo, SessionInfo};
use motif_proto::terminal_query::QueryKind;
use motif_proto::view::{ViewId, ViewInfo, ViewSpec};
use parking_lot::Mutex;
use tokio::sync::{broadcast, watch, Notify};

use crate::pty::PtyPool;

const RING_CAPACITY: usize = 4096; // events buffered for replay
const BROADCAST_CAPACITY: usize = 4096;

/// Trailing window for `publish_coalesced`. A burst of same-key last-wins
/// events (rapid tab switching, a resize storm) collapses to its final value
/// once this much quiet has elapsed — see [`Session::publish_coalesced`].
const COALESCE_WINDOW: Duration = Duration::from_millis(40);

struct PublishState {
    seq: Seq,
    ring: VecDeque<Arc<Event>>,
}

/// Identifies a stream of last-wins events that should collapse to its most
/// recent value. Only used for scalar state with no cross-event ordering
/// dependency — notably NOT `view.moved` (whose `order` would go stale against
/// an interleaved open/close) or any lifecycle/output event.
#[derive(Clone, PartialEq, Eq, Hash)]
enum CoalesceKey {
    ViewActive,
    Theme,
    PtyResize(PtyId),
}

/// A coalesced event awaiting its trailing-window flush. `build` is the same
/// `FnOnce(Seq) -> Event` shape `publish_event` takes — the seq is assigned at
/// flush time so the ring stays monotonic with whatever was published meanwhile.
struct Pending {
    deadline: Instant,
    build: Box<dyn FnOnce(Seq) -> Event + Send>,
}

pub struct Session {
    pub id: SessionId,
    pub name: String,
    pub workdir: PathBuf,
    pub created_at: UnixMs,

    /// Seq counter and replay ring share one mutex so `publish_event` can
    /// allocate a seq, push to the ring, and broadcast under a single
    /// critical section. With separate locks two concurrent publishers
    /// (PTY reader threads, RPC handlers, fswatch forwarder) could
    /// interleave seq allocation with ring/broadcast pushes — leaving the
    /// ring out of seq order, which corrupts replay-after-reconnect
    /// (`session.attach { last_seq }` slices the ring by seq position).
    publish: Mutex<PublishState>,
    clients: Mutex<Vec<ClientInfo>>,
    tx: broadcast::Sender<Arc<Event>>,

    /// One-way lifecycle latch. `SessionManager::destroy` sets this exactly
    /// once, then every events/PTY/TCP WebSocket observes `shutdown_tx` and
    /// exits. The atomic also lets late upgrades and attach races reject a
    /// Session whose `Arc` was obtained just before it left the manager map.
    destroyed: AtomicBool,
    shutdown_tx: watch::Sender<bool>,

    pub pty_pool: Arc<PtyPool>,

    /// Synced tab list. Order matters (UI renders left-to-right). Mutated by
    /// view.* RPCs and PTY lifecycle hooks.
    views: Mutex<Vec<ViewInfo>>,
    active_view: Mutex<Option<ViewId>>,

    /// Filesystem watcher rooted at `workdir`. Spawned lazily when the first
    /// client calls `fs.watch`; dropped when the last subscriber leaves
    /// (`fs.unwatch` or detach). The forwarder thread holds a `Weak<Session>`
    /// so this can be torn down without leaks.
    fswatcher: Mutex<Option<crate::fswatch::FsWatcher>>,

    /// Per-client opt-in to `tree.changed` / `git.changed`. Empty by default
    /// — neither event is emitted nor delivered while this set is empty, and
    /// `fswatcher` stays `None`. Toggled by `fs.watch` / `fs.unwatch` RPCs
    /// and cleaned up on `detach_client`.
    fs_subscribers: Mutex<HashSet<ClientId>>,

    /// Latest client-reported terminal palette as `(fg, bg)`, where each is
    /// the rgb portion of an OSC 10/11 reply (e.g. `"e6e6/e6e6/e6e6"`).
    /// Updated on `session.attach`; consulted by the PTY reader when it
    /// needs to answer an OSC 10/11 query from the shell. Latest writer
    /// wins under multi-client mirror — colour queries are rare enough
    /// that this is fine, and matches the rest of the mirror semantics.
    term_palette: Mutex<Option<(String, String)>>,

    /// Session-wide effective light/dark theme (`"light"` / `"dark"`), set by
    /// whichever client is currently driving (focused / foreground). Broadcast
    /// via `session.theme_changed` so every attached client renders the whole
    /// UI the same way and PTY output colours match the rendered background.
    theme: Mutex<Option<String>>,

    /// Remote loopback services the user pinned for this session. The client
    /// owns ephemeral local forwarders; motifd owns this session-scoped config.
    remote_ports: Mutex<Vec<RemotePortMapping>>,

    /// Pending last-wins events keyed by stream, flushed after a trailing quiet
    /// window by the `coalesce_task`. Lets a burst of `view.active_changed` /
    /// `session.theme_changed` / `pty.resize` collapse to its final value
    /// *before* hitting the wire — the redundant intermediates never reach any
    /// client. See [`Session::publish_coalesced`].
    coalesce: Mutex<HashMap<CoalesceKey, Pending>>,
    /// Wakes the flush task whenever `coalesce` gains an entry or its nearest
    /// deadline moves earlier.
    coalesce_wake: Arc<Notify>,
    /// The flush task, spawned lazily on the first `publish_coalesced` (so we
    /// pick up the ambient runtime — `Session::new` itself may run off-runtime
    /// in unit tests). Aborted on drop so an idle task can't outlive us.
    coalesce_task: Mutex<Option<tokio::task::JoinHandle<()>>>,
    /// Self-reference handed to the flush task so it can call back into
    /// `publish_event` without keeping the session alive. Set in `new`.
    me: Mutex<Weak<Session>>,
}

impl Session {
    pub fn new(name: impl Into<String>, workdir: PathBuf) -> Arc<Self> {
        let (tx, _) = broadcast::channel::<Arc<Event>>(BROADCAST_CAPACITY);
        let (shutdown_tx, _) = watch::channel(false);
        let s = Arc::new(Self {
            id: ulid::Ulid::new().to_string(),
            name: name.into(),
            workdir,
            created_at: now_ms(),
            publish: Mutex::new(PublishState {
                seq: 0,
                ring: VecDeque::with_capacity(RING_CAPACITY),
            }),
            clients: Mutex::new(Vec::new()),
            tx,
            destroyed: AtomicBool::new(false),
            shutdown_tx,
            pty_pool: PtyPool::new(),
            views: Mutex::new(Vec::new()),
            active_view: Mutex::new(None),
            fswatcher: Mutex::new(None),
            fs_subscribers: Mutex::new(HashSet::new()),
            term_palette: Mutex::new(None),
            theme: Mutex::new(None),
            remote_ports: Mutex::new(Vec::new()),
            coalesce: Mutex::new(HashMap::new()),
            coalesce_wake: Arc::new(Notify::new()),
            coalesce_task: Mutex::new(None),
            me: Mutex::new(Weak::new()),
        });
        // pool + coalesce flush task need a back-reference for publishing events.
        s.pty_pool.set_session(Arc::downgrade(&s));
        *s.me.lock() = Arc::downgrade(&s);
        s
    }

    pub fn info(&self) -> SessionInfo {
        SessionInfo {
            id: self.id.clone(),
            name: self.name.clone(),
            workdir: self.workdir.clone(),
            created_at: self.created_at,
            client_count: self.clients.lock().len() as u32,
        }
    }

    pub fn list_clients(&self) -> Vec<ClientInfo> {
        self.clients.lock().clone()
    }

    pub fn last_seq(&self) -> Seq {
        self.publish.lock().seq
    }

    /// Stash the client-reported terminal palette. `None` for either field
    /// keeps the existing value, so a client that can detect only one of
    /// the two doesn't blow away the other side's previous report.
    pub fn set_terminal_palette(&self, fg: Option<String>, bg: Option<String>) {
        if fg.is_none() && bg.is_none() {
            return;
        }
        let mut p = self.term_palette.lock();
        let (cur_fg, cur_bg) = p.clone().unwrap_or_default();
        let new_fg = fg.unwrap_or(cur_fg);
        let new_bg = bg.unwrap_or(cur_bg);
        if new_fg.is_empty() && new_bg.is_empty() {
            *p = None;
        } else {
            *p = Some((new_fg, new_bg));
        }
    }

    /// The session's current effective light/dark theme, if any client has
    /// reported one.
    pub fn theme(&self) -> Option<String> {
        self.theme.lock().clone()
    }

    pub fn remote_ports(&self) -> Vec<RemotePortMapping> {
        self.remote_ports.lock().clone()
    }

    pub fn add_remote_port(
        &self,
        remote_host: String,
        remote_port: u16,
        local_scheme: String,
    ) -> RemotePortMapping {
        let mapping = RemotePortMapping {
            id: format!("remote-port-{}", ulid::Ulid::new()),
            remote_host,
            remote_port,
            local_scheme,
            created_at: now_ms(),
        };
        self.remote_ports.lock().push(mapping.clone());
        mapping
    }

    pub fn update_remote_port(
        &self,
        id: &str,
        remote_host: String,
        remote_port: u16,
        local_scheme: String,
    ) -> Option<RemotePortMapping> {
        let mut mappings = self.remote_ports.lock();
        let mapping = mappings.iter_mut().find(|m| m.id == id)?;
        mapping.remote_host = remote_host;
        mapping.remote_port = remote_port;
        mapping.local_scheme = local_scheme;
        Some(mapping.clone())
    }

    pub fn remove_remote_port(&self, id: &str) -> bool {
        let mut mappings = self.remote_ports.lock();
        let before = mappings.len();
        mappings.retain(|m| m.id != id);
        mappings.len() != before
    }

    /// Update the session-wide theme. `None` leaves it untouched. When the
    /// value actually changes, broadcast `session.theme_changed` so every
    /// attached client re-renders to match the driving client.
    pub fn set_theme(&self, theme: Option<String>) {
        let Some(theme) = theme else { return };
        {
            let mut t = self.theme.lock();
            if t.as_deref() == Some(theme.as_str()) {
                return;
            }
            *t = Some(theme.clone());
        }
        self.publish_coalesced(CoalesceKey::Theme, |seq| Event::SessionThemeChanged {
            theme,
            seq,
        });
    }

    /// Build the OSC 10/11 reply bytes for `kind` using the cached palette.
    /// Returns `None` if the kind isn't OSC 10/11, or no palette has been
    /// reported, or the requested side is empty — caller falls back to the
    /// canonical default in that case.
    pub fn osc_palette_response(&self, kind: &QueryKind) -> Option<Vec<u8>> {
        let p = self.term_palette.lock();
        let (fg, bg) = p.as_ref()?;
        let (tag, rgb) = match kind {
            QueryKind::Osc10 => ("10", fg),
            QueryKind::Osc11 => ("11", bg),
            _ => return None,
        };
        if rgb.is_empty() {
            return None;
        }
        let mut out = Vec::with_capacity(16 + rgb.len());
        out.extend_from_slice(b"\x1b]");
        out.extend_from_slice(tag.as_bytes());
        out.extend_from_slice(b";rgb:");
        out.extend_from_slice(rgb.as_bytes());
        out.extend_from_slice(b"\x1b\\");
        Some(out)
    }

    pub fn subscribe(&self) -> broadcast::Receiver<Arc<Event>> {
        self.tx.subscribe()
    }

    pub fn is_destroyed(&self) -> bool {
        self.destroyed.load(Ordering::Acquire)
    }

    pub fn subscribe_shutdown(&self) -> watch::Receiver<bool> {
        self.shutdown_tx.subscribe()
    }

    /// Permanently stop this Session and every resource scoped to it.
    /// Idempotent so manager removal and final `Drop` can both call it safely.
    pub fn shutdown(&self) {
        if self.destroyed.swap(true, Ordering::AcqRel) {
            return;
        }

        // Wake socket handlers first so they stop accepting input while PTYs
        // are being terminated. `send_replace` retains the true value even if
        // no receiver exists yet, covering an upgrade that raced with destroy.
        self.shutdown_tx.send_replace(true);

        self.pty_pool.shutdown();
        self.clients.lock().clear();
        self.fs_subscribers.lock().clear();
        let fswatcher = { self.fswatcher.lock().take() };
        drop(fswatcher);
        self.coalesce.lock().clear();
        if let Some(task) = self.coalesce_task.lock().take() {
            task.abort();
        }
    }

    /// Return all buffered events with seq strictly greater than `after`.
    /// `after = 0` means "give me everything in the ring" (used by
    /// freshly-attaching clients to hydrate PTY scrollback). If the client
    /// fell behind past the ring window, they get only what we still have —
    /// they're expected to be idempotent against duplicate frames.
    pub fn replay_since(&self, after: Seq) -> Vec<Arc<Event>> {
        self.publish
            .lock()
            .ring
            .iter()
            .filter(|e| e.seq() > after)
            .cloned()
            .collect()
    }

    pub fn attach_client(&self, client_id: ClientId) -> Option<AttachOutcome> {
        let now = now_ms();
        let mut cs = self.clients.lock();
        if self.is_destroyed() {
            return None;
        }
        let existing = cs.clone();
        cs.push(ClientInfo {
            id: client_id.clone(),
            since: now,
        });
        drop(cs);

        let last_seq = self.publish_event(|seq| Event::ClientJoined {
            client_id,
            since: now,
            seq,
        });

        Some(AttachOutcome { existing, last_seq })
    }

    pub fn detach_client(&self, client_id: &ClientId) -> bool {
        let removed = {
            let mut cs = self.clients.lock();
            let before = cs.len();
            cs.retain(|c| &c.id != client_id);
            cs.len() != before
        };
        if !removed {
            return false;
        }
        self.pty_pool.forget_client_sizes(client_id);
        // Drop any fs subscription this client held, including the per-session
        // fswatcher if they were the last subscriber. Without this, a client
        // that crashes mid-`fs.watch` would pin the watcher forever (or until
        // `Session::destroy`).
        self.remove_fs_subscriber(client_id);
        self.publish_event(|seq| Event::ClientLeft {
            client_id: client_id.clone(),
            seq,
        });
        true
    }

    // ── tree.changed / git.changed subscription ──

    /// Returns true if any client has called `fs.watch` and not yet
    /// unsubscribed / detached. Call sites for `tree.changed` /
    /// `git.changed` consult this before publishing — when no one is
    /// listening we skip both the ring append and the broadcast send.
    pub fn any_fs_subscriber(&self) -> bool {
        !self.fs_subscribers.lock().is_empty()
    }

    pub fn is_fs_subscribed(&self, client_id: &str) -> bool {
        self.fs_subscribers.lock().contains(client_id)
    }

    /// Add `client_id` to the subscriber set; if the set was empty before,
    /// spawn the per-session fswatcher so PTY-driven edits start producing
    /// events. Idempotent — calling twice from the same client is fine.
    pub fn add_fs_subscriber(self: &Arc<Self>, client_id: ClientId) {
        let became_first = {
            let mut subs = self.fs_subscribers.lock();
            let was_empty = subs.is_empty();
            subs.insert(client_id);
            was_empty
        };
        if became_first {
            self.ensure_fswatcher();
        }
    }

    /// Remove `client_id` from the subscriber set; if it was the last
    /// subscriber, tear down the fswatcher. Idempotent.
    pub fn remove_fs_subscriber(&self, client_id: &str) {
        let became_empty = {
            let mut subs = self.fs_subscribers.lock();
            let removed = subs.remove(client_id);
            removed && subs.is_empty()
        };
        if became_empty {
            *self.fswatcher.lock() = None;
        }
    }

    fn ensure_fswatcher(self: &Arc<Self>) {
        let mut guard = self.fswatcher.lock();
        if guard.is_some() {
            return;
        }
        let root = self.desired_watch_root();
        match crate::fswatch::spawn(Arc::downgrade(self), root) {
            Ok(w) => *guard = Some(w),
            Err(e) => {
                tracing::warn!(error = %e, "fs watcher disabled");
            }
        }
    }

    pub fn views_snapshot(&self) -> Vec<ViewInfo> {
        self.views.lock().clone()
    }

    pub fn active_view(&self) -> Option<ViewId> {
        self.active_view.lock().clone()
    }

    /// If `view_id` refers to a Pty view, return the underlying PtyId.
    pub fn pty_id_of_view(&self, view_id: &str) -> Option<PtyId> {
        self.views
            .lock()
            .iter()
            .find(|v| v.id == view_id)
            .and_then(|v| match &v.spec {
                ViewSpec::Pty { pty_id } => Some(pty_id.clone()),
                _ => None,
            })
    }

    /// Append a view + broadcast. If `activate` is true, also update the
    /// session's active view (and broadcast that change).
    pub fn open_view(&self, spec: ViewSpec, activate: bool) -> ViewInfo {
        let info = ViewInfo {
            id: ulid::Ulid::new().to_string(),
            spec,
            created_at: now_ms(),
        };
        self.views.lock().push(info.clone());
        let info_for_event = info.clone();
        self.publish_event(|seq| Event::ViewOpened {
            view: info_for_event,
            seq,
        });
        if activate {
            self.activate_view(Some(info.id.clone()));
        }
        info
    }

    /// Internal: drop a view by id, broadcast view.closed. Returns the
    /// removed entry if there was one. Does NOT side-effect the PTY pool;
    /// callers handle that explicitly so the reader-thread path can avoid
    /// recursing back into kill on an already-dead PTY.
    pub fn close_view_internal(&self, view_id: &str) -> Option<ViewInfo> {
        let mut views = self.views.lock();
        let idx = views.iter().position(|v| v.id == view_id)?;
        let removed = views.remove(idx);
        // Pick a sensible new active if we just removed the active view —
        // fall back to the previous tab in the list, or the next, or None.
        let mut next_active: Option<ViewId> = None;
        let was_active = self.active_view.lock().as_ref() == Some(&removed.id);
        if was_active {
            next_active = views
                .get(idx.saturating_sub(1))
                .map(|v| v.id.clone())
                .or_else(|| views.first().map(|v| v.id.clone()));
        }
        drop(views);

        let removed_id = removed.id.clone();
        self.publish_event(|seq| Event::ViewClosed {
            view_id: removed_id,
            seq,
        });
        if was_active {
            *self.active_view.lock() = next_active.clone();
            let nv = next_active.clone();
            // Same key as `activate_view`, so this fallback replaces any
            // still-pending activation rather than racing it — the coalesce
            // slot always holds the newest active view, never a closed one.
            self.publish_coalesced(CoalesceKey::ViewActive, |seq| Event::ViewActiveChanged {
                view_id: nv,
                seq,
            });
            self.sync_watch_to_active();
        }
        Some(removed)
    }

    /// Public close: removes view and, if it was a Pty view, also kills the
    /// underlying PTY (whose reader thread will then drop the Pty entry).
    pub fn close_view(&self, view_id: &str) -> bool {
        let Some(removed) = self.close_view_internal(view_id) else {
            return false;
        };
        if let ViewSpec::Pty { pty_id } = &removed.spec {
            let _ = self.pty_pool.kill(pty_id);
        }
        true
    }

    /// Find and close the (single) Pty view matching this pty_id. Used by the
    /// PTY reader thread when the child has already exited.
    pub fn close_pty_view(&self, pty_id: &str) {
        let target = {
            let views = self.views.lock();
            views.iter().find_map(|v| match &v.spec {
                ViewSpec::Pty { pty_id: pid } if pid == pty_id => Some(v.id.clone()),
                _ => None,
            })
        };
        if let Some(vid) = target {
            self.close_view_internal(&vid);
        }
    }

    /// Reorder a view to `to_index` (clamped). Broadcasts `view.moved` with
    /// the resulting full order. Returns false if the view doesn't exist or
    /// the move is a no-op.
    pub fn move_view(&self, view_id: &str, to_index: usize) -> bool {
        let order = {
            let mut views = self.views.lock();
            let Some(from) = views.iter().position(|v| v.id == view_id) else {
                return false;
            };
            let to = to_index.min(views.len().saturating_sub(1));
            if from == to {
                return false;
            }
            let v = views.remove(from);
            views.insert(to, v);
            views.iter().map(|v| v.id.clone()).collect::<Vec<_>>()
        };
        self.publish_event(|seq| Event::ViewMoved { order, seq });
        true
    }

    pub fn activate_view(&self, view_id: Option<ViewId>) {
        {
            let mut av = self.active_view.lock();
            if *av == view_id {
                return;
            }
            *av = view_id.clone();
        }
        self.publish_coalesced(CoalesceKey::ViewActive, |seq| Event::ViewActiveChanged {
            view_id,
            seq,
        });
        self.sync_watch_to_active();
    }

    /// Called by the PTY reader when a shell-integration cwd marker changed the
    /// PTY's tracked cwd. Re-points the fswatcher only if the changed PTY is the
    /// currently-active one (cwd of background tabs doesn't affect what the file
    /// tree shows).
    pub fn note_pty_cwd_changed(&self, pty_id: &str) {
        let active_pty = self
            .active_view
            .lock()
            .clone()
            .and_then(|vid| self.pty_id_of_view(&vid));
        if active_pty.as_deref() != Some(pty_id) {
            return;
        }
        self.sync_watch_to_active();
    }

    /// Recompute the desired watch root from the currently-active view and
    /// update the fswatcher if it differs. Idempotent — safe to call from
    /// any of the activation / cwd hooks.
    fn sync_watch_to_active(&self) {
        let target = self.desired_watch_root();
        let mut guard = self.fswatcher.lock();
        let Some(w) = guard.as_mut() else { return };
        if w.root() == target {
            return;
        }
        if let Err(e) = w.swap_root(target.clone()) {
            tracing::warn!(target = %target.display(), error = %e, "swap watch root");
        }
    }

    /// "Where should we watch right now?" — the active PTY's latest known
    /// cwd if there is one, otherwise the session's workdir as a stable
    /// fallback (used when the active view is non-PTY, or no view at all).
    fn desired_watch_root(&self) -> PathBuf {
        let pty_id = self
            .active_view
            .lock()
            .clone()
            .and_then(|vid| self.pty_id_of_view(&vid));
        pty_id
            .and_then(|pid| self.pty_pool.get(&pid))
            .map(|pty| pty.info().cwd)
            .unwrap_or_else(|| self.workdir.clone())
    }

    /// Atomic seq-allocate + ring-record + broadcast. Returns the seq used.
    ///
    /// Holds `publish` across all three steps so two concurrent publishers
    /// can't end up with ring or broadcast deliveries out of seq order. The
    /// `tx.send` itself only enqueues into the broadcast channel (it
    /// returns once subscribers' bounded buffers have a slot or the slowest
    /// is dropped), so holding the lock across it doesn't block on slow
    /// receivers.
    pub fn publish_event<F>(&self, build: F) -> Seq
    where
        F: FnOnce(Seq) -> Event,
    {
        let mut p = self.publish.lock();
        p.seq += 1;
        let seq = p.seq;
        let arc = Arc::new(build(seq));
        if p.ring.len() == RING_CAPACITY {
            p.ring.pop_front();
        }
        p.ring.push_back(arc.clone());
        let _ = self.tx.send(arc);
        seq
    }

    /// Broadcast a last-wins event, but coalesce a burst: stash `build` under
    /// `key` and let the flush task publish only the most recent one after a
    /// `COALESCE_WINDOW` of quiet. A newer event for the same key replaces the
    /// stash and resets the window, so A→B→A→C within the window emits just C.
    ///
    /// Authoritative state (the `active_view` / `theme` / pty-geometry mutexes)
    /// must already be updated by the caller — only the *notification* is
    /// delayed. That keeps `session.attach` snapshots correct: a pending event
    /// that flushes after a reconnect is just an idempotent echo of state the
    /// snapshot already carried.
    ///
    /// Falls back to an immediate `publish_event` when there is no runtime to
    /// host the flush task (off-runtime unit tests) — correctness over latency.
    fn publish_coalesced<F>(&self, key: CoalesceKey, build: F)
    where
        F: FnOnce(Seq) -> Event + Send + 'static,
    {
        if !self.ensure_coalesce_task() {
            self.publish_event(build);
            return;
        }
        self.coalesce.lock().insert(
            key,
            Pending {
                deadline: Instant::now() + COALESCE_WINDOW,
                build: Box::new(build),
            },
        );
        self.coalesce_wake.notify_one();
    }

    /// Coalesced `pty.resize`: a window-resize / rotation storm for one PTY
    /// collapses to its final geometry. Keyed per `pty_id` so concurrent
    /// resizes of different PTYs don't clobber each other.
    pub(crate) fn publish_pty_resize(&self, pty_id: PtyId, cols: u16, rows: u16) {
        self.publish_coalesced(CoalesceKey::PtyResize(pty_id.clone()), move |seq| {
            Event::PtyResize {
                pty_id,
                cols,
                rows,
                seq,
            }
        });
    }

    /// Drop a pending coalesced `pty.resize` without publishing it. Used when
    /// the PTY exits, so a still-pending resize for it would describe geometry
    /// no one can see.
    pub(crate) fn cancel_coalesced_resize(&self, pty_id: &str) {
        self.coalesce
            .lock()
            .remove(&CoalesceKey::PtyResize(pty_id.to_string()));
    }

    /// Ensure the flush task is running. Returns false (and spawns nothing)
    /// when called outside a tokio runtime, signalling the caller to publish
    /// immediately instead.
    fn ensure_coalesce_task(&self) -> bool {
        let mut guard = self.coalesce_task.lock();
        if guard.as_ref().is_some_and(|h| !h.is_finished()) {
            return true;
        }
        if tokio::runtime::Handle::try_current().is_err() {
            return false;
        }
        let weak = self.me.lock().clone();
        let wake = self.coalesce_wake.clone();
        *guard = Some(tokio::spawn(coalesce_flush_loop(weak, wake)));
        true
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        self.shutdown();
    }
}

/// Trailing-window flush loop for [`Session::publish_coalesced`]. Sleeps until
/// the nearest pending deadline (or until woken by a new/earlier entry), then
/// publishes every entry whose window has elapsed. Holds only a `Weak` to the
/// session, so it exits once the session is dropped.
async fn coalesce_flush_loop(weak: Weak<Session>, wake: Arc<Notify>) {
    loop {
        // Nearest deadline across all pending keys (None ⇒ nothing pending).
        let next = {
            let Some(s) = weak.upgrade() else { return };
            let map = s.coalesce.lock();
            map.values().map(|p| p.deadline).min()
        };
        match next {
            None => wake.notified().await,
            Some(deadline) => {
                let now = Instant::now();
                if deadline > now {
                    // A new/earlier entry fires `wake` → restart and recompute.
                    tokio::select! {
                        _ = tokio::time::sleep(deadline - now) => {}
                        _ = wake.notified() => continue,
                    }
                }
                let due: Vec<Box<dyn FnOnce(Seq) -> Event + Send>> = {
                    let Some(s) = weak.upgrade() else { return };
                    let mut map = s.coalesce.lock();
                    let now = Instant::now();
                    let keys: Vec<CoalesceKey> = map
                        .iter()
                        .filter(|(_, p)| p.deadline <= now)
                        .map(|(k, _)| k.clone())
                        .collect();
                    keys.into_iter()
                        .filter_map(|k| map.remove(&k).map(|p| p.build))
                        .collect()
                };
                let Some(s) = weak.upgrade() else { return };
                for build in due {
                    s.publish_event(build);
                }
            }
        }
    }
}

pub struct AttachOutcome {
    pub existing: Vec<ClientInfo>,
    pub last_seq: Seq,
}

fn now_ms() -> UnixMs {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::thread;

    /// Concurrent publishers must observe seq monotonic in the ring.
    /// Pre-fix this would fail with extremely high probability under
    /// MIRI-like scheduling: T1 allocates seq=N and is preempted before
    /// pushing; T2 allocates seq=N+1 and pushes first; ring becomes
    /// [..., N+1, N]. `replay_since(0)` would then return events with
    /// non-monotonic seq, and `session.attach { last_seq }` slicing would
    /// either skip events or replay duplicates depending on the cutoff.
    #[test]
    fn publish_event_keeps_ring_monotonic_under_contention() {
        let s = Session::new("test", PathBuf::from("/tmp"));
        const THREADS: usize = 8;
        const PER_THREAD: usize = 500;

        let mut handles = Vec::with_capacity(THREADS);
        for _ in 0..THREADS {
            let s = s.clone();
            handles.push(thread::spawn(move || {
                for _ in 0..PER_THREAD {
                    s.publish_event(|seq| Event::GitChanged { seq });
                }
            }));
        }
        for h in handles {
            h.join().unwrap();
        }

        let total = THREADS * PER_THREAD;
        let events = s.replay_since(0);
        assert_eq!(
            events.len(),
            total,
            "lost or duplicated events under contention"
        );

        // Seqs must be strictly increasing in ring order. (Not just unique
        // — `replay_since` slices by seq position, so the slice must equal
        // the dense [k+1..N] range for every cutoff k.)
        let mut prev = 0;
        for e in &events {
            let cur = e.seq();
            assert!(cur > prev, "seq order broken: {prev} → {cur}");
            prev = cur;
        }
        assert_eq!(prev, total as Seq);

        // Spot-check the slicing invariant attach relies on.
        let mid = (total / 2) as Seq;
        let after_mid = s.replay_since(mid);
        assert_eq!(after_mid.len(), total - mid as usize);
        assert_eq!(after_mid.first().unwrap().seq(), mid + 1);
    }

    #[test]
    fn remote_ports_are_session_scoped() {
        let a = Session::new("a", PathBuf::from("/tmp"));
        let b = Session::new("b", PathBuf::from("/tmp"));

        let first = a.add_remote_port("127.0.0.1".into(), 3000, "http".into());
        let second = a.add_remote_port("localhost".into(), 8443, "https".into());

        assert!(b.remote_ports().is_empty());
        assert_eq!(a.remote_ports(), vec![first.clone(), second.clone()]);

        let updated = a
            .update_remote_port(&first.id, "127.0.0.1".into(), 3001, "http".into())
            .expect("mapping should update");
        assert_eq!(updated.created_at, first.created_at);
        assert_eq!(updated.remote_port, 3001);
        assert_eq!(a.remote_ports()[0], updated);

        assert!(a.remove_remote_port(&second.id));
        assert_eq!(a.remote_ports(), vec![updated]);
        assert!(!a.remove_remote_port("missing"));
    }

    /// A burst of distinct `view.active_changed` within the trailing window
    /// must reach the wire as a single event carrying the final value — and
    /// not before the window closes.
    #[tokio::test]
    async fn coalesces_view_active_burst_to_latest() {
        let s = Session::new("test-coalesce", PathBuf::from("/tmp"));
        for id in ["a", "b", "a", "c"] {
            s.activate_view(Some(id.to_string()));
        }
        // The flush task hasn't had a chance to fire yet: nothing published.
        assert!(
            s.replay_since(0).is_empty(),
            "burst must not publish before the window closes"
        );

        tokio::time::sleep(COALESCE_WINDOW * 3).await;
        let events = s.replay_since(0);
        assert_eq!(events.len(), 1, "burst must collapse to one event");
        match &*events[0] {
            Event::ViewActiveChanged { view_id, .. } => {
                assert_eq!(view_id.as_deref(), Some("c"), "must keep the latest value");
            }
            other => panic!("unexpected event: {other:?}"),
        }
    }

    #[test]
    fn detach_client_is_idempotent() {
        let s = Session::new("test-detach", PathBuf::from("/tmp"));
        let client = "client-1".to_string();

        assert!(s.attach_client(client.clone()).is_some());
        assert_eq!(s.info().client_count, 1);

        assert!(s.detach_client(&client));
        assert_eq!(s.info().client_count, 0);
        let seq_after_first_detach = s.last_seq();

        assert!(!s.detach_client(&client));
        assert_eq!(s.info().client_count, 0);
        assert_eq!(s.last_seq(), seq_after_first_detach);
    }

    #[test]
    fn shutdown_is_latched_and_rejects_new_clients() {
        let s = Session::new("test-shutdown", PathBuf::from("/tmp"));
        assert!(s.attach_client("client-1".to_string()).is_some());
        let mut shutdown = s.subscribe_shutdown();

        s.shutdown();
        s.shutdown(); // idempotent

        assert!(s.is_destroyed());
        assert!(*shutdown.borrow_and_update());
        assert_eq!(s.info().client_count, 0);
        assert!(s.attach_client("client-2".to_string()).is_none());
    }
}
