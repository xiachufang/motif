//! Per-session state: subscribers, event bus, ring buffer, PTY pool.

pub mod manager;

use std::collections::VecDeque;
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

use crate::blob::BlobRegistry;
use crate::pty::PtyPool;

const RING_CAPACITY: usize = 4096; // events buffered for replay
const BROADCAST_CAPACITY: usize = 4096;

pub struct Session {
    pub id:         SessionId,
    pub name:       String,
    pub workdir:    PathBuf,
    pub created_at: UnixMs,

    seq:     Mutex<Seq>,
    ring:    Mutex<VecDeque<Arc<Event>>>,
    clients: Mutex<Vec<ClientInfo>>,
    tx:      broadcast::Sender<Arc<Event>>,

    pub pty_pool: Arc<PtyPool>,
    pub blobs:    Arc<BlobRegistry>,

    /// Synced tab list. Order matters (UI renders left-to-right). Mutated by
    /// view.* RPCs and PTY lifecycle hooks.
    views:        Mutex<Vec<ViewInfo>>,
    active_view:  Mutex<Option<ViewId>>,

    /// Filesystem watcher rooted at `workdir`. Initialized lazily after
    /// `Arc::new` so the forwarder thread can hold a `Weak<Session>` for
    /// publish-event callbacks. Dropped with the Session.
    fswatcher:    Mutex<Option<crate::fswatch::FsWatcher>>,

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
            id:         ulid::Ulid::new().to_string(),
            name:       name.into(),
            workdir,
            created_at: now_ms(),
            seq:        Mutex::new(0),
            ring:       Mutex::new(VecDeque::with_capacity(RING_CAPACITY)),
            clients:    Mutex::new(Vec::new()),
            tx,
            pty_pool:   PtyPool::new(),
            blobs:      BlobRegistry::new(),
            views:      Mutex::new(Vec::new()),
            active_view: Mutex::new(None),
            fswatcher:  Mutex::new(None),
            term_palette: Mutex::new(None),
        });
        // pool needs a back-reference for publishing events.
        s.pty_pool.set_session(Arc::downgrade(&s));

        // Watch workdir so PTY-driven edits surface as tree.changed/git.changed.
        // A failure here is logged but doesn't kill the session — the user can
        // still work, they just won't get auto-refresh.
        match crate::fswatch::spawn(Arc::downgrade(&s), s.workdir.clone()) {
            Ok(w)  => *s.fswatcher.lock() = Some(w),
            Err(e) => tracing::warn!(workdir = %s.workdir.display(), error = %e, "fs watcher disabled"),
        }
        s
    }

    pub fn info(&self) -> SessionInfo {
        SessionInfo {
            id:           self.id.clone(),
            name:         self.name.clone(),
            workdir:      self.workdir.clone(),
            created_at:   self.created_at,
            client_count: self.clients.lock().len() as u32,
        }
    }

    pub fn list_clients(&self) -> Vec<ClientInfo> {
        self.clients.lock().clone()
    }

    pub fn last_seq(&self) -> Seq { *self.seq.lock() }

    /// Stash the client-reported terminal palette. `None` for either field
    /// keeps the existing value, so a client that can detect only one of
    /// the two doesn't blow away the other side's previous report.
    pub fn set_terminal_palette(&self, fg: Option<String>, bg: Option<String>) {
        if fg.is_none() && bg.is_none() { return; }
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
        if rgb.is_empty() { return None; }
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
        self.ring.lock().iter().filter(|e| e.seq() > after).cloned().collect()
    }

    pub fn attach_client(&self, client_id: ClientId) -> AttachOutcome {
        let now    = now_ms();
        let mut cs = self.clients.lock();
        let existing = cs.clone();
        cs.push(ClientInfo { id: client_id.clone(), since: now });
        drop(cs);

        let last_seq = self.publish_event(|seq| Event::ClientJoined {
            client_id, since: now, seq,
        });

        AttachOutcome { existing, last_seq }
    }

    pub fn detach_client(&self, client_id: &ClientId) {
        {
            let mut cs = self.clients.lock();
            cs.retain(|c| &c.id != client_id);
        }
        self.pty_pool.forget_client_sizes(client_id);
        self.publish_event(|seq| Event::ClientLeft {
            client_id: client_id.clone(), seq,
        });
    }

    pub fn views_snapshot(&self) -> Vec<ViewInfo> {
        self.views.lock().clone()
    }

    pub fn active_view(&self) -> Option<ViewId> {
        self.active_view.lock().clone()
    }

    /// If `view_id` refers to a Pty view, return the underlying PtyId.
    pub fn pty_id_of_view(&self, view_id: &str) -> Option<PtyId> {
        self.views.lock().iter().find(|v| v.id == view_id).and_then(|v| match &v.spec {
            ViewSpec::Pty { pty_id } => Some(pty_id.clone()),
            _ => None,
        })
    }

    /// Append a view + broadcast. If `activate` is true, also update the
    /// session's active view (and broadcast that change).
    pub fn open_view(&self, spec: ViewSpec, activate: bool) -> ViewInfo {
        let info = ViewInfo {
            id:         ulid::Ulid::new().to_string(),
            spec,
            created_at: now_ms(),
        };
        self.views.lock().push(info.clone());
        let info_for_event = info.clone();
        self.publish_event(|seq| Event::ViewOpened { view: info_for_event, seq });
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
            next_active = views.get(idx.saturating_sub(1)).map(|v| v.id.clone())
                .or_else(|| views.first().map(|v| v.id.clone()));
        }
        drop(views);

        let removed_id = removed.id.clone();
        self.publish_event(|seq| Event::ViewClosed { view_id: removed_id, seq });
        if was_active {
            *self.active_view.lock() = next_active.clone();
            let nv = next_active.clone();
            self.publish_event(|seq| Event::ViewActiveChanged { view_id: nv, seq });
        }
        Some(removed)
    }

    /// Public close: removes view and, if it was a Pty view, also kills the
    /// underlying PTY (whose reader thread will then drop the Pty entry).
    pub fn close_view(&self, view_id: &str) -> bool {
        let Some(removed) = self.close_view_internal(view_id) else { return false };
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
            let Some(from) = views.iter().position(|v| v.id == view_id) else { return false };
            let to = to_index.min(views.len().saturating_sub(1));
            if from == to { return false; }
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
            if *av == view_id { return; }
            *av = view_id.clone();
        }
        self.publish_event(|seq| Event::ViewActiveChanged { view_id, seq });
    }

    /// Atomic seq-allocate + ring-record + broadcast. Returns the seq used.
    pub fn publish_event<F>(&self, build: F) -> Seq
    where F: FnOnce(Seq) -> Event,
    {
        let mut s = self.seq.lock();
        *s += 1;
        let seq = *s;
        drop(s);

        let event = build(seq);
        let arc   = Arc::new(event);
        {
            let mut ring = self.ring.lock();
            if ring.len() == RING_CAPACITY { ring.pop_front(); }
            ring.push_back(arc.clone());
        }
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
