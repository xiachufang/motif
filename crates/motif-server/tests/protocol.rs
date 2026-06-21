//! End-to-end protocol coverage for `motif-server`.
//!
//! Each test boots the server in-process on an ephemeral port and drives it
//! through the real HTTP + WebSocket transport. The aim is twofold:
//! 1. Hit every JSON-RPC method and every server-emitted event variant.
//! 2. Prove multi-client mirroring: a mutation on client A produces the
//!    matching event on clients B/C with monotonically increasing seq.

mod common;

use std::process::Command;
use std::time::Duration;

use common::{b64_decode, b64_encode, init_git_repo, TestClient, TestServer};
use motif_proto::event::Event;
use motif_proto::{fs as pfs, git as pgit, pty as ppty, session as ses, view as pview};
use serde_json::json;
use tempfile::TempDir;

// ─────────────────────────── 1. session_lifecycle ───────────────────────────

#[tokio::test]
async fn session_lifecycle() {
    let server = TestServer::start().await;
    let dir_a = TempDir::new().unwrap();
    let dir_b = TempDir::new().unwrap();

    // list() empty
    let listed: ses::ListResult = server
        .call("session.list", ses::ListParams::default())
        .await
        .unwrap();
    assert_eq!(listed.sessions.len(), 0);

    // create A
    let created: ses::CreateResult = server
        .call(
            "session.create",
            ses::CreateParams {
                name: "A".into(),
                workdir: dir_a.path().to_path_buf(),
            },
        )
        .await
        .unwrap();
    assert_eq!(created.session.name, "A");
    assert_eq!(created.session.client_count, 0);

    // create B
    server
        .call::<_, ses::CreateResult>(
            "session.create",
            ses::CreateParams {
                name: "B".into(),
                workdir: dir_b.path().to_path_buf(),
            },
        )
        .await
        .unwrap();

    // list shows both, neither attached
    let listed: ses::ListResult = server
        .call("session.list", ses::ListParams::default())
        .await
        .unwrap();
    assert_eq!(listed.sessions.len(), 2);
    assert!(listed.sessions.iter().all(|s| s.client_count == 0));

    // attach A via TestClient (it tolerates AlreadyExists)
    let mut client_a = TestClient::connect(&server, "A", dir_a.path())
        .await
        .unwrap();
    assert_eq!(client_a.attach_result.session.name, "A");
    // Single attach => empty `clients` list (the new client isn't in the
    // `existing` snapshot — that's the rule that lets us know if siblings are
    // present without filtering out self).
    assert_eq!(client_a.attach_result.clients.len(), 0);

    let listed: ses::ListResult = server
        .call("session.list", ses::ListParams::default())
        .await
        .unwrap();
    let a = listed.sessions.iter().find(|s| s.name == "A").unwrap();
    assert_eq!(a.client_count, 1);

    // detach
    client_a.detach().await.unwrap();
    let listed: ses::ListResult = server
        .call("session.list", ses::ListParams::default())
        .await
        .unwrap();
    let a = listed.sessions.iter().find(|s| s.name == "A").unwrap();
    assert_eq!(a.client_count, 0);

    // destroy A
    server
        .call::<_, ses::DestroyResult>("session.destroy", ses::DestroyParams { name: "A".into() })
        .await
        .unwrap();
    let listed: ses::ListResult = server
        .call("session.list", ses::ListParams::default())
        .await
        .unwrap();
    assert_eq!(listed.sessions.len(), 1);
    assert_eq!(listed.sessions[0].name, "B");
}

// ─────────────────────────── 2. fs_operations_and_events ───────────────────────────

#[tokio::test]
async fn fs_operations_and_events() {
    let server = TestServer::start().await;
    let dir = TempDir::new().unwrap();
    let mut c = TestClient::connect(&server, "fs", dir.path())
        .await
        .unwrap();
    // tree.changed / git.changed are opt-in: subscribe before driving fs.* so
    // the per-client filter delivers them.
    let _: serde_json::Value = c.call("fs.watch", json!({})).await.unwrap();

    // mkdir sub/ — emits TreeChanged only (rpc.rs: no GitChanged for mkdir).
    let _: serde_json::Value = c.call("fs.mkdir", json!({ "path": "sub" })).await.unwrap();
    let ev = c
        .expect_event(
            "tree.changed after mkdir",
            |e| matches!(e, Event::TreeChanged { paths, .. } if paths.iter().any(|p| p == "sub")),
        )
        .await;
    let mkdir_seq = ev.seq();
    assert!(mkdir_seq > 0);

    // write sub/a.txt "hi" — emits TreeChanged + GitChanged.
    let payload = b"hi";
    let written: pfs::WriteResult = c
        .call(
            "fs.write",
            pfs::WriteParams {
                path: "sub/a.txt".into(),
                content_b64: b64_encode(payload),
                expected_sha256: None,
                force: false,
            },
        )
        .await
        .unwrap();
    let sha_v1 = written.sha256.clone();
    let tree_ev = c
        .expect_event("tree.changed after write", |e| {
            matches!(e, Event::TreeChanged { paths, .. } if paths.iter().any(|p| p == "sub/a.txt"))
        })
        .await;
    let git_ev = c
        .expect_event("git.changed after write", |e| {
            matches!(e, Event::GitChanged { .. })
        })
        .await;
    assert!(tree_ev.seq() > mkdir_seq);
    assert!(git_ev.seq() > tree_ev.seq());

    // stat
    let st: pfs::StatResult = c
        .call(
            "fs.stat",
            pfs::StatParams {
                path: "sub/a.txt".into(),
            },
        )
        .await
        .unwrap();
    assert_eq!(st.kind, pfs::FileType::File);
    assert_eq!(st.size, payload.len() as u64);

    // read — content + sha256 match
    let rd: pfs::ReadResult = c
        .call(
            "fs.read",
            pfs::ReadParams {
                path: "sub/a.txt".into(),
                max_bytes: 1024,
            },
        )
        .await
        .unwrap();
    assert!(!rd.truncated);
    assert!(!rd.binary);
    assert_eq!(b64_decode(&rd.content_b64), payload);
    assert_eq!(rd.sha256, sha_v1);

    // write with correct expected_sha256 — succeeds, new sha256 returned.
    let v2 = b"world\n";
    let written2: pfs::WriteResult = c
        .call(
            "fs.write",
            pfs::WriteParams {
                path: "sub/a.txt".into(),
                content_b64: b64_encode(v2),
                expected_sha256: Some(sha_v1.clone()),
                force: false,
            },
        )
        .await
        .unwrap();
    assert_ne!(written2.sha256, sha_v1);
    // Drain the matching events so the next assertion isn't confused.
    let _ = c.drain_events().await;

    // write with wrong expected_sha256 — Conflict.
    let (status, body) = c
        .call_raw(
            "fs.write",
            pfs::WriteParams {
                path: "sub/a.txt".into(),
                content_b64: b64_encode(b"x"),
                expected_sha256: Some("0".repeat(64)),
                force: false,
            },
        )
        .await
        .unwrap();
    assert!(!status.is_success(), "expected error, got {status}");
    let err: motif_proto::error::RpcError = serde_json::from_slice(&body).unwrap();
    assert_eq!(err.code, motif_proto::error::ErrorCode::Conflict as i32);

    // rename sub/a.txt → sub/b.txt — emits TreeChanged (with both paths) + GitChanged.
    let _: serde_json::Value = c
        .call(
            "fs.rename",
            json!({ "from": "sub/a.txt", "to": "sub/b.txt" }),
        )
        .await
        .unwrap();
    c.expect_event("tree.changed after rename", |e| {
        matches!(e, Event::TreeChanged { paths, .. }
            if paths.iter().any(|p| p == "sub/a.txt") && paths.iter().any(|p| p == "sub/b.txt"))
    })
    .await;
    c.expect_event("git.changed after rename", |e| {
        matches!(e, Event::GitChanged { .. })
    })
    .await;

    // remove sub/b.txt — emits TreeChanged + GitChanged.
    let _: serde_json::Value = c
        .call("fs.remove", json!({ "path": "sub/b.txt" }))
        .await
        .unwrap();
    c.expect_event(
        "tree.changed after remove",
        |e| matches!(e, Event::TreeChanged { paths, .. } if paths.iter().any(|p| p == "sub/b.txt")),
    )
    .await;
    c.expect_event("git.changed after remove", |e| {
        matches!(e, Event::GitChanged { .. })
    })
    .await;

    // tree at root, depth=2 — only `sub/` survives (empty after remove).
    let tree: pfs::TreeResult = c
        .call(
            "fs.tree",
            pfs::TreeParams {
                path: ".".into(),
                depth: 2,
                show_hidden: false,
            },
        )
        .await
        .unwrap();
    assert!(tree
        .entries
        .iter()
        .any(|e| e.name == "sub" && e.kind == pfs::FileType::Dir));
    assert!(tree
        .entries
        .iter()
        .all(|e| e.name != "a.txt" && e.name != "b.txt"));
}

/// `fs.tree` must list directories WITHOUT an attached session, so the dir
/// picker works before a session exists. `TestServer::call` sends no session
/// header, exercising exactly that path.
#[tokio::test]
async fn fs_tree_browses_without_a_session() {
    let server = TestServer::start().await;

    let tmp = tempfile::tempdir().unwrap();
    std::fs::create_dir(tmp.path().join("alpha")).unwrap();
    std::fs::write(tmp.path().join("beta.txt"), b"x").unwrap();

    // Absolute path: ignores the (home) browse base, lists the temp dir.
    let tree: pfs::TreeResult = server
        .call(
            "fs.tree",
            pfs::TreeParams {
                path: tmp.path().to_string_lossy().to_string(),
                depth: 1,
                show_hidden: false,
            },
        )
        .await
        .expect("fs.tree without a session should succeed");
    assert!(tree
        .entries
        .iter()
        .any(|e| e.name == "alpha" && e.kind == pfs::FileType::Dir));
    assert!(tree.entries.iter().any(|e| e.name == "beta.txt"));

    // `~` expands to $HOME even unattached (smoke: the call resolves & succeeds).
    server
        .call::<_, pfs::TreeResult>(
            "fs.tree",
            pfs::TreeParams {
                path: "~".into(),
                depth: 1,
                show_hidden: false,
            },
        )
        .await
        .expect("fs.tree ~ should resolve to $HOME without a session");
}

// ─────────────────────────── 3. git_operations ───────────────────────────

#[tokio::test]
async fn git_operations() {
    let server = TestServer::start().await;
    let dir = TempDir::new().unwrap();
    if init_git_repo(dir.path()).is_err() {
        eprintln!("skipping git_operations: `git` CLI not available");
        return;
    }
    let mut c = TestClient::connect(&server, "git", dir.path())
        .await
        .unwrap();

    // Mutate the tracked file via fs.write so git sees a working-tree change.
    let _: pfs::WriteResult = c
        .call(
            "fs.write",
            pfs::WriteParams {
                path: "README.md".into(),
                content_b64: b64_encode(b"hello\nworld\n"),
                expected_sha256: None,
                force: false,
            },
        )
        .await
        .unwrap();
    // Drain the fs events so they don't pollute later tests on this client.
    let _ = c.drain_events().await;

    // git.status — branch=main, README.md unstaged Modified.
    let status: pgit::StatusResult = c
        .call("git.status", pgit::StatusParams::default())
        .await
        .unwrap();
    assert_eq!(status.branch.as_deref(), Some("main"));
    let readme = status
        .files
        .iter()
        .find(|f| f.path == "README.md")
        .expect("README.md in status");
    assert_eq!(readme.unstaged, pgit::GitFileStatus::Modified);
    assert_eq!(readme.staged, pgit::GitFileStatus::Unmodified);

    // git.diff — unified patch contains the new line.
    let diff: pgit::DiffResult = c
        .call(
            "git.diff",
            pgit::DiffParams {
                path: Some("README.md".into()),
                staged: false,
                cwd: None,
            },
        )
        .await
        .unwrap();
    assert!(
        diff.patch.contains("+world"),
        "unstaged diff missing change: {}",
        diff.patch
    );

    // `git add README.md` so we can verify the staged path too.
    Command::new("git")
        .args(["add", "README.md"])
        .current_dir(dir.path())
        .status()
        .unwrap();

    let status: pgit::StatusResult = c
        .call("git.status", pgit::StatusParams::default())
        .await
        .unwrap();
    let readme = status.files.iter().find(|f| f.path == "README.md").unwrap();
    assert_eq!(readme.staged, pgit::GitFileStatus::Modified);
    assert_eq!(readme.unstaged, pgit::GitFileStatus::Unmodified);

    let diff_staged: pgit::DiffResult = c
        .call(
            "git.diff",
            pgit::DiffParams {
                path: Some("README.md".into()),
                staged: true,
                cwd: None,
            },
        )
        .await
        .unwrap();
    assert!(
        diff_staged.patch.contains("+world"),
        "staged diff missing change: {}",
        diff_staged.patch
    );

    // git.diffSummary — counts the added line.
    let summary: pgit::DiffSummaryResult = c
        .call(
            "git.diffSummary",
            pgit::DiffParams {
                path: None,
                staged: true,
                cwd: None,
            },
        )
        .await
        .unwrap();
    let entry = summary
        .files
        .iter()
        .find(|f| f.path == "README.md")
        .expect("README.md in summary");
    assert!(
        entry.additions >= 1,
        "expected at least 1 addition, got {entry:?}"
    );
}

// ─────────────────────────── 4. view_operations_and_events ───────────────────────────

#[tokio::test]
async fn view_operations_and_events() {
    let server = TestServer::start().await;
    let dir = TempDir::new().unwrap();
    std::fs::write(dir.path().join("README.md"), b"hi\n").unwrap();
    let mut c = TestClient::connect(&server, "views", dir.path())
        .await
        .unwrap();

    // Open a Preview view (default activate=true).
    let open1: pview::OpenResult = c
        .call(
            "view.open",
            pview::OpenParams {
                spec: pview::ViewSpec::Preview {
                    path: "README.md".into(),
                },
                activate: true,
            },
        )
        .await
        .unwrap();
    let v1 = open1.view.id.clone();
    let opened1 = c
        .expect_event(
            "view.opened (Preview)",
            |e| matches!(e, Event::ViewOpened { view, .. } if view.id == v1),
        )
        .await;
    // First view → also flips active.
    c.expect_event(
        "view.active_changed (-> v1)",
        |e| matches!(e, Event::ViewActiveChanged { view_id: Some(id), .. } if id == &v1),
    )
    .await;
    assert!(opened1.seq() > 0);

    // Open a Diff view, *without* activating, so we don't get an extra active_changed.
    let open2: pview::OpenResult = c
        .call(
            "view.open",
            pview::OpenParams {
                spec: pview::ViewSpec::Diff {
                    staged: false,
                    path: None,
                },
                activate: false,
            },
        )
        .await
        .unwrap();
    let v2 = open2.view.id.clone();
    c.expect_event(
        "view.opened (Diff)",
        |e| matches!(e, Event::ViewOpened { view, .. } if view.id == v2),
    )
    .await;

    // Move v2 to index 0.
    let _: pview::MoveResult = c
        .call(
            "view.move",
            pview::MoveParams {
                view_id: v2.clone(),
                to_index: 0,
            },
        )
        .await
        .unwrap();
    let moved = c
        .expect_event("view.moved", |e| matches!(e, Event::ViewMoved { .. }))
        .await;
    if let Event::ViewMoved { order, .. } = moved {
        assert_eq!(order.first(), Some(&v2));
        assert!(order.contains(&v1));
    }

    // Activate v2.
    let _: pview::ActivateResult = c
        .call(
            "view.activate",
            pview::ActivateParams {
                view_id: Some(v2.clone()),
            },
        )
        .await
        .unwrap();
    c.expect_event(
        "view.active_changed (-> v2)",
        |e| matches!(e, Event::ViewActiveChanged { view_id: Some(id), .. } if id == &v2),
    )
    .await;

    // Close the currently active view → view.closed + view.active_changed.
    let _: pview::CloseResult = c
        .call(
            "view.close",
            pview::CloseParams {
                view_id: v2.clone(),
            },
        )
        .await
        .unwrap();
    c.expect_event(
        "view.closed (v2)",
        |e| matches!(e, Event::ViewClosed { view_id, .. } if view_id == &v2),
    )
    .await;
    c.expect_event("view.active_changed after close", |e| {
        matches!(e, Event::ViewActiveChanged { .. })
    })
    .await;
}

// ─────────────────────────── 5. pty_lifecycle_and_mirror ───────────────────────────

#[tokio::test]
async fn pty_lifecycle_and_mirror() {
    let server = TestServer::start().await;
    let dir = TempDir::new().unwrap();
    let mut a = TestClient::connect(&server, "ptys", dir.path())
        .await
        .unwrap();
    let mut b = TestClient::connect(&server, "ptys", dir.path())
        .await
        .unwrap();
    let mut c = TestClient::connect(&server, "ptys", dir.path())
        .await
        .unwrap();
    // Drain any client.joined events accumulated during the attach handshake.
    let _ = a.drain_events().await;
    let _ = b.drain_events().await;
    let _ = c.drain_events().await;

    // A creates a PTY. cmd=/bin/sh keeps the test independent of the user's
    // login shell. env is left empty — the server fills in TERM/etc.
    let created: ppty::PtyCreateResult = a
        .call(
            "pty.create",
            ppty::PtyCreateParams {
                cmd: Some("/bin/sh".into()),
                cwd: None,
                env: vec![],
                cols: 80,
                rows: 24,
            },
        )
        .await
        .unwrap();
    let pty_id = created.info.id.clone();
    assert!(created.info.alive);

    // All three clients see pty.created + view.opened (auto-created Pty view).
    for client in [&mut a, &mut b, &mut c] {
        client
            .expect_event(
                "pty.created",
                |e| matches!(e, Event::PtyCreated { info, .. } if info.id == pty_id),
            )
            .await;
        client
            .expect_event("view.opened (Pty)", |e| {
                matches!(e, Event::ViewOpened { view, .. }
                    if matches!(&view.spec, pview::ViewSpec::Pty { pty_id: pid } if pid == &pty_id))
            })
            .await;
        // The new PTY view is activated as part of pty.create.
        client
            .expect_event("view.active_changed (-> Pty view)", |e| {
                matches!(
                    e,
                    Event::ViewActiveChanged {
                        view_id: Some(_),
                        ..
                    }
                )
            })
            .await;
    }

    // All three open /pty/<id> raw byte streams (pure transport — primary is
    // already A's from pty.create auto-activating the view).
    let mut a_ws = a.open_pty_ws(&pty_id, None).await.unwrap();
    let mut b_ws = b.open_pty_ws(&pty_id, None).await.unwrap();
    let mut c_ws = c.open_pty_ws(&pty_id, None).await.unwrap();

    // PTY input — A sends `echo motif-marker\n` over its /pty WS; all three
    // clients see the echoed output. Picking a deliberately unique token so we
    // don't false-positive on the shell's prompt.
    let cmd = b"echo motif-marker\n";
    a_ws.write(cmd).await.unwrap();
    // sh takes a moment to start + echo + run.
    let wait = Duration::from_secs(5);
    let needle = b"motif-marker";
    a_ws.read_until(needle, wait).await.unwrap();
    b_ws.read_until(needle, wait).await.unwrap();
    c_ws.read_until(needle, wait).await.unwrap();

    // pty.resize from A — all three see pty.resize event.
    let _: serde_json::Value = a
        .call(
            "pty.resize",
            ppty::PtyResizeParams {
                pty_id: pty_id.clone(),
                cols: 100,
                rows: 30,
            },
        )
        .await
        .unwrap();
    for client in [&mut a, &mut b, &mut c] {
        client
            .expect_event("pty.resize", |e| {
                matches!(e, Event::PtyResize { pty_id: pid, cols, rows, .. }
                    if pid == &pty_id && *cols == 100 && *rows == 30)
            })
            .await;
    }

    // B asks for the pty list — sees the single PTY with new dimensions.
    let listed: ppty::PtyListResult = b.call("pty.list", json!({})).await.unwrap();
    assert_eq!(listed.ptys.len(), 1);
    assert_eq!(listed.ptys[0].id, pty_id);
    assert_eq!(listed.ptys[0].cols, 100);
    assert!(listed.ptys[0].alive);

    // A kills the PTY → pty.exited + the auto-opened view closes.
    let _: serde_json::Value = a
        .call(
            "pty.kill",
            ppty::PtyKillParams {
                pty_id: pty_id.clone(),
            },
        )
        .await
        .unwrap();
    for client in [&mut a, &mut b, &mut c] {
        client
            .expect_event(
                "pty.exited",
                |e| matches!(e, Event::PtyExited { pty_id: pid, .. } if pid == &pty_id),
            )
            .await;
        client
            .expect_event("view.closed (Pty view)", |e| {
                matches!(e, Event::ViewClosed { .. })
            })
            .await;
    }
}

// ─────────────────────────── 6. multi_client_mirror ───────────────────────────

#[tokio::test]
async fn multi_client_mirror() {
    let server = TestServer::start().await;
    let dir = TempDir::new().unwrap();

    // A attaches first — no siblings.
    let mut a = TestClient::connect(&server, "mirror", dir.path())
        .await
        .unwrap();
    assert_eq!(a.attach_result.clients.len(), 0);
    // All three clients opt into tree.changed / git.changed (gated by fs.watch).
    let _: serde_json::Value = a.call("fs.watch", json!({})).await.unwrap();

    // B attaches — A sees `client.joined(B)`; B's snapshot lists A.
    let mut b = TestClient::connect(&server, "mirror", dir.path())
        .await
        .unwrap();
    let _: serde_json::Value = b.call("fs.watch", json!({})).await.unwrap();
    a.expect_event(
        "A: client.joined(B)",
        |e| matches!(e, Event::ClientJoined { client_id, .. } if client_id == &b.client_id),
    )
    .await;
    assert_eq!(b.attach_result.clients.len(), 1);
    assert_eq!(b.attach_result.clients[0].id, a.client_id);

    // C attaches — both A and B see `client.joined(C)`.
    let mut c = TestClient::connect(&server, "mirror", dir.path())
        .await
        .unwrap();
    let _: serde_json::Value = c.call("fs.watch", json!({})).await.unwrap();
    a.expect_event(
        "A: client.joined(C)",
        |e| matches!(e, Event::ClientJoined { client_id, .. } if client_id == &c.client_id),
    )
    .await;
    b.expect_event(
        "B: client.joined(C)",
        |e| matches!(e, Event::ClientJoined { client_id, .. } if client_id == &c.client_id),
    )
    .await;
    assert_eq!(c.attach_result.clients.len(), 2);

    // A track-last-seq helpers. The harness already buffers out-of-order
    // events; we additionally assert that what *we* expect arrives in strict
    // seq order on each client.
    let mut last_a: u64 = 0;
    let mut last_b: u64 = 0;
    let mut last_c: u64 = 0;
    let step = |label: &str, seq: u64, last: &mut u64| {
        assert!(seq > *last, "[{label}] seq {seq} not > previous {}", *last);
        *last = seq;
    };

    // ── A creates a PTY → pty.created + view.opened + view.active_changed.
    let created: ppty::PtyCreateResult = a
        .call(
            "pty.create",
            ppty::PtyCreateParams {
                cmd: Some("/bin/sh".into()),
                cwd: None,
                env: vec![],
                cols: 80,
                rows: 24,
            },
        )
        .await
        .unwrap();
    let pty_id = created.info.id.clone();
    let mut pty_view_id: Option<String> = None;
    for (label, client, last) in [
        ("A", &mut a, &mut last_a),
        ("B", &mut b, &mut last_b),
        ("C", &mut c, &mut last_c),
    ] {
        let pty_id_inner = pty_id.clone();
        let ev = client
            .expect_event(
                "pty.created",
                move |e| matches!(e, Event::PtyCreated { info, .. } if info.id == pty_id_inner),
            )
            .await;
        step(&format!("{label}: pty.created"), ev.seq(), last);
        let ev = client
            .expect_event("view.opened (Pty)", |e| {
                matches!(e, Event::ViewOpened { .. })
            })
            .await;
        if pty_view_id.is_none() {
            if let Event::ViewOpened { view, .. } = &ev {
                pty_view_id = Some(view.id.clone());
            }
        }
        step(&format!("{label}: view.opened"), ev.seq(), last);
        let ev = client
            .expect_event("view.active_changed", |e| {
                matches!(e, Event::ViewActiveChanged { .. })
            })
            .await;
        step(&format!("{label}: view.active_changed"), ev.seq(), last);
    }
    let pty_view_id = pty_view_id.expect("captured Pty view id");

    // ── A opens a Preview view without activating it → view.opened only.
    // Use fs.write so we don't race the fswatch debouncer with a separate
    // synthesized tree.changed event.
    let _: pfs::WriteResult = a
        .call(
            "fs.write",
            pfs::WriteParams {
                path: "seed.txt".into(),
                content_b64: b64_encode(b"seed\n"),
                expected_sha256: None,
                force: false,
            },
        )
        .await
        .unwrap();
    for (label, client, last) in [
        ("A", &mut a, &mut last_a),
        ("B", &mut b, &mut last_b),
        ("C", &mut c, &mut last_c),
    ] {
        let ev = client
            .expect_event("tree.changed (seed.txt)", |e| {
                matches!(e, Event::TreeChanged { paths, .. } if paths.iter().any(|p| p == "seed.txt"))
            })
            .await;
        step(&format!("{label}: tree.changed (seed.txt)"), ev.seq(), last);
        let ev = client
            .expect_event("git.changed (seed.txt)", |e| {
                matches!(e, Event::GitChanged { .. })
            })
            .await;
        step(&format!("{label}: git.changed (seed.txt)"), ev.seq(), last);
    }
    let preview: pview::OpenResult = a
        .call(
            "view.open",
            pview::OpenParams {
                spec: pview::ViewSpec::Preview {
                    path: "seed.txt".into(),
                },
                activate: false,
            },
        )
        .await
        .unwrap();
    let preview_id = preview.view.id.clone();
    for (label, client, last) in [
        ("A", &mut a, &mut last_a),
        ("B", &mut b, &mut last_b),
        ("C", &mut c, &mut last_c),
    ] {
        let preview_id = preview_id.clone();
        let ev = client
            .expect_event(
                "view.opened (Preview)",
                move |e| matches!(e, Event::ViewOpened { view, .. } if view.id == preview_id),
            )
            .await;
        step(&format!("{label}: view.opened (Preview)"), ev.seq(), last);
    }

    // ── A activates the Preview → view.active_changed.
    let _: pview::ActivateResult = a
        .call(
            "view.activate",
            pview::ActivateParams {
                view_id: Some(preview_id.clone()),
            },
        )
        .await
        .unwrap();
    for (label, client, last) in [
        ("A", &mut a, &mut last_a),
        ("B", &mut b, &mut last_b),
        ("C", &mut c, &mut last_c),
    ] {
        let preview_id = preview_id.clone();
        let ev = client
            .expect_event("view.active_changed (-> Preview)", move |e| {
                matches!(e, Event::ViewActiveChanged { view_id: Some(id), .. }
                    if id == &preview_id)
            })
            .await;
        step(
            &format!("{label}: view.active_changed (Preview)"),
            ev.seq(),
            last,
        );
    }

    // ── B writes a file → tree.changed + git.changed (broadcast to all 3).
    let _: pfs::WriteResult = b
        .call(
            "fs.write",
            pfs::WriteParams {
                path: "hello.txt".into(),
                content_b64: b64_encode(b"hi\n"),
                expected_sha256: None,
                force: false,
            },
        )
        .await
        .unwrap();
    for (label, client, last) in [
        ("A", &mut a, &mut last_a),
        ("B", &mut b, &mut last_b),
        ("C", &mut c, &mut last_c),
    ] {
        let ev = client
            .expect_event("tree.changed (hello.txt)", |e| {
                matches!(e, Event::TreeChanged { paths, .. } if paths.iter().any(|p| p == "hello.txt"))
            })
            .await;
        step(&format!("{label}: tree.changed"), ev.seq(), last);
        let ev = client
            .expect_event("git.changed", |e| matches!(e, Event::GitChanged { .. }))
            .await;
        step(&format!("{label}: git.changed"), ev.seq(), last);
    }

    // ── B reorders: move the Preview view (currently at index 1) to index 0.
    // Server-side, move_view is a no-op when from==to, so we deliberately
    // pick a view that isn't already at the target index.
    let _: pview::MoveResult = b
        .call(
            "view.move",
            pview::MoveParams {
                view_id: preview_id.clone(),
                to_index: 0,
            },
        )
        .await
        .unwrap();
    for (label, client, last) in [
        ("A", &mut a, &mut last_a),
        ("B", &mut b, &mut last_b),
        ("C", &mut c, &mut last_c),
    ] {
        let pty_view_id = pty_view_id.clone();
        let preview_id = preview_id.clone();
        let ev = client
            .expect_event("view.moved", move |e| {
                matches!(e, Event::ViewMoved { order, .. }
                    if order.first() == Some(&preview_id) && order.contains(&pty_view_id))
            })
            .await;
        step(&format!("{label}: view.moved"), ev.seq(), last);
    }

    // ── C closes the Preview view → view.closed + view.active_changed.
    let _: pview::CloseResult = c
        .call(
            "view.close",
            pview::CloseParams {
                view_id: preview_id.clone(),
            },
        )
        .await
        .unwrap();
    for (label, client, last) in [
        ("A", &mut a, &mut last_a),
        ("B", &mut b, &mut last_b),
        ("C", &mut c, &mut last_c),
    ] {
        let pid = preview_id.clone();
        let ev = client
            .expect_event(
                "view.closed (Preview)",
                move |e| matches!(e, Event::ViewClosed { view_id, .. } if view_id == &pid),
            )
            .await;
        step(&format!("{label}: view.closed"), ev.seq(), last);
        let ev = client
            .expect_event("view.active_changed after close", |e| {
                matches!(e, Event::ViewActiveChanged { .. })
            })
            .await;
        step(
            &format!("{label}: view.active_changed (after close)"),
            ev.seq(),
            last,
        );
    }

    // ── session.list from each client sees one session with client_count=3.
    for label in ["A", "B", "C"] {
        let client = match label {
            "A" => &a,
            "B" => &b,
            _ => &c,
        };
        let listed: ses::ListResult = client
            .call("session.list", ses::ListParams::default())
            .await
            .unwrap();
        let s = listed
            .sessions
            .iter()
            .find(|s| s.name == "mirror")
            .expect("mirror session");
        assert_eq!(s.client_count, 3, "[{label}] session.list client_count");
    }

    // ── C detaches → A and B see client.left(C).
    let c_id = c.client_id.clone();
    c.detach().await.unwrap();
    a.expect_event(
        "A: client.left(C)",
        |e| matches!(e, Event::ClientLeft { client_id, .. } if client_id == &c_id),
    )
    .await;
    b.expect_event(
        "B: client.left(C)",
        |e| matches!(e, Event::ClientLeft { client_id, .. } if client_id == &c_id),
    )
    .await;
}

// ─────────────────────────── 7. event_replay_on_reattach ───────────────────────────

#[tokio::test]
async fn event_replay_on_reattach() {
    let server = TestServer::start().await;
    let dir = TempDir::new().unwrap();

    // A attaches and seeds the ring with a few events. fs.watch first so the
    // tree.changed / git.changed events the test relies on actually go into
    // the ring (default-off post-`fs.watch` rewrite).
    let mut a = TestClient::connect(&server, "replay", dir.path())
        .await
        .unwrap();
    let _: serde_json::Value = a.call("fs.watch", json!({})).await.unwrap();
    let _: ppty::PtyCreateResult = a
        .call(
            "pty.create",
            ppty::PtyCreateParams {
                cmd: Some("/bin/sh".into()),
                cwd: None,
                env: vec![],
                cols: 80,
                rows: 24,
            },
        )
        .await
        .unwrap();
    let _: pfs::WriteResult = a
        .call(
            "fs.write",
            pfs::WriteParams {
                path: "f.txt".into(),
                content_b64: b64_encode(b"x\n"),
                expected_sha256: None,
                force: false,
            },
        )
        .await
        .unwrap();
    // Drain A's events and capture the highest seq we've published so far.
    let mut highest = 0u64;
    for ev in a.drain_events().await {
        highest = highest.max(ev.seq());
    }
    assert!(highest > 0, "expected some events to have been published");

    // ── Scenario 1: a fresh client subscribes with `since=0` and receives the
    //    full ring replay. B has to call fs.watch BEFORE opening /events:
    //    the per-client filter consults the live subscriber set during the
    //    replay loop, so a late subscribe drops the buffered tree/git events.
    let mut b = TestClient::connect_no_events(&server, "replay", dir.path())
        .await
        .unwrap();
    let _: serde_json::Value = b.call("fs.watch", json!({})).await.unwrap();
    b.spawn_events_ws(0).await.unwrap();
    let collected = b.drain_events().await;
    // B's own ClientJoined is filtered server-side; everything earlier is
    // replayed in order.
    assert!(
        collected
            .iter()
            .any(|e| matches!(e, Event::PtyCreated { .. })),
        "replay missing pty.created: {collected:?}"
    );
    assert!(
        collected
            .iter()
            .any(|e| matches!(e, Event::TreeChanged { .. })),
        "replay missing tree.changed: {collected:?}"
    );
    assert!(
        collected.iter().any(
            |e| matches!(e, Event::ClientJoined { client_id, .. } if client_id == &a.client_id)
        ),
        "replay missing client.joined(A): {collected:?}"
    );
    // Seqs are monotonic.
    let seqs: Vec<u64> = collected.iter().map(|e| e.seq()).collect();
    let sorted = {
        let mut s = seqs.clone();
        s.sort();
        s
    };
    assert_eq!(seqs, sorted, "replayed events out of order");

    // ── Scenario 2: a fresh client subscribes with `since=highest`.
    //    Only the new client.joined event (for itself, filtered) and any
    //    events strictly greater than `highest` are sent — for this client
    //    that means: nothing pre-existing replays, and only the live
    //    ClientLeft fires later. The ring-replay path should yield zero items.
    //    We use connect_no_events so we can choose the `since=` on the WS.
    let mut d = TestClient::connect_no_events(&server, "replay", dir.path())
        .await
        .unwrap();
    // Capture the seq published by D's own attach (the server already wrote
    // ClientJoined(D) into the ring; D itself filters that). After this point
    // we know the ring contains events up to at least D's attach seq.
    let d_attach_seq = d.attach_result.last_seq;
    // Subscribe before opening /events so we receive the upcoming
    // tree.changed / git.changed (subscribe-then-open keeps the filter happy).
    let _: serde_json::Value = d.call("fs.watch", json!({})).await.unwrap();
    d.spawn_events_ws(d_attach_seq).await.unwrap();
    let collected = d.drain_events().await;
    assert!(
        collected.iter().all(|e| e.seq() > d_attach_seq),
        "received pre-existing event with seq <= {d_attach_seq}: {collected:?}"
    );

    // Trigger one more event and confirm only that one shows up.
    let _: pfs::WriteResult = a
        .call(
            "fs.write",
            pfs::WriteParams {
                path: "g.txt".into(),
                content_b64: b64_encode(b"y\n"),
                expected_sha256: None,
                force: false,
            },
        )
        .await
        .unwrap();
    d.expect_event(
        "tree.changed (g.txt)",
        |e| matches!(e, Event::TreeChanged { paths, .. } if paths.iter().any(|p| p == "g.txt")),
    )
    .await;
    d.expect_event("git.changed (g.txt)", |e| {
        matches!(e, Event::GitChanged { .. })
    })
    .await;

    // ── Scenario 3: since= a value larger than current total → empty replay
    //    (no special close code, just zero past events; the WS stays open and
    //    delivers any subsequent live events normally).
    let mut e = TestClient::connect_no_events(&server, "replay", dir.path())
        .await
        .unwrap();
    e.spawn_events_ws(9_999_999).await.unwrap();
    let collected = e.drain_events().await;
    assert!(
        collected.is_empty(),
        "expected empty replay for huge since, got {collected:?}"
    );
}

// ─────────────────────────── 8. fs_watch_subscription ───────────────────────────

#[tokio::test]
async fn fs_watch_subscription_gates_events() {
    let server = TestServer::start().await;
    let dir = TempDir::new().unwrap();

    // ── Default state: no subscription, no events.
    let mut a = TestClient::connect(&server, "watch", dir.path())
        .await
        .unwrap();
    let _: pfs::WriteResult = a
        .call(
            "fs.write",
            pfs::WriteParams {
                path: "before.txt".into(),
                content_b64: b64_encode(b"hi\n"),
                expected_sha256: None,
                force: false,
            },
        )
        .await
        .unwrap();
    let collected = a.drain_events().await;
    assert!(
        collected
            .iter()
            .all(|e| !matches!(e, Event::TreeChanged { .. } | Event::GitChanged { .. })),
        "unsubscribed client received tree/git events: {collected:?}"
    );

    // ── Subscribe → events flow.
    let _: serde_json::Value = a.call("fs.watch", json!({})).await.unwrap();
    let _: pfs::WriteResult = a
        .call(
            "fs.write",
            pfs::WriteParams {
                path: "during.txt".into(),
                content_b64: b64_encode(b"yo\n"),
                expected_sha256: None,
                force: false,
            },
        )
        .await
        .unwrap();
    a.expect_event("tree.changed (during)", |e| {
        matches!(e, Event::TreeChanged { paths, .. } if paths.iter().any(|p| p == "during.txt"))
    })
    .await;
    a.expect_event("git.changed (during)", |e| {
        matches!(e, Event::GitChanged { .. })
    })
    .await;

    // ── Unsubscribe → events stop. fs.watch / fs.unwatch are both idempotent.
    let _: serde_json::Value = a.call("fs.unwatch", json!({})).await.unwrap();
    let _: serde_json::Value = a.call("fs.unwatch", json!({})).await.unwrap();
    let _: pfs::WriteResult = a
        .call(
            "fs.write",
            pfs::WriteParams {
                path: "after.txt".into(),
                content_b64: b64_encode(b"bye\n"),
                expected_sha256: None,
                force: false,
            },
        )
        .await
        .unwrap();
    let collected = a.drain_events().await;
    assert!(
        collected
            .iter()
            .all(|e| !matches!(e, Event::TreeChanged { .. } | Event::GitChanged { .. })),
        "events arrived after unwatch: {collected:?}"
    );

    // ── Multi-client: A subscribed, B not. A's write reaches only A.
    //    A must re-subscribe — we unwatched above.
    let _: serde_json::Value = a.call("fs.watch", json!({})).await.unwrap();
    let mut b = TestClient::connect(&server, "watch", dir.path())
        .await
        .unwrap();
    let _: pfs::WriteResult = a
        .call(
            "fs.write",
            pfs::WriteParams {
                path: "split.txt".into(),
                content_b64: b64_encode(b"split\n"),
                expected_sha256: None,
                force: false,
            },
        )
        .await
        .unwrap();
    a.expect_event(
        "A: tree.changed (split)",
        |e| matches!(e, Event::TreeChanged { paths, .. } if paths.iter().any(|p| p == "split.txt")),
    )
    .await;
    let b_collected = b.drain_events().await;
    assert!(
        b_collected
            .iter()
            .all(|e| !matches!(e, Event::TreeChanged { .. } | Event::GitChanged { .. })),
        "unsubscribed B received tree/git events: {b_collected:?}"
    );
}
