use std::io::Write;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::time::Duration;

use base64::Engine;
use clap::Parser;

#[derive(Parser, Debug)]
#[command(name = "motifd", version, about = "motif remote dev agent — server")]
struct Args {
    /// TCP listen address. Omit to run tailscale-only. Non-loopback without
    /// --token-file requires --insecure-no-auth. At least one of --listen /
    /// --tailscale must be set. motifd does not terminate TLS — front it with
    /// a proxy, or use the tailnet, if you need encryption.
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

    /// Push-relay base URL for iOS background notifications. When set, Claude
    /// Code hook notifications are forwarded here (end-to-end encrypted) for
    /// APNs delivery. Omit to disable push. motifd never holds the APNs
    /// signing key — only this URL.
    #[arg(long)]
    push_relay_url: Option<String>,

    /// Rendezvous relay address (`host:port`) to park `accept` waiters at, so
    /// clients can reach this motifd through the relay without direct
    /// connectivity. Requires --rzv-token. The relay only sees ciphertext.
    #[arg(long)]
    rzv_relay: Option<String>,

    /// 32-byte pairing secret as base64url. Omit to auto-generate and persist
    /// one (printed as a `motif://pair` QR/link to pair a client). The
    /// on-the-wire token is derived one-way from this, so the relay never sees
    /// the secret.
    #[arg(long, requires = "rzv_relay")]
    rzv_psk: Option<String>,

    /// Where to persist the auto-generated pairing secret. Defaults to
    /// `<data-dir>/motif/rzv_psk`. Ignored when --rzv-psk is given.
    #[arg(long, requires = "rzv_relay")]
    rzv_psk_file: Option<PathBuf>,

    /// How many idle `accept` waiters to keep parked at the relay (default 2).
    #[arg(long, requires = "rzv_relay")]
    rzv_pool: Option<usize>,

    /// Log filter (env: MOTIFD_LOG). Examples: info, debug, motif_server=trace.
    #[arg(long, env = "MOTIFD_LOG", default_value = "info")]
    log: String,

    /// Append every client↔server RPC frame (request, response,
    /// notification) to this file for protocol debugging. Omit to
    /// disable. Env: MOTIFD_RPC_LOG.
    #[arg(long, env = "MOTIFD_RPC_LOG")]
    rpc_log: Option<PathBuf>,
}

fn main() -> anyhow::Result<()> {
    let rt = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?;
    let result = rt.block_on(run());

    // libtailscale's accept/log plumbing uses blocking tasks. During Ctrl-C
    // shutdown those tasks can stay parked inside Go/C FFI after motifd has
    // already closed its listeners, and Tokio's default runtime drop waits
    // for blocking tasks forever. Bound that wait for the CLI process; the
    // embeddable `motif_server::start` path keeps the regular runtime owned
    // by its host.
    let _ = std::io::stdout().flush();
    let _ = std::io::stderr().flush();
    rt.shutdown_timeout(Duration::from_secs(2));

    result
}

async fn run() -> anyhow::Result<()> {
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
        let hostname = args
            .tailscale_hostname
            .unwrap_or_else(motif_server::default_tailscale_hostname);
        let state_dir = match args.tailscale_state_dir {
            Some(p) => p,
            None => motif_server::default_tailscale_state_dir().ok_or_else(|| {
                anyhow::anyhow!(
                    "cannot determine state dir; pass --tailscale-state-dir or set HOME / XDG_DATA_HOME"
                )
            })?,
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

    let rendezvous = match args.rzv_relay {
        Some(url) => {
            // Obtain the pairing secret: explicit flag, or persisted/auto-gen.
            let psk: [u8; 32] = match args.rzv_psk {
                Some(b64) => {
                    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
                        .decode(b64.trim())
                        .map_err(|e| anyhow::anyhow!("--rzv-psk is not base64url: {e}"))?;
                    bytes.as_slice().try_into().map_err(|_| {
                        anyhow::anyhow!("--rzv-psk must decode to 32 bytes, got {}", bytes.len())
                    })?
                }
                None => {
                    let path = args
                        .rzv_psk_file
                        .unwrap_or_else(motif_server::default_rzv_psk_path);
                    motif_server::rzv::load_or_create_psk(&path)?
                }
            };

            // The wire token is derived one-way from the secret.
            let token = motif_server::rzv::derive_token(&psk);

            // Print the pairing QR/link for a client to scan.
            let name = motif_server::default_tailscale_hostname();
            let uri = motif_server::rzv::pair_uri(&url, &psk, Some(&name));
            if let Some(qr) = motif_server::rzv::render_qr(&uri) {
                println!("\n{qr}");
            }
            println!("Pair a client by scanning the QR above or opening this link:\n  {uri}\n");

            let mut c = motif_server::RzvListenConfig::new(url, token);
            if let Some(pool) = args.rzv_pool {
                c.pool = pool;
            }
            Some(c)
        }
        None => None,
    };

    let cfg = motif_server::ServerConfig {
        listen: args.listen,
        tailscale,
        rendezvous,
        token,
        allow_insecure_no_auth: args.insecure_no_auth,
        push_relay_url: args.push_relay_url,
    };
    motif_server::serve(cfg).await
}
