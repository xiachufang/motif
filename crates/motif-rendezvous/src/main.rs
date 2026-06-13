//! Motif rendezvous relay binary.
//!
//! Pairs a `motifd` `accept` connection with a client `connect` connection by
//! token, then pipes bytes. It only ever sees ciphertext. Does not terminate
//! TLS — listen on loopback / a trusted segment and front it with a
//! TLS-terminating proxy (same posture as `motif-push-relay`).
//!
//!   motif-rendezvous --listen 0.0.0.0:9999

use std::time::Duration;

use clap::Parser;
use motif_rendezvous::{Hub, HubConfig};

#[derive(Parser)]
#[command(about = "Motif rendezvous relay — token-paired byte pipe for motifd <-> client")]
struct Args {
    /// Address to listen on. Front with a TLS-terminating proxy; do not expose
    /// the plaintext port to untrusted networks.
    #[arg(long, default_value = "127.0.0.1:9999")]
    listen: String,

    /// Drop parked (unpaired) connections idle longer than this many seconds.
    #[arg(long, default_value_t = 300)]
    park_ttl_secs: u64,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_target(false)
        .init();

    let args = Args::parse();
    let listener = tokio::net::TcpListener::bind(&args.listen).await?;
    tracing::info!(addr = %args.listen, "motif-rendezvous listening");

    let hub = Hub::new(HubConfig {
        park_ttl: Duration::from_secs(args.park_ttl_secs),
    });
    hub.run(listener).await;
    Ok(())
}
