//! Local unix-socket listener that receives Claude Code hook notifications.
//!
//! A Claude Code `Notification`/`Stop` hook (provisioned with zero user config
//! by the shell bootstrap — see `crate::shell`) runs `motif-notify.sh`, which
//! POSTs the hook's stdin JSON to this socket. We deliberately use a unix
//! socket rather than the main axum router: it's auth-gated by filesystem
//! permissions (0600, local-only) instead of the bearer token, so no secret
//! has to be exposed in the PTY environment.
//!
//! On each hook we (i) publish an `Event::Notification` to the originating
//! session's broadcast (the "live" channel — attached clients show an in-app
//! / terminal banner) and (ii) forward an encrypted payload to the push relay
//! for iOS background delivery (`crate::relay`).

use std::path::{Path, PathBuf};
use std::sync::Arc;

use bytes::Bytes;
use http_body_util::{BodyExt, Full};
use hyper::body::Incoming;
use hyper::service::service_fn;
use hyper::{Request, Response, StatusCode};
use hyper_util::rt::TokioIo;
use motif_proto::event::Event;
use serde::Deserialize;
use tokio::net::UnixListener;
use tokio_util::sync::CancellationToken;

use crate::relay::{DeviceState, PushNotification};
use crate::session::manager::SessionManager;

/// Header carrying the originating motif session name (injected into the PTY
/// env as `MOTIF_SESSION_NAME` and forwarded by `motif-notify.sh`). Empty /
/// absent when the hook didn't fire inside a motif PTY.
const SESSION_HEADER: &str = "x-motif-session";

/// Claude Code hook payload (subset we use), delivered on the hook command's
/// stdin and forwarded verbatim as the POST body.
#[derive(Debug, Default, Deserialize)]
struct HookPayload {
    #[serde(default)]
    message: Option<String>,
    #[serde(default)]
    title: Option<String>,
    #[serde(default)]
    hook_event_name: Option<String>,
    /// The assistant's final message for the turn. Claude Code includes this
    /// directly on Stop/SubagentStop hooks, so we surface it as the body
    /// without reading the transcript (and with no write-flush race).
    #[serde(default)]
    last_assistant_message: Option<String>,
}

/// Resolve the hook socket path: `$XDG_RUNTIME_DIR/motifd/hook.sock`, else
/// `$TMPDIR/motifd/hook.sock`, else `/tmp/motifd/hook.sock`.
pub fn default_hook_socket_path() -> PathBuf {
    let base = std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("TMPDIR").map(PathBuf::from))
        .unwrap_or_else(|| PathBuf::from("/tmp"));
    base.join("motifd").join("hook.sock")
}

/// Bind the unix socket (0600) and serve hook POSTs until `shutdown` fires.
/// Returns the bound listener wrapped in a task. Errors binding are fatal to
/// the push feature but not to motifd, so the caller logs and continues.
pub fn spawn(
    path: PathBuf,
    devices: DeviceState,
    manager: Arc<SessionManager>,
    shutdown: CancellationToken,
) -> std::io::Result<tokio::task::JoinHandle<()>> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
        let _ = set_dir_private(parent);
    }
    // Remove a stale socket from a prior run before binding.
    let _ = std::fs::remove_file(&path);
    let listener = UnixListener::bind(&path)?;
    let _ = set_socket_private(&path);
    tracing::info!(socket = %path.display(), "hook ingress listening");

    let handle = tokio::spawn(async move {
        loop {
            tokio::select! {
                _ = shutdown.cancelled() => break,
                accepted = listener.accept() => {
                    let (stream, _addr) = match accepted {
                        Ok(v) => v,
                        Err(e) => {
                            tracing::warn!("hook ingress accept failed: {e}");
                            continue;
                        }
                    };
                    let devices = devices.clone();
                    let manager = manager.clone();
                    tokio::spawn(async move {
                        let io = TokioIo::new(stream);
                        let svc = service_fn(move |req| {
                            handle(req, devices.clone(), manager.clone())
                        });
                        if let Err(e) =
                            hyper::server::conn::http1::Builder::new().serve_connection(io, svc).await
                        {
                            tracing::debug!("hook ingress conn ended: {e}");
                        }
                    });
                }
            }
        }
        // Best-effort cleanup so a restart can rebind cleanly.
        let _ = std::fs::remove_file(&path);
    });
    Ok(handle)
}

async fn handle(
    req: Request<Incoming>,
    devices: DeviceState,
    manager: Arc<SessionManager>,
) -> Result<Response<Full<Bytes>>, std::convert::Infallible> {
    let session_name = req
        .headers()
        .get(SESSION_HEADER)
        .and_then(|v| v.to_str().ok())
        .map(|s| s.to_string())
        .filter(|s| !s.is_empty());

    let body = match req.into_body().collect().await {
        Ok(b) => b.to_bytes(),
        Err(_) => return Ok(reply(StatusCode::BAD_REQUEST)),
    };
    let payload: HookPayload = serde_json::from_slice(&body).unwrap_or_default();

    let is_stop = matches!(
        payload.hook_event_name.as_deref(),
        Some("Stop") | Some("SubagentStop")
    );
    let (default_title, kind) = match payload.hook_event_name.as_deref() {
        Some("Stop") | Some("SubagentStop") => ("Claude finished", "finished"),
        Some("Notification") => ("Claude needs your input", "needs_input"),
        _ => ("Claude Code", "info"),
    };
    // Title is the originating session name when known — with several Claude
    // sessions running at once, that's the disambiguator you scan for (the
    // finish/needs-input cue lives in `kind` + the body). Fall back to a
    // hook-provided title, then the generic default, outside a motif PTY.
    let title = session_name
        .clone()
        .or_else(|| payload.title.clone().filter(|t| !t.is_empty()))
        .unwrap_or_else(|| default_title.to_string());
    // Body precedence: an explicit hook `message` wins (Notification); else, on
    // a Stop/finish hook, the assistant's final message; else the generic
    // default.
    let body_text = payload
        .message
        .filter(|m| !m.is_empty())
        .or_else(|| {
            if is_stop {
                payload
                    .last_assistant_message
                    .as_deref()
                    .map(summarize)
                    .filter(|s| !s.is_empty())
            } else {
                None
            }
        })
        .unwrap_or_else(|| default_title.to_string());

    // (i) Live channel: publish to the originating session's broadcast.
    if let Some(name) = &session_name {
        if let Some(session) = manager.get(name) {
            let title = title.clone();
            let body_text = body_text.clone();
            let kind = kind.to_string();
            let name = name.clone();
            session.publish_event(|seq| Event::Notification {
                title,
                body: body_text,
                session_id: Some(name),
                kind,
                seq,
            });
        }
    }

    // (ii) Background channel: encrypted APNs via the relay.
    if let Some(relay) = &devices.relay {
        relay
            .push_to_all(
                &devices.store,
                &PushNotification {
                    title,
                    body: body_text,
                    session_id: session_name,
                    kind: kind.to_string(),
                },
            )
            .await;
    }

    Ok(reply(StatusCode::OK))
}

/// Condense an assistant message into a one-line, notification-sized snippet:
/// collapse runs of whitespace/newlines to single spaces, then truncate to a
/// char-boundary with an ellipsis if cut.
fn summarize(s: &str) -> String {
    let one_line = s.split_whitespace().collect::<Vec<_>>().join(" ");
    const MAX_CHARS: usize = 140;
    if one_line.chars().count() <= MAX_CHARS {
        return one_line;
    }
    let mut out: String = one_line.chars().take(MAX_CHARS).collect();
    out.push('…');
    out
}

fn reply(status: StatusCode) -> Response<Full<Bytes>> {
    Response::builder()
        .status(status)
        .body(Full::new(Bytes::from_static(b"{}")))
        .unwrap()
}

#[cfg(unix)]
fn set_socket_private(path: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))
}

#[cfg(unix)]
fn set_dir_private(path: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))
}

#[cfg(not(unix))]
fn set_socket_private(_path: &Path) -> std::io::Result<()> {
    Ok(())
}

#[cfg(not(unix))]
fn set_dir_private(_path: &Path) -> std::io::Result<()> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn summarize_collapses_whitespace() {
        assert_eq!(summarize("Done —\n  built the\tfeature."), "Done — built the feature.");
    }

    #[test]
    fn summarize_truncates_on_char_boundary_with_ellipsis() {
        let long = "x".repeat(200);
        let out = summarize(&long);
        assert_eq!(out.chars().count(), 141); // 140 + ellipsis
        assert!(out.ends_with('…'));
        assert_eq!(summarize("short"), "short");
    }
}
