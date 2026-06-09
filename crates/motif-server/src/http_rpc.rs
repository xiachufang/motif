//! `POST /rpc/<method>` — HTTP request/response transport for the
//! existing JSON-RPC dispatch table.
//!
//! This is the future home of all RPC; `/ws` keeps working alongside it
//! during migration. Each method route delegates to the same
//! `dispatch_concurrent` / `dispatch_mut` functions used by the WS
//! layer — only the framing changes (HTTP body in / JSON body out
//! instead of WS frames). Concurrent dispatch goes onto
//! `tokio::task::spawn_blocking` so slow fs / git handlers don't tie up
//! axum worker threads.
//!
//! ## Session binding
//!
//! Today's `ConnState` (which session you're attached to, your client_id,
//! pending replay cursor) lived on the WS task. Now it lives in
//! [`ConnRegistry`] keyed by an opaque `session_id`:
//!
//! - `POST /rpc/session.attach`: server reuses the request's
//!   `X-Motif-Session` entry when present, otherwise mints a fresh
//!   session_id. The id is returned via the `X-Motif-Session` response
//!   header. The JSON body keeps the existing `AttachResult` shape, so
//!   the proto crate doesn't need to grow a new field this iteration.
//! - All other methods that need session state: client echoes the id in
//!   the `X-Motif-Session` request header.
//! - `POST /rpc/session.detach`: looks up by header, runs detach,
//!   removes the registry entry.

use std::sync::Arc;
use std::time::Instant;

use axum::body::Bytes;
use axum::extract::{ConnectInfo, Path as AxumPath, Query, State};
use axum::http::{HeaderMap, HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};
use motif_net::PeerAddr;
use motif_proto::envelope::{Id, Request};
use motif_proto::error::{ErrorCode, RpcError};

use crate::conn_registry::ConnEntry;
use crate::rpc::{self, ConnState};
use crate::ws::{AppState, TIMING_TARGET};

/// Custom HTTP header used to pin a session_id across requests.
/// Lowercase per HTTP/2 conventions; axum normalizes.
pub const SESSION_HEADER: &str = "x-motif-session";

/// Query string for `fs.write`'s binary variant (`?path=&force=&expected_sha256=`).
/// Empty/absent on every other RPC (all fields optional), so the extractor is
/// harmless on the shared `/rpc/{method}` route.
#[derive(serde::Deserialize, Default)]
pub struct RpcQuery {
    path: Option<String>,
    #[serde(default)]
    force: bool,
    expected_sha256: Option<String>,
}

fn is_octet_stream(headers: &HeaderMap) -> bool {
    headers
        .get("content-type")
        .and_then(|v| v.to_str().ok())
        .map(|v| v.starts_with("application/octet-stream"))
        .unwrap_or(false)
}

pub async fn rpc_dispatch(
    State(state): State<AppState>,
    ConnectInfo(peer): ConnectInfo<PeerAddr>,
    AxumPath(method): AxumPath<String>,
    Query(q): Query<RpcQuery>,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    let req_recv_at = Instant::now();
    tracing::info!(
        target: TIMING_TARGET,
        peer = %peer,
        method = %method,
        req_size = body.len(),
        transport = "http",
        "rpc recv",
    );

    if !state.auth.verify_header(&headers) {
        tracing::warn!(peer = %peer, method = %method, "rpc auth rejected");
        return (StatusCode::UNAUTHORIZED, "missing or invalid Bearer token").into_response();
    }

    // `fs.write` extra encoding: an octet-stream body carries the raw file
    // bytes (no base64), with path/force/expected in the query string. The
    // JSON+base64 form keeps working for every other client.
    if method == "fs.write" && is_octet_stream(&headers) {
        return fs_write_binary(state, &headers, peer, q, body, req_recv_at).await;
    }

    // Body is just the params object; the JSON-RPC envelope is
    // synthesized server-side so we keep the existing dispatch
    // functions unchanged. Empty body → params = null (allowed by the
    // existing default_params hook in motif-proto).
    let params: serde_json::Value = if body.is_empty() {
        serde_json::Value::Null
    } else {
        match serde_json::from_slice(&body) {
            Ok(v) => v,
            Err(e) => {
                return err_response(
                    RpcError::parse_error(format!("body json: {e}")),
                    req_recv_at,
                    &method,
                    None,
                    peer,
                )
            }
        }
    };

    // Synthetic id — clients don't see it (HTTP correlates request ↔
    // response by socket, not by id). Use 0 uniformly so logs stay
    // recognizable.
    let req = Request::new(0u64, method.clone(), params);

    let (resp, minted_session, removed_session) = if rpc::is_mutating_method(&req.method) {
        dispatch_mutating(state.clone(), &headers, req).await
    } else {
        dispatch_concurrent_http(state.clone(), &headers, req).await
    };

    // Build the HTTP response. JSON-RPC error → 4xx with the existing
    // error envelope. Success → 200 with the bare result. The shape
    // matches what an HTTP client expects without forcing it to peek
    // for a JSON-RPC envelope on every reply.
    let total_us = req_recv_at.elapsed().as_micros() as u64;
    let mut http: Response = if let Some(err) = resp.error {
        err_response(err, req_recv_at, &method, minted_session.as_deref(), peer)
    } else {
        let body_bytes = serde_json::to_vec(&resp.result.unwrap_or(serde_json::Value::Null))
            .unwrap_or_else(|_| b"null".to_vec());
        tracing::info!(
            target: TIMING_TARGET,
            peer       = %peer,
            method     = %method,
            req_size   = body.len(),
            resp_size  = body_bytes.len(),
            total_ms   = us_to_ms(total_us),
            error      = false,
            transport  = "http",
            "rpc done",
        );
        let mut r = (StatusCode::OK, body_bytes).into_response();
        r.headers_mut()
            .insert("content-type", HeaderValue::from_static("application/json"));
        r
    };

    // Echo the session_id back. On attach this is the newly minted id;
    // on subsequent calls it's the same value the client sent, which
    // makes proxy logging easier and lets clients sanity-check that
    // the server actually recognized their session.
    if let Some(sid) = minted_session.or_else(|| header_session(&headers)) {
        if let Ok(v) = HeaderValue::from_str(&sid) {
            http.headers_mut().insert(SESSION_HEADER, v);
        }
    }
    if let Some(removed) = removed_session {
        // No state to echo — but record removal so audit logs make sense.
        tracing::debug!(session_id = %removed, "session entry removed (detach)");
    }

    http
}

/// Binary `fs.write`: same auth + session + workdir/conflict/mkdir semantics
/// as the JSON RPC, but the body is the raw file bytes and the params ride in
/// the query string. Returns the same `WriteResult` JSON.
async fn fs_write_binary(
    state: AppState,
    headers: &HeaderMap,
    peer: PeerAddr,
    q: RpcQuery,
    body: Bytes,
    req_recv_at: Instant,
) -> Response {
    let Some(path) = q.path else {
        return err_response(
            RpcError::invalid_params("fs.write (binary): missing ?path="),
            req_recv_at,
            "fs.write",
            None,
            peer,
        );
    };
    let expected = q.expected_sha256;
    let force = q.force;

    // Same conn/session resolution as the concurrent RPC path.
    let snap = match header_session(headers).and_then(|sid| state.conns.get(&sid)) {
        Some(entry) => entry.state.lock().snapshot(),
        None => rpc::ConnSnapshot {
            client_id: String::new(),
            attached: None,
        },
    };

    let manager = Arc::clone(&state.manager);
    let path_for_event = path.clone();
    let result = tokio::task::spawn_blocking(move || -> Result<_, RpcError> {
        let Some(s) = rpc::current_session(&manager, &snap) else {
            return Err(RpcError::new(
                ErrorCode::NotAttached,
                "must session.attach first",
            ));
        };
        let r = crate::fs::write_bytes(&s, &path, &body, expected.as_deref(), force)?;
        rpc::publish_fs_change(&s, vec![path_for_event]);
        Ok(r)
    })
    .await
    .unwrap_or_else(|e| Err(RpcError::internal(format!("fs.write binary panic: {e}"))));

    match result {
        Ok(r) => {
            let body_bytes = serde_json::to_vec(&r).unwrap_or_else(|_| b"{}".to_vec());
            tracing::info!(
                target: TIMING_TARGET,
                peer = %peer,
                method = "fs.write",
                resp_size = body_bytes.len(),
                total_ms = us_to_ms(req_recv_at.elapsed().as_micros() as u64),
                error = false,
                transport = "http-bin",
                "rpc done",
            );
            let mut http = (StatusCode::OK, body_bytes).into_response();
            http.headers_mut()
                .insert("content-type", HeaderValue::from_static("application/json"));
            if let Some(sid) = header_session(headers) {
                if let Ok(v) = HeaderValue::from_str(&sid) {
                    http.headers_mut().insert(SESSION_HEADER, v);
                }
            }
            http
        }
        Err(err) => err_response(err, req_recv_at, "fs.write", None, peer),
    }
}

/// Run an immutable method on the blocking pool. Returns the dispatch
/// `Response`, plus optionally a session_id that was created or
/// removed (always None on this path).
async fn dispatch_concurrent_http(
    state: AppState,
    headers: &HeaderMap,
    req: Request,
) -> (
    motif_proto::envelope::Response,
    Option<String>,
    Option<String>,
) {
    // Resolve the conn snapshot from the registry, if the client has
    // a session_id. Methods like session.list / session.create work
    // without one.
    //
    // A present-but-unknown session_id (motifd restarted while the client
    // still holds an old id, or the entry was GC'd) must NOT hard-fail every
    // method: discovery calls like session.list have to keep working so the
    // client can recover, and session.attach re-mints anyway. So an unknown
    // id falls through to the same not-attached snapshot as a missing header;
    // methods that actually need a session enforce it themselves via
    // `attached(...)`, returning NotAttached against this empty snapshot.
    let snap = match header_session(headers).and_then(|sid| state.conns.get(&sid)) {
        Some(entry) => entry.state.lock().snapshot(),
        None => rpc::ConnSnapshot {
            client_id: String::new(),
            attached: None,
        },
    };

    let manager = Arc::clone(&state.manager);
    let devices = state.devices.clone();
    let resp = tokio::task::spawn_blocking(move || {
        rpc::dispatch_concurrent(&manager, &snap, &devices, req)
    })
    .await
    .unwrap_or_else(|e| {
        motif_proto::envelope::Response::err(
            Id::Num(0),
            RpcError::internal(format!("dispatch panic: {e}")),
        )
    });

    (resp, None, None)
}

/// Run `session.attach` / `session.detach`. Mutates ConnState so we
/// can't go through `spawn_blocking` with a borrow — we hold the
/// registry's per-entry mutex for the call.
async fn dispatch_mutating(
    state: AppState,
    headers: &HeaderMap,
    req: Request,
) -> (
    motif_proto::envelope::Response,
    Option<String>,
    Option<String>,
) {
    match req.method.as_str() {
        "session.attach" => handle_attach_http(state, headers, req).await,
        "session.detach" => handle_detach_http(state, headers, req).await,
        _ => (
            motif_proto::envelope::Response::err(
                Id::Num(0),
                RpcError::internal("non-mutating method routed to mutating dispatch"),
            ),
            None,
            None,
        ),
    }
}

async fn handle_attach_http(
    state: AppState,
    headers: &HeaderMap,
    req: Request,
) -> (
    motif_proto::envelope::Response,
    Option<String>,
    Option<String>,
) {
    // Attach is also the reconnect path. If the browser/native client
    // still has a live session_id, reuse its ConnState so dispatch_mut
    // can replace the existing attachment instead of creating another
    // client_id. If the header is missing or stale, mint a new entry.
    state.conns.gc(&state.manager);
    let (session_id, entry, minted) = match header_session(headers)
        .and_then(|sid| state.conns.get(&sid).map(|entry| (sid, entry)))
    {
        Some((sid, entry)) => (sid, entry, false),
        None => {
            let (sid, entry) = state.conns.mint();
            (sid, entry, true)
        }
    };
    let manager = Arc::clone(&state.manager);

    // Use blocking spawn since dispatch_mut -> attach_client touches
    // session-wide locks; consistent with WS path's treatment of
    // mutating dispatch as a synchronous operation. We hold the ConnEntry
    // lock for the duration of dispatch_mut.
    let entry_for_task = Arc::clone(&entry);
    let resp = tokio::task::spawn_blocking(move || {
        let mut conn = entry_for_task.state.lock();
        rpc::dispatch_mut(&manager, &mut conn, req)
    })
    .await
    .unwrap_or_else(|e| {
        motif_proto::envelope::Response::err(
            Id::Num(0),
            RpcError::internal(format!("attach panic: {e}")),
        )
    });

    // If attach failed, drop the freshly minted entry so the client
    // doesn't end up with a dangling session_id pointing at empty
    // state.
    if resp.error.is_some() && minted {
        state.conns.remove(&session_id);
        return (resp, None, None);
    }

    (resp, Some(session_id), None)
}

async fn handle_detach_http(
    state: AppState,
    headers: &HeaderMap,
    req: Request,
) -> (
    motif_proto::envelope::Response,
    Option<String>,
    Option<String>,
) {
    let Some(session_id) = header_session(headers) else {
        return (
            motif_proto::envelope::Response::err(
                Id::Num(0),
                RpcError::invalid_request("missing X-Motif-Session header"),
            ),
            None,
            None,
        );
    };
    let Some(entry) = state.conns.get(&session_id) else {
        return (
            motif_proto::envelope::Response::err(
                Id::Num(0),
                RpcError::new(ErrorCode::NotAttached, "unknown or expired session_id"),
            ),
            None,
            None,
        );
    };
    let entry: Arc<ConnEntry> = entry;
    let manager = Arc::clone(&state.manager);
    let resp = tokio::task::spawn_blocking(move || {
        let mut conn = entry.state.lock();
        rpc::dispatch_mut(&manager, &mut conn, req)
    })
    .await
    .unwrap_or_else(|e| {
        motif_proto::envelope::Response::err(
            Id::Num(0),
            RpcError::internal(format!("detach panic: {e}")),
        )
    });

    // Always remove on detach — even on error. The error usually means
    // "already not attached", and we don't want to keep a stale entry
    // around. (Compare WS path: connection closing is implicit GC.)
    state.conns.remove(&session_id);
    (resp, None, Some(session_id))
}

fn header_session(headers: &HeaderMap) -> Option<String> {
    headers
        .get(SESSION_HEADER)
        .and_then(|v| v.to_str().ok())
        .map(|s| s.to_string())
}

fn err_response(
    err: RpcError,
    req_recv_at: Instant,
    method: &str,
    minted_session: Option<&str>,
    peer: PeerAddr,
) -> Response {
    let body_bytes = serde_json::to_vec(&err).unwrap_or_else(|_| b"{}".to_vec());
    let status = match err.code {
        -32600 => StatusCode::BAD_REQUEST,
        -32601 => StatusCode::NOT_FOUND,
        -32602 => StatusCode::BAD_REQUEST,
        -32700 => StatusCode::BAD_REQUEST,
        c if c == ErrorCode::AuthRequired as i32 => StatusCode::UNAUTHORIZED,
        c if c == ErrorCode::PathEscape as i32 => StatusCode::FORBIDDEN,
        c if c == ErrorCode::SessionNotFound as i32 => StatusCode::NOT_FOUND,
        c if c == ErrorCode::NotAttached as i32 => StatusCode::CONFLICT,
        c if c == ErrorCode::AlreadyExists as i32 => StatusCode::CONFLICT,
        c if c == ErrorCode::PtyNotFound as i32 => StatusCode::NOT_FOUND,
        c if c == ErrorCode::FileTooLarge as i32 => StatusCode::PAYLOAD_TOO_LARGE,
        _ => StatusCode::INTERNAL_SERVER_ERROR,
    };
    tracing::info!(
        target: TIMING_TARGET,
        peer       = %peer,
        method     = %method,
        resp_size  = body_bytes.len(),
        total_ms   = us_to_ms(req_recv_at.elapsed().as_micros() as u64),
        error      = true,
        code       = err.code,
        transport  = "http",
        "rpc done",
    );
    let mut r = (status, body_bytes).into_response();
    r.headers_mut()
        .insert("content-type", HeaderValue::from_static("application/json"));
    if let Some(sid) = minted_session {
        if let Ok(v) = HeaderValue::from_str(sid) {
            r.headers_mut().insert(SESSION_HEADER, v);
        }
    }
    r
}

fn us_to_ms(us: u64) -> f64 {
    us as f64 / 1000.0
}

/// Re-export so tests / external code referring to ConnState through
/// the HTTP path don't need to dig into rpc::ConnState directly.
pub use rpc::ConnSnapshot as _ConnSnapshotPub;
pub type _ConnStatePub = ConnState;
