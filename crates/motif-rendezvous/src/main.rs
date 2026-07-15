//! Motif rendezvous relay binary — authenticated WebSocket byte relay.

use std::net::SocketAddr;
use std::path::PathBuf;
use std::time::Duration;

use clap::{Parser, Subcommand};
use motif_rendezvous::{health_check, Authenticator, Hub, HubConfig};
use tokio::net::TcpListener;

#[derive(Parser)]
#[command(
    about = "Motif rendezvous relay — JWT-authenticated WebSocket relay with per-user limits"
)]
struct Args {
    #[command(subcommand)]
    command: Option<Command>,

    /// HTTP/WebSocket listen address. Put it behind an HTTPS reverse proxy.
    #[arg(long, default_value = "127.0.0.1:8765")]
    listen: SocketAddr,

    /// JSON JWT verifier and user bandwidth configuration.
    #[arg(long)]
    auth_config: Option<PathBuf>,

    /// Drop an unpaired WebSocket after this many seconds.
    #[arg(long, default_value_t = 3600)]
    park_ttl_secs: u64,

    /// Send native WebSocket PING frames at this interval. `0` disables.
    #[arg(long, default_value_t = 15)]
    keepalive_secs: u64,
}

#[derive(Subcommand)]
enum Command {
    /// Check that the relay TCP listener accepts connections.
    Healthcheck {
        #[arg(long, default_value = "127.0.0.1:8765")]
        addr: String,
        #[arg(long, default_value_t = 5)]
        timeout_secs: u64,
    },
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args = Args::parse();
    if let Some(Command::Healthcheck { addr, timeout_secs }) = args.command {
        return match health_check(&addr, Duration::from_secs(timeout_secs)).await {
            Ok(()) => {
                println!("ok");
                Ok(())
            }
            Err(e) => {
                eprintln!("unhealthy: {e}");
                std::process::exit(1);
            }
        };
    }

    tracing_subscriber::fmt().with_target(false).init();
    let auth_path = args
        .auth_config
        .as_deref()
        .ok_or_else(|| anyhow::anyhow!("serving requires --auth-config"))?;
    let auth = Authenticator::from_file(auth_path)?;
    let listener = TcpListener::bind(args.listen).await?;
    let hub = Hub::new(
        HubConfig {
            park_ttl: Duration::from_secs(args.park_ttl_secs),
            keepalive: Duration::from_secs(args.keepalive_secs),
        },
        auth,
    );
    hub.spawn_reaper();
    tracing::info!(addr = %args.listen, "motif-rendezvous HTTP/WebSocket listening");
    axum::serve(listener, hub.router()).await?;
    Ok(())
}
