use std::net::SocketAddr;
use std::path::PathBuf;

use clap::Parser;

#[derive(Parser, Debug)]
#[command(name = "motifd", version, about = "motif remote dev agent — server")]
struct Args {
    /// TCP listen address. Omit to run tailscale-only. Non-loopback requires
    /// --cert/--key (M1 not yet wired). At least one of --listen /
    /// --tailscale-hostname must be set.
    #[arg(long)]
    listen: Option<SocketAddr>,

    /// Bring up an embedded tsnet node and listen on the tailnet under this
    /// hostname. When set, --tailscale-state-dir is required.
    #[arg(long)]
    tailscale_hostname: Option<String>,

    /// Persistent state dir for the embedded tsnet node (keys, logs).
    #[arg(long, requires = "tailscale_hostname")]
    tailscale_state_dir: Option<PathBuf>,

    /// Tailnet listen port for the embedded node.
    #[arg(long, default_value_t = 7777, requires = "tailscale_hostname")]
    tailscale_port: u16,

    /// Tailnet authkey for unattended bring-up. Optional; if absent, tsnet
    /// emits a login URL on stderr.
    #[arg(long, requires = "tailscale_hostname")]
    tailscale_authkey: Option<String>,

    /// Override the coordination server (e.g. for headscale). Tailscale
    /// SaaS by default.
    #[arg(long, requires = "tailscale_hostname")]
    tailscale_control_url: Option<String>,

    /// Bring the node up as ephemeral (no persistent device entry on the
    /// tailnet — auto-removed when the process exits).
    #[arg(long, requires = "tailscale_hostname")]
    tailscale_ephemeral: bool,

    /// Bearer-token file. The server reads this once at startup; rotate by restart.
    #[arg(long)]
    token_file: PathBuf,

    /// TLS cert (PEM). M1 does not yet implement TLS; rejected on startup if set.
    #[arg(long)]
    cert: Option<PathBuf>,

    /// TLS private key (PEM). See --cert.
    #[arg(long)]
    key: Option<PathBuf>,

    /// Log filter (env: MOTIFD_LOG). Examples: info, debug, motif_server=trace.
    #[arg(long, env = "MOTIFD_LOG", default_value = "info")]
    log: String,

    /// Append every client↔server RPC frame (request, response,
    /// notification) to this file for protocol debugging. Omit to
    /// disable. Env: MOTIFD_RPC_LOG.
    #[arg(long, env = "MOTIFD_RPC_LOG")]
    rpc_log: Option<PathBuf>,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args = Args::parse();
    motif_server::init_tracing(&args.log, args.rpc_log.as_deref())?;

    let token = std::fs::read_to_string(&args.token_file)
        .map_err(|e| anyhow::anyhow!("failed to read --token-file {}: {e}", args.token_file.display()))?
        .trim()
        .to_string();
    if token.is_empty() {
        anyhow::bail!("token file is empty: {}", args.token_file.display());
    }

    let tailscale = match args.tailscale_hostname {
        Some(hostname) => {
            let state_dir = args.tailscale_state_dir
                .ok_or_else(|| anyhow::anyhow!("--tailscale-state-dir is required with --tailscale-hostname"))?;
            Some(motif_server::TailscaleListenConfig {
                hostname,
                state_dir,
                port:        args.tailscale_port,
                authkey:     args.tailscale_authkey,
                control_url: args.tailscale_control_url,
                ephemeral:   args.tailscale_ephemeral,
            })
        }
        None => None,
    };

    let cfg = motif_server::ServerConfig {
        listen: args.listen,
        tailscale,
        token,
        cert:   args.cert,
        key:    args.key,
    };
    motif_server::serve(cfg).await
}
