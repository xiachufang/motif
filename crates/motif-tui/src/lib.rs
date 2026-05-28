//! Motif TUI client library.

pub mod pty_view;
pub mod ui;

pub use motif_client::{palette, transport};

use std::path::{Path, PathBuf};

use anyhow::Context;
use motif_proto::session as ses;

pub fn read_token(path: Option<&Path>) -> anyhow::Result<String> {
    let Some(path) = path else {
        return Ok(String::new());
    };
    let raw = std::fs::read_to_string(path)
        .with_context(|| format!("reading token file {}", path.display()))?;
    Ok(raw.trim().to_string())
}

/// Helper: connect with optional SSH tunneling and return the live
/// `ConnectedV2`. The TUI runs on the new HTTP-split protocol; the
/// legacy `transport::connect` (and `Client`) are still exported for
/// motif-cast until Phase 5.
pub async fn connect(
    url: &str,
    token: &str,
    via: Option<&str>,
    ssh_remote_port: Option<u16>,
) -> anyhow::Result<transport::ConnectedV2> {
    transport::connect_v2(url, token, via, ssh_remote_port).await
}

pub async fn cmd_list(
    url: &str,
    token: &str,
    via: Option<&str>,
    ssh_remote_port: Option<u16>,
) -> anyhow::Result<()> {
    let tr = connect(url, token, via, ssh_remote_port).await?;
    let r: ses::ListResult = tr
        .client
        .call("session.list", ses::ListParams::default())
        .await?;
    if r.sessions.is_empty() {
        println!("(no sessions)");
        return Ok(());
    }
    println!("{:<20} {:<28} CLIENTS  WORKDIR", "NAME", "ID");
    for s in &r.sessions {
        println!(
            "{:<20} {:<28} {:<8} {}",
            s.name,
            s.id,
            s.client_count,
            s.workdir.display()
        );
    }
    Ok(())
}

pub async fn cmd_new(
    url: &str,
    token: &str,
    name: String,
    workdir: PathBuf,
    via: Option<&str>,
    ssh_remote_port: Option<u16>,
) -> anyhow::Result<()> {
    let tr = connect(url, token, via, ssh_remote_port).await?;
    let r: ses::CreateResult = tr
        .client
        .call("session.create", ses::CreateParams { name, workdir })
        .await?;
    println!("session created: {} (id={})", r.session.name, r.session.id);
    Ok(())
}

pub async fn cmd_destroy(
    url: &str,
    token: &str,
    name: String,
    via: Option<&str>,
    ssh_remote_port: Option<u16>,
) -> anyhow::Result<()> {
    let tr = connect(url, token, via, ssh_remote_port).await?;
    let _: ses::DestroyResult = tr
        .client
        .call("session.destroy", ses::DestroyParams { name: name.clone() })
        .await?;
    println!("session destroyed: {name}");
    Ok(())
}

pub async fn cmd_pty_run(
    url: &str,
    token: &str,
    name: String,
    cmd: String,
    via: Option<&str>,
    ssh_remote_port: Option<u16>,
) -> anyhow::Result<()> {
    use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
    use motif_proto::pty as ppty;
    use std::io::Write;

    let tr = connect(url, token, via, ssh_remote_port).await?;
    let (term_fg, term_bg) = palette::probe();
    let _: ses::AttachResult = tr
        .client
        .call(
            "session.attach",
            ses::AttachParams {
                name: name.clone(),
                last_seq: None,
                term_fg,
                term_bg,
                theme: None,
            },
        )
        .await?;
    let r: ppty::PtyCreateResult = tr
        .client
        .call(
            "pty.create",
            ppty::PtyCreateParams {
                cmd: Some(cmd),
                cwd: None,
                env: vec![],
                cols: 120,
                rows: 40,
            },
        )
        .await?;
    let want = r.info.id;

    let mut stdout = std::io::stdout();
    while let Some(n) = tr.client.recv_notification().await {
        match n.method.as_str() {
            "pty.output" => {
                if let (Some(pid), Some(b64)) = (
                    n.params.get("pty_id").and_then(|v| v.as_str()),
                    n.params.get("data_b64").and_then(|v| v.as_str()),
                ) {
                    if pid == want {
                        if let Ok(b) = BASE64.decode(b64.as_bytes()) {
                            stdout.write_all(&b)?;
                            stdout.flush()?;
                        }
                    }
                }
            }
            "pty.exited" => {
                if n.params.get("pty_id").and_then(|v| v.as_str()) == Some(want.as_str()) {
                    return Ok(());
                }
            }
            _ => {}
        }
    }
    Ok(())
}

pub async fn cmd_attach_log(
    url: &str,
    token: &str,
    name: String,
    via: Option<&str>,
    ssh_remote_port: Option<u16>,
) -> anyhow::Result<()> {
    let tr = connect(url, token, via, ssh_remote_port).await?;
    let (term_fg, term_bg) = palette::probe();
    let r: ses::AttachResult = tr
        .client
        .call(
            "session.attach",
            ses::AttachParams {
                name: name.clone(),
                last_seq: None,
                term_fg,
                term_bg,
                theme: None,
            },
        )
        .await?;
    println!(
        "attached: session={} client_id={} other-clients={}",
        r.session.name,
        r.client_id,
        r.clients.len()
    );
    while let Some(n) = tr.client.recv_notification().await {
        let p = serde_json::to_string(&n.params).unwrap_or_default();
        println!("event {}  {}", n.method, p);
    }
    Ok(())
}

pub async fn cmd_attach(
    url: &str,
    token: &str,
    name: String,
    via: Option<&str>,
    ssh_remote_port: Option<u16>,
) -> anyhow::Result<()> {
    let tr = connect(url, token, via, ssh_remote_port).await?;
    ui::run_with(tr, name).await
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
