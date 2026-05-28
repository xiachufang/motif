//! Interactive session picker — motif-tui's default entry point.
//!
//! On launch, the picker fetches `session.list` from the connected
//! motifd and shows it in a ratatui list. The user can:
//!
//! - `↑` / `↓` (or `k` / `j`) — navigate
//! - `Enter`                  — attach to the selected session,
//!                              handing off to [`ui::run_with`].
//! - `n`                      — open the inline "new session" form
//!                              (name + workdir). Enter to create,
//!                              Esc to cancel.
//! - `d`                      — destroy the selected session
//!                              (y/N confirm).
//! - `r`                      — refresh `session.list`.
//! - `q` / `Esc`              — quit.
//!
//! After attaching, the inner `run_with` loop owns the terminal until
//! the user detaches with the tmux-style `Ctrl-g d`. The picker does
//! not loop back: detach exits the process (matching tmux's
//! semantics). To pick a different session, re-run `motif-tui`.

use std::io::Stdout;
use std::path::PathBuf;
use std::time::Duration;

use anyhow::Result;
use crossterm::event::{
    self, Event as CtEvent, KeyCode, KeyEventKind, KeyModifiers,
};
use crossterm::execute;
use crossterm::terminal::{
    disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen,
};
use motif_proto::session as ses;
use ratatui::backend::CrosstermBackend;
use ratatui::layout::{Alignment, Constraint, Direction, Layout, Position, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Clear, List, ListItem, ListState, Paragraph, Wrap};
use ratatui::{Frame, Terminal};

use crate::transport::ConnectedV2;
use motif_client::coordinator::Coordinator as Client;

type Backend = CrosstermBackend<Stdout>;

enum Outcome {
    Quit,
    Attach(String),
}

/// Run the picker, then (if the user picks one) hand `tr` to
/// [`crate::ui::run_with`]. `host_label` is shown in the title bar so
/// the user can tell which motifd they're talking to (especially when
/// using `--via ssh://` / `--via tailscale://`).
pub async fn run(tr: ConnectedV2, host_label: String) -> Result<()> {
    let outcome = run_picker(&tr.client, host_label).await?;
    match outcome {
        Outcome::Quit => Ok(()),
        Outcome::Attach(name) => crate::ui::run_with(tr, name).await,
    }
}

async fn run_picker(client: &Client, host_label: String) -> Result<Outcome> {
    let mut state = State::new(host_label);
    refresh_sessions(client, &mut state).await;

    enable_raw_mode()?;
    let mut stdout = std::io::stdout();
    execute!(stdout, EnterAlternateScreen)?;
    let backend = CrosstermBackend::new(stdout);
    let mut term = Terminal::new(backend)?;

    let outcome = picker_loop(&mut term, client, &mut state).await;

    disable_raw_mode()?;
    execute!(term.backend_mut(), LeaveAlternateScreen)?;
    term.show_cursor()?;
    outcome
}

async fn picker_loop(
    term: &mut Terminal<Backend>,
    client: &Client,
    state: &mut State,
) -> Result<Outcome> {
    loop {
        term.draw(|f| draw(f, state))?;
        if event::poll(Duration::from_millis(100))? {
            if let CtEvent::Key(k) = event::read()? {
                if k.kind != KeyEventKind::Press {
                    continue;
                }
                if let Some(outcome) = handle_key(state, client, k.code, k.modifiers).await? {
                    return Ok(outcome);
                }
            }
        }
    }
}

// ─────────────────────────── State ───────────────────────────

struct State {
    host_label: String,
    sessions: Vec<ses::SessionInfo>,
    list_state: ListState,
    mode: Mode,
    status: String,
}

impl State {
    fn new(host_label: String) -> Self {
        Self {
            host_label,
            sessions: Vec::new(),
            list_state: ListState::default(),
            mode: Mode::Browse,
            status: String::new(),
        }
    }

    fn selected(&self) -> Option<&ses::SessionInfo> {
        self.sessions.get(self.list_state.selected()?)
    }
}

enum Mode {
    Browse,
    Create {
        name: TextField,
        workdir: TextField,
        focus: CreateFocus,
    },
    /// Pre-filled with the target session's name (used for the
    /// `session.destroy` call AND the modal label). We keep the name —
    /// not just the id — because `session.destroy` is name-keyed.
    DestroyConfirm { target_name: String },
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum CreateFocus {
    Name,
    Workdir,
}

/// Minimal single-line text editor. Byte-indexed cursor; `insert`,
/// `backspace`, and `move_*` all step by `char::len_utf8` so multi-byte
/// codepoints stay aligned. Plenty for session names and paths.
#[derive(Default)]
struct TextField {
    buf: String,
    cursor: usize,
}

impl TextField {
    fn new(initial: &str) -> Self {
        Self {
            buf: initial.to_string(),
            cursor: initial.len(),
        }
    }

    fn insert(&mut self, c: char) {
        self.buf.insert(self.cursor, c);
        self.cursor += c.len_utf8();
    }

    fn backspace(&mut self) {
        if self.cursor == 0 {
            return;
        }
        let step = self.buf[..self.cursor]
            .chars()
            .next_back()
            .map(|c| c.len_utf8())
            .unwrap_or(0);
        self.buf.replace_range(self.cursor - step..self.cursor, "");
        self.cursor -= step;
    }

    fn move_left(&mut self) {
        if let Some(prev) = self.buf[..self.cursor].chars().next_back() {
            self.cursor -= prev.len_utf8();
        }
    }

    fn move_right(&mut self) {
        if let Some(next) = self.buf[self.cursor..].chars().next() {
            self.cursor += next.len_utf8();
        }
    }

    fn move_home(&mut self) {
        self.cursor = 0;
    }
    fn move_end(&mut self) {
        self.cursor = self.buf.len();
    }

    fn text(&self) -> &str {
        &self.buf
    }
}

// ─────────────────────────── Drawing ───────────────────────────

fn draw(f: &mut Frame, state: &mut State) {
    let outer = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(1),
            Constraint::Min(1),
            Constraint::Length(1),
        ])
        .split(f.area());

    let header = Line::from(vec![
        Span::raw(" motif · "),
        Span::styled(state.host_label.clone(), Style::default().fg(Color::Cyan)),
        Span::raw(format!("  ·  {} session", state.sessions.len())),
        Span::raw(if state.sessions.len() == 1 { "" } else { "s" }),
        if state.status.is_empty() {
            Span::raw("")
        } else {
            Span::raw(format!("  ·  {}", state.status))
        },
    ]);
    f.render_widget(
        Paragraph::new(header).style(Style::default().bg(Color::DarkGray)),
        outer[0],
    );

    if state.sessions.is_empty() {
        let placeholder = Paragraph::new(Line::from(vec![
            Span::styled("(no sessions)", Style::default().fg(Color::DarkGray)),
            Span::raw("  ·  press "),
            Span::styled("n", Style::default().fg(Color::LightYellow)),
            Span::raw(" to create one"),
        ]))
        .alignment(Alignment::Center)
        .wrap(Wrap { trim: false })
        .block(Block::default().borders(Borders::ALL).title("sessions"));
        f.render_widget(placeholder, outer[1]);
    } else {
        let rows: Vec<ListItem> = state
            .sessions
            .iter()
            .map(|s| {
                let clients = if s.client_count == 1 {
                    "1 client".to_string()
                } else {
                    format!("{} clients", s.client_count)
                };
                ListItem::new(Line::from(vec![
                    Span::raw(format!("{:<24}  ", s.name)),
                    Span::styled(
                        format!("{:<12}  ", clients),
                        Style::default().fg(Color::Gray),
                    ),
                    Span::styled(
                        s.workdir.display().to_string(),
                        Style::default().fg(Color::Cyan),
                    ),
                ]))
            })
            .collect();
        let list = List::new(rows)
            .block(Block::default().borders(Borders::ALL).title("sessions"))
            .highlight_style(
                Style::default()
                    .add_modifier(Modifier::REVERSED)
                    .fg(Color::LightYellow),
            );
        f.render_stateful_widget(list, outer[1], &mut state.list_state);
    }

    let help = match state.mode {
        Mode::Browse => " Enter attach · n new · d destroy · r refresh · q quit ",
        Mode::Create { .. } => " Enter create · Tab switch field · Esc cancel ",
        Mode::DestroyConfirm { .. } => " y confirm · n / Esc cancel ",
    };
    f.render_widget(
        Paragraph::new(help).style(Style::default().bg(Color::DarkGray)),
        outer[2],
    );

    // Modal overlays go last so they paint on top.
    match &state.mode {
        Mode::Browse => {}
        Mode::Create {
            name,
            workdir,
            focus,
        } => draw_create_modal(f, outer[1], name, workdir, *focus),
        Mode::DestroyConfirm { target_name } => draw_destroy_modal(f, outer[1], target_name),
    }
}

fn draw_create_modal(
    f: &mut Frame,
    area: Rect,
    name: &TextField,
    workdir: &TextField,
    focus: CreateFocus,
) {
    let modal = center_rect(area, 64, 7);
    f.render_widget(Clear, modal);
    let block = Block::default().borders(Borders::ALL).title(" new session ");
    let inner = block.inner(modal);
    f.render_widget(block, modal);

    let rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(1), // name
            Constraint::Length(1), // spacer
            Constraint::Length(1), // workdir
            Constraint::Min(0),    // filler
        ])
        .split(inner);

    let label = "name    ";
    let wlabel = "workdir ";
    let label_style = Style::default().fg(Color::DarkGray);
    let focused_label_style = Style::default()
        .fg(Color::LightYellow)
        .add_modifier(Modifier::BOLD);

    f.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled(
                label,
                if focus == CreateFocus::Name {
                    focused_label_style
                } else {
                    label_style
                },
            ),
            Span::raw(name.text()),
        ])),
        rows[0],
    );
    f.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled(
                wlabel,
                if focus == CreateFocus::Workdir {
                    focused_label_style
                } else {
                    label_style
                },
            ),
            Span::raw(workdir.text()),
        ])),
        rows[2],
    );

    let (row_idx, label_len, field) = match focus {
        CreateFocus::Name => (0usize, label.len() as u16, name),
        CreateFocus::Workdir => (2usize, wlabel.len() as u16, workdir),
    };
    let target_row = rows[row_idx];
    f.set_cursor_position(Position {
        x: target_row.x + label_len + field.cursor as u16,
        y: target_row.y,
    });
}

fn draw_destroy_modal(f: &mut Frame, area: Rect, target_name: &str) {
    let modal = center_rect(area, 50, 5);
    f.render_widget(Clear, modal);
    let block = Block::default()
        .borders(Borders::ALL)
        .title(" destroy session ");
    let inner = block.inner(modal);
    f.render_widget(block, modal);
    f.render_widget(
        Paragraph::new(Line::from(vec![
            Span::raw("Destroy "),
            Span::styled(target_name, Style::default().fg(Color::Red)),
            Span::raw(" ?  (y / N)"),
        ]))
        .alignment(Alignment::Center),
        inner,
    );
}

fn center_rect(area: Rect, width: u16, height: u16) -> Rect {
    let w = width.min(area.width.saturating_sub(2));
    let h = height.min(area.height.saturating_sub(2));
    let x = area.x + (area.width.saturating_sub(w)) / 2;
    let y = area.y + (area.height.saturating_sub(h)) / 2;
    Rect {
        x,
        y,
        width: w,
        height: h,
    }
}

// ─────────────────────────── Key handling ───────────────────────────

async fn handle_key(
    state: &mut State,
    client: &Client,
    code: KeyCode,
    mods: KeyModifiers,
) -> Result<Option<Outcome>> {
    // Move out of the mode so we can consume its fields (TextFields)
    // without partial-borrow gymnastics. Handlers re-set the mode
    // before returning.
    let mode = std::mem::replace(&mut state.mode, Mode::Browse);
    match mode {
        Mode::Browse => handle_browse_key(state, client, code, mods).await,
        Mode::Create {
            name,
            workdir,
            focus,
        } => handle_create_key(state, client, name, workdir, focus, code, mods).await,
        Mode::DestroyConfirm { target_name } => {
            handle_destroy_key(state, client, target_name, code).await
        }
    }
}

async fn handle_browse_key(
    state: &mut State,
    client: &Client,
    code: KeyCode,
    mods: KeyModifiers,
) -> Result<Option<Outcome>> {
    state.mode = Mode::Browse;
    match code {
        KeyCode::Char('q') | KeyCode::Esc => Ok(Some(Outcome::Quit)),
        KeyCode::Char('c') if mods.contains(KeyModifiers::CONTROL) => Ok(Some(Outcome::Quit)),
        KeyCode::Up | KeyCode::Char('k') => {
            move_selection(state, -1);
            Ok(None)
        }
        KeyCode::Down | KeyCode::Char('j') => {
            move_selection(state, 1);
            Ok(None)
        }
        KeyCode::Char('r') => {
            refresh_sessions(client, state).await;
            Ok(None)
        }
        KeyCode::Char('n') => {
            let cwd = std::env::current_dir().ok().unwrap_or_default();
            state.mode = Mode::Create {
                name: TextField::default(),
                workdir: TextField::new(&cwd.to_string_lossy()),
                focus: CreateFocus::Name,
            };
            state.status.clear();
            Ok(None)
        }
        KeyCode::Char('d') => {
            if let Some(s) = state.selected() {
                state.mode = Mode::DestroyConfirm {
                    target_name: s.name.clone(),
                };
            }
            Ok(None)
        }
        KeyCode::Enter => {
            if let Some(s) = state.selected() {
                Ok(Some(Outcome::Attach(s.name.clone())))
            } else {
                Ok(None)
            }
        }
        _ => Ok(None),
    }
}

async fn handle_create_key(
    state: &mut State,
    client: &Client,
    mut name: TextField,
    mut workdir: TextField,
    mut focus: CreateFocus,
    code: KeyCode,
    mods: KeyModifiers,
) -> Result<Option<Outcome>> {
    match code {
        KeyCode::Esc => {
            state.status = "create cancelled".into();
            return Ok(None);
        }
        KeyCode::Tab | KeyCode::BackTab => {
            focus = match focus {
                CreateFocus::Name => CreateFocus::Workdir,
                CreateFocus::Workdir => CreateFocus::Name,
            };
        }
        KeyCode::Enter => {
            let n = name.text().trim().to_string();
            let w = workdir.text().trim().to_string();
            if n.is_empty() {
                state.status = "name is required".into();
                state.mode = Mode::Create {
                    name,
                    workdir,
                    focus: CreateFocus::Name,
                };
                return Ok(None);
            }
            let wd = if w.is_empty() {
                std::env::current_dir().ok().unwrap_or_default()
            } else {
                PathBuf::from(w)
            };
            match client
                .call::<_, ses::CreateResult>(
                    "session.create",
                    ses::CreateParams {
                        name: n.clone(),
                        workdir: wd,
                    },
                )
                .await
            {
                Ok(r) => {
                    state.status = format!("created {}", r.session.name);
                    refresh_sessions(client, state).await;
                    if let Some(idx) = state.sessions.iter().position(|s| s.id == r.session.id) {
                        state.list_state.select(Some(idx));
                    }
                    // Drop fields; leave mode = Browse (set at top of
                    // handle_key when we replaced it).
                    return Ok(None);
                }
                Err(e) => {
                    state.status = format!("session.create: {e}");
                    // Keep the form open so the user can fix and retry.
                    state.mode = Mode::Create {
                        name,
                        workdir,
                        focus,
                    };
                    return Ok(None);
                }
            }
        }
        KeyCode::Char(c)
            if !mods.contains(KeyModifiers::CONTROL) && !mods.contains(KeyModifiers::ALT) =>
        {
            field_mut(&mut name, &mut workdir, focus).insert(c);
        }
        KeyCode::Backspace => field_mut(&mut name, &mut workdir, focus).backspace(),
        KeyCode::Left => field_mut(&mut name, &mut workdir, focus).move_left(),
        KeyCode::Right => field_mut(&mut name, &mut workdir, focus).move_right(),
        KeyCode::Home => field_mut(&mut name, &mut workdir, focus).move_home(),
        KeyCode::End => field_mut(&mut name, &mut workdir, focus).move_end(),
        _ => {}
    }
    state.mode = Mode::Create {
        name,
        workdir,
        focus,
    };
    Ok(None)
}

fn field_mut<'a>(
    name: &'a mut TextField,
    workdir: &'a mut TextField,
    focus: CreateFocus,
) -> &'a mut TextField {
    match focus {
        CreateFocus::Name => name,
        CreateFocus::Workdir => workdir,
    }
}

async fn handle_destroy_key(
    state: &mut State,
    client: &Client,
    target_name: String,
    code: KeyCode,
) -> Result<Option<Outcome>> {
    match code {
        KeyCode::Char('y') | KeyCode::Char('Y') => {
            match client
                .call::<_, ses::DestroyResult>(
                    "session.destroy",
                    ses::DestroyParams {
                        name: target_name.clone(),
                    },
                )
                .await
            {
                Ok(_) => state.status = format!("destroyed {target_name}"),
                Err(e) => state.status = format!("session.destroy: {e}"),
            }
            refresh_sessions(client, state).await;
            Ok(None)
        }
        KeyCode::Char('n') | KeyCode::Char('N') | KeyCode::Esc => {
            state.status = "destroy cancelled".into();
            Ok(None)
        }
        _ => {
            // Unknown key in a confirm modal: keep it open so the user
            // doesn't accidentally tab back into browse mid-confirm.
            state.mode = Mode::DestroyConfirm { target_name };
            Ok(None)
        }
    }
}

fn move_selection(state: &mut State, delta: i32) {
    if state.sessions.is_empty() {
        state.list_state.select(None);
        return;
    }
    let len = state.sessions.len() as i32;
    let cur = state.list_state.selected().unwrap_or(0) as i32;
    let next = (cur + delta).rem_euclid(len);
    state.list_state.select(Some(next as usize));
}

async fn refresh_sessions(client: &Client, state: &mut State) {
    match client
        .call::<_, ses::ListResult>("session.list", ses::ListParams::default())
        .await
    {
        Ok(r) => {
            state.sessions = r.sessions;
            if state.sessions.is_empty() {
                state.list_state.select(None);
            } else {
                let cur = state.list_state.selected().unwrap_or(0);
                state
                    .list_state
                    .select(Some(cur.min(state.sessions.len() - 1)));
            }
        }
        Err(e) => {
            state.status = format!("session.list: {e}");
        }
    }
}
