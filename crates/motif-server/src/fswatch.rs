//! Filesystem watcher per session.
//!
//! Why: PTY-driven changes (touch, git add, editor saves) bypass our fs.* RPC
//! layer, so without a watcher the client never gets `tree.changed` /
//! `git.changed` for those edits and the file tree / git pane go stale.
//!
//! Strategy: notify-debouncer-full watches a single root recursively,
//! coalesces bursts (200ms), then a forwarder thread:
//!   - Filters out high-frequency hot dirs (`.git/objects`, `node_modules`,
//!     build outputs, …).
//!   - Publishes `tree.changed` only on Create / Remove / Rename — content
//!     edits don't change the file-tree entries the client renders.
//!   - Publishes `git.changed` on Create / Remove / Modify (incl. content
//!     edits and metadata changes), but only when the path lives inside a
//!     git repo. The "in repo?" lookup walks ancestors for a `.git` and
//!     caches per-directory; the cache invalidates when this watcher itself
//!     observes a `.git` Create/Remove, so `git init` / `rm -rf .git` mid-
//!     session is picked up without re-attaching.
//!
//! Root tracking: the watch root follows the session's active PTY's cwd —
//! `Session::sync_watch_to_active` calls [`FsWatcher::swap_root`] on view
//! activation and on `pty.cwd_changed`. The forwarder reads the current
//! root through a shared `Arc<Mutex<PathBuf>>` so mid-flight events use the
//! up-to-date prefix for `strip_prefix`. The brief overlap during
//! unwatch/watch may drop a few events; that's acceptable.
//!
//! Lifetime: the returned `FsWatcher` owns the debouncer; dropping it stops
//! the watch and the forwarder thread exits when the channel closes.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Weak};
use std::time::Duration;

use notify::event::ModifyKind;
use notify::{Config, EventKind, RecommendedWatcher, RecursiveMode};
use notify_debouncer_full::{new_debouncer_opt, DebounceEventResult, Debouncer, NoCache};
use parking_lot::Mutex;

use crate::session::Session;
use motif_proto::event::Event;

const TREE_PATHS_CAP: usize = 64;

pub struct FsWatcher {
    debouncer: Debouncer<RecommendedWatcher, NoCache>,
    /// Shared with the forwarder thread so events post-`swap_root` get
    /// `strip_prefix`'d against the new root, not the old.
    root: Arc<Mutex<PathBuf>>,
}

impl FsWatcher {
    pub fn root(&self) -> PathBuf {
        self.root.lock().clone()
    }

    /// Re-target the watcher at `new_root`. No-op if the root is unchanged.
    /// Old root is unwatched best-effort (failures logged, not propagated)
    /// so a transient unwatch error doesn't prevent attaching to the new
    /// path.
    pub fn swap_root(&mut self, new_root: PathBuf) -> Result<(), String> {
        let old = self.root.lock().clone();
        if old == new_root {
            return Ok(());
        }
        if let Err(e) = self.debouncer.unwatch(&old) {
            tracing::warn!(old = %old.display(), error = %e, "fswatch unwatch");
        }
        self.debouncer
            .watch(&new_root, RecursiveMode::Recursive)
            .map_err(|e| format!("watch {}: {e}", new_root.display()))?;
        *self.root.lock() = new_root;
        Ok(())
    }
}

pub fn spawn(session: Weak<Session>, workdir: PathBuf) -> Result<FsWatcher, String> {
    let (tx, rx) = std::sync::mpsc::channel::<DebounceEventResult>();
    // NoCache: skip the default FileIdMap, which would WalkDir the entire
    // workdir at watch-time to build a file_id → path map. On large trees
    // (e.g. `~`) that walk takes minutes and blocks `session.create`. We
    // don't need rename pairing — `Modify(Name(_))` events without a
    // From/To partner still classify correctly as tree-changing.
    let mut debouncer: Debouncer<RecommendedWatcher, NoCache> = new_debouncer_opt(
        Duration::from_millis(200),
        None,
        tx,
        NoCache,
        Config::default(),
    )
    .map_err(|e| format!("create debouncer: {e}"))?;
    debouncer
        .watch(&workdir, RecursiveMode::Recursive)
        .map_err(|e| format!("watch {}: {e}", workdir.display()))?;

    let root = Arc::new(Mutex::new(workdir));
    let root_for_loop = root.clone();
    std::thread::Builder::new()
        .name("motif-fswatch".into())
        .spawn(move || forward_loop(session, root_for_loop, rx))
        .map_err(|e| format!("spawn forwarder: {e}"))?;

    Ok(FsWatcher { debouncer, root })
}

fn forward_loop(
    session: Weak<Session>,
    root: Arc<Mutex<PathBuf>>,
    rx: std::sync::mpsc::Receiver<DebounceEventResult>,
) {
    // dir → "is this dir inside a git repo?". Built lazily; invalidated
    // wholesale when this watcher observes a `.git` Create/Remove anywhere
    // in the tree (rare, cheap to rebuild on demand). Also cleared on
    // `swap_root` since the new tree may have entirely different repo
    // boundaries.
    let mut repo_cache: HashMap<PathBuf, bool> = HashMap::new();
    let mut last_seen_root = root.lock().clone();

    while let Ok(result) = rx.recv() {
        let Some(s) = session.upgrade() else { return };
        let workdir = root.lock().clone();
        if workdir != last_seen_root {
            repo_cache.clear();
            last_seen_root = workdir.clone();
        }
        let events = match result {
            Ok(events) => events,
            Err(errs) => {
                for e in errs {
                    tracing::warn!(?e, "fswatch error");
                }
                continue;
            }
        };

        let mut tree_paths: Vec<String> = Vec::new();
        let mut git_changed = false;

        for de in events {
            let kind = de.event.kind;
            // Access (read/open/close) is pure noise — skip outright.
            if matches!(kind, EventKind::Access(_)) {
                continue;
            }

            // Pre-compute classifications once per event (cheap; same for
            // every path in the event).
            let is_create = matches!(kind, EventKind::Create(_));
            let is_remove = matches!(kind, EventKind::Remove(_));
            let is_rename = matches!(kind, EventKind::Modify(ModifyKind::Name(_)));
            // tree.changed: only structure-changing events. Pure content
            // edits don't change `fs.tree` entries.
            let tree_event = is_create || is_remove || is_rename;
            // git.changed: anything that could change `git status` output —
            // creates, deletes, renames, content edits, metadata. We could
            // be even more specific but git status is cheap to recompute
            // and the alternative is missing a state change.
            let git_event = is_create || is_remove
                || matches!(kind, EventKind::Modify(_))
                // Other / Any: be conservative, treat as a state change.
                || matches!(kind, EventKind::Other | EventKind::Any);

            for path in &de.event.paths {
                let Ok(rel) = path.strip_prefix(&workdir) else {
                    continue;
                };
                if is_excluded(rel) {
                    continue;
                }

                // Self-maintain the repo cache: when a `.git` entry itself
                // appears or disappears, drop everything and let the next
                // events rebuild lazily. This is the only time the cache
                // can go stale, and `.git` create/remove is rare.
                if (is_create || is_remove) && rel.file_name().map(|n| n == ".git").unwrap_or(false)
                {
                    repo_cache.clear();
                }

                if tree_event && !rel.starts_with(".git") && tree_paths.len() < TREE_PATHS_CAP {
                    tree_paths.push(rel.to_string_lossy().into_owned());
                }

                if !git_changed
                    && git_event
                    && (rel.starts_with(".git") || path_in_git_repo(&workdir, rel, &mut repo_cache))
                {
                    git_changed = true;
                }
            }
        }

        if !tree_paths.is_empty() {
            s.publish_event(|seq| Event::TreeChanged {
                paths: tree_paths,
                seq,
            });
        }
        if git_changed {
            s.publish_event(|seq| Event::GitChanged { seq });
        }
    }
}

/// Walk from the changed path's parent up to the watch root, asking
/// "does this directory contain `.git`?". Caches every directory seen so
/// the next event under the same subtree is O(1). `.git` can be a dir
/// (normal repo) or a file (worktree/submodule pointer); both count.
fn path_in_git_repo(workdir: &Path, rel: &Path, cache: &mut HashMap<PathBuf, bool>) -> bool {
    let abs = workdir.join(rel);
    let start = abs.parent().unwrap_or(&abs);
    let mut walked: Vec<PathBuf> = Vec::new();
    let mut cur: &Path = start;

    let result = loop {
        if let Some(&hit) = cache.get(cur) {
            break hit;
        }
        if cur.join(".git").exists() {
            cache.insert(cur.to_path_buf(), true);
            break true;
        }
        walked.push(cur.to_path_buf());
        // Don't escape the watch root — anything above `workdir` is
        // outside this session's concern.
        if cur == workdir {
            break false;
        }
        match cur.parent() {
            Some(p) => cur = p,
            None => break false,
        }
    };
    for d in walked {
        cache.insert(d, result);
    }
    result
}

fn is_excluded(rel: &Path) -> bool {
    // Hot directories nested anywhere in the tree (npm install, build outputs).
    for c in rel.components() {
        if let std::path::Component::Normal(s) = c {
            let s = s.to_string_lossy();
            if matches!(
                s.as_ref(),
                "node_modules"
                    | "target"
                    | "dist"
                    | "build"
                    | ".next"
                    | ".nuxt"
                    | ".vite"
                    | ".turbo"
                    | ".cache"
                    | "coverage"
                    | ".pytest_cache"
                    | "__pycache__"
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
