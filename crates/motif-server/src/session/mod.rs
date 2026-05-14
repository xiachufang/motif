//! Per-session state: subscribers, event bus, ring buffer, PTY pool.

pub mod manager;

use std::collections::{HashSet, VecDeque};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use motif_proto::common::{ClientId, PtyId, Seq, SessionId, UnixMs};
use motif_proto::event::Event;
use motif_proto::session::{ClientInfo, SessionInfo};
use motif_proto::terminal_query::QueryKind;
use motif_proto::view::{ViewId, ViewInfo, ViewSpec};
use parking_lot::Mutex;
use tokio::sync::broadcast;

use crate::pty::PtyPool;

const RING_CAPACITY: usize = 4096; // events buffered for replay
const BROADCAST_CAPACITY: usize = 4096;

struct PublishState {
    seq: Seq,
    ring: VecDeque<Arc<Event>>,
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
}

impl Session {
    pub fn new(name: impl Into<String>, workdir: PathBuf) -> Arc<Self> {
        let (tx, _) = broadcast::channel::<Arc<Event>>(BROADCAST_CAPACITY);
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
            pty_pool: PtyPool::new(),
            views: Mutex::new(Vec::new()),
            active_view: Mutex::new(None),
            fswatcher: Mutex::new(None),
            fs_subscribers: Mutex::new(HashSet::new()),
            term_palette: Mutex::new(None),
        });
        // pool needs a back-reference for publishing events.
        s.pty_pool.set_session(Arc::downgrade(&s));
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

    pub fn attach_client(&self, client_id: ClientId) -> AttachOutcome {
        let now = now_ms();
        let mut cs = self.clients.lock();
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

        AttachOutcome { existing, last_seq }
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
            self.publish_event(|seq| Event::ViewActiveChanged { view_id: nv, seq });
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
        self.publish_event(|seq| Event::ViewActiveChanged { view_id, seq });
        self.sync_watch_to_active();
    }

    /// Called by the PTY reader after publishing `pty.cwd_changed`. Re-points
    /// the fswatcher only if the changed PTY is the currently-active one
    /// (cwd of background tabs doesn't affect what the file tree shows).
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
    fn detach_client_is_idempotent() {
        let s = Session::new("test-detach", PathBuf::from("/tmp"));
        let client = "client-1".to_string();

        s.attach_client(client.clone());
        assert_eq!(s.info().client_count, 1);

        assert!(s.detach_client(&client));
        assert_eq!(s.info().client_count, 0);
        let seq_after_first_detach = s.last_seq();

        assert!(!s.detach_client(&client));
        assert_eq!(s.info().client_count, 0);
        assert_eq!(s.last_seq(), seq_after_first_detach);
    }
}
