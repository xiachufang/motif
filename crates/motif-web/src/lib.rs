//! motif-web — browser bridge.
//!
//! Surface:
//!   * `GET  /`            — embedded SPA index (fallback `index.html`)
//!   * `GET  /assets/*`    — embedded static assets
//!   * `GET  /ws`          — JSON-RPC WebSocket from browser; first message
//!                           must be `auth.login`. After that, frames are
//!                           forwarded 1:1 to motifd over a per-browser WS.
//!   * `GET  /blob/<id>`   — pull a blob from motifd, stream to browser
//!   * `PUT  /blob/<id>`   — push a blob from browser, stream to motifd

pub mod bridge;
pub mod config;
pub mod embed;
pub mod http;

pub use config::WebConfig;

use anyhow::Context;
use tracing_subscriber::EnvFilter;

pub fn init_tracing(filter: &str) -> anyhow::Result<()> {
    let env = EnvFilter::try_new(filter).unwrap_or_else(|_| EnvFilter::new("info"));
    tracing_subscriber::fmt().with_env_filter(env).try_init().ok();
    Ok(())
}

pub async fn run(cfg: WebConfig) -> anyhow::Result<()> {
    cfg.validate()?;
    let app      = http::router(cfg.clone());
    let listener = tokio::net::TcpListener::bind(cfg.listen)
        .await
        .with_context(|| format!("binding {}", cfg.listen))?;
    tracing::info!(listen = %cfg.listen, motifd = %cfg.motifd_url, "motif-web listening");
    axum::serve(listener, app).await?;
    Ok(())
}
