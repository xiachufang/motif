//! End-to-end test for the "shell `cd` updates the file tree" feature.
//!
//! Reproduces the bug we hit on macOS where the session workdir was the
//! user-supplied `/tmp/foo` while the kernel reported the child's cwd as
//! `/private/tmp/foo`, breaking the `cwd.starts_with(workdir)` check on the
//! client and silently freezing the file-tree pane.
//!
//! This test exercises the full chain:
//!   SessionManager::create  →  PtyPool::create  →  shell `cd <sub>`
//!   →  cwd watcher  →  Event::PtyCwdChanged
//! and asserts the reported cwd is inside the session's canonical workdir.

use std::path::PathBuf;
use std::time::Duration;

use motif_proto::common::ClientId;
use motif_proto::event::Event;
use motif_proto::pty::PtyCreateParams;
use motif_server::session::manager::SessionManager;

/// Unique tempdir under the system tmp. We deliberately do NOT canonicalize
/// the path we hand to SessionManager — the manager is supposed to do that.
fn unique_tmpdir(tag: &str) -> PathBuf {
    let p = std::env::temp_dir().join(format!("motif-{}-{}", tag, ulid::Ulid::new()));
    std::fs::create_dir_all(&p).expect("mkdir tempdir");
    p
}

#[test]
fn session_manager_canonicalizes_workdir() {
    // The fix: a workdir under `/tmp` on macOS must be stored as its
    // `/private/tmp/...` canonical form, otherwise the kernel-reported cwd
    // for child processes won't `starts_with` it.
    let raw = unique_tmpdir("canon");
    let canon = raw.canonicalize().expect("canonicalize raw");

    let mgr = SessionManager::new();
    let session = mgr.create("canon-test".into(), raw.clone()).expect("create session");

    assert_eq!(
        session.workdir, canon,
        "session.workdir should be the canonical path, not the user-supplied one",
    );

    let _ = std::fs::remove_dir_all(&raw);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn pty_cd_emits_cwd_changed_inside_workdir() {
    let raw     = unique_tmpdir("cd");
    let sub_raw = raw.join("sub");
    std::fs::create_dir_all(&sub_raw).expect("mkdir sub");
    let sub_canon = sub_raw.canonicalize().expect("canonicalize sub");

    let mgr     = SessionManager::new();
    let session = mgr.create("cd-test".into(), raw.clone()).expect("create session");

    // The post-fix invariant the client relies on: any cwd inside the workdir
    // tree (after canonicalization) must `starts_with(session.workdir)`.
    assert!(
        sub_canon.starts_with(&session.workdir),
        "sub {sub_canon:?} should live inside canonical workdir {:?}",
        session.workdir,
    );

    // Subscribe BEFORE creating the PTY so we don't miss any early events.
    let mut rx = session.subscribe();

    let owner: ClientId = "test-client".into();
    let pty = session.pty_pool.create(
        PtyCreateParams {
            cmd:  Some("/bin/sh".into()),
            cwd:  None, // defaults to session.workdir (already canonical)
            env:  vec![],
            cols: 80,
            rows: 24,
        },
        owner,
        &session.workdir,
    ).expect("spawn pty");

    // Let the shell finish its startup before we shove input at it.
    tokio::time::sleep(Duration::from_millis(300)).await;
    let line = format!("cd {}\n", sub_raw.display());
    pty.write_bytes(line.as_bytes()).expect("write to pty");

    // Watcher polls every 1.5s, so wait up to 5s for the transition event.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    let mut observed: Option<PathBuf> = None;
    while tokio::time::Instant::now() < deadline {
        let remaining = deadline - tokio::time::Instant::now();
        match tokio::time::timeout(remaining, rx.recv()).await {
            Ok(Ok(ev)) => {
                if let Event::PtyCwdChanged { cwd, .. } = ev.as_ref() {
                    if cwd == &sub_canon {
                        observed = Some(cwd.clone());
                        break;
                    }
                }
            }
            _ => break,
        }
    }

    pty.kill();
    let _ = std::fs::remove_dir_all(&raw);

    let observed = observed.expect(
        "did not see PtyCwdChanged with the expected canonical sub path within 5s",
    );
    assert!(
        observed.starts_with(&session.workdir),
        "reported cwd {observed:?} must live under session workdir {:?} \
         — otherwise the file-tree pane will reject it as 'outside workdir'",
        session.workdir,
    );
}

#[test]
fn fs_tree_accepts_absolute_path_outside_workdir() {
    // Per the design call in this thread: workdir is no longer a hard
    // boundary, the file tree should follow the active PTY's cwd anywhere
    // on disk. fs.tree must accept an absolute path that is not under the
    // session workdir and just list it.
    use motif_proto::fs::TreeParams;

    let raw = unique_tmpdir("absolute-tree-workdir");
    // Create a SIBLING dir outside the session workdir, populate it.
    let outside_parent = unique_tmpdir("absolute-tree-outside");
    let outside        = outside_parent.canonicalize().unwrap();
    std::fs::write(outside.join("a.txt"), b"hi").unwrap();
    std::fs::create_dir_all(outside.join("sub")).unwrap();

    let mgr     = SessionManager::new();
    let session = mgr.create("absolute-tree".into(), raw.clone()).expect("create session");

    // Sanity: the outside path is genuinely not under the session workdir.
    assert!(!outside.starts_with(&session.workdir));

    let params = TreeParams { path: outside.to_string_lossy().into_owned(), depth: 1, show_hidden: false };
    let result = motif_server::fs::tree(&session, &params).expect("fs.tree should accept absolute path outside workdir");

    let names: Vec<&str> = result.entries.iter().map(|e| e.name.as_str()).collect();
    assert!(names.contains(&"a.txt"), "expected a.txt in {names:?}");
    assert!(names.contains(&"sub"),   "expected sub in {names:?}");

    let _ = std::fs::remove_dir_all(&raw);
    let _ = std::fs::remove_dir_all(&outside_parent);
}
