//! End-to-end test for the v2 shell-integration pipeline:
//!   PtyPool::create  →  bash sources injected rcfile  →  OSC 133 markers
//!   →  reader_loop routes through ShellState  →  Event::Pty* broadcasts.
//!
//! Skipped at runtime when /bin/bash is missing (CI on minimal images).

use std::path::PathBuf;
use std::sync::Mutex;
use std::time::Duration;

use motif_proto::common::ClientId;
use motif_proto::event::Event;
use motif_proto::pty::{PtyCreateParams, ShellKind};
use motif_server::session::manager::SessionManager;

/// These tests share the process-wide `MOTIF_SHELL_INTEGRATION` env var
/// (set by the disabled-mode test). Cargo runs tests in a single
/// process by default, so we need a mutex to keep the env-mutating
/// case from racing the bash_emits case.
static ENV_LOCK: Mutex<()> = Mutex::new(());

fn unique_tmpdir(tag: &str) -> PathBuf {
    let p = std::env::temp_dir().join(format!("motif-shell-it-{}-{}", tag, ulid::Ulid::new()));
    std::fs::create_dir_all(&p).unwrap();
    p
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn bash_emits_block_lifecycle_events() {
    if !std::path::Path::new("/bin/bash").exists() {
        eprintln!("skipping: /bin/bash not present");
        return;
    }
    let _guard = ENV_LOCK.lock().unwrap_or_else(|p| p.into_inner());
    let raw     = unique_tmpdir("bash");
    let mgr     = SessionManager::new();
    let session = mgr.create("shell-it".into(), raw.clone()).expect("create session");
    let mut rx  = session.subscribe();

    let owner: ClientId = "tester".into();
    let pty = session.pty_pool.create(
        PtyCreateParams {
            cmd:  Some("/bin/bash".into()),
            cwd:  None,
            env:  vec![],
            cols: 80,
            rows: 24,
        },
        owner,
        &session.workdir,
    ).expect("spawn pty");

    // 1. Wait for the shell_bootstrapped announcement (real bash → Bash;
    //    bootstrap injection failure → Unknown via 5s timeout).
    let deadline = tokio::time::Instant::now() + Duration::from_secs(7);
    let mut bootstrapped: Option<ShellKind> = None;
    while tokio::time::Instant::now() < deadline && bootstrapped.is_none() {
        if let Ok(Ok(ev)) = tokio::time::timeout(Duration::from_millis(800), rx.recv()).await {
            if let Event::PtyShellBootstrapped { shell, .. } = ev.as_ref() {
                bootstrapped = Some(*shell);
            }
        }
    }
    let kind = bootstrapped.expect("no shell_bootstrapped event within 7s");
    assert!(matches!(kind, ShellKind::Bash),
        "expected Bash, got {kind:?} — bootstrap injection may have failed");

    // 2. Submit a command, watch the started → finished lifecycle.
    tokio::time::sleep(Duration::from_millis(250)).await;
    pty.write_bytes(b"echo motif-hi\n").expect("write to pty");

    let mut started_id: Option<String> = None;
    let mut finished_exit: Option<Option<i32>> = None;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(6);
    while tokio::time::Instant::now() < deadline && finished_exit.is_none() {
        if let Ok(Ok(ev)) = tokio::time::timeout(Duration::from_millis(800), rx.recv()).await {
            match ev.as_ref() {
                Event::PtyCommandStarted { text, block_id, .. } if started_id.is_none() => {
                    if text.contains("echo motif-hi") {
                        started_id = Some(block_id.clone());
                    }
                }
                Event::PtyCommandFinished { block_id, exit_code, .. }
                    if started_id.as_ref() == Some(block_id) =>
                {
                    finished_exit = Some(*exit_code);
                }
                _ => {}
            }
        }
    }

    let id = started_id.clone().expect("no command_started for `echo motif-hi`");
    assert!(!id.is_empty(), "block id should not be empty");
    let exit = finished_exit.expect("no command_finished within 6s");
    assert_eq!(exit, Some(0), "echo should exit 0; got {exit:?}");

    // 3. The finished block must land in the BlockStore so a late-join
    //    client could fetch it via `pty.list_blocks` / `pty.get_block_output`.
    let blocks = pty.list_blocks(None, 10);
    let summary = blocks.iter().find(|b| b.id == id)
        .expect("finished block missing from BlockStore");
    assert_eq!(summary.cmd, "echo motif-hi");
    assert_eq!(summary.exit_code, Some(0));
    assert!(summary.output_size > 0);

    let seg = pty.get_block_output(&id)
        .expect("get_block_output: block not found");
    assert!(!seg.output_truncated, "tiny output should not be truncated");
    let utf = String::from_utf8_lossy(&seg.output);
    assert!(utf.contains("motif-hi"),
        "block output should contain `motif-hi`; got: {utf:?}");

    pty.kill();
    let _ = std::fs::remove_dir_all(&raw);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn shell_integration_disabled_falls_back_to_unknown() {
    // MOTIF_SHELL_INTEGRATION=0 — skip injection. The 5s timeout should
    // still emit Bootstrapped { shell: Unknown } so clients stop waiting.
    if !std::path::Path::new("/bin/bash").exists() {
        eprintln!("skipping: /bin/bash not present");
        return;
    }
    let _guard = ENV_LOCK.lock().unwrap_or_else(|p| p.into_inner());
    let prev_env = std::env::var_os("MOTIF_SHELL_INTEGRATION");
    std::env::set_var("MOTIF_SHELL_INTEGRATION", "0");

    let raw     = unique_tmpdir("disabled");
    let mgr     = SessionManager::new();
    let session = mgr.create("shell-it-off".into(), raw.clone()).expect("create session");
    let mut rx  = session.subscribe();

    let pty = session.pty_pool.create(
        PtyCreateParams {
            cmd:  Some("/bin/bash".into()),
            cwd:  None, env: vec![], cols: 80, rows: 24,
        },
        "tester".into(),
        &session.workdir,
    ).expect("spawn pty");

    // Restore env early so other parallel tests don't inherit the off
    // state. Bootstrap::prepare already read it for this PTY's spawn.
    match prev_env {
        Some(v) => std::env::set_var("MOTIF_SHELL_INTEGRATION", v),
        None    => std::env::remove_var("MOTIF_SHELL_INTEGRATION"),
    }

    let deadline = tokio::time::Instant::now() + Duration::from_secs(7);
    let mut got: Option<ShellKind> = None;
    while tokio::time::Instant::now() < deadline && got.is_none() {
        if let Ok(Ok(ev)) = tokio::time::timeout(Duration::from_millis(800), rx.recv()).await {
            if let Event::PtyShellBootstrapped { shell, .. } = ev.as_ref() {
                got = Some(*shell);
            }
        }
    }
    pty.kill();
    let _ = std::fs::remove_dir_all(&raw);
    assert!(matches!(got, Some(ShellKind::Unknown)),
        "expected timeout-driven Unknown, got {got:?}");
}
