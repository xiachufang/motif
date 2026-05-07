use std::net::SocketAddr;
use std::path::PathBuf;

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

    /// Token file the bridge presents to motifd.
    #[arg(long)]
    motifd_token_file: PathBuf,

    /// Token file browsers must present (`auth.login` first message). May be
    /// the same as motifd-token-file for single-user setups.
    #[arg(long)]
    browser_token_file: PathBuf,

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

    let motifd_token   = std::fs::read_to_string(&args.motifd_token_file)?.trim().to_string();
    let browser_token  = std::fs::read_to_string(&args.browser_token_file)?.trim().to_string();
    if motifd_token.is_empty() || browser_token.is_empty() {
        anyhow::bail!("token files must be non-empty");
    }
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
