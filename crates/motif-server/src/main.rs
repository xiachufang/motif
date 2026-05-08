use std::net::SocketAddr;
use std::path::PathBuf;

use clap::Parser;

#[derive(Parser, Debug)]
#[command(name = "motifd", version, about = "motif remote dev agent — server")]
struct Args {
    /// Listen address. Non-loopback requires --cert/--key (M1 not yet wired).
    #[arg(long, default_value = "127.0.0.1:7777")]
    listen: SocketAddr,

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

    let cfg = motif_server::ServerConfig {
        listen: args.listen,
        token,
        cert:   args.cert,
        key:    args.key,
    };
    motif_server::serve(cfg).await
}
