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

use anyhow::{anyhow, Context};
use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
use motif_proto::common::PtyId;
use motif_proto::envelope::Notification;
use motif_proto::pty as ppty;
use serde_json::Value;
use tokio::signal::unix::{signal, SignalKind};
use tokio::sync::{mpsc, Mutex};

use crate::client::Client;

/// Restores the terminal mode no matter how the function returns. Constructed
/// after every fallible setup step so a failure to enable raw mode doesn't
/// leave a stale guard behind.
struct RawGuard;
impl RawGuard {
    fn enable() -> anyhow::Result<Self> {
        crossterm::terminal::enable_raw_mode().context("enabling raw mode")?;
        Ok(RawGuard)
    }
}
impl Drop for RawGuard {
    fn drop(&mut self) {
        let _ = crossterm::terminal::disable_raw_mode();
        // Newline so the next shell prompt doesn't paste onto the last
        // line of the (now-detached) PTY's output.
        let _ = writeln!(std::io::stdout());
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
    client: Arc<Mutex<Client>>,
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
                    if stdin_tx.blocking_send(buf[..n].to_vec()).is_err() { break; }
                }
                Err(_) => break,
            }
        }
    });

    let mut sigwinch = signal(SignalKind::window_change())
        .context("installing SIGWINCH handler")?;

    let mut stdout = std::io::stdout();

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
                        stdout.write_all(&bytes)?;
                        stdout.flush()?;
                    }
                    "pty.exited" => {
                        let pid = n.params.get("pty_id").and_then(Value::as_str);
                        if pid == Some(pty_id.as_str()) { return Ok(()); }
                    }
                    _ => {}
                }
            }

            bytes_opt = stdin_rx.recv() => {
                let Some(bytes) = bytes_opt else { return Ok(()); };
                let mut c = client.lock().await;
                let _: Value = c.call(
                    "pty.write",
                    ppty::PtyWriteParams {
                        pty_id:   pty_id.clone(),
                        data_b64: BASE64.encode(&bytes),
                    },
                ).await?;
            }

            _ = sigwinch.recv() => {
                let (cols, rows) = current_size();
                let mut c = client.lock().await;
                let _: Value = c.call(
                    "pty.resize",
                    ppty::PtyResizeParams { pty_id: pty_id.clone(), cols, rows },
                ).await?;
            }
        }
    }
}
