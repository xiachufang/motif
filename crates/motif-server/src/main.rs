use std::io::Write;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::time::Duration;

use base64::Engine;
use clap::Parser;

#[derive(Parser, Debug)]
#[command(name = "motifd", version, about = "motif remote dev agent — server")]
struct Args {
    /// TCP listen address. Omit to run tailscale-/rzv-only. A non-loopback
    /// address is automatically encrypted (self-signed TLS, client pins the
    /// cert) and authenticated (psk-derived bearer) — motifd prints a
    /// `motif://pair` link/QR carrying its NIC addresses, psk, and pin.
    /// Loopback stays plaintext (local / embedded use). At least one of
    /// --listen / --tailscale / --rzv-relay must be set.
    #[arg(long)]
    listen: Option<SocketAddr>,

    /// Enable embedded Tailscale listener. Hostname auto-defaults to
    /// `motifd-<system-hostname>`; state dir defaults to
    /// Platform data dir (XDG/~/.local/share on Unix, LocalAppData on Windows).
    /// First start without --tailscale-authkey will print a login URL on
    /// stderr — open it once in a browser to authorize this node.
    /// The whole `--tailscale*` family exists only when built with the
    /// `tailscale` feature (the default); `--no-default-features` drops it.
    #[cfg(feature = "tailscale")]
    #[arg(long)]
    tailscale: bool,

    /// Override the embedded tsnet hostname. Default: `motifd-<system-hostname>`.
    #[cfg(feature = "tailscale")]
    #[arg(long, requires = "tailscale")]
    tailscale_hostname: Option<String>,

    /// Override the persistent state dir. Default:
    /// Platform data dir under motifd/tsnet.
    #[cfg(feature = "tailscale")]
    #[arg(long, requires = "tailscale")]
    tailscale_state_dir: Option<PathBuf>,

    /// Tailnet listen port for the embedded node.
    #[cfg(feature = "tailscale")]
    #[arg(long, default_value_t = 7777, requires = "tailscale")]
    tailscale_port: u16,

    /// Tailnet authkey for unattended bring-up. Optional; if absent, tsnet
    /// emits a login URL on stderr.
    #[cfg(feature = "tailscale")]
    #[arg(long, requires = "tailscale")]
    tailscale_authkey: Option<String>,

    /// Override the coordination server (e.g. for headscale). Tailscale
    /// SaaS by default.
    #[cfg(feature = "tailscale")]
    #[arg(long, requires = "tailscale")]
    tailscale_control_url: Option<String>,

    /// Bring the node up as ephemeral (no persistent device entry on the
    /// tailnet — auto-removed when the process exits).
    #[cfg(feature = "tailscale")]
    #[arg(long, requires = "tailscale")]
    tailscale_ephemeral: bool,

    /// 32-byte pairing secret as base64url. The single capability for both rzv
    /// and direct: the relay token and the motifd access bearer are derived from
    /// it, and it goes in the `motif://pair` QR. Omit to auto-generate and
    /// persist one (stable across restarts). Pass a fixed value for unattended
    /// deployments (e.g. a public review server) so the QR/link stays constant.
    #[arg(long)]
    psk: Option<String>,

    /// Where to persist the auto-generated pairing secret. Defaults to
    /// `<data-dir>/motif/rzv_psk`. Ignored when --psk is given.
    #[arg(long)]
    psk_file: Option<PathBuf>,

    /// Push-relay base URL for iOS background notifications. When set, Claude
    /// Code hook notifications are forwarded here (end-to-end encrypted) for
    /// APNs delivery. Omit to disable push. motifd never holds the APNs
    /// signing key — only this URL.
    #[arg(long)]
    push_relay_url: Option<String>,

    /// Host(s) to advertise in the **direct** pairing QR instead of this
    /// machine's NIC addresses. Use for a server reached at a stable public
    /// address / behind NAT (e.g. `--advertise-host 203.0.113.5` or a domain);
    /// comma-separate multiple. Omit on a LAN to advertise all local NIC IPs.
    #[arg(long)]
    advertise_host: Option<String>,

    /// Rendezvous relay address (`host:port` or `wss://...`) to park WSS
    /// `accept` waiters at. Requires an owner JWT for relay-side per-user
    /// bandwidth limits. The WSS payload remains end-to-end TLS ciphertext.
    #[arg(long, requires = "rzv_jwt_file")]
    rzv_relay: Option<String>,

    /// File containing the owner JWT sent in the rendezvous WSS Upgrade.
    #[arg(long, requires = "rzv_relay")]
    rzv_jwt_file: Option<PathBuf>,

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

    let listen = args.listen;
    // A non-loopback --listen is a network-reachable surface: encrypt + auth it.
    // Loopback (embed / local) stays plaintext & unauthenticated as before.
    let is_network_listen = listen.map(|a| !a.ip().is_loopback()).unwrap_or(false);
    let rzv_on = args.rzv_relay.is_some();
    // "Pairing mode": a network surface exists (relay or non-loopback --listen),
    // so motifd needs a psk (→ access bearer), a TLS identity, and a pairing QR.
    let pairing = rzv_on || is_network_listen;

    // Built without the `tailscale` feature, the `--tailscale*` flags don't
    // exist and the listener carries no tsnet backend, so the field is `None`.
    #[cfg(feature = "tailscale")]
    let tailscale = if args.tailscale {
        let hostname = args
            .tailscale_hostname
            .unwrap_or_else(motif_server::default_tailscale_hostname);
        let state_dir = match args.tailscale_state_dir {
            Some(p) => p,
            None => motif_server::default_tailscale_state_dir().ok_or_else(|| {
                anyhow::anyhow!("cannot determine state dir; pass --tailscale-state-dir")
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

    // In pairing mode, derive everything from one psk: the TLS identity (→ pin),
    // the relay token, and the access bearer. One secret in the QR; the relay
    // never sees the bearer (distinct HKDF label). Outside pairing mode
    // (tailscale-only / loopback / embed) there is no psk: auth disabled, no TLS.
    let (psk, identity, token) = if pairing {
        let psk: [u8; 32] = match args.psk {
            Some(b64) => {
                let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
                    .decode(b64.trim())
                    .map_err(|e| anyhow::anyhow!("--psk is not base64url: {e}"))?;
                bytes.as_slice().try_into().map_err(|_| {
                    anyhow::anyhow!("--psk must decode to 32 bytes, got {}", bytes.len())
                })?
            }
            None => {
                let path = args
                    .psk_file
                    .unwrap_or_else(motif_server::default_rzv_psk_path);
                motif_server::rzv::load_or_create_psk(&path)?
            }
        };
        let psk_dir = motif_server::default_rzv_psk_path();
        let rzv_dir = psk_dir
            .parent()
            .unwrap_or_else(|| std::path::Path::new("."));
        let identity = motif_server::rzv::load_or_create_identity(rzv_dir)?;
        let bearer = motif_server::rzv::bearer_token(&psk);
        (Some(psk), Some(identity), Some(bearer))
    } else {
        (None, None, None)
    };
    let pin = identity.as_ref().map(|id| id.cert_sha256);

    let rzv_jwt = match args.rzv_jwt_file.as_deref() {
        Some(path) => {
            let jwt = std::fs::read_to_string(path)
                .map_err(|e| anyhow::anyhow!("read --rzv-jwt-file {}: {e}", path.display()))?;
            let jwt = jwt.trim().to_string();
            if jwt.is_empty() {
                anyhow::bail!("--rzv-jwt-file {} is empty", path.display());
            }
            Some(jwt)
        }
        None => None,
    };

    let rendezvous = match &args.rzv_relay {
        Some(url) => {
            let psk = psk.expect("rzv ⇒ pairing ⇒ psk present");
            let mut c = motif_server::RzvListenConfig::new(
                url.clone(),
                motif_server::rzv::derive_token(&psk),
                rzv_jwt.clone().expect("clap requires --rzv-jwt-file"),
            );
            if let Some(pool) = args.rzv_pool {
                c.pool = pool;
            }
            c.tls = identity.as_ref().map(|id| id.server_config.clone());
            Some(c)
        }
        None => None,
    };

    // A non-loopback --listen terminates TLS with the same identity (client
    // pins the cert); loopback stays plaintext.
    let listen_tls = if is_network_listen {
        identity.as_ref().map(|id| id.server_config.clone())
    } else {
        None
    };

    // LAN-direct /ping hint: only for rzv + a network --listen, so a same-LAN
    // rzv client can upgrade off the relay onto the (TLS-pinned) direct port.
    // Pure-direct deployments carry their NIC candidates in the QR instead.
    let rzv_direct = if rzv_on && is_network_listen {
        let addr = listen.expect("is_network_listen ⇒ listen present");
        let addrs = if addr.ip().is_unspecified() {
            motif_server::rzv::local_nic_addrs()
        } else {
            vec![addr.ip().to_string()]
        };
        (!addrs.is_empty()).then(|| {
            std::sync::Arc::new(motif_server::RzvDirectInfo {
                port: addr.port(),
                addrs,
            })
        })
    } else {
        None
    };

    // One pairing QR per server: rzv form when a relay is set, else the direct
    // form carrying every NIC address (the client probes them to pick one).
    if pairing {
        let name = motif_server::default_tailscale_hostname();
        let psk = psk.as_ref().expect("pairing ⇒ psk present");
        let uri = match &args.rzv_relay {
            Some(url) => motif_server::rzv::pair_uri(url, psk, pin.as_ref(), Some(&name)),
            None => {
                let addr = listen.expect("pairing without relay ⇒ network listen");
                // Explicit --advertise-host (public/NAT) wins; else all NICs for
                // an unspecified bind, or the specific bind IP.
                let hosts = match &args.advertise_host {
                    Some(h) => h.split(',').map(|s| s.trim().to_string()).collect(),
                    None if addr.ip().is_unspecified() => motif_server::rzv::local_nic_addrs(),
                    None => vec![addr.ip().to_string()],
                };
                motif_server::rzv::pair_uri_direct(
                    &hosts,
                    addr.port(),
                    psk,
                    pin.as_ref(),
                    Some(&name),
                )
            }
        };
        if let Some(qr) = motif_server::rzv::render_qr(&uri) {
            println!("\n{qr}");
        }
        println!("Pair a client by scanning the QR above or opening this link:\n  {uri}\n");
    }

    let cfg = motif_server::ServerConfig {
        listen,
        listen_tls,
        #[cfg(feature = "tailscale")]
        tailscale,
        #[cfg(not(feature = "tailscale"))]
        tailscale: None,
        rendezvous,
        rzv_direct,
        token,
        push_relay_url: args.push_relay_url,
    };
    motif_server::serve(cfg).await
}
