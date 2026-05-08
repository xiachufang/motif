//! ratatui-based attach UI. Tabs are server-synced (Option B mirror): the
//! session owns a `views: Vec<ViewInfo>` plus an `active_view`, and every
//! client mirrors that state. User actions go through `view.open` /
//! `view.close` / `view.activate` RPCs; the server broadcasts and we update.
//!
//! ## Keymap (tmux-flavored, emacs sub-mode keys)
//!
//! Default ("Pane") mode forwards every key to the active PTY — exactly like
//! a terminal multiplexer's pane. There is no separate "input mode": you're
//! always typing into the active pane unless you've pressed the prefix.
//!
//! **Prefix** is `Ctrl-g`. It deliberately avoids `Ctrl-b` (tmux),
//! `Ctrl-a` (screen) and `Ctrl-x` (bash readline + emacs prefix), which
//! means a motif TUI running inside any of those won't fight over the
//! prefix. (Zellij users: zellij's default mode-toggle is also `Ctrl-g`, so
//! if you nest motif inside zellij you'll need to remap one of them.)
//! After the prefix, single keys take a tmux-shaped command:
//!
//!   - `c`              create a new PTY tab (tmux: new-window)
//!   - `n` / `p`        next / previous tab
//!   - `&`              close current tab (tmux: kill-window)
//!   - `1`..`9`         jump to tab N (1-based, matches displayed labels)
//!   - `d`              detach (close motif TUI, server keeps running)
//!   - `?`              show help line
//!   - `r`              refresh tree + git
//!   - `g`              re-anchor file tree to active PTY's cwd
//!   - `D`              open diff tab (Shift+d so it doesn't collide with detach)
//!   - `t`              enter Tree mode (file-tree navigation)
//!   - `[`              enter Scroll mode (PTY scrollback; tmux: copy-mode)
//!   - `Ctrl-g`         send a literal Ctrl-g to the active PTY
//!   - `Ctrl-c`         quit (emacs `C-x C-c`)
//!
//! **Tree mode** (after `Ctrl-g t`) — emacs movement keys:
//!
//!   - `Ctrl-n` / `↓`         select next entry
//!   - `Ctrl-p` / `↑`         select previous entry
//!   - `Ctrl-v`               page down
//!   - `Alt-v`                page up
//!   - `Alt-<`                jump to top
//!   - `Alt->`                jump to bottom
//!   - `Ctrl-m` / `Enter`     open file (preview tab) or descend into directory
//!   - `Ctrl-h` / `Backspace` go up one directory
//!   - `q`                    leave Tree mode (back to Pane)
//!   - `Ctrl-g`               leave Tree mode and start a Prefix sequence
//!
//! **Scroll mode** (after `Ctrl-g [`) — emacs scrolling for the active PTY:
//!
//!   - `Ctrl-v`         page down
//!   - `Alt-v`          page up
//!   - `Alt-<`          jump to top of scrollback
//!   - `Alt->`          jump back to live
//!   - `Ctrl-n` / `↓`   line down
//!   - `Ctrl-p` / `↑`   line up
//!   - `q`              leave Scroll mode (and jump back to live, tmux-style)
//!   - `Ctrl-g`         leave Scroll mode and start a Prefix sequence
//!
//! ## File tree follows active PTY's cwd
//!
//! When a PTY tab is active and that PTY's cwd changes (the server polls
//! `proc_pidinfo` / `/proc/<pid>/cwd` every ~1.5s and emits `pty.cwd_changed`),
//! the file tree retargets to the new cwd. If the user has manually navigated
//! in Tree mode (`Backspace`/`Enter`-into-subdir), auto-follow pauses until
//! they press `Ctrl-g g` to re-anchor or switch tabs.

use std::collections::HashMap;
use std::io::Stdout;
use std::path::PathBuf;
use std::time::Duration;

use anyhow::Result;
use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
use crossterm::event::{
    self, DisableMouseCapture, EnableMouseCapture, Event as CtEvent, KeyCode, KeyEventKind, KeyModifiers,
};
use crossterm::execute;
use crossterm::terminal::{
    disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen,
};
use motif_proto::common::PtyId;
use motif_proto::envelope::Notification;
use motif_proto::event::Event;
use motif_proto::fs as pfs;
use motif_proto::git as pgit;
use motif_proto::pty as ppty;
use motif_proto::session as ses;
use motif_proto::terminal_query::QueryScanner;
use motif_proto::view::{self as pview, ViewId, ViewInfo, ViewSpec};
use ratatui::backend::CrosstermBackend;
use ratatui::layout::{Constraint, Direction, Layout, Position, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, List, ListItem, ListState, Paragraph, Tabs, Wrap};
use ratatui::Terminal;

use tui_term::widget::PseudoTerminal;

use crate::client::Client;
use crate::pty_view::{BlockMark, BlockStatus, PtyView};

type TermBackend = CrosstermBackend<Stdout>;

pub async fn run(url: &str, token: &str, session: String) -> Result<()> {
    let tr = crate::transport::connect(url, token, None, None).await?;
    run_with(tr, session).await
}

pub async fn run_with(mut tr: crate::transport::Connected, session: String) -> Result<()> {
    // Probe BEFORE entering raw mode / alt screen so the OSC reply the
    // terminal writes back doesn't get mixed with crossterm event traffic.
    let (term_fg, term_bg) = crate::palette::probe();
    let attach: ses::AttachResult = tr.client.call(
        "session.attach",
        ses::AttachParams { name: session.clone(), last_seq: None, term_fg, term_bg },
    ).await?;
    // Initial tree root: active PTY's cwd if there's one already running,
    // otherwise the session's workdir. Either way it's an absolute path.
    let initial_root: PathBuf = attach
        .active_view
        .as_ref()
        .and_then(|vid| attach.views.iter().find(|v| &v.id == vid))
        .and_then(|v| match &v.spec {
            ViewSpec::Pty { pty_id } => attach.ptys.iter().find(|p| &p.id == pty_id).map(|p| p.cwd.clone()),
            _ => None,
        })
        .unwrap_or_else(|| attach.session.workdir.clone());

    let tree: pfs::TreeResult = tr.client.call(
        "fs.tree",
        pfs::TreeParams { path: initial_root.to_string_lossy().into_owned(), depth: 1, show_hidden: false },
    ).await.unwrap_or(pfs::TreeResult { path: initial_root.to_string_lossy().into_owned(), entries: vec![] });
    let git_status = tr.client.call::<_, pgit::StatusResult>(
        "git.status",
        pgit::StatusParams { cwd: Some(initial_root.clone()) },
    ).await.ok();

    let mut state = AppState::new(session, attach, initial_root, tree, git_status);

    enable_raw_mode()?;
    let mut stdout = std::io::stdout();
    execute!(stdout, EnterAlternateScreen, EnableMouseCapture)?;
    let backend = CrosstermBackend::new(stdout);
    let mut term = Terminal::new(backend)?;

    let result = main_loop(&mut term, &mut tr.client, &mut state).await;

    disable_raw_mode()?;
    execute!(term.backend_mut(), LeaveAlternateScreen, DisableMouseCapture)?;
    term.show_cursor()?;

    result
}

async fn main_loop(
    term:   &mut Terminal<TermBackend>,
    client: &mut Client,
    state:  &mut AppState,
) -> Result<()> {
    loop {
        term.draw(|f| draw(f, state))?;

        // Push out any deferred pty.resize requests (driven by render-time
        // measurements of the body area).
        let resizes: Vec<(PtyId, u16, u16)> = state.pending_resizes.drain(..).collect();
        for (pty_id, cols, rows) in resizes {
            let _: serde_json::Value = client.call(
                "pty.resize",
                ppty::PtyResizeParams { pty_id, cols, rows },
            ).await.unwrap_or(serde_json::Value::Null);
        }

        // Push out canonical responses to terminal capability queries that
        // came in with the last batch of pty.output events. Same deferred
        // pattern as resizes — we don't want to send these synchronously
        // from inside `apply_frame`.
        let writes: Vec<(PtyId, Vec<u8>)> = state.pending_pty_writes.drain(..).collect();
        for (pty_id, data) in writes {
            let _: serde_json::Value = client.call(
                "pty.write",
                ppty::PtyWriteParams { pty_id, data_b64: BASE64.encode(&data) },
            ).await.unwrap_or(serde_json::Value::Null);
        }

        // Lazy-load the active view's body cache (preview text / diff patch).
        // PTYs and images don't need this — PTYs stream via pty.output, and
        // images aren't in the TUI body for now.
        load_active_view_if_needed(state, client).await;

        // Drain incoming server notifications quickly. Responses are routed
        // by id inside `Client` and never show up here — this loop only sees
        // server-pushed events (pty.output, view.opened, …).
        for _ in 0..64 {
            match tokio::time::timeout(Duration::from_millis(0), client.recv_notification()).await {
                Ok(Some(n)) => apply_notification(state, n),
                Ok(None)    => return Ok(()), // connection closed
                Err(_)      => break,         // queue empty for now
            }
        }

        // Retarget the file tree when the active PTY's cwd has moved.
        // Skipped while the user has manually navigated away — they re-anchor
        // explicitly with `g` (or implicitly by switching tabs).
        if !state.manual_nav {
            if let Some(target) = active_pty_cwd(state).cloned() {
                if state.current_path != target {
                    state.current_path = target;
                    refresh_tree(state, client).await;
                }
            }
        }

        if event::poll(Duration::from_millis(20))? {
            if let CtEvent::Key(k) = event::read()? {
                if k.kind != KeyEventKind::Press { continue; }
                match handle_key(state, client, k.code, k.modifiers).await? {
                    KeyOutcome::Quit  => return Ok(()),
                    KeyOutcome::Stay  => {}
                }
            }
        }
    }
}

// ─────────────────────────── App state ───────────────────────────

struct AppState {
    session_name:    String,
    /// Workdir as reported by the server. Used as the fallback tree root when
    /// no PTY is active.
    session_workdir: PathBuf,
    other_clients:   u32,

    /// Absolute directory the file tree pane is currently showing.
    current_path:    PathBuf,
    files:           Vec<pfs::TreeEntry>,
    tree_state:      ListState,
    git:             Option<pgit::StatusResult>,

    /// Synced from server.
    views:           Vec<ViewInfo>,
    active_view:     Option<ViewId>,

    /// Latest known cwd per PTY. Seeded from `attach.ptys` and updated on
    /// `pty.created` and `pty.cwd_changed`. The main loop diffs the active
    /// PTY's entry against `current_path` and retargets the tree.
    pty_cwds:        HashMap<PtyId, PathBuf>,
    /// Spawn command per PTY (e.g. "/bin/zsh"), seeded from `attach.ptys`
    /// and `pty.created`. Used as a fallback label when nothing better is
    /// available.
    pty_cmds:        HashMap<PtyId, String>,
    /// v2 shell-integration UI state per PTY: the currently-running
    /// command (for `▶ <cmd>` chip + `<cwd> · <fg>` tab labels) and the
    /// most-recent finish for a brief flash of `✓ 0` / `✗ N`.
    pty_blocks:      HashMap<PtyId, PtyBlockUi>,

    /// True when the user has manually navigated away (Backspace / Enter into
    /// a subdir). While true, we DON'T auto-follow the active PTY's cwd —
    /// otherwise their browsing would get yanked back every 1.5s. Reset by
    /// `g` (re-anchor) or by switching tabs.
    manual_nav:      bool,

    /// Per-client PTY screen state, keyed by pty_id.
    pty_views:       HashMap<PtyId, PtyView>,
    pty_last_size:   HashMap<PtyId, (u16, u16)>,
    pending_resizes: Vec<(PtyId, u16, u16)>,

    /// Per-PTY scanner that strips fish-style terminal capability queries
    /// from the byte stream and lets us answer them. The server already
    /// filters its broadcast so this is a defence-in-depth path: if the
    /// server filter were ever bypassed (e.g. older server, query split
    /// across the broadcast boundary in a way the server's scanner missed),
    /// the TUI still keeps fish unstuck.
    pty_scanners:    HashMap<PtyId, QueryScanner>,
    /// Bytes destined for `pty.write` calls, drained by the main loop.
    /// Mirrors the deferred-RPC pattern used for `pending_resizes`.
    pending_pty_writes: Vec<(PtyId, Vec<u8>)>,

    /// Per-view client cache for preview/diff content. Hydrated lazily when
    /// the view becomes active.
    view_cache:      HashMap<ViewId, ViewBodyCache>,

    /// Modal state. Keys behave very differently across modes — see the
    /// module docs for the full keymap.
    mode:            Mode,

    status:          String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Mode {
    /// Default. Every key (other than `Ctrl-g`) is forwarded to the active
    /// PTY, same as inside a tmux/screen pane.
    Pane,
    /// Just pressed `Ctrl-g`; the next keystroke is interpreted as a
    /// motif command, then we drop back to `Pane`.
    Prefix,
    /// File-tree navigation. `Ctrl-n`/`Ctrl-p`/`Ctrl-m`/`Ctrl-h` etc.
    Tree,
    /// PTY scrollback navigation (tmux's copy-mode equivalent).
    Scroll,
}

enum ViewBodyCache {
    Preview { content: String, binary: bool },
    Diff    { patch: String },
}

#[derive(Default, Debug, Clone)]
struct PtyBlockUi {
    /// Set to the command text on `pty.command_started`, cleared on the
    /// matching `command_finished`. Drives the "currently running" chip.
    running: Option<String>,
    /// Most-recent finish: (command text, exit code, when it landed).
    /// Rendered for ~3s as a colour flash, then suppressed.
    flash:   Option<(String, Option<i32>, std::time::Instant)>,
}

const FLASH_TTL: std::time::Duration = std::time::Duration::from_secs(3);

/// First token of a command line, ignoring `KEY=VAL` env-var prefixes
/// and stripping the path so `/usr/bin/git push` → "git" and
/// `EDITOR=vim git commit` → "git".
fn first_meaningful_token(cmd: &str) -> String {
    for tok in cmd.split_whitespace() {
        if tok.contains('=') { continue; }
        return std::path::Path::new(tok)
            .file_name().and_then(|s| s.to_str())
            .unwrap_or(tok).to_string();
    }
    cmd.split_whitespace().next().unwrap_or("").to_string()
}

impl AppState {
    fn new(
        session_name:    String,
        attach:          ses::AttachResult,
        initial_root:    PathBuf,
        tree:            pfs::TreeResult,
        git:             Option<pgit::StatusResult>,
    ) -> Self {
        let mut tree_state = ListState::default();
        if !tree.entries.is_empty() { tree_state.select(Some(0)); }

        // Pre-allocate PTY screen state + cwd map for any PTYs already in the
        // session; output will replay via the broadcast ring after attach.
        let mut pty_views     = HashMap::new();
        let mut pty_cwds      = HashMap::new();
        let mut pty_cmds      = HashMap::new();
        for p in &attach.ptys {
            pty_views.insert(p.id.clone(), PtyView::new(p.rows.max(1), p.cols.max(1)));
            pty_cwds.insert(p.id.clone(), p.cwd.clone());
            pty_cmds.insert(p.id.clone(), p.cmd.clone());
        }

        let session_workdir = attach.session.workdir.clone();
        Self {
            session_name,
            session_workdir,
            other_clients:   attach.clients.len() as u32,
            current_path:    initial_root,
            files:           tree.entries,
            tree_state,
            git,
            views:           attach.views,
            active_view:     attach.active_view,
            pty_cwds,
            pty_cmds,
            pty_blocks:      HashMap::new(),
            manual_nav:      false,
            pty_views,
            pty_last_size:   HashMap::new(),
            pending_resizes: Vec::new(),
            pty_scanners:       HashMap::new(),
            pending_pty_writes: Vec::new(),
            view_cache:      HashMap::new(),
            mode:            Mode::Pane,
            status:          format!("attached as {} — Ctrl-g for prefix, Ctrl-g ? for help", attach.client_id),
        }
    }
}

// ─────────────────────────── Notification application ───────────────────────────

fn apply_notification(state: &mut AppState, n: Notification) {
    match n.method.as_str() {
        "client.joined" => state.other_clients += 1,
        "client.left"   => state.other_clients = state.other_clients.saturating_sub(1),
        "tree.changed"  => state.status = "tree changed (press r to refresh)".into(),
        "git.changed"   => state.status = "git changed (press r to refresh)".into(),

        // Synced tabs: views are the source of truth for "what tabs exist /
        // which is active". They auto-pop-up on every client.
        "view.opened"   => {
            if let Ok(Event::ViewOpened { view, .. }) =
                serde_json::from_value::<Event>(serde_json::json!({"method":"view.opened","params":n.params}))
            {
                if !state.views.iter().any(|v| v.id == view.id) {
                    state.views.push(view);
                }
            }
        }
        "view.closed" => {
            if let Some(view_id) = n.params.get("view_id").and_then(|v| v.as_str()) {
                let vid = view_id.to_string();
                state.views.retain(|v| v.id != vid);
                state.view_cache.remove(&vid);
                if state.active_view.as_deref() == Some(&vid) {
                    // server's view.active_changed will follow; clear active
                    // so the render falls through to "none". Drop out of
                    // Scroll mode if we were scrolling the now-dead PTY.
                    state.active_view = None;
                    if state.mode == Mode::Scroll { state.mode = Mode::Pane; }
                }
            }
        }
        "view.active_changed" => {
            if let Ok(Event::ViewActiveChanged { view_id, .. }) =
                serde_json::from_value::<Event>(serde_json::json!({"method":"view.active_changed","params":n.params}))
            {
                let new_active_pty_changed = match (
                    active_pty_id(state).cloned(),
                    view_id.as_ref().and_then(|vid| pty_id_of(state, vid).cloned()),
                ) {
                    (Some(a), Some(b)) if a == b => false,
                    _ => true,
                };
                state.active_view = view_id;
                if new_active_pty_changed {
                    // Tab switch resets the manual-nav escape so the new
                    // tab's cwd will pull the file tree along. Also drop
                    // Scroll mode (it was tied to the previous PTY).
                    state.manual_nav = false;
                    if state.mode == Mode::Scroll { state.mode = Mode::Pane; }
                }
            }
        }
        "view.moved" => {
            // Reorder local views to match the server's new order. Any view
            // we don't recognise gets dropped (it should have been closed
            // separately, but be defensive); any local view missing from
            // `order` is appended in its original position to avoid losing
            // tabs if events race.
            if let Ok(Event::ViewMoved { order, .. }) =
                serde_json::from_value::<Event>(serde_json::json!({"method":"view.moved","params":n.params}))
            {
                let mut by_id: std::collections::HashMap<String, ViewInfo> =
                    state.views.drain(..).map(|v| (v.id.clone(), v)).collect();
                let mut next: Vec<ViewInfo> = Vec::with_capacity(order.len());
                for id in &order {
                    if let Some(v) = by_id.remove(id) { next.push(v); }
                }
                // Append leftovers (rare) so we don't silently drop tabs.
                for (_id, v) in by_id { next.push(v); }
                state.views = next;
            }
        }

        // PTY infrastructure events — these maintain the per-PTY screen
        // buffer + cwd map. Tab list is synced via view.* (above), not these.
        "pty.created"   => {
            if let Ok(Event::PtyCreated { info, .. }) =
                serde_json::from_value::<Event>(serde_json::json!({"method":"pty.created","params":n.params}))
            {
                state.pty_views.entry(info.id.clone())
                    .or_insert_with(|| PtyView::new(info.rows.max(1), info.cols.max(1)));
                state.pty_cwds.insert(info.id.clone(), info.cwd.clone());
                state.pty_cmds.insert(info.id.clone(), info.cmd.clone());
                state.status = format!("pty {} created", info.id);
            }
        }
        "pty.exited" => {
            if let Some(pid) = n.params.get("pty_id").and_then(|v| v.as_str()) {
                let pid_owned = pid.to_string();
                state.pty_views.remove(&pid_owned);
                state.pty_last_size.remove(&pid_owned);
                state.pty_cwds.remove(&pid_owned);
                state.pty_cmds.remove(&pid_owned);
                state.pty_blocks.remove(&pid_owned);
                state.pty_scanners.remove(&pid_owned);
                state.pending_pty_writes.retain(|(p, _)| p != &pid_owned);
                state.status = format!("pty {pid_owned} exited");
            }
        }
        // v2 shell-integration: track running command + last-finished
        // flash for the header chip and PTY tab label, AND register the
        // start row in PtyView so Ctrl-g b/f can jump to it later.
        "pty.command_started" => {
            if let (Some(pid), Some(block_id), Some(text)) = (
                n.params.get("pty_id").and_then(|v| v.as_str()),
                n.params.get("block_id").and_then(|v| v.as_str()),
                n.params.get("text").and_then(|v| v.as_str()),
            ) {
                state.pty_blocks.entry(pid.to_string())
                    .or_default().running = Some(text.to_string());
                if let Some(view) = state.pty_views.get_mut(pid) {
                    view.mark_block_start(block_id.to_string());
                }
            }
        }
        "pty.command_finished" => {
            if let Some(pid) = n.params.get("pty_id").and_then(|v| v.as_str()) {
                let exit = n.params.get("exit_code")
                    .and_then(|v| if v.is_null() { None } else { v.as_i64().map(|x| x as i32) });
                let entry = state.pty_blocks.entry(pid.to_string()).or_default();
                let cmd = entry.running.take().unwrap_or_default();
                entry.flash = Some((cmd, exit, std::time::Instant::now()));
                if let (Some(block_id), Some(view)) = (
                    n.params.get("block_id").and_then(|v| v.as_str()),
                    state.pty_views.get_mut(pid),
                ) {
                    view.mark_block_end(block_id, exit);
                }
            }
        }
        // shell_bootstrapped / shell_context don't need stored state for
        // the TUI — bootstrap status only matters for log noise, and
        // shell_context (git branch / venv) duplicates what the git pane
        // already shows on a longer cadence.
        "pty.shell_bootstrapped" | "pty.shell_context" => {}
        "pty.cwd_changed" => {
            if let Some(pid) = n.params.get("pty_id").and_then(|v| v.as_str()) {
                if let Some(cwd) = n.params.get("cwd").and_then(|v| v.as_str()) {
                    state.pty_cwds.insert(pid.to_string(), PathBuf::from(cwd));
                }
                // Tree retargeting happens in main_loop (needs &mut Client
                // for the refresh fetch).
            }
        }
        "pty.resize" => {
            if let (Some(pid), Some(cols), Some(rows)) = (
                n.params.get("pty_id").and_then(|v| v.as_str()),
                n.params.get("cols").and_then(|v| v.as_u64()),
                n.params.get("rows").and_then(|v| v.as_u64()),
            ) {
                if let Some(view) = state.pty_views.get_mut(pid) {
                    view.set_size(rows as u16, cols as u16);
                }
            }
        }
        "pty.output" => {
            if let (Some(pid), Some(b64)) = (
                n.params.get("pty_id").and_then(|v| v.as_str()),
                n.params.get("data_b64").and_then(|v| v.as_str()),
            ) {
                if let Ok(bytes) = BASE64.decode(b64.as_bytes()) {
                    let pid_owned = pid.to_string();
                    // Strip terminal capability queries before they reach
                    // vt100; queue a `pty.write` with the canonical reply
                    // so fish doesn't hang on its 10s timeout. Queries
                    // must be answered as a single response per query —
                    // no batching across queries, since each shell-side
                    // consumer reads them with strict framing.
                    let scanner = state.pty_scanners.entry(pid_owned.clone()).or_default();
                    let scan = scanner.feed(&bytes);
                    // v2: shell-integration markers (OSC 133 / 7 / 7770 /
                    // 7771) have no canonical response — server already
                    // consumed them into block events. Only capability
                    // queries reach this defence-in-depth path.
                    for q in scan.queries {
                        if let Some(reply) = q.canonical_response() {
                            state.pending_pty_writes.push((pid_owned.clone(), reply));
                        }
                    }
                    let view = state.pty_views.entry(pid_owned)
                        .or_insert_with(|| PtyView::new(24, 80));
                    view.process(&scan.passthrough);
                }
            }
        }
        _ => {}
    }
}

// ─────────────────────────── Helpers ───────────────────────────

fn active_view_info(state: &AppState) -> Option<&ViewInfo> {
    state.active_view.as_ref().and_then(|id| state.views.iter().find(|v| &v.id == id))
}

fn active_index(state: &AppState) -> Option<usize> {
    state.active_view.as_ref().and_then(|id| state.views.iter().position(|v| &v.id == id))
}

fn pty_id_of<'a>(state: &'a AppState, view_id: &str) -> Option<&'a PtyId> {
    state.views.iter().find(|v| v.id == view_id).and_then(|v| match &v.spec {
        ViewSpec::Pty { pty_id } => Some(pty_id),
        _ => None,
    })
}

fn active_pty_id(state: &AppState) -> Option<&PtyId> {
    match active_view_info(state).map(|v| &v.spec) {
        Some(ViewSpec::Pty { pty_id }) => Some(pty_id),
        _ => None,
    }
}

/// Latest known cwd of whichever PTY is active right now (None if the active
/// view isn't a PTY, or its cwd hasn't surfaced yet).
fn active_pty_cwd(state: &AppState) -> Option<&PathBuf> {
    let id = active_pty_id(state)?;
    state.pty_cwds.get(id)
}

async fn activate_view_id(client: &mut Client, view_id: ViewId) {
    let _: serde_json::Value = client.call(
        "view.activate",
        pview::ActivateParams { view_id: Some(view_id) },
    ).await.unwrap_or(serde_json::Value::Null);
}

async fn close_view_id(client: &mut Client, view_id: ViewId) {
    let _: serde_json::Value = client.call(
        "view.close",
        pview::CloseParams { view_id },
    ).await.unwrap_or(serde_json::Value::Null);
}

async fn open_view(client: &mut Client, spec: ViewSpec, activate: bool) {
    let _: serde_json::Value = client.call(
        "view.open",
        pview::OpenParams { spec, activate },
    ).await.unwrap_or(serde_json::Value::Null);
}

// ─────────────────────────── Lazy view content loading ───────────────────────────

async fn load_active_view_if_needed(state: &mut AppState, client: &mut Client) {
    let Some(vid) = state.active_view.clone() else { return };
    if state.view_cache.contains_key(&vid) { return; }
    let spec = match state.views.iter().find(|v| v.id == vid).map(|v| v.spec.clone()) {
        Some(s) => s,
        None    => return,
    };
    match spec {
        ViewSpec::Preview { path } => {
            if let Ok(r) = client.call::<_, pfs::ReadResult>(
                "fs.read",
                pfs::ReadParams { path: path.clone(), max_bytes: 5_000_000 },
            ).await {
                let bytes = BASE64.decode(r.content_b64.as_bytes()).unwrap_or_default();
                let content = if r.binary {
                    format!("(binary file, {} bytes, mime: {})", bytes.len(), r.mime.as_deref().unwrap_or("?"))
                } else {
                    String::from_utf8_lossy(&bytes).into_owned()
                };
                state.view_cache.insert(vid, ViewBodyCache::Preview { content, binary: r.binary });
            }
        }
        ViewSpec::Diff { staged, path } => {
            // Compute the diff scoped to whatever the file-tree pane is
            // pointing at. Mirrors the web client's behavior — switching cwd
            // and reopening diff yields a fresh view of the new repo.
            let cwd = Some(state.current_path.clone());
            if let Ok(r) = client.call::<_, pgit::DiffResult>(
                "git.diff",
                pgit::DiffParams { path, staged, cwd },
            ).await {
                state.view_cache.insert(vid, ViewBodyCache::Diff { patch: r.patch });
            }
        }
        ViewSpec::Pty { .. } | ViewSpec::Image { .. } => {
            // No body fetch needed.
        }
    }
}

// ─────────────────────────── Key handling ───────────────────────────

enum KeyOutcome { Stay, Quit }

/// Number of rows we move on `C-v` / `M-v` in tree mode. Half a typical
/// terminal height; we don't track the actual pane size here so this is a
/// fixed compromise.
const TREE_PAGE_LINES: i32 = 10;

async fn handle_key(
    state:  &mut AppState,
    client: &mut Client,
    code:   KeyCode,
    mods:   KeyModifiers,
) -> Result<KeyOutcome> {
    match state.mode {
        Mode::Prefix => {
            // Drop back to Pane unconditionally; specific prefix commands
            // that enter another mode (Tree / Scroll) reset state.mode below.
            state.mode = Mode::Pane;
            handle_prefix_key(state, client, code, mods).await
        }
        Mode::Tree   => handle_tree_mode_key(state, client, code, mods).await,
        Mode::Scroll => handle_scroll_mode_key(state, client, code, mods).await,
        Mode::Pane   => handle_pane_key(state, client, code, mods).await,
    }
}

/// Default mode: every key (other than the prefix `Ctrl-g`) is forwarded to
/// the active PTY, exactly like a tmux pane.
async fn handle_pane_key(
    state:  &mut AppState,
    client: &mut Client,
    code:   KeyCode,
    mods:   KeyModifiers,
) -> Result<KeyOutcome> {
    if matches!(code, KeyCode::Char('g')) && mods.contains(KeyModifiers::CONTROL) {
        state.mode = Mode::Prefix;
        state.status =
            "prefix · c=newpty n/p=tab &=close 1-9=jump d=detach r=refresh g=re-anchor D=diff t=tree [=scroll ?=help".into();
        return Ok(KeyOutcome::Stay);
    }
    forward_to_pty(state, client, code, mods).await
}

/// One-shot prefix dispatcher. Entered after `Ctrl-g` from any mode; falls
/// back to Pane after the command (unless the command itself entered Tree
/// or Scroll).
async fn handle_prefix_key(
    state:  &mut AppState,
    client: &mut Client,
    code:   KeyCode,
    mods:   KeyModifiers,
) -> Result<KeyOutcome> {
    let ctrl = mods.contains(KeyModifiers::CONTROL);
    match (code, ctrl) {
        // tmux: prefix-c → new window
        (KeyCode::Char('c'), false) => {
            let (cols, rows) = (100u16, 30u16);
            match client.call::<_, ppty::PtyCreateResult>(
                "pty.create",
                ppty::PtyCreateParams { cmd: None, cwd: None, env: vec![], cols, rows },
            ).await {
                Ok(r)  => state.status = format!("created {}", r.info.id),
                Err(e) => state.status = format!("pty.create: {e}"),
            }
        }
        // tmux: prefix-n / prefix-p → next/prev window
        (KeyCode::Char('n'), false) => cycle_tabs(state, client,  1).await,
        (KeyCode::Char('p'), false) => cycle_tabs(state, client, -1).await,
        // tmux: prefix-& → kill window
        (KeyCode::Char('&'), _) => {
            if let Some(vid) = state.active_view.clone() {
                close_view_id(client, vid).await;
                state.status = "closed tab".into();
            }
        }
        // prefix-1..9 → select tab N (matches the visible 1-based labels).
        // '0' is intentionally a no-op — leaves room to overflow nothing past 9.
        (KeyCode::Char(c), false) if matches!(c, '1'..='9') => {
            let idx = (c as u8 - b'1') as usize;
            if let Some(v) = state.views.get(idx) {
                let id = v.id.clone();
                activate_view_id(client, id).await;
            }
        }
        // tmux: prefix-d → detach
        (KeyCode::Char('d'), false) => return Ok(KeyOutcome::Quit),
        // tmux: prefix-? → list keys
        (KeyCode::Char('?'), _) => {
            state.status =
                "prefix · c=newpty n/p=tab &=close 1-9=jump d=detach r=refresh g=re-anchor D=diff t=tree [=scroll b/f=block Ctrl-g=literal Ctrl-c=quit".into();
        }
        // refresh tree + git (motif-specific)
        (KeyCode::Char('r'), false) => refresh_tree(state, client).await,
        // re-anchor tree to active PTY's cwd (motif-specific)
        (KeyCode::Char('g'), false) => re_anchor_tree(state, client).await,
        // open diff tab. Capital D so prefix-d stays "detach" per tmux.
        (KeyCode::Char('D'), false) => {
            open_view(client, ViewSpec::Diff { staged: false, path: None }, true).await;
        }
        // enter Tree mode (file-tree navigation, emacs keys)
        (KeyCode::Char('t'), false) => {
            state.mode = Mode::Tree;
            state.status =
                "tree · Ctrl-n/Ctrl-p select · Ctrl-m open · Ctrl-h up · Ctrl-v/Alt-v page · Alt-</Alt-> top/bottom · q or Ctrl-g leave".into();
        }
        // enter Scroll mode (tmux's copy-mode equivalent)
        (KeyCode::Char('['), _) => {
            if active_pty_id(state).is_some() {
                state.mode = Mode::Scroll;
                state.status =
                    "scroll · Ctrl-v/Alt-v page · Alt-</Alt-> top/live · Ctrl-n/Ctrl-p line · b/f block · q or Ctrl-g leave".into();
            } else {
                state.status = "no PTY to scroll".into();
            }
        }
        // v2 shell-integration: jump to the previous / next block start.
        // Enters Scroll mode so the user can keep walking with the same
        // keys; pressing q / Ctrl-g leaves it as usual.
        (KeyCode::Char('b'), false) => jump_block(state, /* forward */ false),
        (KeyCode::Char('f'), false) => jump_block(state, /* forward */ true),
        // tmux: prefix-prefix → send literal prefix to the PTY
        (KeyCode::Char('g'), true) => {
            forward_to_pty(state, client, KeyCode::Char('g'), KeyModifiers::CONTROL).await?;
        }
        _ => state.status = "prefix cancelled".into(),
    }
    Ok(KeyOutcome::Stay)
}

/// Jump the active PTY's viewport to the prev/next block start. Stays
/// idempotent if there's nothing in that direction.
fn jump_block(state: &mut AppState, forward: bool) {
    let pid = match active_pty_id(state) {
        Some(p) => p.clone(),
        None    => { state.status = "no PTY to jump".into(); return; }
    };
    let view = match state.pty_views.get_mut(&pid) {
        Some(v) => v,
        None    => { state.status = "no PTY view yet".into(); return; }
    };
    let target = if forward { view.next_block_anchor() } else { view.prev_block_anchor() };
    let Some(target) = target else {
        state.status = if forward { "no later block".into() } else { "no earlier block".into() };
        return;
    };
    view.jump_to_abs(target);
    state.mode   = Mode::Scroll;
    state.status = format!(
        "scroll · {} block · b/f to walk · q/Ctrl-g leave",
        if forward { "next" } else { "prev" },
    );
}

/// File-tree navigation. Emacs movement keys; arrows/Backspace/Enter as
/// fallbacks since they're unambiguous when keys aren't being forwarded
/// to a shell.
async fn handle_tree_mode_key(
    state:  &mut AppState,
    client: &mut Client,
    code:   KeyCode,
    mods:   KeyModifiers,
) -> Result<KeyOutcome> {
    let ctrl = mods.contains(KeyModifiers::CONTROL);
    let alt  = mods.contains(KeyModifiers::ALT);
    match (code, ctrl, alt) {
        // Ctrl-g re-enters Prefix so commands chain (the prefix is "always
        // reachable" from inside any sub-mode, tmux-style).
        (KeyCode::Char('g'), true, false) => {
            state.mode   = Mode::Prefix;
            state.status = "tree → prefix".into();
        }
        // Plain `q` leaves to Pane.
        (KeyCode::Char('q'), false, false) => {
            state.mode   = Mode::Pane;
            state.status = "left tree".into();
        }
        // Selection up/down — emacs Ctrl-n / Ctrl-p (and arrow fallbacks).
        (KeyCode::Char('n'), true, false) | (KeyCode::Down, false, false) => move_tree(state,  1),
        (KeyCode::Char('p'), true, false) | (KeyCode::Up,   false, false) => move_tree(state, -1),
        // Page — emacs Ctrl-v / Alt-v.
        (KeyCode::Char('v'), true, false) => move_tree(state,  TREE_PAGE_LINES),
        (KeyCode::Char('v'), false, true) => move_tree(state, -TREE_PAGE_LINES),
        // First / last — emacs M-< / M->.
        (KeyCode::Char('<'), false, true) => move_tree(state, i32::MIN),
        (KeyCode::Char('>'), false, true) => move_tree(state, i32::MAX),
        // Open / go up — emacs Ctrl-m (RET) / Ctrl-h (BS) and friendly fallbacks.
        (KeyCode::Char('m'), true, false) | (KeyCode::Enter,     false, false) => on_enter_in_tree(state, client).await,
        (KeyCode::Char('h'), true, false) | (KeyCode::Backspace, false, false) => go_up_dir(state, client).await,
        _ => {}
    }
    Ok(KeyOutcome::Stay)
}

/// Active-PTY scrollback. Same emacs movement vocabulary as Tree mode.
async fn handle_scroll_mode_key(
    state:  &mut AppState,
    _client: &mut Client,
    code:   KeyCode,
    mods:   KeyModifiers,
) -> Result<KeyOutcome> {
    let ctrl = mods.contains(KeyModifiers::CONTROL);
    let alt  = mods.contains(KeyModifiers::ALT);
    match (code, ctrl, alt) {
        // Ctrl-g re-enters Prefix so commands chain (same as Tree mode).
        (KeyCode::Char('g'), true, false) => {
            state.mode   = Mode::Prefix;
            state.status = "scroll → prefix".into();
        }
        // Plain `q` leaves to Pane. tmux's copy-mode-q leaves where you are;
        // we jump to live so the user doesn't end up frozen against drifting
        // output that they have to scroll back to see.
        (KeyCode::Char('q'), false, false) => {
            jump_active_pty(state, false);
            state.mode   = Mode::Pane;
            state.status = "back to live".into();
        }
        // Page (emacs).
        (KeyCode::Char('v'), true, false) => scroll_active_pty(state, -1),
        (KeyCode::Char('v'), false, true) => scroll_active_pty(state,  1),
        // Top of scrollback / live (emacs M-< / M->).
        (KeyCode::Char('<'), false, true) => jump_active_pty(state, true),
        (KeyCode::Char('>'), false, true) => jump_active_pty(state, false),
        // Line up/down.
        (KeyCode::Char('n'), true, false) | (KeyCode::Down, false, false) => scroll_lines(state, -1),
        (KeyCode::Char('p'), true, false) | (KeyCode::Up,   false, false) => scroll_lines(state,  1),
        // v2 shell-integration: walk between block starts.
        (KeyCode::Char('b'), false, false) => jump_block(state, /* forward */ false),
        (KeyCode::Char('f'), false, false) => jump_block(state, /* forward */ true),
        _ => {}
    }
    Ok(KeyOutcome::Stay)
}

fn scroll_lines(state: &mut AppState, lines: i64) {
    let id = match active_pty_id(state) { Some(i) => i.clone(), None => return };
    if let Some(view) = state.pty_views.get_mut(&id) {
        view.scroll_lines(lines);
        state.status = scroll_status(view);
    }
}

async fn cycle_tabs(state: &AppState, client: &mut Client, delta: i32) {
    if state.views.is_empty() { return; }
    let len = state.views.len() as i32;
    let cur = active_index(state).unwrap_or(0) as i32;
    let next = ((cur + delta).rem_euclid(len)) as usize;
    let id = state.views[next].id.clone();
    activate_view_id(client, id).await;
}

async fn forward_to_pty(
    state:  &AppState,
    client: &mut Client,
    code:   KeyCode,
    mods:   KeyModifiers,
) -> Result<KeyOutcome> {
    let Some(pty_id) = active_pty_id(state).cloned() else {
        return Ok(KeyOutcome::Stay);
    };
    let bytes = key_to_bytes(code, mods);
    if bytes.is_empty() { return Ok(KeyOutcome::Stay); }
    let _: serde_json::Value = client.call(
        "pty.write",
        ppty::PtyWriteParams { pty_id, data_b64: BASE64.encode(&bytes) },
    ).await.unwrap_or(serde_json::Value::Null);
    Ok(KeyOutcome::Stay)
}

fn key_to_bytes(code: KeyCode, mods: KeyModifiers) -> Vec<u8> {
    match code {
        KeyCode::Char(c) => {
            if mods.contains(KeyModifiers::CONTROL) {
                let lc = c.to_ascii_lowercase();
                if ('a'..='z').contains(&lc) { return vec![(lc as u8) - b'a' + 1]; }
                return vec![c as u8];
            }
            if mods.contains(KeyModifiers::ALT) {
                let mut v = vec![0x1b];
                v.extend_from_slice(c.to_string().as_bytes());
                return v;
            }
            c.to_string().into_bytes()
        }
        KeyCode::Enter      => vec![b'\r'],
        KeyCode::Tab        => vec![b'\t'],
        KeyCode::Backspace  => vec![0x7f],
        KeyCode::Esc        => vec![0x1b],
        KeyCode::Up         => b"\x1b[A".to_vec(),
        KeyCode::Down       => b"\x1b[B".to_vec(),
        KeyCode::Right      => b"\x1b[C".to_vec(),
        KeyCode::Left       => b"\x1b[D".to_vec(),
        KeyCode::Home       => b"\x1b[H".to_vec(),
        KeyCode::End        => b"\x1b[F".to_vec(),
        KeyCode::PageUp     => b"\x1b[5~".to_vec(),
        KeyCode::PageDown   => b"\x1b[6~".to_vec(),
        KeyCode::Delete     => b"\x1b[3~".to_vec(),
        _                   => vec![],
    }
}

fn page_size(state: &AppState) -> i64 {
    let id = match active_pty_id(state) { Some(i) => i, None => return 10 };
    state.pty_last_size.get(id).map(|(_, r)| (*r / 2).max(1) as i64).unwrap_or(10)
}

fn scroll_active_pty(state: &mut AppState, dir: i32) {
    let step = -(dir as i64) * page_size(state);
    let id   = match active_pty_id(state) { Some(i) => i.clone(), None => return };
    if let Some(view) = state.pty_views.get_mut(&id) {
        view.scroll_lines(step);
        state.status = scroll_status(view);
    }
}

fn jump_active_pty(state: &mut AppState, top: bool) {
    let id = match active_pty_id(state) { Some(i) => i.clone(), None => return };
    if let Some(view) = state.pty_views.get_mut(&id) {
        if top { view.jump_top(); } else { view.jump_live(); }
        state.status = scroll_status(view);
    }
}

fn scroll_status(view: &PtyView) -> String {
    match view.anchor() {
        None    => "live".into(),
        Some(a) => format!("scroll: line {a} of {} (End=live, Home=top)", view.abs_top()),
    }
}

fn move_tree(state: &mut AppState, delta: i32) {
    let total = state.files.len() + parent_offset(state);
    if total == 0 { return; }
    let max  = total as i32 - 1;
    let cur  = state.tree_state.selected().unwrap_or(0) as i32;
    // Clamp instead of wrap. `i32::MIN`/`MAX` are the sentinels used for
    // emacs `M-<` / `M->` (jump to first / last) — they saturate cleanly.
    let new = cur.saturating_add(delta).clamp(0, max);
    state.tree_state.select(Some(new as usize));
}

/// Whether to render a `.. (parent)` row at the top of the file list. We hide
/// it when the current path has no parent (e.g., `/`) to avoid a dead row.
fn parent_offset(state: &AppState) -> usize {
    if state.current_path.parent().is_some() { 1 } else { 0 }
}

async fn refresh_tree(state: &mut AppState, client: &mut Client) {
    let path_str = state.current_path.to_string_lossy().into_owned();
    if let Ok(t) = client.call::<_, pfs::TreeResult>(
        "fs.tree",
        pfs::TreeParams { path: path_str.clone(), depth: 1, show_hidden: false },
    ).await {
        state.files = t.entries;
        let cap = state.files.len() + parent_offset(state);
        if cap == 0 { state.tree_state.select(None); }
        else if state.tree_state.selected().unwrap_or(0) >= cap {
            state.tree_state.select(Some(cap - 1));
        }
    }
    // git.status with the active cwd; if outside any repo the server returns
    // NotAGitRepo, which we surface as None (panel shows "(not a git repo)").
    state.git = client.call::<_, pgit::StatusResult>(
        "git.status",
        pgit::StatusParams { cwd: Some(state.current_path.clone()) },
    ).await.ok();
    state.status = format!("refreshed @ {path_str}");
}

/// Move the tree root. Sets `manual_nav` so auto-follow doesn't immediately
/// snap us back on the next pty.cwd_changed tick.
async fn change_dir(state: &mut AppState, client: &mut Client, new_path: PathBuf) {
    state.current_path = new_path;
    state.manual_nav   = true;
    state.tree_state.select(Some(0));
    refresh_tree(state, client).await;
}

async fn go_up_dir(state: &mut AppState, client: &mut Client) {
    let Some(parent) = state.current_path.parent().map(|p| p.to_path_buf()) else { return };
    change_dir(state, client, parent).await;
}

async fn on_enter_in_tree(state: &mut AppState, client: &mut Client) {
    let sel  = state.tree_state.selected().unwrap_or(0);
    let off  = parent_offset(state);
    if sel == 0 && off == 1 {
        go_up_dir(state, client).await;
        return;
    }
    let idx = sel.saturating_sub(off);
    let Some(ent) = state.files.get(idx).cloned() else { return };
    let abs_path = state.current_path.join(&ent.name);
    match ent.kind {
        pfs::FileType::Dir => change_dir(state, client, abs_path).await,
        pfs::FileType::File | pfs::FileType::Symlink => {
            // Synced preview tab: server creates view → broadcasts → all
            // clients add the tab and (since activate=true) jump to it.
            let path_str = abs_path.to_string_lossy().into_owned();
            open_view(client, ViewSpec::Preview { path: path_str }, true).await;
        }
    }
}

/// Re-anchor the tree to the active PTY's cwd, clearing manual-nav so future
/// `pty.cwd_changed` events keep pulling us along.
async fn re_anchor_tree(state: &mut AppState, client: &mut Client) {
    state.manual_nav = false;
    if let Some(cwd) = active_pty_cwd(state).cloned() {
        if state.current_path != cwd {
            state.current_path = cwd;
            state.tree_state.select(Some(0));
            refresh_tree(state, client).await;
        } else {
            state.status = "already at active PTY's cwd".into();
        }
    } else {
        // No active PTY — fall back to session workdir.
        let target = state.session_workdir.clone();
        if state.current_path != target {
            state.current_path = target;
            state.tree_state.select(Some(0));
            refresh_tree(state, client).await;
        }
    }
}

// ─────────────────────────── Drawing ───────────────────────────

fn draw(f: &mut ratatui::Frame, state: &mut AppState) {
    let outer = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(1), Constraint::Min(1), Constraint::Length(1)])
        .split(f.area());

    let mut spans: Vec<Span> = vec![Span::raw(format!(
        " motif · {} · path: {} · {} other client{}",
        state.session_name,
        state.current_path.display(),
        state.other_clients,
        if state.other_clients == 1 { "" } else { "s" },
    ))];
    match state.mode {
        Mode::Pane   => {}
        Mode::Prefix => spans.push(Span::raw("  [PREFIX]")),
        Mode::Tree   => spans.push(Span::raw("  [TREE]")),
        Mode::Scroll => spans.push(Span::raw("  [SCROLL]")),
    }
    if state.manual_nav { spans.push(Span::raw("  [MANUAL]")); }
    // v2 shell-integration: render the active PTY's command-state chip
    // — `▶ cmd` while running, `✓0 cmd` / `✗N cmd` for ~3s after.
    if let Some(active_pid) = active_pty_id(state) {
        if let Some((text, color)) = block_chip(&state.pty_blocks, active_pid.as_str()) {
            spans.push(Span::raw(" · "));
            spans.push(Span::styled(text, Style::default().fg(color)));
        }
    }
    if !state.status.is_empty() {
        spans.push(Span::raw(" · "));
        spans.push(Span::raw(state.status.clone()));
    }
    f.render_widget(
        Paragraph::new(Line::from(spans)).style(Style::default().bg(Color::DarkGray)),
        outer[0],
    );

    let main = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(28), Constraint::Min(1)])
        .split(outer[1]);

    let left = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Percentage(60), Constraint::Min(1)])
        .split(main[0]);

    // ── files panel ──
    let mut rows: Vec<ListItem> = Vec::with_capacity(state.files.len() + 1);
    if state.current_path.parent().is_some() {
        rows.push(ListItem::new(".. (parent)").style(Style::default().fg(Color::DarkGray)));
    }
    for e in &state.files {
        let glyph = match e.kind {
            pfs::FileType::Dir     => "📁 ",
            pfs::FileType::Symlink => "↳ ",
            pfs::FileType::File    => "  ",
        };
        let style = if matches!(e.kind, pfs::FileType::Dir) {
            Style::default().fg(Color::Cyan)
        } else {
            Style::default()
        };
        rows.push(ListItem::new(format!("{glyph}{}", e.name)).style(style));
    }
    // Show only the leaf segment in the panel title to keep it compact;
    // the full absolute path is in the header bar.
    let leaf = state.current_path.file_name()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| state.current_path.to_string_lossy().into_owned());
    let title = format!("files · {leaf}");
    let list = List::new(rows)
        .block(Block::default().borders(Borders::ALL).title(title))
        .highlight_style(Style::default().add_modifier(Modifier::REVERSED));
    f.render_stateful_widget(list, left[0], &mut state.tree_state);

    // ── git panel ──
    let git_lines: Vec<Line> = match &state.git {
        Some(g) => {
            let mut v = Vec::new();
            v.push(Line::from(vec![
                Span::styled("branch ", Style::default().fg(Color::DarkGray)),
                Span::raw(g.branch.clone().unwrap_or_else(|| "(detached)".into())),
            ]));
            for f in &g.files {
                let symbol = format!("{}{}", short_status(f.staged), short_status(f.unstaged));
                v.push(Line::from(vec![
                    Span::styled(symbol, Style::default().fg(Color::Yellow)),
                    Span::raw(" "),
                    Span::raw(f.path.clone()),
                ]));
                if v.len() > 200 { break; }
            }
            v
        }
        None => vec![Line::from(Span::styled("(not a git repo)", Style::default().fg(Color::DarkGray)))],
    };
    f.render_widget(
        Paragraph::new(git_lines)
            .block(Block::default().borders(Borders::ALL).title("git"))
            .wrap(Wrap { trim: false }),
        left[1],
    );

    // ── tabs + body ──
    let right = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(3), Constraint::Min(1)])
        .split(main[1]);

    // Tabs are labelled 1..N by current position. PTY tabs additionally show
    // a 1-based ordinal among PTYs (matches the web TabBar) instead of the
    // server-side monotonic id, so closing the middle PTY makes the next one
    // slide up to "pty:2" rather than leaving a "sh-7" gap.
    let mut pty_seen = 0usize;
    let titles: Vec<Line> = state.views.iter().enumerate().map(|(i, v)| {
        let label = match &v.spec {
            ViewSpec::Pty { pty_id } => {
                pty_seen += 1;
                pty_tab_label(state, pty_id, pty_seen)
            }
            _ => view_label(v),
        };
        Line::from(format!("{} {}", i + 1, label))
    }).collect();
    let tabs_widget = if titles.is_empty() {
        Tabs::new(vec![Line::from("(no tabs — Ctrl-b c to open PTY)")])
    } else {
        Tabs::new(titles)
            .select(active_index(state).unwrap_or(0))
            .highlight_style(Style::default().add_modifier(Modifier::REVERSED).fg(Color::LightYellow))
    };
    f.render_widget(tabs_widget.block(Block::default().borders(Borders::ALL).title("tabs")), right[0]);

    let body_block = Block::default().borders(Borders::ALL).title(match state.mode {
        Mode::Pane   => "Ctrl-g c=newpty · Ctrl-g n/p=tab · Ctrl-g t=tree · Ctrl-g [=scroll · Ctrl-g ?=help",
        Mode::Prefix => "[prefix] · waiting for command key",
        Mode::Tree   => "[tree mode] · Ctrl-n/p select · Ctrl-m open · Ctrl-h up · q to leave",
        Mode::Scroll => "[scroll mode] · Ctrl-v/Alt-v page · Alt-</Alt-> top/live · q to leave",
    });
    let inner = body_block.inner(right[1]);
    f.render_widget(body_block, right[1]);

    // Snapshot the active view so we don't hold a borrow of state.views
    // while passing &mut state to render_pty_tab.
    enum ActiveBody {
        Pty(PtyId),
        Preview(String),
        Diff(String),
        Loading(&'static str),
        None,
    }
    let active_body: ActiveBody = match active_view_info(state).map(|v| v.spec.clone()) {
        Some(ViewSpec::Pty { pty_id }) => ActiveBody::Pty(pty_id),
        Some(ViewSpec::Preview { .. }) => {
            match state.active_view.as_ref().and_then(|vid| state.view_cache.get(vid)) {
                Some(ViewBodyCache::Preview { content, .. }) => ActiveBody::Preview(content.clone()),
                _ => ActiveBody::Loading("loading file…"),
            }
        }
        Some(ViewSpec::Diff { .. }) => {
            match state.active_view.as_ref().and_then(|vid| state.view_cache.get(vid)) {
                Some(ViewBodyCache::Diff { patch }) => ActiveBody::Diff(patch.clone()),
                _ => ActiveBody::Loading("loading diff…"),
            }
        }
        Some(ViewSpec::Image { path }) => ActiveBody::Loading(Box::leak(format!("(image: {} — open in browser to view)", path).into_boxed_str())),
        None => ActiveBody::None,
    };
    match active_body {
        ActiveBody::Pty(id) => render_pty_tab(f, state, &id, inner),
        ActiveBody::Preview(content) => {
            f.render_widget(Paragraph::new(content).wrap(Wrap { trim: false }), inner);
        }
        ActiveBody::Diff(patch) => {
            let lines: Vec<Line> = patch.lines().map(|l| {
                let style = if l.starts_with('+') { Style::default().fg(Color::Green) }
                            else if l.starts_with('-') { Style::default().fg(Color::Red) }
                            else if l.starts_with("@@") { Style::default().fg(Color::Cyan) }
                            else { Style::default() };
                Line::from(Span::styled(l.to_string(), style))
            }).collect();
            f.render_widget(Paragraph::new(lines), inner);
        }
        ActiveBody::Loading(msg) => {
            f.render_widget(Paragraph::new(msg).style(Style::default().fg(Color::DarkGray)), inner);
        }
        ActiveBody::None => {}
    }

    let help = match state.mode {
        Mode::Pane   => " Ctrl-g prefix · keys flow to active PTY ",
        Mode::Prefix => " prefix: c=newpty n/p=tab &=close 1-9=jump d=detach r=refresh g=re-anchor D=diff t=tree [=scroll ?=help · Ctrl-g=send literal Ctrl-g ",
        Mode::Tree   => " tree: Ctrl-n/p select · Ctrl-m open · Ctrl-h up · Ctrl-v/M-v page · M-</M-> top/bot · q leave · Ctrl-g chain prefix ",
        Mode::Scroll => " scroll: Ctrl-v/M-v page · M-</M-> top/live · Ctrl-n/p line · b/f block · q leave · Ctrl-g chain prefix ",
    };
    f.render_widget(
        Paragraph::new(help).style(Style::default().bg(Color::DarkGray)),
        outer[2],
    );
}

fn render_pty_tab(
    f:     &mut ratatui::Frame,
    state: &mut AppState,
    id:    &PtyId,
    inner: Rect,
) {
    // Reserve one column on the left for a per-block status gutter:
    //   ▶ yellow │ — running command's row range
    //   ✓ green  │ — finished, exit 0
    //   ✗ red    │ — finished, non-zero exit
    //   ·  gray  │ — finished, signaled (no exit code)
    // The icon shows on the block's start row; subsequent rows in the
    // block use a vertical bar in the same color. Rows that don't fall
    // inside any tracked block stay blank.
    const GUTTER_W: u16 = 1;
    if inner.width <= GUTTER_W || inner.height == 0 { return; }
    let gutter_area = Rect { x: inner.x, y: inner.y, width: GUTTER_W, height: inner.height };
    let pty_area    = Rect {
        x: inner.x + GUTTER_W, y: inner.y,
        width:  inner.width - GUTTER_W,
        height: inner.height,
    };

    let cols = pty_area.width.max(1);
    let rows = pty_area.height.max(1);

    let view = state.pty_views.entry(id.clone()).or_insert_with(|| PtyView::new(rows, cols));
    let (sr, sc) = view.current_size();
    if sr != rows || sc != cols { view.set_size(rows, cols); }
    let last = state.pty_last_size.get(id).copied();
    if last != Some((cols, rows)) {
        state.pty_last_size.insert(id.clone(), (cols, rows));
        state.pending_resizes.push((id.clone(), cols, rows));
    }

    let scr_ref = state.pty_views.get_mut(id).unwrap();
    let cursor          = scr_ref.cursor_position();
    let scrolled        = scr_ref.is_scrolled_back();
    let abs_top_visible = scr_ref.anchor().unwrap_or(scr_ref.abs_top());
    // Snapshot the block list before borrowing the screen; we'll need
    // the buffer mutably afterward to paint the gutter.
    let blocks: Vec<BlockMark> = scr_ref.block_marks().to_vec();
    f.render_widget(PseudoTerminal::new(scr_ref.screen_for_render()), pty_area);

    // Paint the gutter cells.
    let buf = f.buffer_mut();
    for r in 0..rows {
        let abs_r = abs_top_visible.saturating_add(r as u64);
        let block = blocks.iter().rev().find(|b| {
            b.start_abs <= abs_r && match b.end_abs {
                Some(end) => abs_r < end,
                None      => true, // running: extends to live cursor
            }
        });
        if let Some(b) = block {
            let (sym, color) = match b.status {
                BlockStatus::Running           => ("▶", Color::Yellow),
                BlockStatus::Finished(Some(0)) => ("✓", Color::Green),
                BlockStatus::Finished(Some(_)) => ("✗", Color::Red),
                BlockStatus::Finished(None)    => ("·", Color::Gray),
            };
            let glyph = if abs_r == b.start_abs { sym } else { "│" };
            if let Some(cell) = buf.cell_mut(Position { x: gutter_area.x, y: gutter_area.y + r }) {
                cell.set_symbol(glyph).set_style(Style::default().fg(color));
            }
        }
    }

    // Show the cursor only while keys are flowing into this PTY (Pane mode,
    // not scrolled). In Tree/Scroll/Prefix the focus is somewhere else and a
    // blinking cursor here would be misleading.
    if matches!(state.mode, Mode::Pane) && !scrolled {
        let (cy, cx) = cursor;
        let cur_x = pty_area.x + cx.min(cols.saturating_sub(1));
        let cur_y = pty_area.y + cy.min(rows.saturating_sub(1));
        f.set_cursor_position(Position { x: cur_x, y: cur_y });
    }
}

fn view_label(v: &ViewInfo) -> String {
    match &v.spec {
        ViewSpec::Pty { pty_id }       => format!("pty:{pty_id}"),
        ViewSpec::Preview { path }     => format!("file:{path}"),
        ViewSpec::Diff { staged, .. }  => if *staged { "diff(staged)".into() } else { "diff".into() },
        ViewSpec::Image { path }       => format!("img:{path}"),
    }
}

/// Header chip text + colour for a PTY's current block state. Returns
/// `None` when there's nothing to show (idle and outside the
/// just-finished flash window).
fn block_chip(blocks: &HashMap<PtyId, PtyBlockUi>, pty_id: &str) -> Option<(String, Color)> {
    let s = blocks.get(pty_id)?;
    if let Some(cmd) = &s.running {
        return Some((format!("▶ {}", trim_cmd(cmd, 40)), Color::Yellow));
    }
    if let Some((cmd, exit, ts)) = &s.flash {
        if ts.elapsed() < FLASH_TTL {
            let (sym, color) = match exit {
                Some(0) => ("✓", Color::Green),
                Some(_) => ("✗", Color::Red),
                None    => ("·", Color::Gray),
            };
            let exit_str = match exit { Some(c) => format!("{c}"), None => String::new() };
            return Some((format!("{sym}{exit_str} {}", trim_cmd(cmd, 40)), color));
        }
    }
    None
}

/// Truncate a command string for compact display, appending `…` when
/// the original was longer.
fn trim_cmd(cmd: &str, max: usize) -> String {
    if cmd.chars().count() > max {
        let take: String = cmd.chars().take(max - 1).collect();
        format!("{take}…")
    } else {
        cmd.to_string()
    }
}

/// Tab label for a PTY: `<cwd basename> · <fg>`, where `<fg>` is the
/// first meaningful token of the running command (`KEY=VAL` prefixes
/// skipped). When nothing is running, the suffix is omitted; falling
/// back chain: cwd → spawn cmd basename → 1-based ordinal.
fn pty_tab_label(state: &AppState, pty_id: &str, ordinal: usize) -> String {
    let cwd_base = state.pty_cwds.get(pty_id)
        .and_then(|p| p.file_name().and_then(|s| s.to_str()))
        .map(|s| s.to_string());
    let fg = state.pty_blocks.get(pty_id)
        .and_then(|b| b.running.as_deref())
        .map(first_meaningful_token)
        .filter(|s| !s.is_empty());

    match (cwd_base, fg) {
        (Some(c), Some(f)) => format!("{c} · {f}"),
        (Some(c), None)    => c,
        (None,    Some(f)) => f,
        (None,    None)    => {
            if let Some(cmd) = state.pty_cmds.get(pty_id) {
                let base = first_meaningful_token(cmd);
                if !base.is_empty() { return base; }
            }
            format!("pty:{ordinal}")
        }
    }
}

fn short_status(s: pgit::GitFileStatus) -> &'static str {
    use pgit::GitFileStatus::*;
    match s {
        Unmodified => ".", Modified => "M", Added => "A", Deleted => "D",
        Renamed => "R", Copied => "C", Untracked => "?", Ignored => "!",
        Conflicted => "U",
    }
}
