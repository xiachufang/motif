//! End-to-end check that the PTY reader_loop actually *answers* terminal
//! capability queries instead of just stripping them.
//!
//! Setup: spawn a default shell, send `stty raw -echo; exec cat` to switch
//! the PTY into raw mode (no canonical line buffering, no echo) and replace
//! the shell with `cat`. Now stdin → stdout is a direct passthrough with
//! no transformation. Then:
//!   1. We write an OSC 11 query via the master writer (== cat's stdin).
//!   2. cat copies it byte-for-byte to its stdout.
//!   3. The reader_loop reads the query off stdout, recognizes it, strips
//!      it from the broadcast, and writes the canonical answer back via
//!      `pty.write_bytes` (== cat's stdin).
//!   4. cat copies the answer to stdout.
//!   5. The reader_loop reads the answer (passthrough — it's not a query)
//!      and broadcasts it as `pty.output`.
//!
//! Asserting that step 5's broadcast contains the expected reply bytes
//! pins the contract: server-side answer path works, and the answer is
//! either the canonical default or the client-reported palette.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use motif_proto::common::ClientId;
use motif_proto::event::Event;
use motif_proto::pty::PtyCreateParams;
use motif_server::pty::Pty;
use motif_server::session::manager::SessionManager;
use motif_server::session::Session;
use tokio::sync::broadcast::Receiver;

fn unique_tmpdir(tag: &str) -> PathBuf {
    let p = std::env::temp_dir().join(format!("motif-{}-{}", tag, ulid::Ulid::new()));
    std::fs::create_dir_all(&p).expect("mkdir tempdir");
    p
}

/// Spawn `/bin/sh`, switch the PTY into raw + no-echo, then exec into `cat`
/// so subsequent writes to the master are echoed back through the broadcast
/// unmodified. This is the byte-faithful test scaffold for query→answer round
/// trips: without it, the PTY's default cooked mode turns `\x1b]11;?\x07`
/// into the visible string `^[]11;?^G` before the reader_loop sees it.
async fn spawn_passthrough_pty(session: &Arc<Session>) -> Arc<Pty> {
    let mut rx = session.subscribe();
    let pty = session
        .pty_pool
        .create(
            PtyCreateParams {
                cmd: Some("/bin/sh".into()),
                cwd: None,
                env: vec![],
                cols: 80,
                rows: 24,
            },
            ClientId::from("test-client"),
            &session.workdir,
        )
        .expect("spawn pty");

    drain(&mut rx);
    pty.write_bytes(b"stty raw -echo; exec cat\n")
        .expect("setup write");

    // Do not rely on a fixed sleep here. The default cooked PTY line
    // discipline echoes control bytes as caret notation, so use a raw OSC 9
    // passthrough probe and wait until `cat` echoes the exact bytes back.
    let probe = format!("\x1b]9;motif-ready-{}\x07", ulid::Ulid::new());
    pty.write_bytes(probe.as_bytes()).expect("probe write");
    wait_for_bytes(&mut rx, probe.as_bytes(), Duration::from_secs(5)).await;

    pty
}

/// Drain whatever the broadcast accumulated during shell startup / setup
/// so the test only sees the answer to its own query.
fn drain(rx: &mut Receiver<Arc<Event>>) {
    while rx.try_recv().is_ok() {}
}

async fn wait_for_bytes(rx: &mut Receiver<Arc<Event>>, needle: &[u8], duration: Duration) {
    let mut out = Vec::new();
    let deadline = tokio::time::Instant::now() + duration;
    while tokio::time::Instant::now() < deadline {
        let remaining = deadline - tokio::time::Instant::now();
        match tokio::time::timeout(remaining, rx.recv()).await {
            Ok(Ok(ev)) => {
                if let Event::PtyOutput { data, .. } = ev.as_ref() {
                    out.extend_from_slice(data);
                    if out.windows(needle.len()).any(|w| w == needle) {
                        return;
                    }
                    let keep_from = out.len().saturating_sub(16 * 1024);
                    if keep_from > 0 {
                        out.drain(..keep_from);
                    }
                }
            }
            _ => break,
        }
    }
    panic!(
        "passthrough PTY did not echo raw probe; needle={:?}, collected={:?}",
        needle, out,
    );
}

async fn collect_for(rx: &mut Receiver<Arc<Event>>, duration: Duration) -> Vec<u8> {
    let mut out = Vec::new();
    let deadline = tokio::time::Instant::now() + duration;
    while tokio::time::Instant::now() < deadline {
        let remaining = deadline - tokio::time::Instant::now();
        match tokio::time::timeout(remaining, rx.recv()).await {
            Ok(Ok(ev)) => {
                if let Event::PtyOutput { data, .. } = ev.as_ref() {
                    out.extend_from_slice(data);
                }
            }
            _ => break,
        }
    }
    out
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn osc11_falls_back_to_canonical_when_no_palette() {
    let raw = unique_tmpdir("osc11-default");
    let mgr = SessionManager::new();
    let session = mgr
        .create("osc11-default".into(), raw.clone())
        .expect("create session");

    let pty = spawn_passthrough_pty(&session).await;
    let mut rx = session.subscribe();
    drain(&mut rx);

    pty.write_bytes(b"\x1b]11;?\x07").expect("write query");
    let collected = collect_for(&mut rx, Duration::from_millis(800)).await;

    pty.kill();
    let _ = std::fs::remove_dir_all(&raw);

    let s = String::from_utf8_lossy(&collected);
    assert!(
        s.contains("\x1b]11;rgb:0a0a/0a0a/0a0a"),
        "canonical OSC 11 reply not in broadcast: bytes={:?}",
        collected,
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn osc11_uses_client_reported_palette_when_set() {
    let raw = unique_tmpdir("osc11-custom");
    let mgr = SessionManager::new();
    let session = mgr
        .create("osc11-custom".into(), raw.clone())
        .expect("create session");

    // Pretend a TUI client reported its terminal palette on attach.
    session.set_terminal_palette(Some("ffff/eeee/dddd".into()), Some("1111/2222/3333".into()));

    let pty = spawn_passthrough_pty(&session).await;
    let mut rx = session.subscribe();
    drain(&mut rx);

    pty.write_bytes(b"\x1b]11;?\x07").expect("write query");
    let collected = collect_for(&mut rx, Duration::from_millis(800)).await;

    pty.kill();
    let _ = std::fs::remove_dir_all(&raw);

    let s = String::from_utf8_lossy(&collected);
    assert!(
        s.contains("\x1b]11;rgb:1111/2222/3333"),
        "custom OSC 11 reply not in broadcast: bytes={:?}",
        collected,
    );
    // The hardcoded default must NOT appear when the palette is set —
    // otherwise we'd be answering twice.
    assert!(
        !s.contains("\x1b]11;rgb:0a0a/0a0a/0a0a"),
        "canonical reply leaked when palette was set: bytes={:?}",
        collected,
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn osc10_uses_client_reported_foreground() {
    let raw = unique_tmpdir("osc10-custom");
    let mgr = SessionManager::new();
    let session = mgr
        .create("osc10-custom".into(), raw.clone())
        .expect("create session");

    session.set_terminal_palette(Some("aaaa/bbbb/cccc".into()), Some("0000/0000/0000".into()));

    let pty = spawn_passthrough_pty(&session).await;
    let mut rx = session.subscribe();
    drain(&mut rx);

    pty.write_bytes(b"\x1b]10;?\x07").expect("write query");
    let collected = collect_for(&mut rx, Duration::from_millis(800)).await;

    pty.kill();
    let _ = std::fs::remove_dir_all(&raw);

    let s = String::from_utf8_lossy(&collected);
    assert!(
        s.contains("\x1b]10;rgb:aaaa/bbbb/cccc"),
        "custom OSC 10 reply not in broadcast: bytes={:?}",
        collected,
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn da1_always_gets_canonical_answer() {
    // DA1 is a "what terminal are you" query — it's not client-specific,
    // so the answer is always the canonical VT102 reply regardless of
    // whether a palette has been set.
    let raw = unique_tmpdir("da1");
    let mgr = SessionManager::new();
    let session = mgr
        .create("da1".into(), raw.clone())
        .expect("create session");

    // Set a palette — DA1 must still ignore it.
    session.set_terminal_palette(Some("ffff/eeee/dddd".into()), Some("1111/2222/3333".into()));

    let pty = spawn_passthrough_pty(&session).await;
    let mut rx = session.subscribe();
    drain(&mut rx);

    pty.write_bytes(b"\x1b[c").expect("write DA1 query");
    let collected = collect_for(&mut rx, Duration::from_millis(800)).await;

    pty.kill();
    let _ = std::fs::remove_dir_all(&raw);

    let s = String::from_utf8_lossy(&collected);
    assert!(
        s.contains("\x1b[?6c"),
        "DA1 reply not in broadcast: bytes={:?}",
        collected,
    );
}
