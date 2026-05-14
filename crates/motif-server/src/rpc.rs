//! JSON-RPC method dispatcher.

use std::sync::Arc;

use motif_proto::envelope::{Id, Request, Response};
use motif_proto::error::{ErrorCode, RpcError};
use motif_proto::view as pview;
use motif_proto::{event::Event, fs as pfs, git as pgit, pty as ppty, session as ses};
use serde::de::DeserializeOwned;
use serde_json::Value;

use crate::session::manager::{ManagerError, SessionManager};
use crate::session::Session;

pub struct ConnState {
    pub client_id: motif_proto::common::ClientId,
    pub attached: Option<String>,
    /// After a successful session.attach, set to the client's last known seq
    /// (or 0 for fresh connects). The ws layer drains this and replays
    /// buffered events to bootstrap the new client's view of the session.
    pub pending_replay_since: Option<motif_proto::common::Seq>,
}

impl ConnState {
    pub fn new() -> Self {
        Self {
            client_id: ulid::Ulid::new().to_string(),
            attached: None,
            pending_replay_since: None,
        }
    }

    /// Owned snapshot of the read-only fields handlers actually need.
    /// The ws layer takes one of these per request when spawning the
    /// handler concurrently, so the handler can run without holding any
    /// borrow on the ConnState (which lives on the ws task).
    pub fn snapshot(&self) -> ConnSnapshot {
        ConnSnapshot {
            client_id: self.client_id.clone(),
            attached: self.attached.clone(),
        }
    }
}

/// Per-request view of ConnState. Cloned at the moment the WS layer
/// reads a frame, then passed by reference through dispatch_concurrent
/// into handlers. Anything mutating (attach/detach) goes through the
/// serial `dispatch_mut` path instead and operates on `&mut ConnState`.
#[derive(Clone)]
pub struct ConnSnapshot {
    pub client_id: motif_proto::common::ClientId,
    pub attached: Option<String>,
}

/// Serial dispatcher for the small set of methods that mutate
/// ConnState. The WS layer awaits this in-line so post-attach event
/// replay setup can run immediately after the response returns.
pub fn dispatch_mut(manager: &Arc<SessionManager>, conn: &mut ConnState, req: Request) -> Response {
    let id = req.id.clone();
    match req.method.as_str() {
        "session.attach" => handle_attach(manager, conn, id, req.params),
        "session.detach" => handle_detach(manager, conn, id),
        // The WS layer routes every other method to dispatch_concurrent;
        // a stray call here is a programming error, but reply with a
        // plain method_not_found rather than panic — keeps the protocol
        // tolerant of older callers.
        other => Response::err(id, RpcError::method_not_found(other)),
    }
}

/// Lookup table of methods routed through `dispatch_mut`. Kept here so
/// the WS layer doesn't have to hard-code the pair.
pub fn is_mutating_method(method: &str) -> bool {
    matches!(method, "session.attach" | "session.detach")
}

/// Concurrent dispatcher: every other method. Synchronous (no `.await`
/// inside) so the WS layer can drop it onto `tokio::task::spawn_blocking`
/// to keep heavy fs/git handlers off the runtime workers.
pub fn dispatch_concurrent(
    manager: &Arc<SessionManager>,
    conn: &ConnSnapshot,
    req: Request,
) -> Response {
    let id = req.id.clone();
    match req.method.as_str() {
        // session.*
        "session.list" => handle_list(manager, id, req.params),
        "session.create" => handle_create(manager, id, req.params),
        "session.destroy" => handle_destroy(manager, id, req.params),
        // mutating methods belong on the serial path
        "session.attach" | "session.detach" => Response::err(
            id,
            RpcError::internal("mutating method routed to concurrent dispatcher"),
        ),

        // pty.*
        "pty.create" => handle_pty_create(manager, conn, id, req.params),
        "pty.list" => handle_pty_list(manager, conn, id),
        "pty.write" => handle_pty_write(manager, conn, id, req.params),
        "pty.resize" => handle_pty_resize(manager, conn, id, req.params),
        "pty.kill" => handle_pty_kill(manager, conn, id, req.params),
        // (pty.list_blocks / pty.get_block_output removed — block history
        // tracking moved out of the server when shell-integration parsing
        // was relocated to clients.)

        // view.* (synced tab state)
        "view.open" => handle_view_open(manager, conn, id, req.params),
        "view.close" => handle_view_close(manager, conn, id, req.params),
        "view.activate" => handle_view_activate(manager, conn, id, req.params),
        "view.move" => handle_view_move(manager, conn, id, req.params),

        // fs.*
        "fs.tree" => attached(manager, conn, id, req.params, |s, p: pfs::TreeParams| {
            crate::fs::tree(&s, &p)
        }),
        "fs.stat" => attached(manager, conn, id, req.params, |s, p: pfs::StatParams| {
            crate::fs::stat(&s, &p)
        }),
        "fs.read" => attached(manager, conn, id, req.params, |s, p: pfs::ReadParams| {
            crate::fs::read(&s, &p)
        }),
        "fs.write" => {
            attached_with_session(manager, conn, id, req.params, |s, p: pfs::WriteParams| {
                let r = crate::fs::write(&s, &p)?;
                // Emit changes.
                let path = p.path.clone();
                s.publish_event(|seq| Event::TreeChanged {
                    paths: vec![path],
                    seq,
                });
                // Unconditional: clients fan out to whichever cwd they care about
                // (which may be outside the session workdir). They handle
                // NotAGitRepo gracefully on the re-fetch.
                s.publish_event(|seq| Event::GitChanged { seq });
                Ok(r)
            })
        }
        "fs.mkdir" => attached_with_session(manager, conn, id, req.params, |s, p: MkdirParams| {
            let safe = crate::fs::resolve(&s.workdir, &p.path)?;
            std::fs::create_dir_all(&safe).map_err(crate::fs::io_to_rpc_err)?;
            s.publish_event(|seq| Event::TreeChanged {
                paths: vec![p.path],
                seq,
            });
            Ok(Empty {})
        }),
        "fs.remove" => {
            attached_with_session(manager, conn, id, req.params, |s, p: RemoveParams| {
                let safe = crate::fs::resolve(&s.workdir, &p.path)?;
                if safe.is_dir() {
                    std::fs::remove_dir_all(&safe).map_err(crate::fs::io_to_rpc_err)?;
                } else {
                    std::fs::remove_file(&safe).map_err(crate::fs::io_to_rpc_err)?;
                }
                s.publish_event(|seq| Event::TreeChanged {
                    paths: vec![p.path],
                    seq,
                });
                // Unconditional: clients fan out to whichever cwd they care about
                // (which may be outside the session workdir). They handle
                // NotAGitRepo gracefully on the re-fetch.
                s.publish_event(|seq| Event::GitChanged { seq });
                Ok(Empty {})
            })
        }
        "fs.rename" => {
            attached_with_session(manager, conn, id, req.params, |s, p: RenameParams| {
                let from = crate::fs::resolve(&s.workdir, &p.from)?;
                let to = crate::fs::resolve(&s.workdir, &p.to)?;
                std::fs::rename(&from, &to).map_err(crate::fs::io_to_rpc_err)?;
                s.publish_event(|seq| Event::TreeChanged {
                    paths: vec![p.from, p.to],
                    seq,
                });
                // Unconditional: clients fan out to whichever cwd they care about
                // (which may be outside the session workdir). They handle
                // NotAGitRepo gracefully on the re-fetch.
                s.publish_event(|seq| Event::GitChanged { seq });
                Ok(Empty {})
            })
        }

        // git.*
        "git.status" => attached(manager, conn, id, req.params, |s, p: pgit::StatusParams| {
            let cwd = p.cwd.as_deref().unwrap_or(&s.workdir);
            crate::git::status(cwd)
        }),
        "git.diff" => attached(manager, conn, id, req.params, |s, p: pgit::DiffParams| {
            let cwd = p.cwd.clone().unwrap_or_else(|| s.workdir.clone());
            crate::git::diff(&cwd, &p)
        }),
        "git.diffSummary" => attached(manager, conn, id, req.params, |s, p: pgit::DiffParams| {
            let cwd = p.cwd.clone().unwrap_or_else(|| s.workdir.clone());
            crate::git::diff_summary(&cwd, &p)
        }),

        other => Response::err(id, RpcError::method_not_found(other)),
    }
}

fn parse<P: DeserializeOwned>(v: Value) -> Result<P, RpcError> {
    serde_json::from_value(v).map_err(|e| RpcError::invalid_params(e.to_string()))
}

fn handle_list(mgr: &Arc<SessionManager>, id: Id, _params: Value) -> Response {
    let sessions = mgr.list().into_iter().map(|s| s.info()).collect();
    Response::ok(id, ses::ListResult { sessions })
}

fn handle_create(mgr: &Arc<SessionManager>, id: Id, params: Value) -> Response {
    let p: ses::CreateParams = match parse(params) {
        Ok(p) => p,
        Err(e) => return Response::err(id, e),
    };
    match mgr.create(p.name, p.workdir) {
        Ok(s) => Response::ok(id, ses::CreateResult { session: s.info() }),
        Err(ManagerError::AlreadyExists(n)) => Response::err(
            id,
            RpcError::new(
                ErrorCode::AlreadyExists,
                format!("session '{n}' already exists"),
            ),
        ),
        Err(ManagerError::BadWorkdir(p)) => Response::err(
            id,
            RpcError::invalid_params(format!("workdir not a directory: {}", p.display())),
        ),
        Err(e) => Response::err(id, RpcError::internal(e.to_string())),
    }
}

fn handle_attach(
    mgr: &Arc<SessionManager>,
    conn: &mut ConnState,
    id: Id,
    params: Value,
) -> Response {
    let p: ses::AttachParams = match parse(params) {
        Ok(p) => p,
        Err(e) => return Response::err(id, e),
    };
    let Some(s) = mgr.get(&p.name) else {
        return Response::err(
            id,
            RpcError::new(
                ErrorCode::SessionNotFound,
                format!("session '{}' not found", p.name),
            ),
        );
    };
    if let Some(old_name) = conn.attached.take() {
        if let Some(old) = mgr.get(&old_name) {
            old.detach_client(&conn.client_id);
        }
    }
    let outcome = s.attach_client(conn.client_id.clone());
    conn.attached = Some(p.name.clone());
    // Stash the client-supplied cursor (default 0 = "give me everything")
    // for the ws layer to drain after this response goes out.
    conn.pending_replay_since = Some(p.last_seq.unwrap_or(0));
    // Update the cached terminal palette so OSC 10/11 queries from the
    // shell get answered with the user's actual terminal colours.
    s.set_terminal_palette(p.term_fg.clone(), p.term_bg.clone());

    let ptys = s.pty_pool.list();
    let views = s.views_snapshot();
    let active_view = s.active_view();

    Response::ok(
        id,
        ses::AttachResult {
            session: s.info(),
            client_id: conn.client_id.clone(),
            clients: outcome.existing,
            ptys,
            views,
            active_view,
            last_seq: outcome.last_seq,
        },
    )
}

fn handle_detach(mgr: &Arc<SessionManager>, conn: &mut ConnState, id: Id) -> Response {
    let Some(name) = conn.attached.take() else {
        return Response::err(id, RpcError::new(ErrorCode::NotAttached, "not attached"));
    };
    if let Some(s) = mgr.get(&name) {
        s.detach_client(&conn.client_id);
    }
    Response::ok(id, ses::DetachResult::default())
}

fn handle_destroy(mgr: &Arc<SessionManager>, id: Id, params: Value) -> Response {
    let p: ses::DestroyParams = match parse(params) {
        Ok(p) => p,
        Err(e) => return Response::err(id, e),
    };
    match mgr.destroy(&p.name) {
        Ok(()) => Response::ok(id, ses::DestroyResult::default()),
        Err(ManagerError::NotFound(n)) => Response::err(
            id,
            RpcError::new(
                ErrorCode::SessionNotFound,
                format!("session '{n}' not found"),
            ),
        ),
        Err(e) => Response::err(id, RpcError::internal(e.to_string())),
    }
}

// ─────────────────────────── PTY handlers ───────────────────────────

fn handle_pty_create(
    mgr: &Arc<SessionManager>,
    conn: &ConnSnapshot,
    id: Id,
    params: Value,
) -> Response {
    let Some(s) = current_session(mgr, conn) else {
        return Response::err(
            id,
            RpcError::new(ErrorCode::NotAttached, "must session.attach first"),
        );
    };
    let p: ppty::PtyCreateParams = match parse(params) {
        Ok(p) => p,
        Err(e) => return Response::err(id, e),
    };
    match s.pty_pool.create(p, conn.client_id.clone(), &s.workdir) {
        Ok(pty) => {
            // Auto-open a Pty view so the new tab appears on every client.
            // Activate so the user who created it lands on it (and so do all
            // other clients — the synced-active is part of B's contract).
            s.open_view(
                pview::ViewSpec::Pty {
                    pty_id: pty.id.clone(),
                },
                true,
            );
            Response::ok(id, ppty::PtyCreateResult { info: pty.info() })
        }
        Err(crate::pty::PtyError::LimitReached) => Response::err(
            id,
            RpcError::new(ErrorCode::PtyLimitReached, "PTY limit reached"),
        ),
        Err(e) => Response::err(id, RpcError::internal(e.to_string())),
    }
}

fn handle_pty_list(mgr: &Arc<SessionManager>, conn: &ConnSnapshot, id: Id) -> Response {
    let Some(s) = current_session(mgr, conn) else {
        return Response::err(
            id,
            RpcError::new(ErrorCode::NotAttached, "must session.attach first"),
        );
    };
    Response::ok(
        id,
        ppty::PtyListResult {
            ptys: s.pty_pool.list(),
        },
    )
}

fn handle_pty_write(
    mgr: &Arc<SessionManager>,
    conn: &ConnSnapshot,
    id: Id,
    params: Value,
) -> Response {
    let Some(s) = current_session(mgr, conn) else {
        return Response::err(
            id,
            RpcError::new(ErrorCode::NotAttached, "must session.attach first"),
        );
    };
    let p: ppty::PtyWriteParams = match parse(params) {
        Ok(p) => p,
        Err(e) => return Response::err(id, e),
    };
    let Some(pty) = s.pty_pool.get(&p.pty_id) else {
        return Response::err(id, RpcError::new(ErrorCode::PtyNotFound, "pty not found"));
    };
    if let Err(e) = pty.write_bytes(&p.data) {
        return Response::err(id, RpcError::internal(format!("pty write: {e}")));
    }
    mark_pty_primary(&s, &p.pty_id, conn.client_id.clone());
    Response::ok(id, EmptyOk {})
}

fn handle_pty_resize(
    mgr: &Arc<SessionManager>,
    conn: &ConnSnapshot,
    id: Id,
    params: Value,
) -> Response {
    let Some(s) = current_session(mgr, conn) else {
        return Response::err(
            id,
            RpcError::new(ErrorCode::NotAttached, "must session.attach first"),
        );
    };
    let p: ppty::PtyResizeParams = match parse(params) {
        Ok(p) => p,
        Err(e) => return Response::err(id, e),
    };
    let Some(pty) = s.pty_pool.get(&p.pty_id) else {
        return Response::err(id, RpcError::new(ErrorCode::PtyNotFound, "pty not found"));
    };
    if let Some((cols, rows)) = pty.set_client_size(conn.client_id.clone(), p.cols, p.rows) {
        let pid = p.pty_id.clone();
        s.publish_event(|seq| Event::PtyResize {
            pty_id: pid,
            cols,
            rows,
            seq,
        });
    }
    Response::ok(id, EmptyOk {})
}

fn handle_pty_kill(
    mgr: &Arc<SessionManager>,
    conn: &ConnSnapshot,
    id: Id,
    params: Value,
) -> Response {
    let Some(s) = current_session(mgr, conn) else {
        return Response::err(
            id,
            RpcError::new(ErrorCode::NotAttached, "must session.attach first"),
        );
    };
    let p: ppty::PtyKillParams = match parse(params) {
        Ok(p) => p,
        Err(e) => return Response::err(id, e),
    };
    match s.pty_pool.kill(&p.pty_id) {
        Ok(()) => Response::ok(id, EmptyOk {}),
        Err(_) => Response::err(id, RpcError::new(ErrorCode::PtyNotFound, "pty not found")),
    }
}

// ─────────────────────────── view handlers ───────────────────────────

fn handle_view_open(
    mgr: &Arc<SessionManager>,
    conn: &ConnSnapshot,
    id: Id,
    params: Value,
) -> Response {
    let Some(s) = current_session(mgr, conn) else {
        return Response::err(
            id,
            RpcError::new(ErrorCode::NotAttached, "must session.attach first"),
        );
    };
    let p: pview::OpenParams = match parse(params) {
        Ok(p) => p,
        Err(e) => return Response::err(id, e),
    };
    // Capture the pty id (if any) before moving spec into open_view.
    let pty_to_mark = if p.activate {
        match &p.spec {
            pview::ViewSpec::Pty { pty_id } => Some(pty_id.clone()),
            _ => None,
        }
    } else {
        None
    };
    let info = s.open_view(p.spec, p.activate);
    if let Some(pid) = pty_to_mark {
        mark_pty_primary(&s, &pid, conn.client_id.clone());
    }
    Response::ok(id, pview::OpenResult { view: info })
}

fn handle_view_close(
    mgr: &Arc<SessionManager>,
    conn: &ConnSnapshot,
    id: Id,
    params: Value,
) -> Response {
    let Some(s) = current_session(mgr, conn) else {
        return Response::err(
            id,
            RpcError::new(ErrorCode::NotAttached, "must session.attach first"),
        );
    };
    let p: pview::CloseParams = match parse(params) {
        Ok(p) => p,
        Err(e) => return Response::err(id, e),
    };
    // Idempotent: closing an already-gone view is fine.
    s.close_view(&p.view_id);
    Response::ok(id, pview::CloseResult::default())
}

fn handle_view_activate(
    mgr: &Arc<SessionManager>,
    conn: &ConnSnapshot,
    id: Id,
    params: Value,
) -> Response {
    let Some(s) = current_session(mgr, conn) else {
        return Response::err(
            id,
            RpcError::new(ErrorCode::NotAttached, "must session.attach first"),
        );
    };
    let p: pview::ActivateParams = match parse(params) {
        Ok(p) => p,
        Err(e) => return Response::err(id, e),
    };
    let pty_to_mark = p.view_id.as_deref().and_then(|vid| s.pty_id_of_view(vid));
    s.activate_view(p.view_id);
    if let Some(pid) = pty_to_mark {
        mark_pty_primary(&s, &pid, conn.client_id.clone());
    }
    Response::ok(id, pview::ActivateResult::default())
}

fn handle_view_move(
    mgr: &Arc<SessionManager>,
    conn: &ConnSnapshot,
    id: Id,
    params: Value,
) -> Response {
    let Some(s) = current_session(mgr, conn) else {
        return Response::err(
            id,
            RpcError::new(ErrorCode::NotAttached, "must session.attach first"),
        );
    };
    let p: pview::MoveParams = match parse(params) {
        Ok(p) => p,
        Err(e) => return Response::err(id, e),
    };
    s.move_view(&p.view_id, p.to_index);
    Response::ok(id, pview::MoveResult::default())
}

// ─────────────────────────── helpers ───────────────────────────

/// Promote `client` to primary on the named PTY. Resizes the master and
/// publishes a PtyResize event when that changes the effective size.
fn mark_pty_primary(s: &Arc<Session>, pty_id: &str, client: motif_proto::common::ClientId) {
    let Some(pty) = s.pty_pool.get(pty_id) else {
        return;
    };
    if let Some((cols, rows)) = pty.mark_primary(client) {
        let pid = pty_id.to_string();
        s.publish_event(|seq| Event::PtyResize {
            pty_id: pid,
            cols,
            rows,
            seq,
        });
    }
}

fn current_session(mgr: &Arc<SessionManager>, conn: &ConnSnapshot) -> Option<Arc<Session>> {
    let name = conn.attached.as_ref()?;
    mgr.get(name)
}

fn attached<P, R, F>(
    mgr: &Arc<SessionManager>,
    conn: &ConnSnapshot,
    id: Id,
    params: Value,
    f: F,
) -> Response
where
    P: DeserializeOwned,
    R: serde::Serialize,
    F: FnOnce(Arc<Session>, P) -> Result<R, RpcError>,
{
    let Some(s) = current_session(mgr, conn) else {
        return Response::err(
            id,
            RpcError::new(ErrorCode::NotAttached, "must session.attach first"),
        );
    };
    let p: P = match parse(params) {
        Ok(p) => p,
        Err(e) => return Response::err(id, e),
    };
    match f(s, p) {
        Ok(r) => Response::ok(id, r),
        Err(e) => Response::err(id, e),
    }
}

fn attached_with_session<P, R, F>(
    mgr: &Arc<SessionManager>,
    conn: &ConnSnapshot,
    id: Id,
    params: Value,
    f: F,
) -> Response
where
    P: DeserializeOwned,
    R: serde::Serialize,
    F: FnOnce(Arc<Session>, P) -> Result<R, RpcError>,
{
    attached(mgr, conn, id, params, f)
}

pub fn on_disconnect(mgr: &Arc<SessionManager>, conn: &ConnSnapshot) {
    if let Some(name) = &conn.attached {
        if let Some(s) = mgr.get(name) {
            s.detach_client(&conn.client_id);
        }
    }
}

// Plain types used for fs.mkdir/remove/rename which the protocol crate doesn't
// model individually (since they were left as TODO in §14.4). We keep them
// minimal here.

#[derive(serde::Serialize, serde::Deserialize)]
pub struct MkdirParams {
    pub path: String,
}
#[derive(serde::Serialize, serde::Deserialize)]
pub struct RemoveParams {
    pub path: String,
}
#[derive(serde::Serialize, serde::Deserialize)]
pub struct RenameParams {
    pub from: String,
    pub to: String,
}
#[derive(serde::Serialize, serde::Deserialize, Default)]
pub struct Empty {}
#[derive(serde::Serialize, serde::Deserialize)]
pub struct EmptyOk {}
