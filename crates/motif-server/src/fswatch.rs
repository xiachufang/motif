//! Filesystem watcher per session.
//!
//! Why: PTY-driven changes (touch, git add, editor saves) bypass our fs.* RPC
//! layer, so without a watcher the client never gets `tree.changed` /
//! `git.changed` for those edits and the file tree / git pane go stale.
//!
//! Strategy: notify-debouncer-mini watches `workdir` recursively, coalesces
//! bursts (200ms), then a forwarder thread filters out high-frequency dirs
//! (`.git/objects`, `node_modules`, `target`, …) and publishes:
//!   - `tree.changed` for any worktree path
//!   - `git.changed`  for any path under `.git/` (except the excluded subtrees)
//!     OR any worktree path (worktree edits flip git status too)
//!
//! Lifetime: the returned `FsWatcher` owns the debouncer; dropping it stops
//! the watch and the forwarder thread exits when the channel closes.

use std::path::{Path, PathBuf};
use std::sync::Weak;
use std::time::Duration;

use notify::RecursiveMode;
use notify_debouncer_mini::new_debouncer;

use crate::session::Session;
use motif_proto::event::Event;

const TREE_PATHS_CAP: usize = 64;

pub struct FsWatcher {
    _debouncer: Box<dyn std::any::Any + Send + Sync>,
}

pub fn spawn(session: Weak<Session>, workdir: PathBuf) -> Result<FsWatcher, String> {
    let (tx, rx) = std::sync::mpsc::channel();
    let mut debouncer = new_debouncer(Duration::from_millis(200), tx)
        .map_err(|e| format!("create debouncer: {e}"))?;
    debouncer
        .watcher()
        .watch(&workdir, RecursiveMode::Recursive)
        .map_err(|e| format!("watch {}: {e}", workdir.display()))?;

    let workdir_t = workdir.clone();
    std::thread::Builder::new()
        .name("motif-fswatch".into())
        .spawn(move || forward_loop(session, workdir_t, rx))
        .map_err(|e| format!("spawn forwarder: {e}"))?;

    Ok(FsWatcher { _debouncer: Box::new(debouncer) })
}

fn forward_loop(
    session: Weak<Session>,
    workdir: PathBuf,
    rx: std::sync::mpsc::Receiver<notify_debouncer_mini::DebounceEventResult>,
) {
    while let Ok(result) = rx.recv() {
        let Some(s) = session.upgrade() else { return };
        let events = match result {
            Ok(events) => events,
            Err(e) => {
                tracing::warn!(?e, "fswatch error");
                continue;
            }
        };

        let mut tree_paths: Vec<String> = Vec::new();
        let mut git_changed = false;

        for de in events {
            let Ok(rel) = de.path.strip_prefix(&workdir) else { continue };
            if is_excluded(rel) { continue; }

            if rel.starts_with(".git") {
                git_changed = true;
            } else {
                if tree_paths.len() < TREE_PATHS_CAP {
                    tree_paths.push(rel.to_string_lossy().into_owned());
                }
                git_changed = true;
            }
        }

        if !tree_paths.is_empty() {
            s.publish_event(|seq| Event::TreeChanged { paths: tree_paths, seq });
        }
        if git_changed {
            s.publish_event(|seq| Event::GitChanged { seq });
        }
    }
}

fn is_excluded(rel: &Path) -> bool {
    // Hot directories nested anywhere in the tree (npm install, build outputs).
    for c in rel.components() {
        if let std::path::Component::Normal(s) = c {
            let s = s.to_string_lossy();
            if matches!(
                s.as_ref(),
                "node_modules" | "target" | "dist" | "build"
                | ".next" | ".nuxt" | ".vite" | ".turbo" | ".cache"
                | "coverage" | ".pytest_cache" | "__pycache__"
            ) {
                return true;
            }
        }
    }
    // git-internal hot subtrees we don't care about for `git status`.
    rel.starts_with(".git/objects")
        || rel.starts_with(".git/logs")
        || rel.starts_with(".git/lfs")
        || rel.starts_with(".git/pack")
}
