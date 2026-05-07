//! End-to-end check that the PTY reader strips terminal capability queries
//! (DA1, OSC 11, …) from the broadcast stream before they reach clients.
//!
//! Without this, fish (and starship's prompt) emit DA1 / CPR queries to
//! stdout, those bytes flow to xterm.js in motif-web, xterm.js auto-answers
//! them via `term.onData`, and the answer arrives at fish's stdin so late
//! that fish has already given up on the query and renders the response
//! bytes as a fake keystroke. This test pins the contract on the server
//! side: query bytes must never make it into a `pty.output` event.

use std::path::PathBuf;
use std::time::Duration;

use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
use motif_proto::common::ClientId;
use motif_proto::event::Event;
use motif_proto::pty::PtyCreateParams;
use motif_server::session::manager::SessionManager;

fn unique_tmpdir(tag: &str) -> PathBuf {
    let p = std::env::temp_dir().join(format!("motif-{}-{}", tag, ulid::Ulid::new()));
    std::fs::create_dir_all(&p).expect("mkdir tempdir");
    p
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn pty_output_strips_da1_query() {
    let raw     = unique_tmpdir("query-filter");
    let mgr     = SessionManager::new();
    let session = mgr.create("query-filter".into(), raw.clone()).expect("create session");

    let mut rx = session.subscribe();

    let owner: ClientId = "test-client".into();
    let pty = session.pty_pool.create(
        PtyCreateParams {
            cmd:  Some("/bin/sh".into()),
            cwd:  None,
            env:  vec![],
            cols: 80,
            rows: 24,
        },
        owner,
        &session.workdir,
    ).expect("spawn pty");

    // Drain anything emitted during shell startup so the assertion only
    // sees output that follows our printf.
    tokio::time::sleep(Duration::from_millis(300)).await;
    while let Ok(_) = rx.try_recv() {}

    // printf interprets \033 as ESC, so this writes the raw bytes
    // `ESC [ c V I S I B L E \n` to the master — exactly what fish would
    // emit on startup. The scanner must drop the `\x1b[c` and let the
    // rest through.
    pty.write_bytes(b"printf '\\033[cVISIBLE\\n'; exit\n").expect("write to pty");

    let mut all = Vec::new();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    let mut exited = false;
    while tokio::time::Instant::now() < deadline {
        let remaining = deadline - tokio::time::Instant::now();
        match tokio::time::timeout(remaining, rx.recv()).await {
            Ok(Ok(ev)) => {
                match ev.as_ref() {
                    Event::PtyOutput { data_b64, .. } => {
                        all.extend(BASE64.decode(data_b64).unwrap_or_default());
                    }
                    Event::PtyExited { .. } => { exited = true; break; }
                    _ => {}
                }
            }
            _ => break,
        }
    }

    pty.kill();
    let _ = std::fs::remove_dir_all(&raw);

    assert!(exited, "shell never exited; collected so far: {:?}", all);

    // The recognized query must be stripped, but the rest of the printf
    // output must come through verbatim.
    assert!(
        !all.windows(3).any(|w| w == b"\x1b[c"),
        "DA1 query leaked into broadcast — bytes: {:?}",
        all,
    );
    assert!(
        all.windows(7).any(|w| w == b"VISIBLE"),
        "post-query text was lost — bytes: {:?}",
        all,
    );
}
