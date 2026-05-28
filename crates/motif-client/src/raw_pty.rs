//! Raw bidirectional PTY pump used by `motif-cast` (and any future "share
//! my terminal" entrypoint).
//!
//! Behaves like a tmux client: puts the local terminal into raw mode,
//! forwards stdin → `pty.write`, paints `pty.output` events to stdout, and
//! sends `pty.resize` on SIGWINCH. The PTY itself lives inside motifd, so
//! closing the local terminal does NOT kill the program — the host CLI
//! decides whether to destroy the session on exit (via its own guard).
//!
//! The pump takes the notification stream by value (extracted from
//! [`crate::client::Client::take_notifications`]) and the rest of the
//! `Client` behind `Arc<Mutex<…>>`. That split is what lets the caller's
//! drop-time `session.destroy` happen on the same `Client` while the pump
//! is running — without it we'd deadlock the mutex on every notification.

use std::io::{Read, Write};
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{anyhow, Context};
use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
use motif_proto::common::PtyId;
use motif_proto::envelope::Notification;
use motif_proto::pty as ppty;
use motif_proto::view as pview;
use serde_json::Value;
use tokio::signal::unix::{signal, SignalKind};
use tokio::sync::{mpsc, Mutex};

use crate::focus::{FocusEvent, InputFocusFilter, OutputFocusFilter};

/// Fallback re-assert cadence for terminals without focus reporting: local
/// typing stands in for "focus", re-claiming primary at most this often (not
/// an RPC per keystroke). When focus reporting works, `CSI I` reclaims
/// precisely and this is just a backstop.
const RECLAIM_THROTTLE: Duration = Duration::from_secs(2);

/// Restores terminal state no matter how the function returns: disables focus
/// reporting (which we enable for the session) and raw mode. Constructed after
/// every fallible setup step so a failure doesn't leave a stale guard behind.
struct RawGuard;
impl RawGuard {
    fn enable() -> anyhow::Result<Self> {
        crossterm::terminal::enable_raw_mode().context("enabling raw mode")?;
        // Own the local terminal's focus-reporting (DECSET 1004) state for the
        // whole session so we receive `CSI I`/`CSI O` regardless of what the
        // inner program does with 1004 (its toggles are stripped from output).
        let mut out = std::io::stdout();
        let _ = out.write_all(crate::focus::ENABLE_FOCUS);
        let _ = out.flush();
        Ok(RawGuard)
    }
}
impl Drop for RawGuard {
    fn drop(&mut self) {
        let mut out = std::io::stdout();
        let _ = out.write_all(crate::focus::DISABLE_FOCUS);
        let _ = crossterm::terminal::disable_raw_mode();
        // Newline so the next shell prompt doesn't paste onto the last
        // line of the (now-detached) PTY's output.
        let _ = writeln!(out);
    }
}

pub fn current_size() -> (u16, u16) {
    crossterm::terminal::size().unwrap_or((120, 40))
}

/// Run the I/O loop for a single PTY until it exits or the connection drops.
/// `pty_id` must already exist on the server; the caller is responsible for
/// `session.attach` + `pty.create`. Returns `Ok(())` on the inner PTY's
/// `pty.exited`, on stdin EOF, or when the WebSocket reader signals close.
pub async fn pump(
    client: Arc<Mutex<crate::coordinator::Coordinator>>,
    mut events: mpsc::UnboundedReceiver<Notification>,
    pty_id: PtyId,
) -> anyhow::Result<()> {
    let _guard = RawGuard::enable()?;

    // Stdin reader runs on a dedicated OS thread — std::io::stdin doesn't
    // have an async equivalent that respects raw mode. We forward chunks
    // through an mpsc; when stdin EOFs the channel closes and the main
    // loop exits.
    let (stdin_tx, mut stdin_rx) = mpsc::channel::<Vec<u8>>(64);
    std::thread::spawn(move || {
        let mut buf = [0u8; 4096];
        let stdin = std::io::stdin();
        let mut lock = stdin.lock();
        loop {
            match lock.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    if stdin_tx.blocking_send(buf[..n].to_vec()).is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    });

    let mut sigwinch =
        signal(SignalKind::window_change()).context("installing SIGWINCH handler")?;

    let mut stdout = std::io::stdout();

    // View id of our PTY (captured from the auto-opened view event), and the
    // last time we re-asserted primary. Seeded in the past so the first
    // keystroke reclaims immediately.
    let mut view_id: Option<String> = None;
    let mut last_reclaim = Instant::now()
        .checked_sub(RECLAIM_THROTTLE)
        .unwrap_or_else(Instant::now);

    // Focus-reporting arbitration. `out_filter` strips the inner program's
    // 1004 toggles (and tracks whether it wants focus events); `in_filter`
    // pulls `CSI I`/`CSI O` out of stdin for our own use and only forwards
    // them to the inner program when it enabled 1004.
    let mut out_filter = OutputFocusFilter::new();
    let mut in_filter = InputFocusFilter::new();
    let mut inner_wants_focus = false;

    loop {
        tokio::select! {
            // Bias toward reading server output first so the terminal feels
            // responsive when the user is just watching.
            biased;

            n_opt = events.recv() => {
                let n = match n_opt {
                    Some(n) => n,
                    None    => return Ok(()), // ws reader closed
                };
                match n.method.as_str() {
                    "pty.output" => {
                        let pid = n.params.get("pty_id").and_then(Value::as_str);
                        if pid != Some(pty_id.as_str()) { continue; }
                        let Some(b64) = n.params.get("data_b64").and_then(Value::as_str) else { continue; };
                        let bytes = BASE64.decode(b64.as_bytes())
                            .map_err(|e| anyhow!("decode pty.output: {e}"))?;
                        // Strip the inner program's 1004 toggles before writing
                        // to the local terminal (we own its 1004 state), and
                        // record whether it wants focus events forwarded.
                        let mut cleaned = Vec::with_capacity(bytes.len());
                        let mut toggles = Vec::new();
                        out_filter.feed(&bytes, &mut cleaned, &mut toggles);
                        if let Some(&last) = toggles.last() { inner_wants_focus = last; }
                        stdout.write_all(&cleaned)?;
                        stdout.flush()?;
                    }
                    "pty.exited" => {
                        let pid = n.params.get("pty_id").and_then(Value::as_str);
                        if pid == Some(pty_id.as_str()) { return Ok(()); }
                    }
                    "view.opened" => {
                        // Remember the view id the server auto-opened for our
                        // PTY, so local typing can re-activate it to reclaim
                        // primary.
                        let view = n.params.get("view");
                        let spec_pty = view
                            .and_then(|v| v.get("spec"))
                            .and_then(|s| s.get("pty_id"))
                            .and_then(Value::as_str);
                        if spec_pty == Some(pty_id.as_str()) {
                            view_id = view
                                .and_then(|v| v.get("id"))
                                .and_then(Value::as_str)
                                .map(String::from);
                        }
                    }
                    _ => {}
                }
            }

            bytes_opt = stdin_rx.recv() => {
                let Some(bytes) = bytes_opt else { return Ok(()); };
                // Pull focus events out of the input; forward them to the inner
                // program only if it enabled 1004, else strip (a shell that
                // didn't ask for 1004 must not receive spurious `^[[I`).
                let mut forward = Vec::with_capacity(bytes.len());
                let mut focus = Vec::new();
                in_filter.feed(&bytes, inner_wants_focus, &mut forward, &mut focus);
                let forwarded = !forward.is_empty();

                let c = client.lock().await;
                if forwarded {
                    let _: Value = c.call(
                        "pty.write",
                        ppty::PtyWriteParams {
                            pty_id: pty_id.clone(),
                            data:   forward,
                        },
                    ).await?;
                }
                // Reclaim primary: precisely on focus-in, with local typing as a
                // throttled fallback for terminals without focus reporting.
                // Best-effort — a failed reclaim must not tear down the cast.
                let focus_in = focus.iter().any(|e| *e == FocusEvent::In);
                let typed = forwarded && last_reclaim.elapsed() >= RECLAIM_THROTTLE;
                if let Some(vid) = &view_id {
                    if focus_in || typed {
                        last_reclaim = Instant::now();
                        let _ = c.call::<_, Value>(
                            "view.activate",
                            pview::ActivateParams { view_id: Some(vid.clone()) },
                        ).await;
                    }
                }
            }

            _ = sigwinch.recv() => {
                let (cols, rows) = current_size();
                let c = client.lock().await;
                let _: Value = c.call(
                    "pty.resize",
                    ppty::PtyResizeParams { pty_id: pty_id.clone(), cols, rows },
                ).await?;
            }
        }
    }
}
