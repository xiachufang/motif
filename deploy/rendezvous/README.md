# motif rendezvous relay

A self-hostable WebSocket relay for reaching motifd instances behind NAT. An
external HTTPS reverse proxy exposes it as WSS. motifd and native clients both
dial out; the relay pairs their WebSockets by an opaque token and forwards
binary messages containing the existing end-to-end TLS stream.

motifd authenticates its owner with a JWT in the `/v2/accept` WebSocket
Upgrade. The relay maps JWT `sub` to a local rate configuration and aggregates
all of that user's connections into independent client→server and
server→client token buckets. Clients use `/v2/connect` and do not need an
account JWT.

## Required files

Rvz does not load a TLS certificate. It requires an auth configuration and the
JWT verification key referenced by that configuration:

```json
{
  "jwt": {
    "algorithm": "ES256",
    "issuer": "motif-auth",
    "audience": "motif-rendezvous",
    "verification_key": "jwt-public.pem"
  },
  "users": {
    "user-123": {
      "client_to_server_bytes_per_sec": 1048576,
      "server_to_client_bytes_per_sec": 5242880,
      "burst_bytes": 262144
    }
  }
}
```

`verification_key` is resolved relative to the JSON file. Supported algorithms
are `HS256`, `RS256`, `ES256`, and `EdDSA`; asymmetric signing is recommended.
All rates and `burst_bytes` must be positive. Unknown JWT subjects are rejected.

The JWT must contain valid `iss`, `aud`, `exp`, and `sub` claims. Bandwidth
values in JWT claims are ignored.

## Run

Binary:

```sh
cargo build --release -p motif-rendezvous
./target/release/motif-rendezvous \
  --listen 127.0.0.1:8765 \
  --auth-config /etc/motif-rzv/auth.json
```

Docker:

```sh
docker run -d --name motif-rzv --restart=unless-stopped \
  -p 127.0.0.1:8765:8765 \
  -v /etc/motif-rzv:/run/secrets:ro \
  ghcr.io/<owner>/motif-rendezvous:latest
```

The image defaults to:

```text
--listen 0.0.0.0:8765
--auth-config /run/secrets/auth.json
```

Do not expose port 8765 directly to the public Internet. Bind it to loopback,
an internal container network, or another trusted private network.

## HTTPS reverse proxy

The public endpoint must provide HTTPS/WSS and forward the Upgrade request,
including `Authorization`, to Rvz. For example, with nginx:

```nginx
server {
    listen 443 ssl;
    server_name relay.example.com;

    ssl_certificate     /etc/letsencrypt/live/relay.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/relay.example.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:8765;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Authorization $http_authorization;
        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
    }
}
```

The proxy-to-Rvz hop is plaintext. Keep it on a trusted private network because
the JWT and pairing token have already been decrypted by the proxy.

Other flags:

- `--keepalive-secs <n>`: native WebSocket Ping interval; default 15, `0`
  disables relay-generated Ping frames.
- `--park-ttl-secs <n>`: maximum unpaired waiter lifetime; default 3600.
- `healthcheck --addr <host:port>`: lightweight socket liveness probe used by
  the container.

## Connect motifd

Place the owner JWT in a mode-0600 file and start motifd:

```sh
motifd \
  --rzv-relay wss://relay.example.com \
  --rzv-jwt-file /etc/motif/rzv-owner.jwt
```

A bare relay endpoint means WSS. motifd sends the JWT only in the encrypted
`/v2/accept` Upgrade request. The printed pairing QR contains the relay address,
PSK, and motifd certificate pin; native clients connect to `/v2/connect` over
WSS and then establish pinned end-to-end TLS with motifd.

## systemd

```ini
[Unit]
Description=motif rendezvous relay
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/motif-rendezvous \
  --listen 127.0.0.1:8765 \
  --auth-config /etc/motif-rzv/auth.json
Restart=on-failure
RestartSec=2
DynamicUser=yes
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
RestrictAddressFamilies=AF_INET AF_INET6
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
MemoryMax=128M
TasksMax=512

[Install]
WantedBy=multi-user.target
```

## Security notes

- Never expose Rvz's plain HTTP/WebSocket port publicly. Terminate HTTPS/WSS at
  a reverse proxy and keep the proxy-to-Rvz hop private.
- The public outer WSS protects the owner JWT and relay token in transit. The
  inner pinned TLS protects motif application traffic from both proxy and Rvz.
- JWTs remain bearer credentials if copied from disk. Prefer short expiry,
  protect motifd's JWT file, and rotate/revoke credentials when compromised.
- WebSocket compression is disabled; keepalive uses native Ping/Pong only.
