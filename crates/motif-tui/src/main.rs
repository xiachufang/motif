use clap::{Parser, Subcommand};
use motif_client::transport;

#[derive(Parser, Debug)]
#[command(
    name = "motif-tui",
    version,
    about = "motif remote dev agent — TUI client",
    long_about = "Launches the interactive session picker by default. \
                  Use the `list-servers` subcommand to discover motifd \
                  nodes on the current tailnet (requires --features \
                  tailscale-bundled)."
)]
struct Cli {
    /// Log filter (env: MOTIF_TUI_LOG).
    #[arg(long, env = "MOTIF_TUI_LOG", default_value = "warn")]
    log: String,

    /// motifd target (bare host, host:port, or ws://… URL).
    /// Omit to auto-probe ws://127.0.0.1:7777.
    #[arg(long)]
    host: Option<String>,

    /// Path to a token file (falls back to $MOTIF_TOKEN_FILE).
    #[arg(long, env = "MOTIF_TOKEN_FILE")]
    token_file: Option<std::path::PathBuf>,

    /// Transport override: `ssh://[user@]host[:port]` opens a local SSH
    /// tunnel; `tailscale://hostname` dials via tsnet. Default: direct.
    #[arg(long)]
    via: Option<String>,

    /// Remote motifd port reachable on the SSH host (default 7777).
    #[arg(long)]
    ssh_remote_port: Option<u16>,

    #[command(subcommand)]
    cmd: Option<Cmd>,
}

#[derive(Subcommand, Debug)]
enum Cmd {
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
        Some(Cmd::ListServers { prefix }) => motif_tui::cmd_list_servers(&prefix).await,
        None => {
            let url = transport::normalize_target(cli.host.as_deref());
            let token = motif_tui::read_token(cli.token_file.as_deref())?;
            motif_tui::cmd_picker(&url, &token, cli.via.as_deref(), cli.ssh_remote_port).await
        }
    }
}
