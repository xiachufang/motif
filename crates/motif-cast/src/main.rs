//! `motif-cast` — share a local terminal session with motifd.
//!
//! On launch: connect, create a brand-new motifd session, spawn a PTY
//! running the requested command (or `$SHELL`), and proxy stdin / stdout /
//! SIGWINCH from this terminal. On exit (PTY done, stdin EOF, or normal
//! error return): destroy the session.
//!
//! Hard SIGKILL of `motif-cast` (or terminal close before drop runs) leaks
//! the session — there's no graceful cleanup path. The fix lives on the
//! server side (ephemeral session TTL) and is out of scope for v1.

use std::path::PathBuf;
use std::sync::Arc;

use anyhow::{anyhow, Context};
use clap::Parser;
use motif_client::coordinator::Coordinator as Client;
use motif_client::{palette, raw_pty, transport};
use motif_proto::common::PtyId;
use motif_proto::pty as ppty;
use motif_proto::session as ses;
use serde_json::Value;
use tokio::sync::Mutex;

#[derive(Parser, Debug)]
#[command(
    name = "motif-cast",
    version,
    about = "Share a local terminal with motifd (one-shot session host)",
    after_help = "On exit (inner process done / EOF) the session is destroyed automatically. \
                  A hard SIGKILL of motif-cast leaks the session — destroy it manually \
                  via `motif-tui destroy`."
)]
struct Cli {
    /// motifd target: a bare `host`, `host:port`, or a full `ws://…` /
    /// `http://…` URL. A bare host defaults to port 7777. Omit entirely to
    /// auto-probe a local server on `127.0.0.1:7777`.
    #[arg(long)]
    host: Option<String>,

    /// Trailing argv passed to motifd as a single shell command. If omitted,
    /// motifd spawns the user's `$SHELL`.
    #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
    cmd: Vec<String>,

    /// Session name. Default: `cast-<pid>-<6 hex>`.
    #[arg(long)]
    name: Option<String>,

    /// Working directory for the new session. Default: current directory.
    #[arg(long)]
    workdir: Option<PathBuf>,

    /// Path to a token file. Falls back to `$MOTIF_TOKEN_FILE`.
    #[arg(long, env = "MOTIF_TOKEN_FILE")]
    token_file: Option<PathBuf>,

    /// Optional SSH tunnel: `ssh://[user@]host[:port]`.
    #[arg(long)]
    via: Option<String>,

    /// Remote motifd port reachable on the SSH host (default 7777).
    #[arg(long)]
    ssh_remote_port: Option<u16>,

    /// Log filter (env: `MOTIF_CAST_LOG`).
    #[arg(long, env = "MOTIF_CAST_LOG", default_value = "warn")]
    log: String,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();
    let env = tracing_subscriber::EnvFilter::try_new(&cli.log)
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("warn"));
    let timer = tracing_subscriber::fmt::time::LocalTime::new(time::macros::format_description!(
        "[year]-[month]-[day] [hour]:[minute]:[second].[subsecond digits:3]"
    ));
    tracing_subscriber::fmt()
        .with_env_filter(env)
        .with_timer(timer)
        .with_writer(std::io::stderr)
        .try_init()
        .ok();

    let token = read_token(cli.token_file.as_deref())?;
    let workdir = match cli.workdir {
        Some(p) => p,
        None => std::env::current_dir().context("getting current directory")?,
    };
    let name = cli.name.unwrap_or_else(default_session_name);
    // Empty argv → no cmd → motifd uses $SHELL. Otherwise join with single
    // spaces; motifd interprets the whole string via /bin/sh -lc so the
    // user can quote arguments themselves if they need to.
    let cmd = if cli.cmd.is_empty() {
        None
    } else {
        Some(cli.cmd.join(" "))
    };

    run(Run {
        url: transport::normalize_target(cli.host.as_deref()),
        token,
        name,
        workdir,
        cmd,
        via: cli.via,
        ssh_remote_port: cli.ssh_remote_port,
    })
    .await
}

struct Run {
    url: String,
    token: String,
    name: String,
    workdir: PathBuf,
    cmd: Option<String>,
    via: Option<String>,
    ssh_remote_port: Option<u16>,
}

async fn run(r: Run) -> anyhow::Result<()> {
    let tr = transport::connect_v2(&r.url, &r.token, r.via.as_deref(), r.ssh_remote_port).await?;
    let transport::ConnectedV2 { client, _keepalive } = tr;

    // 0. /ping probe — confirm a motif-server is actually answering before
    //    we mint a session. Catches "wrong port / some other HTTP service"
    //    with a clear message instead of a confusing RPC decode failure
    //    later. Unauthenticated, so it works even before the token is
    //    checked.
    let info = client
        .ping()
        .await
        .with_context(|| format!("no motif-server responding at {}", r.url))?;
    if !info.is_motif_server() {
        return Err(anyhow!(
            "{} is not a motif-server (service={:?})",
            r.url,
            info.service
        ));
    }
    eprintln!("motif-cast: found motif-server {} at {}", info.version, r.url);

    // 1. session.create — owns the name from here on. Failure to create →
    //    no guard needed, just bail.
    let _: ses::CreateResult = client
        .call(
            "session.create",
            ses::CreateParams {
                name: r.name.clone(),
                workdir: r.workdir.clone(),
            },
        )
        .await
        .with_context(|| format!("session.create '{}'", r.name))?;

    // 2. session.attach — required to receive pty.output events. Derive a
    //    light/dark theme from the probed background luminance so GUI clients
    //    viewing this cast render to match the host terminal's appearance.
    let (term_fg, term_bg) = palette::probe();
    let theme = theme_from_osc_bg(term_bg.as_deref());
    let _: ses::AttachResult = client
        .call(
            "session.attach",
            ses::AttachParams {
                name: r.name.clone(),
                last_seq: None,
                term_fg,
                term_bg,
                theme,
            },
        )
        .await
        .context("session.attach")?;

    // 3. pty.create — size from the local terminal.
    let (cols, rows) = raw_pty::current_size();
    let pty: ppty::PtyCreateResult = client
        .call(
            "pty.create",
            ppty::PtyCreateParams {
                cmd: r.cmd,
                cwd: None,
                env: vec![],
                cols,
                rows,
            },
        )
        .await
        .context("pty.create")?;
    let pty_id: PtyId = pty.info.id.clone();

    // 4. Open the `/pty/<id>` WS for raw bytes, and pull the structured
    //    notification stream out as a free-standing receiver. The PTY's
    //    bytes flow over `pty.outputs` / `pty.stdin`; notifications still
    //    carry `view.opened` (so we can reclaim primary) and `pty.exited`.
    let pty_ws = client
        .open_pty(pty_id.as_str(), 0)
        .await
        .with_context(|| format!("open /pty/{pty_id} WS"))?;
    let events = client
        .take_notifications()
        .await
        .ok_or_else(|| anyhow!("client lost its notification stream before attach"))?;
    let client = Arc::new(Mutex::new(client));

    // SessionGuard fires session.destroy on drop, regardless of why we're
    // leaving (pump returned Ok, returned Err, or panicked).
    let _guard = SessionGuard::new(r.name.clone(), Arc::clone(&client));

    eprintln!(
        "motif-cast: session={} pty={} ({}x{}); on exit the session will be destroyed",
        r.name, pty_id, cols, rows,
    );

    raw_pty::pump(client, events, pty_ws, pty_id).await
}

/// Tear-down on drop: best-effort `session.destroy`. We move the work onto
/// a fresh OS thread and `Handle::block_on` so the call actually completes
/// before main returns and the runtime drops. If the WS is already gone,
/// the call fails and we just log it.
struct SessionGuard {
    name: String,
    client: Option<Arc<Mutex<Client>>>,
}
impl SessionGuard {
    fn new(name: String, client: Arc<Mutex<Client>>) -> Self {
        Self {
            name,
            client: Some(client),
        }
    }
}
impl Drop for SessionGuard {
    fn drop(&mut self) {
        let Some(client) = self.client.take() else {
            return;
        };
        let name = std::mem::take(&mut self.name);
        let Ok(handle) = tokio::runtime::Handle::try_current() else {
            tracing::warn!(
                "session.destroy: no tokio runtime, leaking session '{}'",
                name
            );
            return;
        };
        // block_on inside a fresh OS thread so we don't deadlock the
        // worker thread we're being dropped on. .join() ensures destroy
        // completes before main returns and the runtime tears down.
        let _ = std::thread::spawn(move || {
            handle.block_on(async move {
                let c = client.lock().await;
                if let Err(e) = c
                    .call::<_, Value>("session.destroy", ses::DestroyParams { name: name.clone() })
                    .await
                {
                    tracing::warn!(error = %e, session = %name, "session.destroy failed");
                }
            });
        })
        .join();
    }
}

fn read_token(path: Option<&std::path::Path>) -> anyhow::Result<String> {
    let Some(path) = path else {
        return Ok(String::new());
    };
    let raw = std::fs::read_to_string(path)
        .with_context(|| format!("reading token file {}", path.display()))?;
    Ok(raw.trim().to_string())
}

/// Classify a probed terminal background as `"light"` / `"dark"` from its
/// perceived luminance. `bg` is the rgb portion of an OSC 11 reply
/// (`"RRRR/GGGG/BBBB"` 16-bit, or `"RR/GG/BB"` 8-bit) — we read the high byte
/// of each channel, so both widths work. `None` (terminal didn't answer) →
/// `None`, leaving the session theme untouched.
fn theme_from_osc_bg(bg: Option<&str>) -> Option<String> {
    let mut chans = bg?.split('/');
    let hi_byte = |s: Option<&str>| -> Option<u32> {
        u32::from_str_radix(s?.get(0..2)?, 16).ok()
    };
    let r = hi_byte(chans.next())?;
    let g = hi_byte(chans.next())?;
    let b = hi_byte(chans.next())?;
    // Rec. 601 perceived luminance, 0..255.
    let lum = (299 * r + 587 * g + 114 * b) / 1000;
    Some(if lum >= 128 { "light" } else { "dark" }.to_string())
}

fn default_session_name() -> String {
    let pid = std::process::id();
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(0);
    format!("cast-{}-{:06x}", pid, nanos & 0x00FF_FFFF)
}
