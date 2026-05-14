//! Connection state registry — replaces the per-WS `ConnState` model
//! with state keyed by an opaque `session_id` string the client carries
//! across HTTP requests and WS upgrades.
//!
//! Today: state lives on the `/ws` read task (`handle_socket`). Once the
//! socket closes, state is gone.
//! New protocol: client gets a `session_id` from `session.attach`, then
//! every subsequent HTTP RPC (`X-Motif-Session: <id>`) and WS upgrade
//! (`?session=<id>`) looks the state up here. Lifetime detaches from
//! any single connection — survives transient disconnects, gets reaped
//! on detach or idle timeout.

use std::sync::Arc;
use std::time::{Duration, Instant};

use dashmap::DashMap;
use motif_proto::common::SessionId;
use parking_lot::Mutex;

use crate::rpc::ConnState;

/// Soft idle timeout. After this much wall-clock with no `touch()`, the
/// entry is eligible for reaping on the next `gc()` call. Lazy GC: we
/// don't run a background sweeper; whoever calls `get` / `mint` opportunistically
/// drops stale entries. Five minutes — long enough to survive a phone
/// going to sleep mid-task, short enough that an abandoned client doesn't
/// pin state forever.
pub const SESSION_IDLE_TTL: Duration = Duration::from_secs(300);

pub struct ConnEntry {
    pub state: Mutex<ConnState>,
    /// Wall-clock of the most recent `touch()`. Used by lazy GC. Mutex
    /// because the field is updated on every HTTP RPC and we don't need
    /// atomic semantics — coarser than a single instant is fine.
    last_seen: Mutex<Instant>,
}

impl ConnEntry {
    fn new(state: ConnState) -> Self {
        Self {
            state: Mutex::new(state),
            last_seen: Mutex::new(Instant::now()),
        }
    }

    pub fn touch(&self) {
        *self.last_seen.lock() = Instant::now();
    }

    fn idle_for(&self) -> Duration {
        self.last_seen.lock().elapsed()
    }
}

#[derive(Default)]
pub struct ConnRegistry {
    conns: DashMap<SessionId, Arc<ConnEntry>>,
}

impl ConnRegistry {
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    /// Mint a fresh session_id, insert a new ConnState, return both.
    /// Called by the HTTP `session.attach` path before delegating to
    /// the existing dispatch_mut logic.
    pub fn mint(&self) -> (SessionId, Arc<ConnEntry>) {
        let id = ulid::Ulid::new().to_string();
        let entry = Arc::new(ConnEntry::new(ConnState::new()));
        self.conns.insert(id.clone(), Arc::clone(&entry));
        (id, entry)
    }

    /// Look up by session_id. Touches the entry on success so liveness
    /// is kept fresh by ordinary RPC traffic without needing a separate
    /// keepalive call.
    pub fn get(&self, id: &str) -> Option<Arc<ConnEntry>> {
        let entry = self.conns.get(id)?.clone();
        entry.touch();
        Some(entry)
    }

    /// Drop an entry — called on `session.detach` and on idle GC.
    pub fn remove(&self, id: &str) -> Option<Arc<ConnEntry>> {
        self.conns.remove(id).map(|(_, v)| v)
    }

    /// Sweep stale entries. Cheap (one pass over a DashMap that's small
    /// in practice — N is in single digits per machine). Caller should
    /// invoke from `mint` and any hot path that can tolerate the work;
    /// no background task needed for v1.
    pub fn gc(&self) {
        let stale: Vec<SessionId> = self
            .conns
            .iter()
            .filter(|kv| kv.value().idle_for() > SESSION_IDLE_TTL)
            .map(|kv| kv.key().clone())
            .collect();
        for id in stale {
            self.conns.remove(&id);
        }
    }

    pub fn len(&self) -> usize {
        self.conns.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mint_then_get_returns_same_entry() {
        let r = ConnRegistry::new();
        let (id, e1) = r.mint();
        let e2 = r.get(&id).expect("entry present");
        assert!(Arc::ptr_eq(&e1, &e2));
    }

    #[test]
    fn remove_drops_entry() {
        let r = ConnRegistry::new();
        let (id, _) = r.mint();
        assert!(r.get(&id).is_some());
        r.remove(&id);
        assert!(r.get(&id).is_none());
    }

    #[test]
    fn gc_keeps_fresh_drops_stale() {
        let r = ConnRegistry::new();
        let (fresh_id, _) = r.mint();
        let (stale_id, stale_entry) = r.mint();
        // Hand-roll a "stale" entry by rewinding its last_seen far enough
        // that the GC threshold triggers.
        *stale_entry.last_seen.lock() = Instant::now() - SESSION_IDLE_TTL - Duration::from_secs(1);
        r.gc();
        assert!(r.get(&fresh_id).is_some(), "fresh entry was reaped");
        assert!(r.get(&stale_id).is_none(), "stale entry survived");
    }
}
