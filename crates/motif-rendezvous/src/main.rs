//! Motif rendezvous relay binary.
//!
//! Pairs a `motifd` `accept` connection with a client `connect` connection by
//! token, then pipes bytes. With motifd's default end-to-end TLS it only ever
//! sees ciphertext (and tokens are one-way derived from the pairing secret), so
//! the plaintext port can be exposed directly on a public address — both motifd
//! and clients dial out to it. (Only `motifd --rzv-no-tls` puts plaintext on the
//! relay, in which case keep it on a trusted segment.)
//!
//!   motif-rendezvous --listen 0.0.0.0:8765

use std::time::Duration;

use clap::{Parser, Subcommand};
use motif_rendezvous::{health_check, Hub, HubConfig};

#[derive(Parser)]
#[command(about = "Motif rendezvous relay — token-paired byte pipe for motifd <-> client")]
struct Args {
    #[command(subcommand)]
    command: Option<Command>,

    /// Address to listen on. With motifd's default end-to-end TLS the relay
    /// only forwards ciphertext, so `0.0.0.0:<port>` on a public host is fine.
    #[arg(long, default_value = "127.0.0.1:8765")]
    listen: String,

    /// Backstop: drop a parked (unpaired) connection after this many seconds.
    /// Keepalive keeps healthy parks alive, so this only reaps abandoned ones.
    #[arg(long, default_value_t = 3600)]
    park_ttl_secs: u64,

    /// PING a parked waiter every this many seconds (and once the instant it
    /// parks) so NATs / proxies don't reap the idle connection before it pairs.
    /// `0` disables keepalive.
    #[arg(long, default_value_t = 15)]
    keepalive_secs: u64,
}

#[derive(Subcommand)]
enum Command {
    /// Probe a running relay and exit 0 if it is healthy, non-zero otherwise.
    /// Dials the relay, sends a health HELLO, and checks the reply — suitable
    /// for a container HEALTHCHECK or an external monitor.
    Healthcheck {
        /// Relay address to probe (default matches the serve default).
        #[arg(long, default_value = "127.0.0.1:8765")]
        addr: String,
        /// Fail the probe if it doesn't complete within this many seconds.
        #[arg(long, default_value_t = 5)]
        timeout_secs: u64,
    },
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args = Args::parse();

    if let Some(Command::Healthcheck { addr, timeout_secs }) = args.command {
        // Quiet by default — the exit code is the signal a HEALTHCHECK reads.
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

    tracing_subscriber::fmt()
        .with_target(false)
        .init();

    let listener = tokio::net::TcpListener::bind(&args.listen).await?;
    tracing::info!(addr = %args.listen, "motif-rendezvous listening");

    let hub = Hub::new(HubConfig {
        park_ttl: Duration::from_secs(args.park_ttl_secs),
        keepalive: Duration::from_secs(args.keepalive_secs),
    });
    hub.run(listener).await;
    Ok(())
}
