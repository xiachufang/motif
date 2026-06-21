# motif rendezvous relay

A tiny, self-hostable NAT-traversal relay. `motifd` and clients both **dial
out** to it; the relay pairs them by token and splices the two TCP streams
together. It coexists with the `tcp` and `tailscale` transports — pick `rzv`
when neither end can accept an inbound connection.

It is **zero-trust by design**: motifd's always-on end-to-end TLS means the relay
only ever forwards ciphertext, and the pairing token is one-way derived from the
pairing secret (HKDF), so the relay never learns the secret and can't read or
forge traffic. That's what makes it safe to run `0.0.0.0:<port>` on a public box.

## What's here

| file | role |
|------|------|
| `Dockerfile`  | pure-Rust multi-stage build of the `motif-rendezvous` binary; debian-slim runtime, unprivileged user, no extra packages |
| `smoke.py`    | pairing smoke check — an `accept` and a `connect` with the same token must both get PAIRED, then bytes must pipe through |
| `README.md`   | this file |

The image is built and pushed to GHCR by
[`.github/workflows/rendezvous-image.yml`](../../.github/workflows/rendezvous-image.yml)
on tags, on `main` pushes touching the relay, and on manual dispatch.

## Run it

### From the published image (GHCR)

```sh
docker run -d --name motif-rzv --restart=unless-stopped \
  -p 8765:8765 \
  ghcr.io/<owner>/motif-rendezvous:latest
```

Replace `<owner>` with your GitHub org/user (the package lives under whoever
owns the repo). The GHCR package defaults to **private** — either make it public
in the repo's *Packages* settings, or `docker login ghcr.io` on the host first.

### Build locally

```sh
# build context MUST be the repo root — the relay is a workspace member
docker build -f deploy/rendezvous/Dockerfile -t motif-rendezvous .
docker run -d -p 8765:8765 motif-rendezvous
```

### As a binary (no Docker)

```sh
cargo build --release -p motif-rendezvous
./target/release/motif-rendezvous --listen 0.0.0.0:8765
```

Flags:
- `--listen <addr>` (default `127.0.0.1:8765`).
- `--keepalive-secs <n>` (default 15, `0` disables) — how often to PING a parked
  waiter (plus one PING the instant it parks) so NATs / proxies on its path
  don't reap the idle connection before it pairs. Lower it if a particularly
  aggressive middlebox still cuts idle parks.
- `--park-ttl-secs <n>` (default 3600) — backstop drop of an abandoned, unpaired
  waiter. Keepalive keeps healthy parks alive, so this rarely fires.

## systemd (binary on a host)

If you'd rather not run Docker, drop the binary at
`/usr/local/bin/motif-rendezvous` and install this unit at
`/etc/systemd/system/motif-rendezvous.service`:

```ini
[Unit]
Description=motif rendezvous relay
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/motif-rendezvous --listen 0.0.0.0:8765
Restart=on-failure
RestartSec=2

# It needs nothing but a socket — lock it down hard.
DynamicUser=yes
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_INET AF_INET6
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
MemoryMax=128M
TasksMax=512

[Install]
WantedBy=multi-user.target
```

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now motif-rendezvous
journalctl -u motif-rendezvous -f
```

For a containerized host, prefer the `docker run … --restart=unless-stopped`
line above (or the equivalent compose service) instead of this unit.

## Wire it up

On the host you want to reach, start motifd pointed at the relay:

```sh
motifd --rzv-relay <relay-host>:8765
```

It prints a pairing QR (and a `motif://` URI). Scan it from the Flutter client
(**Add server → Scan QR**, or the welcome/session-list pairing entry points), or
paste the URI. The QR carries the relay address, the token, and the TLS cert pin
(`pk`) so the client verifies it's terminating TLS against the real motifd, not
the relay or a MITM. Both sides dial the relay, the tokens match, and the
session is spliced together end-to-end encrypted.

## Verify a running relay

**Built-in liveness probe** — the binary probes itself, no extra deps:

```sh
motif-rendezvous healthcheck --addr <host>:8765   # prints "ok", exits 0/1
```

It sends a health HELLO (`role = 2`) and checks the relay replies `HEALTH_OK`,
so a pass means the relay is actually pairing-capable, not just that the port is
bound — and it parks no state. The image runs this as its Docker `HEALTHCHECK`,
so `docker ps` shows `healthy`/`unhealthy` on its own:

```sh
docker inspect --format '{{.State.Health.Status}}' motif-rzv
```

**Full pairing self-test** — exercises a real accept↔connect splice end to end:

```sh
python3 deploy/rendezvous/smoke.py <host> 8765   # -> "relay pairing + pipe OK"
```

This is exactly what CI runs against the freshly built image before pushing.

## Notes

- The relay forwards bytes only — it never parses the motif protocol, holds no
  state beyond the in-flight pairing table, and writes nothing to disk.
- One relay handles many independent pairs; tokens keep them isolated.
- Port `8765` is just the default (it's >1024 so the container needs no
  capabilities). Expose it directly, or front it with whatever you like — the
  relay doesn't care, since it's already only seeing ciphertext.
- The build drops the `apps/*` workspace glob (the Flutter client, excluded by
  `.dockerignore`); `crates/*` and `Cargo.lock` are untouched, so the relay and
  its deps build reproducibly.
