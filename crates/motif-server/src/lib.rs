//! Motif core server library.

pub mod auth;
pub mod blob;
pub mod config;
pub mod fs;
pub mod fswatch;
pub mod git;
pub mod pty;
pub mod rpc;
pub mod session;
pub mod ws;

use std::sync::Arc;

use anyhow::Context;
use tracing_subscriber::EnvFilter;

pub use config::ServerConfig;

pub fn init_tracing(filter: &str) -> anyhow::Result<()> {
    let env = EnvFilter::try_new(filter).unwrap_or_else(|_| EnvFilter::new("info"));
    tracing_subscriber::fmt().with_env_filter(env).try_init().ok();
    Ok(())
}

pub async fn serve(cfg: ServerConfig) -> anyhow::Result<()> {
    cfg.validate()?;

    if cfg.cert.is_some() {
        anyhow::bail!("TLS support not yet implemented (M1 supports loopback plaintext only); see prd.md §7");
    }

    let token   = cfg.token.clone();
    let manager = session::manager::SessionManager::new();
    let state   = ws::AppState {
        manager: manager.clone(),
        auth:    Arc::new(auth::TokenStore::new(token)),
    };
    let app = ws::router(state);

    let listener = tokio::net::TcpListener::bind(cfg.listen)
        .await
        .with_context(|| format!("failed to bind {}", cfg.listen))?;
    let bound = listener.local_addr()?;
    tracing::info!(%bound, "motifd listening");

    axum::serve(listener, app).await?;
    Ok(())
}
