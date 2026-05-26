use std::net::SocketAddr;
use std::path::PathBuf;

use clap::Parser;

#[derive(Parser, Debug)]
#[command(name = "motifd", version, about = "motif remote dev agent — server")]
struct Args {
    /// TCP listen address. Omit to run tailscale-only. Non-loopback requires
    /// --cert/--key (M1 not yet wired). At least one of --listen /
    /// --tailscale must be set.
    #[arg(long)]
    listen: Option<SocketAddr>,

    /// Enable embedded Tailscale listener. Hostname auto-defaults to
    /// `motifd-<system-hostname>`; state dir defaults to
    /// $XDG_DATA_HOME/motifd/tsnet (~/.local/share/motifd/tsnet on Linux/macOS).
    /// First start without --tailscale-authkey will print a login URL on
    /// stderr — open it once in a browser to authorize this node.
    #[arg(long)]
    tailscale: bool,

    /// Override the embedded tsnet hostname. Default: `motifd-<system-hostname>`.
    #[arg(long, requires = "tailscale")]
    tailscale_hostname: Option<String>,

    /// Override the persistent state dir. Default:
    /// $XDG_DATA_HOME/motifd/tsnet (or ~/.local/share/motifd/tsnet).
    #[arg(long, requires = "tailscale")]
    tailscale_state_dir: Option<PathBuf>,

    /// Tailnet listen port for the embedded node.
    #[arg(long, default_value_t = 7777, requires = "tailscale")]
    tailscale_port: u16,

    /// Tailnet authkey for unattended bring-up. Optional; if absent, tsnet
    /// emits a login URL on stderr.
    #[arg(long, requires = "tailscale")]
    tailscale_authkey: Option<String>,

    /// Override the coordination server (e.g. for headscale). Tailscale
    /// SaaS by default.
    #[arg(long, requires = "tailscale")]
    tailscale_control_url: Option<String>,

    /// Bring the node up as ephemeral (no persistent device entry on the
    /// tailnet — auto-removed when the process exits).
    #[arg(long, requires = "tailscale")]
    tailscale_ephemeral: bool,

    /// Bearer-token file. The server reads this once at startup; rotate by
    /// restart. Omit to run with auth disabled — only allowed when the
    /// listener surface is private (loopback TCP or tailscale-only).
    #[arg(long)]
    token_file: Option<PathBuf>,

    /// Permit a non-loopback --listen without --token-file, disabling auth on
    /// a network-reachable port. Off by default; this is an explicit, unsafe
    /// override (anyone who can reach the port can attach). Logs a warning at
    /// startup.
    #[arg(long)]
    insecure_no_auth: bool,

    /// TLS cert (PEM). M1 does not yet implement TLS; rejected on startup if set.
    #[arg(long)]
    cert: Option<PathBuf>,

    /// TLS private key (PEM). See --cert.
    #[arg(long)]
    key: Option<PathBuf>,

    /// Log filter (env: MOTIFD_LOG). Examples: info, debug, motif_server=trace.
    #[arg(long, env = "MOTIFD_LOG", default_value = "info")]
    log: String,

    /// Append every client↔server RPC frame (request, response,
    /// notification) to this file for protocol debugging. Omit to
    /// disable. Env: MOTIFD_RPC_LOG.
    #[arg(long, env = "MOTIFD_RPC_LOG")]
    rpc_log: Option<PathBuf>,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args = Args::parse();
    motif_server::init_tracing(&args.log, args.rpc_log.as_deref())?;

    let token = match args.token_file.as_deref() {
        Some(path) => {
            let raw = std::fs::read_to_string(path).map_err(|e| {
                anyhow::anyhow!("failed to read --token-file {}: {e}", path.display())
            })?;
            let trimmed = raw.trim().to_string();
            if trimmed.is_empty() {
                anyhow::bail!("token file is empty: {}", path.display());
            }
            Some(trimmed)
        }
        None => None,
    };

    let tailscale = if args.tailscale {
        let hostname = args.tailscale_hostname.unwrap_or_else(default_ts_hostname);
        let state_dir = match args.tailscale_state_dir {
            Some(p) => p,
            None => default_ts_state_dir()?,
        };
        Some(motif_server::TailscaleListenConfig {
            hostname,
            state_dir,
            port: args.tailscale_port,
            authkey: args.tailscale_authkey,
            control_url: args.tailscale_control_url,
            ephemeral: args.tailscale_ephemeral,
        })
    } else {
        None
    };

    let cfg = motif_server::ServerConfig {
        listen: args.listen,
        tailscale,
        token,
        cert: args.cert,
        key: args.key,
        allow_insecure_no_auth: args.insecure_no_auth,
    };
    motif_server::serve(cfg).await
}

/// Pick a sensible tsnet hostname from the system hostname so multiple
/// motifd instances on different machines don't collide on a single tailnet
/// device entry. Sanitized to DNS-safe lowercase.
fn default_ts_hostname() -> String {
    let raw = system_hostname().unwrap_or_default();
    let sanitized: String = raw
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' {
                c.to_ascii_lowercase()
            } else {
                '-'
            }
        })
        .collect();
    let sanitized = sanitized.trim_matches('-');
    if sanitized.is_empty() {
        "motifd".into()
    } else {
        format!("motifd-{sanitized}")
    }
}

fn default_ts_state_dir() -> anyhow::Result<PathBuf> {
    if let Some(dir) = std::env::var_os("XDG_DATA_HOME") {
        let mut p = PathBuf::from(dir);
        p.push("motifd");
        p.push("tsnet");
        return Ok(p);
    }
    if let Some(home) = std::env::var_os("HOME") {
        let mut p = PathBuf::from(home);
        p.push(".local");
        p.push("share");
        p.push("motifd");
        p.push("tsnet");
        return Ok(p);
    }
    anyhow::bail!(
        "cannot determine state dir; pass --tailscale-state-dir or set HOME / XDG_DATA_HOME"
    );
}

#[cfg(unix)]
fn system_hostname() -> Option<String> {
    let mut buf = [0u8; 256];
    // SAFETY: we pass a buffer of known size; libc::gethostname writes at most
    // buf.len() bytes including the trailing NUL on success.
    let rc = unsafe { libc::gethostname(buf.as_mut_ptr() as *mut libc::c_char, buf.len()) };
    if rc != 0 {
        return None;
    }
    let nul = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
    std::str::from_utf8(&buf[..nul]).ok().map(|s| s.to_string())
}

#[cfg(not(unix))]
fn system_hostname() -> Option<String> {
    std::env::var("COMPUTERNAME").ok().filter(|s| !s.is_empty())
}
