use std::path::PathBuf;

use clap::{Parser, Subcommand};

#[derive(Parser, Debug)]
#[command(
    name = "motif-tui",
    version,
    about = "motif remote dev agent — TUI client"
)]
struct Cli {
    /// Log filter (env: MOTIF_TUI_LOG).
    #[arg(long, env = "MOTIF_TUI_LOG", default_value = "warn")]
    log: String,

    #[command(subcommand)]
    cmd: Cmd,
}

/// Optional transport override applied to every subcommand. `direct` is the
/// default; `ssh://[user@]host[:port]` opens a local SSH tunnel for the
/// duration of the command.
#[derive(clap::Args, Debug, Clone, Default)]
struct ViaOpts {
    #[arg(long)]
    via: Option<String>,
    /// Remote motifd port reachable on the SSH host (default 7777).
    #[arg(long)]
    ssh_remote_port: Option<u16>,
}

#[derive(Subcommand, Debug)]
enum Cmd {
    /// Attach to a session in the full ratatui UI.
    Attach {
        url: String,
        #[arg(long)]
        session: String,
        #[arg(long, env = "MOTIF_TOKEN_FILE")]
        token_file: Option<PathBuf>,
        #[arg(long)]
        log: bool,
        #[command(flatten)]
        via: ViaOpts,
    },
    List {
        url: String,
        #[arg(long, env = "MOTIF_TOKEN_FILE")]
        token_file: Option<PathBuf>,
        #[command(flatten)]
        via: ViaOpts,
    },
    New {
        url: String,
        #[arg(long)]
        name: String,
        #[arg(long)]
        workdir: PathBuf,
        #[arg(long, env = "MOTIF_TOKEN_FILE")]
        token_file: Option<PathBuf>,
        #[command(flatten)]
        via: ViaOpts,
    },
    Destroy {
        url: String,
        #[arg(long)]
        name: String,
        #[arg(long, env = "MOTIF_TOKEN_FILE")]
        token_file: Option<PathBuf>,
        #[command(flatten)]
        via: ViaOpts,
    },
    PtyRun {
        url: String,
        #[arg(long)]
        session: String,
        #[arg(long)]
        cmd: String,
        #[arg(long, env = "MOTIF_TOKEN_FILE")]
        token_file: Option<PathBuf>,
        #[command(flatten)]
        via: ViaOpts,
    },
    /// Discover motifd nodes on the current tailnet by hostname prefix.
    /// Brings up an ephemeral tsnet client node and queries its LocalAPI
    /// for the netmap, filters by `--prefix`, and prints a table.
    /// Requires --features tailscale-bundled.
    ListServers {
        /// Hostname prefix that identifies motifd nodes. Default matches
        /// the convention motifd uses for its own --tailscale-hostname
        /// auto-default.
        #[arg(long, default_value = "motifd-")]
        prefix: String,
    },
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
        .try_init()
        .ok();

    match cli.cmd {
        Cmd::Attach {
            url,
            session,
            token_file,
            log,
            via,
        } => {
            let token = motif_tui::read_token(token_file.as_deref())?;
            if log {
                motif_tui::cmd_attach_log(
                    &url,
                    &token,
                    session,
                    via.via.as_deref(),
                    via.ssh_remote_port,
                )
                .await
            } else {
                motif_tui::cmd_attach(
                    &url,
                    &token,
                    session,
                    via.via.as_deref(),
                    via.ssh_remote_port,
                )
                .await
            }
        }
        Cmd::List {
            url,
            token_file,
            via,
        } => {
            let token = motif_tui::read_token(token_file.as_deref())?;
            motif_tui::cmd_list(&url, &token, via.via.as_deref(), via.ssh_remote_port).await
        }
        Cmd::New {
            url,
            name,
            workdir,
            token_file,
            via,
        } => {
            let token = motif_tui::read_token(token_file.as_deref())?;
            motif_tui::cmd_new(
                &url,
                &token,
                name,
                workdir,
                via.via.as_deref(),
                via.ssh_remote_port,
            )
            .await
        }
        Cmd::Destroy {
            url,
            name,
            token_file,
            via,
        } => {
            let token = motif_tui::read_token(token_file.as_deref())?;
            motif_tui::cmd_destroy(&url, &token, name, via.via.as_deref(), via.ssh_remote_port)
                .await
        }
        Cmd::PtyRun {
            url,
            session,
            cmd,
            token_file,
            via,
        } => {
            let token = motif_tui::read_token(token_file.as_deref())?;
            motif_tui::cmd_pty_run(
                &url,
                &token,
                session,
                cmd,
                via.via.as_deref(),
                via.ssh_remote_port,
            )
            .await
        }
        Cmd::ListServers { prefix } => motif_tui::cmd_list_servers(&prefix).await,
    }
}
