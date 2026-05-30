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
//! Exception: when the active tab is **not** a PTY (preview / diff), arrow
//! keys, `PageUp` / `PageDown`, and `Home` / `End` scroll the body instead
//! of being swallowed. PTY tabs still forward those keys to the shell
//! (so `less` / `vim` work normally).
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
//!   - `w`              close current tab (tmux: kill-window — rebound from `&`)
//!   - `1`..`9`         jump to tab N (1-based, matches displayed labels)
//!   - `d`              detach (close motif TUI, server keeps running)
//!   - `?`              show help line
//!   - `r`              refresh tree + git
//!   - `g`              re-anchor file tree to active PTY's cwd
//!   - `D`              open diff tab (Shift+d so it doesn't collide with detach)
//!   - `t` / `T`        enter Tree mode  /  toggle tree panel visibility
//!   - `s` / `S`        enter Git mode   /  toggle git panel visibility
//!   - `[`              enter Scroll mode (PTY scrollback; tmux: copy-mode)
//!   - `b` / `f`        jump to previous / next shell block (enters Scroll)
//!   - `Ctrl-g`         send a literal Ctrl-g to the active PTY
//!   - `Ctrl-c`         quit (emacs `C-x C-c`)
//!
//! Capitalised toggles (`T`, `S`) are one-shot visibility flips paired
//! with the lowercase "enter mode" key. Entering Tree or Git mode
//! auto-shows the corresponding panel so the cursor always has a
//! visible home. When both panels are hidden the body claims the full
//! width — useful when the user just wants terminals on screen.
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
//! **Git mode** (after `Ctrl-g s`) — emacs movement, Enter opens diff:
//!
//!   - `Ctrl-n` / `↓`     select next changed file
//!   - `Ctrl-p` / `↑`     select previous changed file
//!   - `Ctrl-v` / `Alt-v` page down / up
//!   - `Alt-<` / `Alt->`  jump to top / bottom of file list
//!   - `Ctrl-m` / `Enter` open the selected file's diff in a new tab
//!                        (`ViewSpec::Diff { staged: false, path: Some(<file>) }`)
//!   - `q`                leave Git mode (back to Pane)
//!   - `Ctrl-g`           leave Git mode and start a Prefix sequence
//!
//! **Scroll mode** (after `Ctrl-g [`) — emacs scrolling for the active PTY:
//!
//!   - `Ctrl-v`         page down
//!   - `Alt-v`          page up
//!   - `Alt-<`          jump to top of scrollback
//!   - `Alt->`          jump back to live
//!   - `Ctrl-n` / `↓`   line down
//!   - `Ctrl-p` / `↑`   line up
//!   - `b` / `f`        walk between shell-integration block starts
//!   - `q`              leave Scroll mode (and jump back to live, tmux-style)
//!   - `Ctrl-g`         leave Scroll mode and start a Prefix sequence
//!
//! ## File tree follows active PTY's cwd
//!
//! When a PTY tab is active and that PTY's cwd changes, the file tree
//! retargets to the new cwd. Post-protocol-redesign the cwd signal is
//! derived client-side: the per-PTY `ShellState` (lifted from the old
//! server module into `motif_client::shell_integration`) consumes shell-
//! integration OSC markers off the `/pty/<id>` byte stream and emits
//! `ShellEvent::CwdChanged`. If the user has manually navigated in Tree
//! mode (`Backspace` / `Enter`-into-subdir), auto-follow pauses until
//! they press `Ctrl-g g` to re-anchor or switch tabs.

use std::collections::HashMap;
use std::io::Stdout;
use std::path::PathBuf;
use std::time::Duration;

use anyhow::Result;
use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
use bytes::Bytes;
use crossterm::event::{
    self, DisableFocusChange, DisableMouseCapture, EnableFocusChange, EnableMouseCapture,
    Event as CtEvent, KeyCode, KeyEventKind, KeyModifiers,
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
use motif_proto::pty::ShellKind;
use motif_proto::session as ses;
use motif_proto::terminal_query::{QueryScanner, ScanItem};
use motif_proto::view::{self as pview, ViewId, ViewInfo, ViewSpec};
use ratatui::backend::CrosstermBackend;
use ratatui::layout::{Constraint, Direction, Layout, Position, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, List, ListItem, ListState, Paragraph, Tabs, Wrap};
use ratatui::Terminal;
use tokio::sync::mpsc;

use tui_term::widget::PseudoTerminal;

use crate::pty_view::{BlockMark, BlockStatus, PtyView};
use motif_client::coordinator::Coordinator as Client;
use motif_client::pty_ws::{CloseReason, PtyClient};
use motif_client::shell_integration::{ShellEvent, ShellState};

type TermBackend = CrosstermBackend<Stdout>;

/// Per-PTY client-side state. Owns the stdin sender (cloned out of
/// `PtyClient.stdin`) and the OSC parsers that turn raw `/pty/<id>`
/// bytes into block lifecycle events. The forwarder task pulls
/// `PtyClient.outputs` and emits [`PtyByteFrame`]s into the unified
/// main-loop channel.
struct PtyStream {
    stdin: mpsc::UnboundedSender<Bytes>,
    shell: ShellState,
    scanner: QueryScanner,
    forwarder: tokio::task::JoinHandle<()>,
}

impl Drop for PtyStream {
    fn drop(&mut self) {
        self.forwarder.abort();
    }
}

/// Time-ordered frame the main loop pulls off the unified `pty_byte_rx`.
/// Bytes interleave with `Closed` so the consumer can flush any
/// trailing buffer before tearing down per-PTY state.
enum PtyByteFrame {
    Bytes(PtyId, Bytes),
    /// The `/pty/<id>` WS closed. Carries why (for the reconnect decision)
    /// and the last absolute resume cursor (`resume_cursor()`), so a warm
    /// reconnect can pass it back as `?since=`.
    Closed(PtyId, Option<CloseReason>, Option<u64>),
}

/// Spawn the per-PTY forwarder that drains `PtyClient.outputs` into the
/// unified `pty_byte_tx`. Returns the [`PtyStream`] handle (stdin
/// sender + ShellState/QueryScanner placeholders + the forwarder
/// JoinHandle) for the caller to register in `AppState.pty_streams`.
fn spawn_pty_stream(
    pty_id: PtyId,
    pty: PtyClient,
    initial_cwd: Option<PathBuf>,
    tx: mpsc::UnboundedSender<PtyByteFrame>,
) -> PtyStream {
    let stdin = pty.stdin.clone();
    let pty_id_for_task = pty_id.clone();
    let forwarder = tokio::spawn(async move {
        let mut pty = pty;
        while let Some(bytes) = pty.outputs.recv().await {
            if tx
                .send(PtyByteFrame::Bytes(pty_id_for_task.clone(), bytes))
                .is_err()
            {
                return;
            }
        }
        let reason = pty.close_reason();
        let cursor = pty.resume_cursor();
        let _ = tx.send(PtyByteFrame::Closed(pty_id_for_task, reason, cursor));
    });
    PtyStream {
        stdin,
        shell: ShellState::new(ShellKind::Unknown, std::time::Instant::now(), initial_cwd),
        scanner: QueryScanner::new(),
        forwarder,
    }
}

pub async fn run(url: &str, token: &str, session: String) -> Result<()> {
    let tr = crate::transport::connect_v2(url, token, None, None).await?;
    run_with(tr, session).await
}

pub async fn run_with(mut tr: crate::transport::ConnectedV2, session: String) -> Result<()> {
    // Probe BEFORE entering raw mode / alt screen so the OSC reply the
    // terminal writes back doesn't get mixed with crossterm event traffic.
    let (term_fg, term_bg) = crate::palette::probe();
    let attach: ses::AttachResult = tr
        .client
        .call(
            "session.attach",
            ses::AttachParams {
                name: session.clone(),
                last_seq: None,
                term_fg,
                term_bg,
                theme: None,
            },
        )
        .await?;

    // `tree.changed` / `git.changed` only fire while at least one client
    // has subscribed (see `docs/rpc.md` §5.4). The TUI's left panels —
    // file tree + git — are always visible during a session, so we
    // subscribe right after attach and best-effort `fs.unwatch` on exit.
    let _: pfs::WatchResult = tr
        .client
        .call("fs.watch", pfs::WatchParams::default())
        .await
        .unwrap_or_default();
    // Initial tree root: active PTY's cwd if there's one already running,
    // otherwise the session's workdir. Either way it's an absolute path.
    let initial_root: PathBuf = attach
        .active_view
        .as_ref()
        .and_then(|vid| attach.views.iter().find(|v| &v.id == vid))
        .and_then(|v| match &v.spec {
            ViewSpec::Pty { pty_id } => attach
                .ptys
                .iter()
                .find(|p| &p.id == pty_id)
                .map(|p| p.cwd.clone()),
            _ => None,
        })
        .unwrap_or_else(|| attach.session.workdir.clone());

    let tree: pfs::TreeResult = tr
        .client
        .call(
            "fs.tree",
            pfs::TreeParams {
                path: initial_root.to_string_lossy().into_owned(),
                depth: 1,
                show_hidden: false,
            },
        )
        .await
        .unwrap_or(pfs::TreeResult {
            path: initial_root.to_string_lossy().into_owned(),
            entries: vec![],
        });
    let git_status = tr
        .client
        .call::<_, pgit::StatusResult>(
            "git.status",
            pgit::StatusParams {
                cwd: Some(initial_root.clone()),
            },
        )
        .await
        .ok();

    let (pty_byte_tx, pty_byte_rx) = mpsc::unbounded_channel::<PtyByteFrame>();
    let mut state = AppState::new(session, attach, initial_root, tree, git_status, pty_byte_tx);

    // Open `/pty/<id>` WS for every PTY that already existed at attach.
    // Subsequent `pty.created` events queue into `pending_pty_opens`
    // and are processed at the top of the main loop.
    let initial_ptys: Vec<ppty::PtyInfo> = state.attach_ptys.drain(..).collect();
    for info in initial_ptys {
        if let Err(e) = open_and_register_pty(&mut state, &tr.client, &info).await {
            state.status = format!("open /pty/{}: {e}", info.id);
        }
    }

    enable_raw_mode()?;
    let mut stdout = std::io::stdout();
    // EnableFocusChange: the terminal emits FocusGained/FocusLost so we can
    // reclaim PTY primary when this TUI's window regains focus (see main_loop).
    execute!(stdout, EnterAlternateScreen, EnableMouseCapture, EnableFocusChange)?;
    let backend = CrosstermBackend::new(stdout);
    let mut term = Terminal::new(backend)?;

    let result = main_loop(&mut term, &mut tr.client, &mut state, pty_byte_rx).await;

    disable_raw_mode()?;
    execute!(
        term.backend_mut(),
        LeaveAlternateScreen,
        DisableMouseCapture,
        DisableFocusChange
    )?;
    term.show_cursor()?;

    // Best-effort unsubscribe so the server can tear down its file
    // watcher if no other client still wants it. `session.detach`
    // would clean up anyway, but the TUI doesn't always detach — when
    // it doesn't, leaving the watcher running costs CPU for nothing.
    let _: pfs::UnwatchResult = tr
        .client
        .call("fs.unwatch", pfs::UnwatchParams::default())
        .await
        .unwrap_or_default();

    result
}

/// Open a `/pty/<id>` WS, spawn the forwarder, and register the
/// resulting [`PtyStream`] under `state.pty_streams`. Idempotent: if
/// we're already tracking this PTY, the call is a no-op (the existing
/// forwarder stays).
async fn open_and_register_pty(
    state: &mut AppState,
    client: &Client,
    info: &ppty::PtyInfo,
) -> Result<()> {
    if state.pty_streams.contains_key(&info.id) {
        return Ok(());
    }
    let pty = client.open_pty(info.id.as_str(), 0).await?;
    let stream = spawn_pty_stream(
        info.id.clone(),
        pty,
        Some(info.cwd.clone()),
        state.pty_byte_tx.clone(),
    );
    state.pty_streams.insert(info.id.clone(), stream);
    Ok(())
}

/// Re-open a `/pty/<id>` WS whose previous connection dropped. `since` is the
/// resume offset: `Some(cursor)` warm-resumes the exact byte delta we missed;
/// `None` reconnects cold (fresh VT snapshot) and first resets the local
/// `PtyView` so the snapshot's scrollback doesn't stack on the stale screen.
/// A failed reconnect just leaves the PTY without a stream (surfaced in the
/// status line) — it does not reschedule, so the loop can't spin.
async fn reconnect_pty(
    state: &mut AppState,
    client: &Client,
    pty_id: PtyId,
    since: Option<u64>,
) {
    if since.is_none() {
        if let Some(view) = state.pty_views.get(&pty_id) {
            let (rows, cols) = view.current_size();
            state.pty_views.insert(pty_id.clone(), PtyView::new(rows, cols));
        }
    }
    // `open_pty` takes an absolute offset; 0 == tail (server treats it as
    // below the ring origin and serves a snapshot), which is exactly our
    // cold case.
    let pty = match client.open_pty(pty_id.as_str(), since.unwrap_or(0)).await {
        Ok(p) => p,
        Err(e) => {
            state.status = format!("reconnect /pty/{pty_id}: {e}");
            return;
        }
    };
    let initial_cwd = state.pty_cwds.get(&pty_id).cloned();
    let stream = spawn_pty_stream(pty_id.clone(), pty, initial_cwd, state.pty_byte_tx.clone());
    state.pty_streams.insert(pty_id.clone(), stream);
    state.status = match since {
        Some(c) => format!("/pty/{pty_id} reconnected (resumed @ {c})"),
        None => format!("/pty/{pty_id} reconnected (fresh snapshot)"),
    };
}

async fn main_loop(
    term: &mut Terminal<TermBackend>,
    client: &mut Client,
    state: &mut AppState,
    mut pty_byte_rx: mpsc::UnboundedReceiver<PtyByteFrame>,
) -> Result<()> {
    // Claim PTY primary on attach so the shared master grid sizes to this
    // terminal from the start — the server doesn't auto-promote an attaching
    // client, and FocusGained only fires on a *later* refocus. Mirrors the iOS
    // client reclaiming primary right after attach.
    if let Some(vid) = state.active_view.clone() {
        activate_view_id(client, vid).await;
    }
    loop {
        term.draw(|f| draw(f, state))?;

        // Push out any deferred pty.resize requests (driven by render-time
        // measurements of the body area).
        let resizes: Vec<(PtyId, u16, u16)> = state.pending_resizes.drain(..).collect();
        for (pty_id, cols, rows) in resizes {
            let _: serde_json::Value = client
                .call("pty.resize", ppty::PtyResizeParams { pty_id, cols, rows })
                .await
                .unwrap_or(serde_json::Value::Null);
        }

        // Open `/pty/<id>` WS for every PTY that surfaced via a
        // `pty.created` event since the last tick. Done out here (not
        // inside `apply_notification`) because open_pty is async and
        // we need access to the Coordinator.
        let opens: Vec<ppty::PtyInfo> = state.pending_pty_opens.drain(..).collect();
        for info in opens {
            if let Err(e) = open_and_register_pty(state, client, &info).await {
                state.status = format!("open /pty/{}: {e}", info.id);
            }
        }

        // Lazy-load the active view's body cache (preview text / diff patch).
        // PTYs and images don't need this — PTY bytes arrive on the
        // raw `/pty/<id>` WS, and images aren't in the TUI body for now.
        load_active_view_if_needed(state, client).await;

        // Drain PTY raw-byte frames first so the rendered terminal stays
        // ahead of the structured event/key flow.
        for _ in 0..64 {
            match pty_byte_rx.try_recv() {
                Ok(PtyByteFrame::Bytes(pid, bytes)) => apply_pty_bytes(state, pid, bytes),
                Ok(PtyByteFrame::Closed(pid, reason, cursor)) => {
                    // `/pty/<id>` WS closed. Drop the dead stream, then decide
                    // whether to reconnect based on why it closed:
                    //
                    //   Normal / None — PTY exited or session detached. Don't
                    //     reconnect; the matching `pty.exited` event cleans up
                    //     `pty_views`/`pty_blocks` on its own schedule.
                    //   Transport — network blip, PTY still alive server-side.
                    //     Warm-resume from our last cursor (`?since=<cursor>`)
                    //     so we pick up exactly the bytes we missed.
                    //   HistoryTruncated (4011) / StaleCursor (4012) — the
                    //     server says our cursor is invalid. Reconnect cold
                    //     (no `since=`) for a fresh VT snapshot; reset the
                    //     local screen first so it doesn't double scrollback.
                    //
                    // Each close schedules at most one reconnect, and a failed
                    // reconnect doesn't reschedule — so a dead server can't
                    // spin us in a tight loop.
                    state.pty_streams.remove(&pid);
                    match reason {
                        None | Some(CloseReason::Normal) => {}
                        Some(CloseReason::Transport) => {
                            state.pending_pty_reconnects.push((pid, cursor));
                        }
                        Some(CloseReason::HistoryTruncated)
                        | Some(CloseReason::StaleCursor) => {
                            state.pending_pty_reconnects.push((pid, None));
                        }
                    }
                }
                Err(mpsc::error::TryRecvError::Empty) => break,
                Err(mpsc::error::TryRecvError::Disconnected) => break,
            }
        }

        // Re-open any `/pty/<id>` WS that dropped this tick (warm or cold per
        // the close reason recorded above). Done out here because reconnect is
        // async and needs the Coordinator — same shape as `pending_pty_opens`.
        let reconnects: Vec<(PtyId, Option<u64>)> =
            state.pending_pty_reconnects.drain(..).collect();
        for (pid, since) in reconnects {
            reconnect_pty(state, client, pid, since).await;
        }

        // Drain incoming server notifications quickly. Responses are routed
        // by id inside `Client` and never show up here — this loop only
        // sees the 12 real server-pushed events.
        for _ in 0..64 {
            match tokio::time::timeout(Duration::from_millis(0), client.recv_notification()).await {
                Ok(Some(n)) => apply_notification(state, n),
                Ok(None) => return Ok(()), // connection closed
                Err(_) => break,           // queue empty for now
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
            match event::read()? {
                CtEvent::Key(k) => {
                    if k.kind != KeyEventKind::Press {
                        continue;
                    }
                    match handle_key(state, client, k.code, k.modifiers).await? {
                        KeyOutcome::Quit => return Ok(()),
                        KeyOutcome::Stay => {}
                    }
                }
                // Window regained focus: reclaim PTY primary for this client so
                // the shared master grid resizes back to this terminal's size.
                // Re-activating the current view runs the server's mark_primary
                // without disturbing peers (a no-op broadcast when unchanged) —
                // the same "I'm driving" signal a tab switch or iOS focus sends.
                CtEvent::FocusGained => {
                    if let Some(vid) = state.active_view.clone() {
                        activate_view_id(client, vid).await;
                    }
                }
                _ => {}
            }
        }
    }
}

// ─────────────────────────── App state ───────────────────────────

struct AppState {
    session_name: String,
    /// Workdir as reported by the server. Used as the fallback tree root when
    /// no PTY is active.
    session_workdir: PathBuf,
    other_clients: u32,

    /// Absolute directory the file tree pane is currently showing.
    current_path: PathBuf,
    files: Vec<pfs::TreeEntry>,
    tree_state: ListState,
    git: Option<pgit::StatusResult>,
    /// Selection in the git panel's file list. Independent of `tree_state`
    /// so each panel keeps its own cursor. Only consulted in `Mode::Git`.
    git_state: ListState,

    /// Per-panel visibility. Hidden panels are skipped at draw time and
    /// the left column collapses; both hidden → body takes full width.
    /// Defaults are both visible to match the legacy layout.
    show_tree: bool,
    show_git: bool,

    /// Synced from server.
    views: Vec<ViewInfo>,
    active_view: Option<ViewId>,

    /// Latest known cwd per PTY. Seeded from `attach.ptys` and updated on
    /// `pty.created` and `pty.cwd_changed`. The main loop diffs the active
    /// PTY's entry against `current_path` and retargets the tree.
    pty_cwds: HashMap<PtyId, PathBuf>,
    /// Spawn command per PTY (e.g. "/bin/zsh"), seeded from `attach.ptys`
    /// and `pty.created`. Used as a fallback label when nothing better is
    /// available.
    pty_cmds: HashMap<PtyId, String>,
    /// v2 shell-integration UI state per PTY: the currently-running
    /// command (for `▶ <cmd>` chip + `<cwd> · <fg>` tab labels) and the
    /// most-recent finish for a brief flash of `✓ 0` / `✗ N`.
    pty_blocks: HashMap<PtyId, PtyBlockUi>,

    /// True when the user has manually navigated away (Backspace / Enter into
    /// a subdir). While true, we DON'T auto-follow the active PTY's cwd —
    /// otherwise their browsing would get yanked back every 1.5s. Reset by
    /// `g` (re-anchor) or by switching tabs.
    manual_nav: bool,

    /// Per-client PTY screen state, keyed by pty_id.
    pty_views: HashMap<PtyId, PtyView>,
    pty_last_size: HashMap<PtyId, (u16, u16)>,
    pending_resizes: Vec<(PtyId, u16, u16)>,

    /// Active `/pty/<id>` WebSocket connections + per-PTY OSC parsers.
    /// Owns the forwarder JoinHandle (aborted on Drop) and the stdin
    /// sender — keyboard input and canonical capability-query replies
    /// both flow back to the server through `pty_streams[id].stdin`.
    pty_streams: HashMap<PtyId, PtyStream>,
    /// Producer end of the unified PTY byte stream. Cloned into each
    /// forwarder spawned by `open_and_register_pty`. Receiver end lives
    /// in `main_loop` as a local.
    pty_byte_tx: mpsc::UnboundedSender<PtyByteFrame>,
    /// PTYs surfaced by `pty.created` events that haven't yet been
    /// opened on the `/pty/<id>` WS. Drained at the top of each main
    /// loop tick (open_pty is async).
    pending_pty_opens: Vec<ppty::PtyInfo>,
    /// `/pty/<id>` WSes that dropped and want re-opening this tick, with the
    /// resume offset to use (`Some` = warm `?since=<cursor>`, `None` = cold
    /// snapshot). Populated by the `PtyByteFrame::Closed` handler, drained by
    /// the main loop (reconnect is async).
    pending_pty_reconnects: Vec<(PtyId, Option<u64>)>,
    /// PTYs present at attach time, drained by `run_with` before the
    /// main loop starts (same shape as `pending_pty_opens` but with
    /// the initial snapshot from `session.attach`).
    attach_ptys: Vec<ppty::PtyInfo>,

    /// Per-view client cache for preview/diff content. Hydrated lazily when
    /// the view becomes active.
    view_cache: HashMap<ViewId, ViewBodyCache>,

    /// Modal state. Keys behave very differently across modes — see the
    /// module docs for the full keymap.
    mode: Mode,

    status: String,
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
    /// Git-panel navigation: select a changed file, press Enter to open
    /// its diff tab. Same emacs movement vocabulary as `Tree`.
    Git,
}

enum ViewBodyCache {
    /// `scroll` is the top-line offset rendered (passed to ratatui's
    /// `Paragraph::scroll((scroll, 0))`). Mutated in-place by the Pane-mode
    /// arrow / page keys when a non-PTY view is active; clamped to
    /// `0..line_count(content)-1` on every render so a freshly-shrunk
    /// content can't leave the cursor pointing past the end.
    Preview { content: String, scroll: u16 },
    Diff { patch: String, scroll: u16 },
}

#[derive(Default, Debug, Clone)]
struct PtyBlockUi {
    /// Set to the command text on `pty.command_started`, cleared on the
    /// matching `command_finished`. Drives the "currently running" chip.
    running: Option<String>,
    /// Most-recent finish: (command text, exit code, when it landed).
    /// Rendered for ~3s as a colour flash, then suppressed.
    flash: Option<(String, Option<i32>, std::time::Instant)>,
}

const FLASH_TTL: std::time::Duration = std::time::Duration::from_secs(3);

/// First token of a command line, ignoring `KEY=VAL` env-var prefixes
/// and stripping the path so `/usr/bin/git push` → "git" and
/// `EDITOR=vim git commit` → "git".
fn first_meaningful_token(cmd: &str) -> String {
    for tok in cmd.split_whitespace() {
        if tok.contains('=') {
            continue;
        }
        return std::path::Path::new(tok)
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or(tok)
            .to_string();
    }
    cmd.split_whitespace().next().unwrap_or("").to_string()
}

impl AppState {
    fn new(
        session_name: String,
        attach: ses::AttachResult,
        initial_root: PathBuf,
        tree: pfs::TreeResult,
        git: Option<pgit::StatusResult>,
        pty_byte_tx: mpsc::UnboundedSender<PtyByteFrame>,
    ) -> Self {
        let mut tree_state = ListState::default();
        if !tree.entries.is_empty() {
            tree_state.select(Some(0));
        }

        // Pre-allocate PTY screen state + cwd map for any PTYs already in
        // the session; bytes will arrive on `/pty/<id>` once `run_with`
        // opens those WS connections.
        let mut pty_views = HashMap::new();
        let mut pty_cwds = HashMap::new();
        let mut pty_cmds = HashMap::new();
        for p in &attach.ptys {
            pty_views.insert(p.id.clone(), PtyView::new(p.rows.max(1), p.cols.max(1)));
            pty_cwds.insert(p.id.clone(), p.cwd.clone());
            pty_cmds.insert(p.id.clone(), p.cmd.clone());
        }

        let session_workdir = attach.session.workdir.clone();
        let attach_ptys = attach.ptys;
        let mut git_state = ListState::default();
        if git
            .as_ref()
            .map(|g| !g.files.is_empty())
            .unwrap_or(false)
        {
            git_state.select(Some(0));
        }
        Self {
            session_name,
            session_workdir,
            other_clients: attach.clients.len() as u32,
            current_path: initial_root,
            files: tree.entries,
            tree_state,
            git,
            git_state,
            show_tree: true,
            show_git: true,
            views: attach.views,
            active_view: attach.active_view,
            pty_cwds,
            pty_cmds,
            pty_blocks: HashMap::new(),
            manual_nav: false,
            pty_views,
            pty_last_size: HashMap::new(),
            pending_resizes: Vec::new(),
            pty_streams: HashMap::new(),
            pty_byte_tx,
            pending_pty_opens: Vec::new(),
            pending_pty_reconnects: Vec::new(),
            attach_ptys,
            view_cache: HashMap::new(),
            mode: Mode::Pane,
            status: format!(
                "attached as {} — Ctrl-g for prefix, Ctrl-g ? for help",
                attach.client_id
            ),
        }
    }
}

// ─────────────────────────── Notification application ───────────────────────────

fn apply_notification(state: &mut AppState, n: Notification) {
    match n.method.as_str() {
        "client.joined" => state.other_clients += 1,
        "client.left" => state.other_clients = state.other_clients.saturating_sub(1),
        "tree.changed" => state.status = "tree changed (press r to refresh)".into(),
        "git.changed" => state.status = "git changed (press r to refresh)".into(),

        // Synced tabs: views are the source of truth for "what tabs exist /
        // which is active". They auto-pop-up on every client.
        "view.opened" => {
            if let Ok(Event::ViewOpened { view, .. }) = serde_json::from_value::<Event>(
                serde_json::json!({"method":"view.opened","params":n.params}),
            ) {
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
                    if state.mode == Mode::Scroll {
                        state.mode = Mode::Pane;
                    }
                }
            }
        }
        "view.active_changed" => {
            if let Ok(Event::ViewActiveChanged { view_id, .. }) = serde_json::from_value::<Event>(
                serde_json::json!({"method":"view.active_changed","params":n.params}),
            ) {
                let new_active_pty_changed = match (
                    active_pty_id(state).cloned(),
                    view_id
                        .as_ref()
                        .and_then(|vid| pty_id_of(state, vid).cloned()),
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
                    if state.mode == Mode::Scroll {
                        state.mode = Mode::Pane;
                    }
                }
            }
        }
        "view.moved" => {
            // Reorder local views to match the server's new order. Any view
            // we don't recognise gets dropped (it should have been closed
            // separately, but be defensive); any local view missing from
            // `order` is appended in its original position to avoid losing
            // tabs if events race.
            if let Ok(Event::ViewMoved { order, .. }) = serde_json::from_value::<Event>(
                serde_json::json!({"method":"view.moved","params":n.params}),
            ) {
                let mut by_id: std::collections::HashMap<String, ViewInfo> =
                    state.views.drain(..).map(|v| (v.id.clone(), v)).collect();
                let mut next: Vec<ViewInfo> = Vec::with_capacity(order.len());
                for id in &order {
                    if let Some(v) = by_id.remove(id) {
                        next.push(v);
                    }
                }
                // Append leftovers (rare) so we don't silently drop tabs.
                for (_id, v) in by_id {
                    next.push(v);
                }
                state.views = next;
            }
        }

        // PTY infrastructure events — these maintain the per-PTY screen
        // buffer + cwd map. Tab list is synced via view.* (above), not these.
        "pty.created" => {
            if let Ok(Event::PtyCreated { info, .. }) = serde_json::from_value::<Event>(
                serde_json::json!({"method":"pty.created","params":n.params}),
            ) {
                state
                    .pty_views
                    .entry(info.id.clone())
                    .or_insert_with(|| PtyView::new(info.rows.max(1), info.cols.max(1)));
                state.pty_cwds.insert(info.id.clone(), info.cwd.clone());
                state.pty_cmds.insert(info.id.clone(), info.cmd.clone());
                state.status = format!("pty {} created", info.id);
                // open_pty needs the Coordinator; defer to main_loop.
                state.pending_pty_opens.push(info);
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
                state.pty_streams.remove(&pid_owned);
                state.pending_pty_opens.retain(|p| p.id != pid_owned);
                state.status = format!("pty {pid_owned} exited");
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
        _ => {}
    }
}

// ─────────────────────────── PTY byte handling ───────────────────────────

/// Drive the per-PTY OSC parser + block state machine off a raw byte
/// burst, then feed the passthrough portion to the vt100 buffer.
/// Capability queries (cursor position, OSC 10/11 colour, XTVERSION,
/// etc.) get answered synchronously by sending the canonical reply
/// straight back to PTY stdin — the same defence-in-depth the
/// previous server-side scanner provided.
fn apply_pty_bytes(state: &mut AppState, pty_id: PtyId, bytes: Bytes) {
    // Pull the per-PTY OSC scan + shell-event derivation out under a
    // narrow borrow of `pty_streams`, then dispatch into the rest of
    // AppState afterwards (which also touches `pty_views` / `pty_cwds`
    // / `pty_blocks`).
    let (passthrough, shell_events): (Vec<u8>, Vec<ShellEvent>) = {
        let Some(stream) = state.pty_streams.get_mut(&pty_id) else {
            return;
        };
        let scan = stream.scanner.feed(&bytes);
        let mut shell_events: Vec<ShellEvent> = Vec::new();
        for item in &scan.items {
            match item {
                ScanItem::Bytes(b) => stream.shell.record_output(b),
                ScanItem::Query { kind, .. } => {
                    if kind.is_shell_integration() {
                        shell_events.extend(stream.shell.on_osc(kind));
                    } else if let Some(reply) = kind.canonical_response() {
                        let _ = stream.stdin.send(Bytes::from(reply));
                    }
                }
            }
        }
        (scan.passthrough, shell_events)
    };

    if !passthrough.is_empty() {
        let view = state
            .pty_views
            .entry(pty_id.clone())
            .or_insert_with(|| PtyView::new(24, 80));
        view.process(&passthrough);
    }

    for ev in shell_events {
        apply_shell_event(state, &pty_id, ev);
    }
}

/// Apply a single decoded [`ShellEvent`] to AppState. Mirrors the old
/// `pty.command_*` / `pty.cwd_changed` notification handlers exactly.
/// `Bootstrapped`, `PromptStarted/Ended`, and `Context` carry no UI
/// state the TUI surfaces today — they're consumed silently.
fn apply_shell_event(state: &mut AppState, pty_id: &PtyId, ev: ShellEvent) {
    match ev {
        ShellEvent::CommandStarted { id, text, .. } => {
            state.pty_blocks.entry(pty_id.clone()).or_default().running = Some(text.clone());
            if let Some(view) = state.pty_views.get_mut(pty_id) {
                view.mark_block_start(id);
            }
        }
        ShellEvent::CommandFinished {
            id, cmd, exit, ..
        } => {
            let entry = state.pty_blocks.entry(pty_id.clone()).or_default();
            entry.running = None;
            entry.flash = Some((cmd, exit, std::time::Instant::now()));
            if let Some(view) = state.pty_views.get_mut(pty_id) {
                view.mark_block_end(&id, exit);
            }
        }
        ShellEvent::CwdChanged { cwd } => {
            state.pty_cwds.insert(pty_id.clone(), cwd);
        }
        ShellEvent::Bootstrapped
        | ShellEvent::PromptStarted { .. }
        | ShellEvent::PromptEnded { .. }
        | ShellEvent::Context { .. } => {}
    }
}

// ─────────────────────────── Helpers ───────────────────────────

fn active_view_info(state: &AppState) -> Option<&ViewInfo> {
    state
        .active_view
        .as_ref()
        .and_then(|id| state.views.iter().find(|v| &v.id == id))
}

fn active_index(state: &AppState) -> Option<usize> {
    state
        .active_view
        .as_ref()
        .and_then(|id| state.views.iter().position(|v| &v.id == id))
}

fn pty_id_of<'a>(state: &'a AppState, view_id: &str) -> Option<&'a PtyId> {
    state
        .views
        .iter()
        .find(|v| v.id == view_id)
        .and_then(|v| match &v.spec {
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
    let _: serde_json::Value = client
        .call(
            "view.activate",
            pview::ActivateParams {
                view_id: Some(view_id),
            },
        )
        .await
        .unwrap_or(serde_json::Value::Null);
}

async fn close_view_id(client: &mut Client, view_id: ViewId) {
    let _: serde_json::Value = client
        .call("view.close", pview::CloseParams { view_id })
        .await
        .unwrap_or(serde_json::Value::Null);
}

async fn open_view(client: &mut Client, spec: ViewSpec, activate: bool) {
    let _: serde_json::Value = client
        .call("view.open", pview::OpenParams { spec, activate })
        .await
        .unwrap_or(serde_json::Value::Null);
}

// ─────────────────────────── Lazy view content loading ───────────────────────────

async fn load_active_view_if_needed(state: &mut AppState, client: &mut Client) {
    let Some(vid) = state.active_view.clone() else {
        return;
    };
    if state.view_cache.contains_key(&vid) {
        return;
    }
    let spec = match state
        .views
        .iter()
        .find(|v| v.id == vid)
        .map(|v| v.spec.clone())
    {
        Some(s) => s,
        None => return,
    };
    match spec {
        ViewSpec::Preview { path } => {
            if let Ok(r) = client
                .call::<_, pfs::ReadResult>(
                    "fs.read",
                    pfs::ReadParams {
                        path: path.clone(),
                        max_bytes: 5_000_000,
                    },
                )
                .await
            {
                let bytes = BASE64.decode(r.content_b64.as_bytes()).unwrap_or_default();
                let content = if r.binary {
                    format!(
                        "(binary file, {} bytes, mime: {})",
                        bytes.len(),
                        r.mime.as_deref().unwrap_or("?")
                    )
                } else {
                    String::from_utf8_lossy(&bytes).into_owned()
                };
                state
                    .view_cache
                    .insert(vid, ViewBodyCache::Preview { content, scroll: 0 });
            }
        }
        ViewSpec::Diff { staged, path } => {
            // Compute the diff scoped to whatever the file-tree pane is
            // pointing at. Mirrors the web client's behavior — switching cwd
            // and reopening diff yields a fresh view of the new repo.
            let cwd = Some(state.current_path.clone());
            if let Ok(r) = client
                .call::<_, pgit::DiffResult>("git.diff", pgit::DiffParams { path, staged, cwd })
                .await
            {
                state
                    .view_cache
                    .insert(vid, ViewBodyCache::Diff { patch: r.patch, scroll: 0 });
            }
        }
        ViewSpec::Pty { .. } | ViewSpec::Image { .. } => {
            // No body fetch needed.
        }
    }
}

// ─────────────────────────── Key handling ───────────────────────────

enum KeyOutcome {
    Stay,
    Quit,
}

/// Number of rows we move on `C-v` / `M-v` in tree mode. Half a typical
/// terminal height; we don't track the actual pane size here so this is a
/// fixed compromise.
const TREE_PAGE_LINES: i32 = 10;

async fn handle_key(
    state: &mut AppState,
    client: &mut Client,
    code: KeyCode,
    mods: KeyModifiers,
) -> Result<KeyOutcome> {
    match state.mode {
        Mode::Prefix => {
            // Drop back to Pane unconditionally; specific prefix commands
            // that enter another mode (Tree / Scroll) reset state.mode below.
            state.mode = Mode::Pane;
            handle_prefix_key(state, client, code, mods).await
        }
        Mode::Tree => handle_tree_mode_key(state, client, code, mods).await,
        Mode::Git => handle_git_mode_key(state, client, code, mods).await,
        Mode::Scroll => handle_scroll_mode_key(state, client, code, mods).await,
        Mode::Pane => handle_pane_key(state, client, code, mods).await,
    }
}

/// Default mode: keys flow to the active PTY (tmux pane), **except**:
///   * `Ctrl-g` — enter Prefix
///   * arrow / PageUp / PageDown / Home / End — scroll the body when
///     the active view is non-PTY (preview / diff). PTY views fall
///     through so those keys still reach the shell (e.g., `less`, `vim`).
async fn handle_pane_key(
    state: &mut AppState,
    _client: &mut Client,
    code: KeyCode,
    mods: KeyModifiers,
) -> Result<KeyOutcome> {
    if matches!(code, KeyCode::Char('g')) && mods.contains(KeyModifiers::CONTROL) {
        state.mode = Mode::Prefix;
        state.status =
            "prefix · c=newpty n/p=tab w=close 1-9=jump d=detach r=refresh g=re-anchor D=diff t/T=tree s/S=git [=scroll ?=help".into();
        return Ok(KeyOutcome::Stay);
    }
    if matches!(
        code,
        KeyCode::Up
            | KeyCode::Down
            | KeyCode::PageUp
            | KeyCode::PageDown
            | KeyCode::Home
            | KeyCode::End
    ) {
        if let Some(out) = scroll_active_body(state, code) {
            return Ok(out);
        }
    }
    forward_to_pty(state, code, mods)
}

/// One half-screen page in lines for PageUp / PageDown over preview /
/// diff bodies. Same rationale as `TREE_PAGE_LINES`: we don't know the
/// real height here, so this is a reasonable fixed compromise.
const BODY_PAGE_LINES: i32 = 10;

/// Scroll the active view's body cache by `code`'s direction. Returns
/// `None` when there's nothing to scroll (active view is a PTY / image,
/// no cache yet, etc.) so the caller can fall through to PTY input.
fn scroll_active_body(state: &mut AppState, code: KeyCode) -> Option<KeyOutcome> {
    let vid = state.active_view.clone()?;
    let spec = state.views.iter().find(|v| v.id == vid).map(|v| &v.spec)?;
    if matches!(spec, ViewSpec::Pty { .. } | ViewSpec::Image { .. }) {
        return None;
    }
    let cache = state.view_cache.get_mut(&vid)?;
    let (scroll_ref, max_line) = match cache {
        ViewBodyCache::Preview { content, scroll } => {
            (scroll, content.lines().count().saturating_sub(1))
        }
        ViewBodyCache::Diff { patch, scroll } => {
            (scroll, patch.lines().count().saturating_sub(1))
        }
    };
    let max = max_line.min(u16::MAX as usize) as i32;
    let step: i32 = match code {
        KeyCode::Up => -1,
        KeyCode::Down => 1,
        KeyCode::PageUp => -BODY_PAGE_LINES,
        KeyCode::PageDown => BODY_PAGE_LINES,
        KeyCode::Home => i32::MIN,
        KeyCode::End => i32::MAX,
        _ => return None,
    };
    let cur = *scroll_ref as i32;
    let next = cur.saturating_add(step).clamp(0, max);
    *scroll_ref = next as u16;
    Some(KeyOutcome::Stay)
}

/// One-shot prefix dispatcher. Entered after `Ctrl-g` from any mode; falls
/// back to Pane after the command (unless the command itself entered Tree
/// or Scroll).
async fn handle_prefix_key(
    state: &mut AppState,
    client: &mut Client,
    code: KeyCode,
    mods: KeyModifiers,
) -> Result<KeyOutcome> {
    let ctrl = mods.contains(KeyModifiers::CONTROL);
    match (code, ctrl) {
        // tmux: prefix-c → new window
        (KeyCode::Char('c'), false) => {
            let (cols, rows) = (100u16, 30u16);
            match client
                .call::<_, ppty::PtyCreateResult>(
                    "pty.create",
                    ppty::PtyCreateParams {
                        cmd: None,
                        cwd: None,
                        env: vec![],
                        cols,
                        rows,
                    },
                )
                .await
            {
                Ok(r) => state.status = format!("created {}", r.info.id),
                Err(e) => state.status = format!("pty.create: {e}"),
            }
        }
        // tmux: prefix-n / prefix-p → next/prev window
        (KeyCode::Char('n'), false) => cycle_tabs(state, client, 1).await,
        (KeyCode::Char('p'), false) => cycle_tabs(state, client, -1).await,
        // prefix-w → close current tab (tmux's kill-window is `&`, but
        // requiring shift on most keyboards makes it awkward; `w` matches
        // the "close window" mnemonic from many editors).
        (KeyCode::Char('w'), false) => {
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
                "prefix · c=newpty n/p=tab w=close 1-9=jump d=detach r=refresh g=re-anchor D=diff t/T=tree s/S=git [=scroll b/f=block Ctrl-g=literal Ctrl-c=quit".into();
        }
        // refresh tree + git (motif-specific)
        (KeyCode::Char('r'), false) => refresh_tree(state, client).await,
        // re-anchor tree to active PTY's cwd (motif-specific)
        (KeyCode::Char('g'), false) => re_anchor_tree(state, client).await,
        // open diff tab. Capital D so prefix-d stays "detach" per tmux.
        (KeyCode::Char('D'), false) => {
            open_view(
                client,
                ViewSpec::Diff {
                    staged: false,
                    path: None,
                },
                true,
            )
            .await;
        }
        // enter Tree mode (file-tree navigation, emacs keys). Auto-show the
        // panel if it was hidden so the cursor has somewhere visible to land.
        (KeyCode::Char('t'), false) => {
            state.show_tree = true;
            state.mode = Mode::Tree;
            state.status =
                "tree · Ctrl-n/Ctrl-p select · Ctrl-m open · Ctrl-h up · Ctrl-v/Alt-v page · Alt-</Alt-> top/bottom · q or Ctrl-g leave".into();
        }
        // Toggle tree panel visibility (paired with `t` = enter Tree mode).
        (KeyCode::Char('T'), false) => {
            state.show_tree = !state.show_tree;
            if !state.show_tree && state.mode == Mode::Tree {
                state.mode = Mode::Pane;
            }
            state.status = if state.show_tree { "tree shown".into() } else { "tree hidden".into() };
        }
        // enter Git mode (changed-file navigation; Enter opens diff for the
        // selected file). Auto-show the panel.
        (KeyCode::Char('s'), false) => {
            state.show_git = true;
            // Seed selection if it was empty (e.g., entering for the first
            // time, or after the file list grew from empty).
            if state.git_state.selected().is_none()
                && state.git.as_ref().is_some_and(|g| !g.files.is_empty())
            {
                state.git_state.select(Some(0));
            }
            state.mode = Mode::Git;
            state.status =
                "git · Ctrl-n/Ctrl-p select · Ctrl-m open diff · q or Ctrl-g leave".into();
        }
        // Toggle git panel visibility (paired with `s` = enter Git mode).
        (KeyCode::Char('S'), false) => {
            state.show_git = !state.show_git;
            if !state.show_git && state.mode == Mode::Git {
                state.mode = Mode::Pane;
            }
            state.status = if state.show_git { "git shown".into() } else { "git hidden".into() };
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
            forward_to_pty(state, KeyCode::Char('g'), KeyModifiers::CONTROL)?;
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
        None => {
            state.status = "no PTY to jump".into();
            return;
        }
    };
    let view = match state.pty_views.get_mut(&pid) {
        Some(v) => v,
        None => {
            state.status = "no PTY view yet".into();
            return;
        }
    };
    let target = if forward {
        view.next_block_anchor()
    } else {
        view.prev_block_anchor()
    };
    let Some(target) = target else {
        state.status = if forward {
            "no later block".into()
        } else {
            "no earlier block".into()
        };
        return;
    };
    view.jump_to_abs(target);
    state.mode = Mode::Scroll;
    state.status = format!(
        "scroll · {} block · b/f to walk · q/Ctrl-g leave",
        if forward { "next" } else { "prev" },
    );
}

/// File-tree navigation. Emacs movement keys; arrows/Backspace/Enter as
/// fallbacks since they're unambiguous when keys aren't being forwarded
/// to a shell.
async fn handle_tree_mode_key(
    state: &mut AppState,
    client: &mut Client,
    code: KeyCode,
    mods: KeyModifiers,
) -> Result<KeyOutcome> {
    let ctrl = mods.contains(KeyModifiers::CONTROL);
    let alt = mods.contains(KeyModifiers::ALT);
    match (code, ctrl, alt) {
        // Ctrl-g re-enters Prefix so commands chain (the prefix is "always
        // reachable" from inside any sub-mode, tmux-style).
        (KeyCode::Char('g'), true, false) => {
            state.mode = Mode::Prefix;
            state.status = "tree → prefix".into();
        }
        // Plain `q` leaves to Pane.
        (KeyCode::Char('q'), false, false) => {
            state.mode = Mode::Pane;
            state.status = "left tree".into();
        }
        // Selection up/down — emacs Ctrl-n / Ctrl-p (and arrow fallbacks).
        (KeyCode::Char('n'), true, false) | (KeyCode::Down, false, false) => move_tree(state, 1),
        (KeyCode::Char('p'), true, false) | (KeyCode::Up, false, false) => move_tree(state, -1),
        // Page — emacs Ctrl-v / Alt-v.
        (KeyCode::Char('v'), true, false) => move_tree(state, TREE_PAGE_LINES),
        (KeyCode::Char('v'), false, true) => move_tree(state, -TREE_PAGE_LINES),
        // First / last — emacs M-< / M->.
        (KeyCode::Char('<'), false, true) => move_tree(state, i32::MIN),
        (KeyCode::Char('>'), false, true) => move_tree(state, i32::MAX),
        // Open / go up — emacs Ctrl-m (RET) / Ctrl-h (BS) and friendly fallbacks.
        (KeyCode::Char('m'), true, false) | (KeyCode::Enter, false, false) => {
            on_enter_in_tree(state, client).await
        }
        (KeyCode::Char('h'), true, false) | (KeyCode::Backspace, false, false) => {
            go_up_dir(state, client).await
        }
        _ => {}
    }
    Ok(KeyOutcome::Stay)
}

/// Git-panel navigation. Mirrors Tree mode's emacs vocabulary; Enter
/// opens the selected file's diff in a new tab. Branch / index lines
/// aren't selectable — only entries in `git.files`.
async fn handle_git_mode_key(
    state: &mut AppState,
    client: &mut Client,
    code: KeyCode,
    mods: KeyModifiers,
) -> Result<KeyOutcome> {
    let ctrl = mods.contains(KeyModifiers::CONTROL);
    let alt = mods.contains(KeyModifiers::ALT);
    match (code, ctrl, alt) {
        (KeyCode::Char('g'), true, false) => {
            state.mode = Mode::Prefix;
            state.status = "git → prefix".into();
        }
        (KeyCode::Char('q'), false, false) => {
            state.mode = Mode::Pane;
            state.status = "left git".into();
        }
        (KeyCode::Char('n'), true, false) | (KeyCode::Down, false, false) => {
            move_git(state, 1)
        }
        (KeyCode::Char('p'), true, false) | (KeyCode::Up, false, false) => move_git(state, -1),
        (KeyCode::Char('v'), true, false) => move_git(state, TREE_PAGE_LINES),
        (KeyCode::Char('v'), false, true) => move_git(state, -TREE_PAGE_LINES),
        (KeyCode::Char('<'), false, true) => move_git(state, i32::MIN),
        (KeyCode::Char('>'), false, true) => move_git(state, i32::MAX),
        (KeyCode::Char('m'), true, false) | (KeyCode::Enter, false, false) => {
            if let Some(path) = selected_git_path(state) {
                open_view(
                    client,
                    ViewSpec::Diff {
                        staged: false,
                        path: Some(path),
                    },
                    true,
                )
                .await;
                // Drop to Pane so focus follows the newly-opened diff tab;
                // the user can scroll it with arrow / PageUp / PageDown.
                state.mode = Mode::Pane;
                state.status = "opened diff".into();
            } else {
                state.status = "no file selected".into();
            }
        }
        _ => {}
    }
    Ok(KeyOutcome::Stay)
}

fn move_git(state: &mut AppState, delta: i32) {
    let total = state.git.as_ref().map(|g| g.files.len()).unwrap_or(0);
    if total == 0 {
        state.git_state.select(None);
        return;
    }
    let max = total as i32 - 1;
    let cur = state.git_state.selected().unwrap_or(0) as i32;
    let new = cur.saturating_add(delta).clamp(0, max);
    state.git_state.select(Some(new as usize));
}

/// Path of the currently-selected git file, or `None` if the selection
/// is out of bounds (e.g., the file list was emptied by an external
/// commit between selection and Enter).
fn selected_git_path(state: &AppState) -> Option<String> {
    let g = state.git.as_ref()?;
    let idx = state.git_state.selected()?;
    g.files.get(idx).map(|f| f.path.clone())
}

/// Active-PTY scrollback. Same emacs movement vocabulary as Tree mode.
async fn handle_scroll_mode_key(
    state: &mut AppState,
    _client: &mut Client,
    code: KeyCode,
    mods: KeyModifiers,
) -> Result<KeyOutcome> {
    let ctrl = mods.contains(KeyModifiers::CONTROL);
    let alt = mods.contains(KeyModifiers::ALT);
    match (code, ctrl, alt) {
        // Ctrl-g re-enters Prefix so commands chain (same as Tree mode).
        (KeyCode::Char('g'), true, false) => {
            state.mode = Mode::Prefix;
            state.status = "scroll → prefix".into();
        }
        // Plain `q` leaves to Pane. tmux's copy-mode-q leaves where you are;
        // we jump to live so the user doesn't end up frozen against drifting
        // output that they have to scroll back to see.
        (KeyCode::Char('q'), false, false) => {
            jump_active_pty(state, false);
            state.mode = Mode::Pane;
            state.status = "back to live".into();
        }
        // Page (emacs).
        (KeyCode::Char('v'), true, false) => scroll_active_pty(state, -1),
        (KeyCode::Char('v'), false, true) => scroll_active_pty(state, 1),
        // Top of scrollback / live (emacs M-< / M->).
        (KeyCode::Char('<'), false, true) => jump_active_pty(state, true),
        (KeyCode::Char('>'), false, true) => jump_active_pty(state, false),
        // Line up/down.
        (KeyCode::Char('n'), true, false) | (KeyCode::Down, false, false) => {
            scroll_lines(state, -1)
        }
        (KeyCode::Char('p'), true, false) | (KeyCode::Up, false, false) => scroll_lines(state, 1),
        // v2 shell-integration: walk between block starts.
        (KeyCode::Char('b'), false, false) => jump_block(state, /* forward */ false),
        (KeyCode::Char('f'), false, false) => jump_block(state, /* forward */ true),
        _ => {}
    }
    Ok(KeyOutcome::Stay)
}

fn scroll_lines(state: &mut AppState, lines: i64) {
    let id = match active_pty_id(state) {
        Some(i) => i.clone(),
        None => return,
    };
    if let Some(view) = state.pty_views.get_mut(&id) {
        view.scroll_lines(lines);
        state.status = scroll_status(view);
    }
}

async fn cycle_tabs(state: &AppState, client: &mut Client, delta: i32) {
    if state.views.is_empty() {
        return;
    }
    let len = state.views.len() as i32;
    let cur = active_index(state).unwrap_or(0) as i32;
    let next = ((cur + delta).rem_euclid(len)) as usize;
    let id = state.views[next].id.clone();
    activate_view_id(client, id).await;
}

fn forward_to_pty(
    state: &AppState,
    code: KeyCode,
    mods: KeyModifiers,
) -> Result<KeyOutcome> {
    let Some(pty_id) = active_pty_id(state) else {
        return Ok(KeyOutcome::Stay);
    };
    let bytes = key_to_bytes(code, mods);
    if bytes.is_empty() {
        return Ok(KeyOutcome::Stay);
    }
    if let Some(stream) = state.pty_streams.get(pty_id) {
        let _ = stream.stdin.send(Bytes::from(bytes));
    }
    Ok(KeyOutcome::Stay)
}

fn key_to_bytes(code: KeyCode, mods: KeyModifiers) -> Vec<u8> {
    match code {
        KeyCode::Char(c) => {
            if mods.contains(KeyModifiers::CONTROL) {
                let lc = c.to_ascii_lowercase();
                if ('a'..='z').contains(&lc) {
                    return vec![(lc as u8) - b'a' + 1];
                }
                return vec![c as u8];
            }
            if mods.contains(KeyModifiers::ALT) {
                let mut v = vec![0x1b];
                v.extend_from_slice(c.to_string().as_bytes());
                return v;
            }
            c.to_string().into_bytes()
        }
        KeyCode::Enter => vec![b'\r'],
        KeyCode::Tab => vec![b'\t'],
        KeyCode::Backspace => vec![0x7f],
        KeyCode::Esc => vec![0x1b],
        KeyCode::Up => b"\x1b[A".to_vec(),
        KeyCode::Down => b"\x1b[B".to_vec(),
        KeyCode::Right => b"\x1b[C".to_vec(),
        KeyCode::Left => b"\x1b[D".to_vec(),
        KeyCode::Home => b"\x1b[H".to_vec(),
        KeyCode::End => b"\x1b[F".to_vec(),
        KeyCode::PageUp => b"\x1b[5~".to_vec(),
        KeyCode::PageDown => b"\x1b[6~".to_vec(),
        KeyCode::Delete => b"\x1b[3~".to_vec(),
        _ => vec![],
    }
}

fn page_size(state: &AppState) -> i64 {
    let id = match active_pty_id(state) {
        Some(i) => i,
        None => return 10,
    };
    state
        .pty_last_size
        .get(id)
        .map(|(_, r)| (*r / 2).max(1) as i64)
        .unwrap_or(10)
}

fn scroll_active_pty(state: &mut AppState, dir: i32) {
    let step = -(dir as i64) * page_size(state);
    let id = match active_pty_id(state) {
        Some(i) => i.clone(),
        None => return,
    };
    if let Some(view) = state.pty_views.get_mut(&id) {
        view.scroll_lines(step);
        state.status = scroll_status(view);
    }
}

fn jump_active_pty(state: &mut AppState, top: bool) {
    let id = match active_pty_id(state) {
        Some(i) => i.clone(),
        None => return,
    };
    if let Some(view) = state.pty_views.get_mut(&id) {
        if top {
            view.jump_top();
        } else {
            view.jump_live();
        }
        state.status = scroll_status(view);
    }
}

fn scroll_status(view: &PtyView) -> String {
    match view.anchor() {
        None => "live".into(),
        Some(a) => format!(
            "scroll: line {a} of {} (End=live, Home=top)",
            view.abs_top()
        ),
    }
}

fn move_tree(state: &mut AppState, delta: i32) {
    let total = state.files.len() + parent_offset(state);
    if total == 0 {
        return;
    }
    let max = total as i32 - 1;
    let cur = state.tree_state.selected().unwrap_or(0) as i32;
    // Clamp instead of wrap. `i32::MIN`/`MAX` are the sentinels used for
    // emacs `M-<` / `M->` (jump to first / last) — they saturate cleanly.
    let new = cur.saturating_add(delta).clamp(0, max);
    state.tree_state.select(Some(new as usize));
}

/// Whether to render a `.. (parent)` row at the top of the file list. We hide
/// it when the current path has no parent (e.g., `/`) to avoid a dead row.
fn parent_offset(state: &AppState) -> usize {
    if state.current_path.parent().is_some() {
        1
    } else {
        0
    }
}

async fn refresh_tree(state: &mut AppState, client: &mut Client) {
    let path_str = state.current_path.to_string_lossy().into_owned();
    if let Ok(t) = client
        .call::<_, pfs::TreeResult>(
            "fs.tree",
            pfs::TreeParams {
                path: path_str.clone(),
                depth: 1,
                show_hidden: false,
            },
        )
        .await
    {
        state.files = t.entries;
        let cap = state.files.len() + parent_offset(state);
        if cap == 0 {
            state.tree_state.select(None);
        } else if state.tree_state.selected().unwrap_or(0) >= cap {
            state.tree_state.select(Some(cap - 1));
        }
    }
    // git.status with the active cwd; if outside any repo the server returns
    // NotAGitRepo, which we surface as None (panel shows "(not a git repo)").
    state.git = client
        .call::<_, pgit::StatusResult>(
            "git.status",
            pgit::StatusParams {
                cwd: Some(state.current_path.clone()),
            },
        )
        .await
        .ok();
    // Keep git_state in bounds — a refresh after the user committed a
    // file can shrink the list past the previously-selected index.
    let git_count = state.git.as_ref().map(|g| g.files.len()).unwrap_or(0);
    if git_count == 0 {
        state.git_state.select(None);
    } else if state.git_state.selected().unwrap_or(0) >= git_count {
        state.git_state.select(Some(git_count - 1));
    } else if state.git_state.selected().is_none() {
        state.git_state.select(Some(0));
    }
    state.status = format!("refreshed @ {path_str}");
}

/// Move the tree root. Sets `manual_nav` so auto-follow doesn't immediately
/// snap us back on the next pty.cwd_changed tick.
async fn change_dir(state: &mut AppState, client: &mut Client, new_path: PathBuf) {
    state.current_path = new_path;
    state.manual_nav = true;
    state.tree_state.select(Some(0));
    refresh_tree(state, client).await;
}

async fn go_up_dir(state: &mut AppState, client: &mut Client) {
    let Some(parent) = state.current_path.parent().map(|p| p.to_path_buf()) else {
        return;
    };
    change_dir(state, client, parent).await;
}

async fn on_enter_in_tree(state: &mut AppState, client: &mut Client) {
    let sel = state.tree_state.selected().unwrap_or(0);
    let off = parent_offset(state);
    if sel == 0 && off == 1 {
        go_up_dir(state, client).await;
        return;
    }
    let idx = sel.saturating_sub(off);
    let Some(ent) = state.files.get(idx).cloned() else {
        return;
    };
    let abs_path = state.current_path.join(&ent.name);
    match ent.kind {
        pfs::FileType::Dir => change_dir(state, client, abs_path).await,
        pfs::FileType::File | pfs::FileType::Symlink => {
            // Synced preview tab: server creates view → broadcasts → all
            // clients add the tab and (since activate=true) jump to it.
            let path_str = abs_path.to_string_lossy().into_owned();
            open_view(client, ViewSpec::Preview { path: path_str }, true).await;
            // Drop back to Pane mode so the newly-active preview body
            // takes focus immediately — keys (incl. arrow-key scroll)
            // flow into it rather than continuing to drive the tree.
            state.mode = Mode::Pane;
            state.status = "opened preview".into();
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
        .constraints([
            Constraint::Length(1),
            Constraint::Min(1),
            Constraint::Length(1),
        ])
        .split(f.area());

    let mut spans: Vec<Span> = vec![Span::raw(format!(
        " motif · {} · path: {} · {} other client{}",
        state.session_name,
        state.current_path.display(),
        state.other_clients,
        if state.other_clients == 1 { "" } else { "s" },
    ))];
    match state.mode {
        Mode::Pane => {}
        Mode::Prefix => spans.push(Span::raw("  [PREFIX]")),
        Mode::Tree => spans.push(Span::raw("  [TREE]")),
        Mode::Git => spans.push(Span::raw("  [GIT]")),
        Mode::Scroll => spans.push(Span::raw("  [SCROLL]")),
    }
    if state.manual_nav {
        spans.push(Span::raw("  [MANUAL]"));
    }
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

    // ── left column layout (conditional on which panels are visible) ──
    // When both panels are hidden the right column claims the full width,
    // so the user can keep terminals open with no UI chrome stealing
    // space. `Ctrl-g T` / `Ctrl-g S` toggle visibility; entering Tree or
    // Git mode auto-reveals the corresponding panel.
    let (tree_area, git_area, body_outer): (Option<Rect>, Option<Rect>, Rect) =
        match (state.show_tree, state.show_git) {
            (false, false) => (None, None, outer[1]),
            (tree, git) => {
                let main = Layout::default()
                    .direction(Direction::Horizontal)
                    .constraints([Constraint::Percentage(28), Constraint::Min(1)])
                    .split(outer[1]);
                let body = main[1];
                let (t, g) = match (tree, git) {
                    (true, true) => {
                        let l = Layout::default()
                            .direction(Direction::Vertical)
                            .constraints([Constraint::Percentage(60), Constraint::Min(1)])
                            .split(main[0]);
                        (Some(l[0]), Some(l[1]))
                    }
                    (true, false) => (Some(main[0]), None),
                    (false, true) => (None, Some(main[0])),
                    (false, false) => unreachable!(),
                };
                (t, g, body)
            }
        };

    // ── files panel ──
    if let Some(tree_area) = tree_area {
        let mut rows: Vec<ListItem> = Vec::with_capacity(state.files.len() + 1);
        if state.current_path.parent().is_some() {
            rows.push(ListItem::new(".. (parent)").style(Style::default().fg(Color::DarkGray)));
        }
        for e in &state.files {
            let glyph = match e.kind {
                pfs::FileType::Dir => "📁 ",
                pfs::FileType::Symlink => "↳ ",
                pfs::FileType::File => "  ",
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
        let leaf = state
            .current_path
            .file_name()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_else(|| state.current_path.to_string_lossy().into_owned());
        let title = format!("files · {leaf}");
        let list = List::new(rows)
            .block(Block::default().borders(Borders::ALL).title(title))
            .highlight_style(Style::default().add_modifier(Modifier::REVERSED));
        f.render_stateful_widget(list, tree_area, &mut state.tree_state);
    }

    // ── git panel ──
    if let Some(git_area) = git_area {
        let branch_line = match &state.git {
            Some(g) => format!(
                "branch {}",
                g.branch.clone().unwrap_or_else(|| "(detached)".into())
            ),
            None => "(not a git repo)".into(),
        };
        let title = format!("git · {branch_line}");
        let block = Block::default().borders(Borders::ALL).title(title);
        let inner = block.inner(git_area);
        f.render_widget(block, git_area);

        match &state.git {
            Some(g) if !g.files.is_empty() => {
                let rows: Vec<ListItem> = g
                    .files
                    .iter()
                    .take(200)
                    .map(|fe| {
                        let symbol =
                            format!("{}{}", short_status(fe.staged), short_status(fe.unstaged));
                        ListItem::new(Line::from(vec![
                            Span::styled(symbol, Style::default().fg(Color::Yellow)),
                            Span::raw(" "),
                            Span::raw(fe.path.clone()),
                        ]))
                    })
                    .collect();
                // Highlight only when the user has focused the git panel.
                // Outside Git mode the same selection renders as a normal
                // row so the panel doesn't visually compete with Tree mode.
                let highlight = if state.mode == Mode::Git {
                    Style::default()
                        .add_modifier(Modifier::REVERSED)
                        .fg(Color::LightYellow)
                } else {
                    Style::default()
                };
                let list = List::new(rows).highlight_style(highlight);
                f.render_stateful_widget(list, inner, &mut state.git_state);
            }
            Some(_) => {
                f.render_widget(
                    Paragraph::new(Line::from(Span::styled(
                        "(working tree clean)",
                        Style::default().fg(Color::DarkGray),
                    ))),
                    inner,
                );
            }
            None => { /* title already says "(not a git repo)" */ }
        }
    }

    // ── tabs + body ──
    let right = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(3), Constraint::Min(1)])
        .split(body_outer);

    // Tabs are labelled 1..N by current position. PTY tabs additionally show
    // a 1-based ordinal among PTYs (matches the web TabBar) instead of the
    // server-side monotonic id, so closing the middle PTY makes the next one
    // slide up to "pty:2" rather than leaving a "sh-7" gap.
    let mut pty_seen = 0usize;
    let titles: Vec<Line> = state
        .views
        .iter()
        .enumerate()
        .map(|(i, v)| {
            let label = match &v.spec {
                ViewSpec::Pty { pty_id } => {
                    pty_seen += 1;
                    pty_tab_label(state, pty_id, pty_seen)
                }
                _ => view_label(v),
            };
            Line::from(format!("{} {}", i + 1, label))
        })
        .collect();
    let tabs_widget = if titles.is_empty() {
        Tabs::new(vec![Line::from("(no tabs — Ctrl-b c to open PTY)")])
    } else {
        Tabs::new(titles)
            .select(active_index(state).unwrap_or(0))
            .highlight_style(
                Style::default()
                    .add_modifier(Modifier::REVERSED)
                    .fg(Color::LightYellow),
            )
    };
    f.render_widget(
        tabs_widget.block(Block::default().borders(Borders::ALL).title("tabs")),
        right[0],
    );

    let body_block = Block::default()
        .borders(Borders::ALL)
        .title(match state.mode {
            Mode::Pane => {
                "Ctrl-g c=newpty · Ctrl-g n/p=tab · Ctrl-g t=tree · Ctrl-g s=git · Ctrl-g [=scroll · Ctrl-g ?=help"
            }
            Mode::Prefix => "[prefix] · waiting for command key",
            Mode::Tree => "[tree mode] · Ctrl-n/p select · Ctrl-m open · Ctrl-h up · q to leave",
            Mode::Git => "[git mode] · Ctrl-n/p select · Ctrl-m open diff · q to leave",
            Mode::Scroll => "[scroll mode] · Ctrl-v/Alt-v page · Alt-</Alt-> top/live · q to leave",
        });
    let inner = body_block.inner(right[1]);
    f.render_widget(body_block, right[1]);

    // Snapshot the active view so we don't hold a borrow of state.views
    // while passing &mut state to render_pty_tab. Preview/Diff also
    // carry the saved `scroll` offset; arrow / page keys mutate it in
    // place via `scroll_active_body`.
    enum ActiveBody {
        Pty(PtyId),
        Preview(String, u16),
        Diff(String, u16),
        Loading(&'static str),
        None,
    }
    let active_body: ActiveBody = match active_view_info(state).map(|v| v.spec.clone()) {
        Some(ViewSpec::Pty { pty_id }) => ActiveBody::Pty(pty_id),
        Some(ViewSpec::Preview { .. }) => {
            match state
                .active_view
                .as_ref()
                .and_then(|vid| state.view_cache.get(vid))
            {
                Some(ViewBodyCache::Preview { content, scroll }) => {
                    ActiveBody::Preview(content.clone(), *scroll)
                }
                _ => ActiveBody::Loading("loading file…"),
            }
        }
        Some(ViewSpec::Diff { .. }) => {
            match state
                .active_view
                .as_ref()
                .and_then(|vid| state.view_cache.get(vid))
            {
                Some(ViewBodyCache::Diff { patch, scroll }) => {
                    ActiveBody::Diff(patch.clone(), *scroll)
                }
                _ => ActiveBody::Loading("loading diff…"),
            }
        }
        Some(ViewSpec::Image { path }) => ActiveBody::Loading(Box::leak(
            format!("(image: {} — open in browser to view)", path).into_boxed_str(),
        )),
        None => ActiveBody::None,
    };
    match active_body {
        ActiveBody::Pty(id) => render_pty_tab(f, state, &id, inner),
        ActiveBody::Preview(content, scroll) => {
            f.render_widget(
                Paragraph::new(content)
                    .wrap(Wrap { trim: false })
                    .scroll((scroll, 0)),
                inner,
            );
        }
        ActiveBody::Diff(patch, scroll) => {
            let lines: Vec<Line> = patch
                .lines()
                .map(|l| {
                    let style = if l.starts_with('+') {
                        Style::default().fg(Color::Green)
                    } else if l.starts_with('-') {
                        Style::default().fg(Color::Red)
                    } else if l.starts_with("@@") {
                        Style::default().fg(Color::Cyan)
                    } else {
                        Style::default()
                    };
                    Line::from(Span::styled(l.to_string(), style))
                })
                .collect();
            f.render_widget(Paragraph::new(lines).scroll((scroll, 0)), inner);
        }
        ActiveBody::Loading(msg) => {
            f.render_widget(
                Paragraph::new(msg).style(Style::default().fg(Color::DarkGray)),
                inner,
            );
        }
        ActiveBody::None => {}
    }

    let help = match state.mode {
        Mode::Pane   => " Ctrl-g prefix · keys flow to active PTY ",
        Mode::Prefix => " prefix: c=newpty n/p=tab w=close 1-9=jump d=detach r=refresh g=re-anchor D=diff t/T=tree s/S=git [=scroll ?=help · Ctrl-g=send literal Ctrl-g ",
        Mode::Tree   => " tree: Ctrl-n/p select · Ctrl-m open · Ctrl-h up · Ctrl-v/M-v page · M-</M-> top/bot · q leave · Ctrl-g chain prefix ",
        Mode::Git    => " git: Ctrl-n/p select · Ctrl-m open diff · Ctrl-v/M-v page · M-</M-> top/bot · q leave · Ctrl-g chain prefix ",
        Mode::Scroll => " scroll: Ctrl-v/M-v page · M-</M-> top/live · Ctrl-n/p line · b/f block · q leave · Ctrl-g chain prefix ",
    };
    f.render_widget(
        Paragraph::new(help).style(Style::default().bg(Color::DarkGray)),
        outer[2],
    );
}

fn render_pty_tab(f: &mut ratatui::Frame, state: &mut AppState, id: &PtyId, inner: Rect) {
    // Reserve one column on the left for a per-block status gutter:
    //   ▶ yellow │ — running command's row range
    //   ✓ green  │ — finished, exit 0
    //   ✗ red    │ — finished, non-zero exit
    //   ·  gray  │ — finished, signaled (no exit code)
    // The icon shows on the block's start row; subsequent rows in the
    // block use a vertical bar in the same color. Rows that don't fall
    // inside any tracked block stay blank.
    const GUTTER_W: u16 = 1;
    if inner.width <= GUTTER_W || inner.height == 0 {
        return;
    }
    let gutter_area = Rect {
        x: inner.x,
        y: inner.y,
        width: GUTTER_W,
        height: inner.height,
    };
    let pty_area = Rect {
        x: inner.x + GUTTER_W,
        y: inner.y,
        width: inner.width - GUTTER_W,
        height: inner.height,
    };

    let cols = pty_area.width.max(1);
    let rows = pty_area.height.max(1);

    let view = state
        .pty_views
        .entry(id.clone())
        .or_insert_with(|| PtyView::new(rows, cols));
    let (sr, sc) = view.current_size();
    if sr != rows || sc != cols {
        view.set_size(rows, cols);
    }
    let last = state.pty_last_size.get(id).copied();
    if last != Some((cols, rows)) {
        state.pty_last_size.insert(id.clone(), (cols, rows));
        state.pending_resizes.push((id.clone(), cols, rows));
    }

    let scr_ref = state.pty_views.get_mut(id).unwrap();
    let cursor = scr_ref.cursor_position();
    let scrolled = scr_ref.is_scrolled_back();
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
            b.start_abs <= abs_r
                && match b.end_abs {
                    Some(end) => abs_r < end,
                    None => true, // running: extends to live cursor
                }
        });
        if let Some(b) = block {
            let (sym, color) = match b.status {
                BlockStatus::Running => ("▶", Color::Yellow),
                BlockStatus::Finished(Some(0)) => ("✓", Color::Green),
                BlockStatus::Finished(Some(_)) => ("✗", Color::Red),
                BlockStatus::Finished(None) => ("·", Color::Gray),
            };
            let glyph = if abs_r == b.start_abs { sym } else { "│" };
            if let Some(cell) = buf.cell_mut(Position {
                x: gutter_area.x,
                y: gutter_area.y + r,
            }) {
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
        ViewSpec::Pty { pty_id } => format!("pty:{pty_id}"),
        ViewSpec::Preview { path } => format!("file:{path}"),
        ViewSpec::Diff { staged, .. } => {
            if *staged {
                "diff(staged)".into()
            } else {
                "diff".into()
            }
        }
        ViewSpec::Image { path } => format!("img:{path}"),
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
                None => ("·", Color::Gray),
            };
            let exit_str = match exit {
                Some(c) => format!("{c}"),
                None => String::new(),
            };
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
    let cwd_base = state
        .pty_cwds
        .get(pty_id)
        .and_then(|p| p.file_name().and_then(|s| s.to_str()))
        .map(|s| s.to_string());
    let fg = state
        .pty_blocks
        .get(pty_id)
        .and_then(|b| b.running.as_deref())
        .map(first_meaningful_token)
        .filter(|s| !s.is_empty());

    match (cwd_base, fg) {
        (Some(c), Some(f)) => format!("{c} · {f}"),
        (Some(c), None) => c,
        (None, Some(f)) => f,
        (None, None) => {
            if let Some(cmd) = state.pty_cmds.get(pty_id) {
                let base = first_meaningful_token(cmd);
                if !base.is_empty() {
                    return base;
                }
            }
            format!("pty:{ordinal}")
        }
    }
}

fn short_status(s: pgit::GitFileStatus) -> &'static str {
    use pgit::GitFileStatus::*;
    match s {
        Unmodified => ".",
        Modified => "M",
        Added => "A",
        Deleted => "D",
        Renamed => "R",
        Copied => "C",
        Untracked => "?",
        Ignored => "!",
        Conflicted => "U",
    }
}
