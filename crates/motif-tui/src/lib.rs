//! Motif TUI client library.

pub mod picker;
pub mod pty_view;
pub mod ui;

pub use motif_client::{palette, transport};

use std::path::Path;

use anyhow::{anyhow, Context};

pub fn read_token(path: Option<&Path>) -> anyhow::Result<String> {
    let Some(path) = path else {
        return Ok(String::new());
    };
    let raw = std::fs::read_to_string(path)
        .with_context(|| format!("reading token file {}", path.display()))?;
    Ok(raw.trim().to_string())
}

/// Helper: connect with optional SSH tunneling and probe `/ping` before
/// handing the [`transport::ConnectedV2`] to the caller. The probe is
/// unauthenticated, so it works before the token gets checked — it
/// catches the "wrong port / some other HTTP service on this host"
/// failure with a clear message instead of an opaque RPC decode error
/// on the first real call. (Same shape as `motif-cast`.)
pub async fn connect(
    url: &str,
    token: &str,
    via: Option<&str>,
    ssh_remote_port: Option<u16>,
) -> anyhow::Result<transport::ConnectedV2> {
    let tr = transport::connect_v2(url, token, via, ssh_remote_port).await?;
    let info = tr
        .client
        .ping()
        .await
        .with_context(|| format!("no motif-server responding at {url}"))?;
    if !info.is_motif_server() {
        return Err(anyhow!(
            "{url} is not a motif-server (service={:?})",
            info.service
        ));
    }
    Ok(tr)
}

/// Top-level entrypoint: connect + drop into the interactive session
/// picker. On Enter the picker hands off to [`ui::run_with`]; on `q`
/// the picker exits cleanly.
pub async fn cmd_picker(
    url: &str,
    token: &str,
    via: Option<&str>,
    ssh_remote_port: Option<u16>,
) -> anyhow::Result<()> {
    let tr = connect(url, token, via, ssh_remote_port).await?;
    picker::run(tr, url.to_string()).await
}

/// Bring up an embedded tsnet client node, query its LocalAPI, and list
/// peers whose hostname starts with `prefix` (default `motifd-`, matching
/// motifd's auto-hostname convention). The command is `tailscale-bundled`
/// gated because it actually needs a working libtailscale link — the stub
/// path would just error.
#[cfg(feature = "tailscale-bundled")]
pub async fn cmd_list_servers(prefix: &str) -> anyhow::Result<()> {
    use motif_client::motif_net::motif_tailscale::TsServer;
    use motif_client::transport::default_client_ts_options;
    use std::io::Write;

    let opts = default_client_ts_options();
    let mut server = TsServer::new(opts).context("tsnet init")?;
    server.up().await.context("tsnet up")?;
    let mut peers = server.list_peers().await.context("tsnet LocalAPI status")?;
    peers.retain(|p| p.hostname.starts_with(prefix));
    if peers.is_empty() {
        println!("No peers matching {prefix:?} found in this tailnet.");
    } else {
        peers.sort_by(|a, b| a.hostname.cmp(&b.hostname));
        println!(
            "{:<40} {:<18} {:<7} {}",
            "HOSTNAME", "TAILNET IP", "ONLINE", "OS"
        );
        for p in peers {
            println!(
                "{:<40} {:<18} {:<7} {}",
                p.hostname,
                p.ip,
                if p.online { "yes" } else { "no" },
                p.os,
            );
        }
    }

    // Bypass the tokio runtime + libtailscale Drop dance on shutdown.
    // - The log-capture spawn_blocking task is parked on a pipe `read`
    //   that only EOFs once libtailscale closes its logfd, which only
    //   happens during `tailscale_close`.
    // - `tailscale_close` is a synchronous Go-side teardown that can
    //   block for tens of seconds (especially with non-ephemeral state
    //   on a flaky network).
    // - tokio's multi-threaded runtime drop waits for spawn_blocking
    //   tasks to finish, so the two together can keep the process alive
    //   well past when we have the user's answer.
    //
    // This is a one-shot CLI flow: tsnet's persistent state was already
    // synced to disk during `up()`, the netmap snapshot we needed is
    // printed, and the OS will reclaim fds + memory on exit. Skipping
    // graceful close here matches the typical Rust+Go CGo pattern for
    // short-lived tools.
    let _ = std::io::stdout().flush();
    let _ = std::io::stderr().flush();
    std::process::exit(0);
}

#[cfg(not(feature = "tailscale-bundled"))]
pub async fn cmd_list_servers(_prefix: &str) -> anyhow::Result<()> {
    anyhow::bail!(
        "list-servers requires this binary to be built with --features tailscale-bundled \
         (Go toolchain needed at build time)"
    )
}
