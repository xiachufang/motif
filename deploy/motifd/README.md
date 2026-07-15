# motifd Docker image

Production/self-hosted image for `motifd`.

This image is different from `deploy/review`: it embeds the Flutter Web client
and keeps `motifd`'s default Tailscale support enabled. Use it for your own
server, VPS, workstation, or LAN deployment. Do not use it as the disposable App
Review sandbox.

## Image

CI publishes the `linux/amd64` image to GHCR:

```sh
ghcr.io/<owner>/motifd:latest
ghcr.io/<owner>/motifd:<git-tag>
ghcr.io/<owner>/motifd:sha-<short-sha>
```

Replace `<owner>` with the GitHub org/user that owns the repository. GHCR
packages default to private; make the package public in GitHub Packages or run
`docker login ghcr.io` on the host.

## Quick start

```sh
mkdir -p ./motif-data ./work

docker run -d --name motifd --restart=unless-stopped \
  -p 7777:7777 \
  -v "$PWD/motif-data:/data" \
  -v "$PWD/work:/work" \
  -e MOTIFD_ADVERTISE_HOST=<your-public-ip-or-domain> \
  ghcr.io/<owner>/motifd:latest

# Print the pairing link to add the server in the app:
docker logs motifd 2>&1 | grep -o 'motif://pair[^ ]*'
```

A non-loopback listener is **automatically encrypted** (self-signed TLS; the
client pins the cert) and **authenticated** with a psk-derived bearer — no token
file, no upstream TLS proxy. On startup `motifd` prints a single `motif://pair`
link/QR carrying its NIC addresses (or `MOTIFD_ADVERTISE_HOST`), psk, and pin;
open it on the device (or scan the QR) to add the server.

Mount `/data` persistently (as above): the psk **and** the TLS identity live
there, so the pairing link's pin stays valid across restarts. The Web UI is
served by `motifd` itself. Sessions run as the unprivileged `motif` user with
`/work` as the default working directory.

## Configuration

The entrypoint maps environment variables to `motifd` flags.

| Variable | Default | Maps to |
| --- | --- | --- |
| `MOTIFD_LISTEN` | `0.0.0.0:7777` | `--listen` |
| `MOTIFD_PSK` | empty | `--psk` (fixed pairing secret; else auto-generated + persisted) |
| `MOTIFD_PSK_FILE` | empty | `--psk-file` |
| `MOTIFD_ADVERTISE_HOST` | empty | `--advertise-host` (direct QR host(s); else all NIC IPs) |
| `MOTIFD_LOG` | `info` | `--log` |
| `MOTIFD_RPC_LOG` | empty | `--rpc-log` |
| `MOTIFD_PUSH_RELAY_URL` | empty | `--push-relay-url` |

Auth and encryption are automatic on a network listener (psk-derived bearer +
self-signed TLS, client pins the cert). There is no token file or
`--insecure-no-auth`; the `motif://pair` link is the single credential.

Set `MOTIFD_LISTEN=off` or `MOTIFD_LISTEN=none` to omit the TCP listener, for
example when running Tailscale-only or rendezvous-only.

Tailscale:

| Variable | Maps to |
| --- | --- |
| `MOTIFD_TAILSCALE=1` | `--tailscale` |
| `MOTIFD_TAILSCALE_HOSTNAME` | `--tailscale-hostname` |
| `MOTIFD_TAILSCALE_STATE_DIR` | `--tailscale-state-dir` |
| `MOTIFD_TAILSCALE_PORT` | `--tailscale-port` |
| `MOTIFD_TAILSCALE_AUTHKEY` | `--tailscale-authkey` |
| `MOTIFD_TAILSCALE_CONTROL_URL` | `--tailscale-control-url` |
| `MOTIFD_TAILSCALE_EPHEMERAL=1` | `--tailscale-ephemeral` |

Rendezvous:

| Variable | Maps to |
| --- | --- |
| `MOTIFD_RZV_RELAY` | `--rzv-relay` |
| `MOTIFD_RZV_JWT_FILE` | `--rzv-jwt-file` |
| `MOTIFD_RZV_POOL` | `--rzv-pool` |

The owner JWT file is required for the WSS Upgrade and relay-side per-user
bandwidth limit. The pairing secret is `MOTIFD_PSK` / `MOTIFD_PSK_FILE`
(shared by the relay and direct paths). Rendezvous end-to-end TLS is always on.

If arguments are passed to the container, they replace the entrypoint's
generated `motifd` command. For example:

```sh
docker run --rm ghcr.io/<owner>/motifd:latest motifd --help
```

## Tailscale-only deployment

```sh
docker run -d --name motifd --restart=unless-stopped \
  -v motifd-data:/data \
  -v "$PWD/work:/work" \
  -e MOTIFD_LISTEN=off \
  -e MOTIFD_TAILSCALE=1 \
  -e MOTIFD_TAILSCALE_AUTHKEY=tskey-auth-... \
  ghcr.io/<owner>/motifd:latest
```

Tailscale-only access is gated by your tailnet ACLs (no psk/bearer is used when
there is no network `--listen`).

Mount `/data` persistently so the tsnet identity, rendezvous pairing secret,
and other motifd state survive restarts.

## Build locally

```sh
docker build --platform linux/amd64 -f deploy/motifd/Dockerfile -t motifd .
docker run --rm -p 7777:7777 motifd   # prints a motif://pair link in the logs
```

The build has two expensive parts: Flutter Web and `motifd`/libghostty. BuildKit
cache is strongly recommended.

`linux/arm64` is not published yet because the upstream `libtailscale` crate
currently fails to compile on that target with Rust 1.95.

## Security notes

- `motifd` is a remote shell. Anyone with the `motif://pair` link (psk) can run
  commands as the container user and read mounted files. Treat the link as a
  secret; rotate by wiping `/data` (regenerates the psk + TLS identity).
- A network listener is encrypted (self-signed TLS, client-pinned) and
  authenticated (psk bearer) out of the box — no token, no upstream TLS proxy.
- Mount `/data` persistently so the psk + TLS identity (and thus the pairing
  link's pin) survive restarts.
- Mount only the project/workspace directories you intend to expose.
