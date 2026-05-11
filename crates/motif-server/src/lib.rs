//! Motif core server library.

pub mod auth;
pub mod blob;
pub mod config;
pub mod fs;
pub mod fswatch;
pub mod git;
pub mod pty;
pub mod rpc;
pub mod rpc_log;
pub mod session;
pub mod shell;
pub mod wake_detector;
pub mod wire;
pub mod ws;

use std::path::Path;
use std::sync::Arc;

use anyhow::Context;
use tracing_subscriber::{fmt, prelude::*, EnvFilter, Registry};

pub use config::{ServerConfig, TailscaleListenConfig};

/// Install the global tracing subscriber.
///
/// The stderr layer applies the user-supplied filter, but always turns
/// the `motif::rpc` target off so the RPC dump (which is large and
/// frame-by-frame) doesn't drown the operator's regular logs. When
/// `rpc_log` is set, a second file layer captures only that target —
/// giving us a clean per-frame audit trail for debugging the wire
/// protocol.
pub fn init_tracing(filter: &str, rpc_log: Option<&Path>) -> anyhow::Result<()> {
    let stderr_filter = EnvFilter::try_new(format!("{filter},{}=off", rpc_log::TARGET))
        .unwrap_or_else(|_| EnvFilter::new(format!("info,{}=off", rpc_log::TARGET)));
    let stderr_layer = fmt::layer()
        .with_writer(std::io::stderr)
        .with_filter(stderr_filter);

    let file_layer = match rpc_log {
        Some(path) => {
            let file = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(path)
                .with_context(|| format!("failed to open --rpc-log {}", path.display()))?;
            // Synchronous Mutex<File> is fine — frames are small and the
            // log is opt-in for debug runs only. with_ansi(false) keeps
            // the file clean of color escape codes.
            let writer = std::sync::Mutex::new(file);
            let filter = EnvFilter::new(format!("{}=trace", rpc_log::TARGET));
            Some(
                fmt::layer()
                    .with_writer(writer)
                    .with_ansi(false)
                    .with_target(false)
                    .with_filter(filter),
            )
        }
        None => None,
    };

    Registry::default()
        .with(stderr_layer)
        .with(file_layer)
        .try_init()
        .ok();
    Ok(())
}

pub async fn serve(cfg: ServerConfig) -> anyhow::Result<()> {
    cfg.validate()?;

    if cfg.cert.is_some() {
        anyhow::bail!("TLS support not yet implemented (M1 supports loopback plaintext only); see prd.md §7");
    }

    let manager = session::manager::SessionManager::new();
    let auth = match cfg.token.clone() {
        Some(t) => auth::TokenStore::new(t),
        None => {
            tracing::warn!(
                "motifd starting WITHOUT --token-file: auth is disabled — every WS upgrade is accepted. \
                 Pass --token-file to require a Bearer token."
            );
            auth::TokenStore::disabled()
        }
    };
    let state   = ws::AppState {
        manager: manager.clone(),
        auth:    Arc::new(auth),
    };
    let app = ws::router(state);

    if let Some(ts) = &cfg.tailscale {
        tracing::info!(
            hostname  = %ts.hostname,
            state_dir = %ts.state_dir.display(),
            port      = ts.port,
            "embedded tailscale node bringing up",
        );
        if ts.authkey.is_none() && !ts.state_dir.join("tailscaled.state").exists() {
            // First-time bring-up without authkey: libtailscale will print a
            // login URL on stderr. Surface a hint so the user knows to
            // expect it. Skip when the state dir already has a session — the
            // node will reuse its persisted identity, no login needed.
            tracing::warn!(
                "tsnet has no authkey and {} appears empty; libtailscale will \
                 print a Tailscale login URL on stderr — open it once in a \
                 browser to authorize this node. After first auth the identity \
                 is cached in the state dir.",
                ts.state_dir.display(),
            );
        }
    }

    // Diagnostic: surface Mac sleep/wake events as WARN lines so the
    // tsnet snapshot logs that follow can be correlated with a known
    // suspend cycle. Cheap; runs regardless of --tailscale.
    let _wake_task = wake_detector::spawn();

    let listener = motif_net::Listener::bind(&cfg.to_listen_config())
        .await
        .with_context(|| "failed to bind listener")?;
    for addr in listener.bound_addrs() {
        tracing::info!(%addr, "motifd listening");
    }

    axum::serve(listener, app).await?;
    Ok(())
}
