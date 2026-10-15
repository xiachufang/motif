# motif rendezvous relay

A self-hostable WebSocket relay for reaching motifd instances behind NAT. An
external HTTPS reverse proxy exposes it as WSS. motifd and native clients both
dial out; the relay pairs their WebSockets by an opaque token and forwards
binary messages containing the existing end-to-end TLS stream.

motifd authenticates its owner with a JWT in the `/v2/accept` WebSocket
Upgrade. Native clients use `/v2/connect` and do not need an account JWT.
Auto-managed Free JWTs carry `sub=<installation id>` and `plan=free`. Older
JWTs without a `plan` claim remain valid and are treated as Free.

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
      "per_installation": {
        "upload_bytes_per_sec": 1048576,
        "download_bytes_per_sec": 5242880
      },
      "total": {
        "upload_bytes_per_sec": 104857600,
        "download_bytes_per_sec": 524288000
      }
    },
    "pro": {
      "per_installation": {
        "upload_bytes_per_sec": 5242880,
        "download_bytes_per_sec": 5242880
      }
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

`plans.free.per_installation` is shared by all simultaneous connections
belonging to one installation. `plans.free.total` is one global bucket shared
by every Free installation and connection. Upload means client→motifd;
download means motifd→client. There is intentionally no users table and no
connection-count setting. Burst capacity is derived as one second of bandwidth.

Additional plans use the same `per_installation`/optional `total` shape. A
trusted issuer selects one with the JWT `plan` claim. Unknown plans are
rejected, while an old JWT with no `plan` uses Free. The built-in anonymous
token endpoints issue only `plan=free`; `add-user.sh` defaults to `plan=pro`.

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

The repository includes a Node.js-based helper that signs an ES256 owner JWT
with the local issuer key. It defaults to the configured `pro` plan:

```sh
./deploy/rendezvous/add-user.sh user-456 \
  --ttl-days 30 \
  --output deploy/motifd/secrets/rendezvous/user-456.jwt
```

By default it reads:

- `deploy/rendezvous/secrets/relay/auth.json`
- `deploy/rendezvous/secrets/issuer/jwt-private.pem`

Without `--output`, the JWT is written to stdout and status messages go to
stderr. Use `--plan NAME` to select another configured plan and `--replace` to
overwrite an existing output file. The script validates `auth.json` but does
not modify it because Rvz has no subject records. Run
`./deploy/rendezvous/add-user.sh --help` for all options.

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

## Logs and connection diagnostics

Rvz writes logs to stdout; it does not create a log file. With Docker, use
`docker logs --timestamps --since 30m motif-rzv`; with the systemd unit below,
use `journalctl -u motif-rendezvous --since '30 minutes ago'`.

The default level is `info`. Set `RUST_LOG=debug` (or
`RUST_LOG=info,motif_rendezvous=debug`) in the service environment for more
detail. Connection lifecycle events remain visible at the default level:

- `websocket upgrade requested` / `websocket connected`: a request reached Rvz
  and its WebSocket opened. `role=Accept` is motifd; `role=Connect` is a client.
- `waiting for peer`: HELLO was accepted; the queue counts show whether motifd
  or the client is missing for that pairing token.
- `peer matched` / `paired; forwarding started`: both endpoints were found and
  Rvz delivered `PAIRED` to both. Inner TLS and Motif requests happen afterward.
- `forwarding finished` / `forwarding failed`: the direction, byte count,
  elapsed time, close code (when present), and error identify which half ended.
  Each direction logs immediately, even if the other half is still open.
- HELLO, upgrade, authentication, and keepalive failures are warnings.

`connection_id` identifies one WebSocket within a process. Pair logs include
both `accept_connection_id` and `connect_connection_id`, so their earlier
events can be correlated. Logs exclude JWTs, pairing tokens, and payloads.
The `/health` endpoint and the Docker healthcheck only establish listener
liveness; they do not prove that pairing, inner TLS, or Codex is working.

For an incident, compare client and motifd timestamps with these Rvz events
and the HTTPS proxy's access/error logs. A client dial timeout with no matching
Rvz upgrade request points to the path before Rvz. A waiting `Connect` without
an `Accept` points to motifd's relay connection. Successful pairing followed
by a TLS/HTTP failure needs the motifd-side logs as well.

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

Device correlation: updated Motif clients send an optional `X-Motif-Device-Id`
Upgrade header. Client installations persist a random `app_<32 hex digits>` ID;
`motifd` uses `cert_<64 hex digits>` from its persisted public TLS certificate
fingerprint. IDs survive reconnects and process restarts. Clearing client app
storage or replacing the server certificate changes the corresponding ID.
Connection logs include `device_id`; pair/forwarding logs include
`accept_device_id` (motifd) and `connect_device_id` (client). These are diagnostic,
self-reported identifiers, not authenticated device identities. The owner JWT
`subject` is recorded separately on the connection span.

Older clients without this header appear as `unknown`. Invalid metadata (over
80 bytes or characters other than ASCII letters, digits, `_`, `-`) is ignored
without rejecting the connection. HELLO and pairing are unchanged; new clients
also work with older relays. Both the relay and the corresponding Motif client /
motifd need updating to obtain device IDs. No pairing secrets or hardware IDs
are used as diagnostic identifiers.
