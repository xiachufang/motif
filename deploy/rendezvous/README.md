# motif rendezvous relay

A self-hostable WebSocket relay for reaching motifd instances behind NAT. An
external HTTPS reverse proxy exposes it as WSS. motifd and native clients both
dial out; the relay pairs their WebSockets by an opaque token and forwards
binary messages containing the existing end-to-end TLS stream.

motifd authenticates its owner with a JWT in the `/v2/accept` WebSocket
Upgrade. Native clients use `/v2/connect` and do not need an account JWT.
Legacy owner JWTs are mapped through `users[sub]`; auto-managed Free JWTs carry
`sub=<installation id>` and `plan=free` and are mapped through `plans.free`.

## Required files

Rvz does not load a TLS certificate. It requires an auth configuration and the
JWT keys referenced by that configuration.

Copy the tracked [`auth.example.json`](./auth.example.json) to
`secrets/relay/auth.json`; the complete shape is:

```json
{
  "jwt": {
    "algorithm": "ES256",
    "issuer": "motif-auth",
    "audience": "motif-rendezvous",
    "verification_key": "jwt-public.pem"
  },
  "free_issuer": {
    "signing_key": "../issuer/jwt-private.pem",
    "access_ttl_secs": 604800,
    "refresh_ttl_secs": 31536000
  },
  "plans": {
    "free": {
      "per_user": {
        "upload_bytes_per_sec": 1048576,
        "download_bytes_per_sec": 5242880
      },
      "total": {
        "upload_bytes_per_sec": 104857600,
        "download_bytes_per_sec": 524288000
      }
    }
  },
  "users": {
    "existing-owner": {
      "client_to_server_bytes_per_sec": 1048576,
      "server_to_client_bytes_per_sec": 5242880,
      "burst_bytes": 262144
    }
  }
}
```

Key paths are resolved relative to the JSON file. The checked-out deployment
layout is therefore:

- `deploy/rendezvous/secrets/relay/auth.json`
- `deploy/rendezvous/secrets/relay/jwt-public.pem`
- `deploy/rendezvous/secrets/issuer/jwt-private.pem`

For ES256, the online signing key must use unencrypted PKCS#8 PEM (`BEGIN
PRIVATE KEY`); keep it mode `0600`. The public key and existing signatures do
not change when converting an SEC1 key with `openssl pkcs8 -topk8 -nocrypt`.

`plans.free.per_user` is shared by all simultaneous connections belonging to
one installation. `plans.free.total` is one global bucket shared by every Free
installation and connection. Upload means client→motifd; download means
motifd→client. There is intentionally no connection-count setting. Burst
capacity for plans is derived internally as one second of bandwidth.

The `users` object remains supported for old manually issued JWTs. Those JWTs
do not need a `plan` claim and continue to use the legacy rate shape. Unknown
subjects/plans are rejected, and bandwidth values in JWT claims are ignored.
Additional plans such as `pro` or `team` use the same `per_user`/optional
`total` shape; a trusted external issuer selects them with the JWT `plan`
claim. The built-in anonymous token endpoints issue only `plan=free`.

Supported algorithms are `HS256`, `RS256`, `ES256`, and `EdDSA`; asymmetric
signing is recommended. JWTs must contain valid `iss`, `aud`, `exp`, and `sub`
claims.

## Free client credentials

When `free_issuer` is configured, Rvz also exposes two HTTP endpoints on the
same HTTPS origin:

- `POST /v1/free/installations` creates an anonymous installation and returns
  an access JWT plus refresh JWT.
- `POST /v1/free/token` accepts the refresh JWT as `Authorization: Bearer ...`,
  rotates it, and returns a new access JWT.

The Flutter app stores both in the system credential vault. It refreshes the
access JWT 24 hours before expiry and updates the running motifd Relay pumps
without restarting active sessions. The defaults above make access JWTs valid
for 7 days and refresh JWTs valid for 365 days. Change `access_ttl_secs` and
`refresh_ttl_secs` to tune expiry; both must be positive.

These are in addition to the two WebSocket endpoints: `/v2/accept` (motifd,
owner JWT required) and `/v2/connect` (native client, no account JWT).

## Add or rotate an owner

The repository includes a Node.js-based helper that updates the local
`auth.json` atomically and signs an ES256 owner JWT with the local issuer key:

```sh
./deploy/rendezvous/add-user.sh user-456 \
  --client-to-server 1048576 \
  --server-to-client 5242880 \
  --burst-bytes 262144 \
  --ttl-days 30 \
  --output deploy/motifd/secrets/rendezvous/user-456.jwt
```

By default it reads:

- `deploy/rendezvous/secrets/relay/auth.json`
- `deploy/rendezvous/secrets/issuer/jwt-private.pem`

Without `--output`, the JWT is written to stdout and status messages go to
stderr. Existing users are rejected unless `--replace` is supplied. Run
`./deploy/rendezvous/add-user.sh --help` for all rate, key, and path options.

Restart Rvz after changing `auth.json`; it loads the user table only at startup.
If an existing motifd JWT file is replaced, restart motifd as well.

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

The mounted directory must contain `relay/` and `issuer/` as shown above. The
container runs as UID/GID `10001`; make the private key readable only by that
identity (for a bind mount, typically owner `10001:10001` and mode `0600`).

The image defaults to:

```text
--listen 0.0.0.0:8765
--auth-config /run/secrets/relay/auth.json
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

For a custom/self-hosted Relay, place the owner JWT in a mode-0600 file and
start motifd:

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
- The anonymous refresh credential is stateless. Rotating the issuer key
  invalidates all Free refresh tokens; individual revocation would require a
  persistent installation registry.
- WebSocket compression is disabled; keepalive uses native Ping/Pong only.
