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

use clap::Parser;
use motif_rendezvous::{Hub, HubConfig};

#[derive(Parser)]
#[command(about = "Motif rendezvous relay — token-paired byte pipe for motifd <-> client")]
struct Args {
    /// Address to listen on. With motifd's default end-to-end TLS the relay
    /// only forwards ciphertext, so `0.0.0.0:<port>` on a public host is fine.
    #[arg(long, default_value = "127.0.0.1:8765")]
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
