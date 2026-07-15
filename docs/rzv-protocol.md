# Motif Rendezvous WSS protocol (v2)

The rendezvous relay pairs a `motifd` accept WebSocket with a native-client
connect WebSocket. Both sides dial an external WSS endpoint; an HTTPS reverse
proxy terminates TLS and forwards WebSocket requests to Rvz over a trusted
private network. After pairing, binary messages carry the existing
client↔motifd end-to-end TLS stream. The outer WSS protects the relay JWT and
pairing token on the public network, while the inner pinned TLS keeps
application traffic opaque to both the proxy and Rvz.

There is no raw-TCP/v1 compatibility mode.

## Endpoints and authentication

- `GET /v2/accept` — motifd. The WebSocket Upgrade must contain
  `Authorization: Bearer <JWT>`.
- `GET /v2/connect` — native client. No account JWT; possession of the pairing
  PSK remains the motifd access capability.
- `GET /health` — HTTP liveness endpoint, normally exposed as HTTPS by the
  reverse proxy.

The relay validates the accept JWT's signature, `iss`, `aud`, `exp`, and `sub`.
`sub` must exist in the relay's local user-rate table. The rate table, rather
than JWT claims, is authoritative for bandwidth limits. Every connection from
the same `sub`, including different motifd instances and pairing tokens, shares
two token buckets:

- client → motifd (`client_to_server_bytes_per_sec`)
- motifd → client (`server_to_client_bytes_per_sec`)

## HELLO and pairing

The first message on either WebSocket must be a 37-byte binary HELLO:

```text
offset  size  field
0       4     magic = "MRZV"
4       1     version = 2
5       32    token
```

The endpoint path defines the role, so the role byte from v1 no longer exists.
The token remains:

```text
HKDF-SHA256(psk, salt = 32 zero bytes, info = "motif-rzv-token-v1")[0..32]
```

An accept and connect with equal tokens are paired. The relay sends each side a
one-byte binary message `0x10` (`PAIRED`). Application bytes must not be sent
before `PAIRED`; afterwards every binary-message payload is an ordered slice of
the inner TLS byte stream.

Text messages are protocol errors. WebSocket message boundaries have no
application meaning: receivers concatenate binary payloads into a byte stream.
Per-message compression is disabled because the payload is already TLS
ciphertext.

## Keepalive and lifecycle

Keepalive exclusively uses native WebSocket Ping/Pong control frames. The old
MRZV `0x01`/`0x02` PING/PONG application bytes do not exist in v2.

motifd keeps a configurable pool of `/v2/accept` WebSockets parked at the relay
and replaces each one after pairing. A client opens one `/v2/connect`
WebSocket per logical HTTP/WebSocket connection exposed through its loopback
forwarder. Parked connections are removed after `--park-ttl-secs`; WSS closure
or failed Ping/Pong also releases them.

## Pairing URI and inner TLS

The QR remains a `motif://pair` URI carrying `rzv`, `psk`, and the motifd cert
pin `pk`. A bare `rzv=host:port` means `wss://host:port`; an explicit `wss://`
URL is also accepted.

After `PAIRED`, the client performs the existing TLS handshake with motifd over
the WebSocket byte stream and verifies `SHA-256(cert DER) == pk`. It then sends
the PSK-derived motifd bearer inside that inner TLS connection. The reverse
proxy terminates only the outer WSS. It and Rvz can observe the JWT, pairing
token, and inner ciphertext, but cannot read or forge motif application traffic.
