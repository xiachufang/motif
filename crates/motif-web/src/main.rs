use std::net::SocketAddr;
use std::path::{Path, PathBuf};

use clap::Parser;

#[derive(Parser, Debug)]
#[command(name = "motif-web", version, about = "motif remote dev agent — browser bridge")]
struct Args {
    /// Browser-facing listen address.
    #[arg(long, default_value = "127.0.0.1:8080")]
    listen: SocketAddr,

    /// Upstream motifd URL (ws:// or wss://).
    #[arg(long)]
    motifd_url: String,

    /// Token file the bridge presents to motifd. Omit for an empty token.
    #[arg(long)]
    motifd_token_file: Option<PathBuf>,

    /// Token file browsers must present (`auth.login` first message). May be
    /// the same as motifd-token-file for single-user setups. Omit for an
    /// empty token (any browser-supplied token is accepted).
    #[arg(long)]
    browser_token_file: Option<PathBuf>,

    /// TLS cert (PEM) for the browser-facing listener.
    #[arg(long)] bind_cert: Option<PathBuf>,
    /// TLS private key (PEM) for the browser-facing listener.
    #[arg(long)] bind_key:  Option<PathBuf>,

    #[arg(long, env = "MOTIF_WEB_LOG", default_value = "info")]
    log: String,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args = Args::parse();
    motif_web::init_tracing(&args.log)?;

    let motifd_token  = read_token_file(args.motifd_token_file.as_deref())?;
    let browser_token = read_token_file(args.browser_token_file.as_deref())?;
    let cfg = motif_web::WebConfig {
        listen:        args.listen,
        motifd_url:    args.motifd_url,
        motifd_token,
        browser_token,
        bind_cert:     args.bind_cert,
        bind_key:      args.bind_key,
    };
    motif_web::run(cfg).await
}

fn read_token_file(path: Option<&Path>) -> anyhow::Result<String> {
    let Some(path) = path else { return Ok(String::new()); };
    let raw = std::fs::read_to_string(path)
        .map_err(|e| anyhow::anyhow!("failed to read token file {}: {e}", path.display()))?;
    Ok(raw.trim().to_string())
}
