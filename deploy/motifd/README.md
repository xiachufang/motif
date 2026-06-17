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
openssl rand -base64 32 > ./motif-token
chmod 600 ./motif-token

docker run -d --name motifd --restart=unless-stopped \
  -p 7777:7777 \
  -v "$PWD/motif-data:/data" \
  -v "$PWD/work:/work" \
  -v "$PWD/motif-token:/run/secrets/motifd_token:ro" \
  -e MOTIFD_TOKEN_FILE=/run/secrets/motifd_token \
  ghcr.io/<owner>/motifd:latest
```

Open:

```text
http://localhost:7777/?token=<contents-of-motif-token>
```

The Web UI is served by `motifd` itself. Sessions run inside the container as
the unprivileged `motif` user, with `/work` as the default working directory.

## Configuration

The entrypoint maps environment variables to `motifd` flags.

| Variable | Default | Maps to |
| --- | --- | --- |
| `MOTIFD_LISTEN` | `0.0.0.0:7777` | `--listen` |
| `MOTIFD_TOKEN_FILE` | empty | `--token-file` |
| `MOTIFD_TOKEN` | empty | writes a temporary token file |
| `MOTIFD_INSECURE_NO_AUTH` | empty | `--insecure-no-auth` when `1`/`true` |
| `MOTIFD_LOG` | `info` | `--log` |
| `MOTIFD_RPC_LOG` | empty | `--rpc-log` |
| `MOTIFD_PUSH_RELAY_URL` | empty | `--push-relay-url` |

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
| `MOTIFD_RZV_PSK` | `--rzv-psk` |
| `MOTIFD_RZV_PSK_FILE` | `--rzv-psk-file` |
| `MOTIFD_RZV_POOL` | `--rzv-pool` |
| `MOTIFD_RZV_NO_TLS=1` | `--rzv-no-tls` |

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
  -e MOTIFD_TOKEN="$(openssl rand -base64 32)" \
  ghcr.io/<owner>/motifd:latest
```

Mount `/data` persistently so the tsnet identity, rendezvous pairing secret,
and other motifd state survive restarts.

## Build locally

```sh
docker build --platform linux/amd64 -f deploy/motifd/Dockerfile -t motifd .
docker run --rm -p 7777:7777 -e MOTIFD_INSECURE_NO_AUTH=1 motifd
```

The build has two expensive parts: Flutter Web and `motifd`/libghostty. BuildKit
cache is strongly recommended.

`linux/arm64` is not published yet because the upstream `libtailscale` crate
currently fails to compile on that target with Rust 1.95.

## Security notes

- `motifd` is a remote shell. Anyone with access and a valid token can run
  commands as the container user and read mounted files.
- Keep `MOTIFD_TOKEN_FILE` or `MOTIFD_TOKEN` set for any non-loopback listener.
- Put public deployments behind TLS termination, a tunnel, VPN, or Tailscale.
  `motifd` itself does not terminate TLS.
- Mount only the project/workspace directories you intend to expose.
