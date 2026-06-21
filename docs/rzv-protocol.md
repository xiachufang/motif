# Motif Rendezvous (rzv) relay protocol

The rendezvous relay lets a `motifd` server and a client reach each other when
neither has a public address, **without** trusting the relay. Both sides dial
**out** to the relay; the relay pairs them by a shared token and then becomes a
dumb byte pipe. All confidentiality/authenticity lives in a layer **above** the
relay (TLS/WebSocket), so the relay only ever sees ciphertext.

This is the shared contract between:

- the Flutter/Dart client — `apps/flutter/lib/motif/net/rzv/`
- the Rust relay server — `crates/motif-rendezvous/` (to be built)
- the Rust `motif-net` rzv backend on `motifd`

Keep all three in lockstep with this file.

## Roles

- **accept** (`role = 0`) — `motifd`. Parks one or more idle connections at the
  relay, each waiting to be paired. After one of its parked connections is
  paired away, `motifd` immediately parks a fresh one, so it can serve an
  unbounded number of clients over time while the relay stays dumb.
- **connect** (`role = 1`) — the client. Dials in on demand, once per logical
  connection (each PTY / events / RPC stream is its own dial in P1).
- **health** (`role = 2`) — a liveness probe (token ignored). The relay replies
  `HEALTH_OK` (`0x20`) and closes; the connection is never parked or paired, so
  it leaves no state. Used by the image's `HEALTHCHECK` and the
  `motif-rendezvous healthcheck` subcommand.

The relay only ever pairs an `accept` with a `connect` bearing the same token —
never accept↔accept or connect↔connect. This is the one difference from the
original magic-wormhole transit relay (which is role-less); roles prevent two
clients from mis-pairing with each other under a shared server token.

## HELLO frame

The first bytes each side writes after the TCP connect. Fixed length, 38 bytes:

```
offset  size  field
0       4     magic = "MRZV" (0x4D 0x52 0x5A 0x56)
4       1     version = 1
5       1     role (0 = accept, 1 = connect, 2 = health)
6       32    token (ignored for role = health)
```

## Pairing & control bytes

Before pairing, the relay may exchange single control bytes with a parked side.
These are valid **only** in the pre-pairing window:

```
0x01  PING      relay → waiter  (keepalive so middleboxes don't drop idle parks)
0x02  PONG      waiter → relay  (keepalive ack)
0x10  PAIRED    relay → both    (sent once to each side at pairing)
0x20  HEALTH_OK relay → health  (reply to a role = health HELLO, then close)
```

### Keepalive

While a waiter is parked (no partner yet), the relay sends `PING` (`0x01`) once
the instant it parks — so a proxy that resets a connection whose server stays
silent sees the server "speak" immediately — and then every keepalive interval
(`--keepalive-secs`, default 15s). The waiter answers each with `PONG` (`0x02`).
This keeps the idle connection active so NATs / L7 proxies / load balancers on
the waiter's path don't reap it before it pairs. Both `motifd`
(`crates/motif-net/src/listener.rs`) and the Dart client
(`apps/flutter/lib/motif/net/rzv/rzv_forwarder_io.dart`) already answer `PONG`.

At pairing the relay stops pinging and **drains any `PONG` still owed** for
PINGs it already sent before it starts copying bytes, so no stray `0x02` leaks
into the transparent stream. (Only the parked socket carries this chatter; the
second party found a waiter and never parked, so its stream is clean.)

### Pairing

When two opposite-role connections with the same token are present, the relay
sends `PAIRED` (`0x10`) to **both** and from then on copies bytes verbatim in
both directions. **After `PAIRED`, no control bytes exist** — every byte is
opaque application data.

Ordering guarantee the implementations rely on: neither application end writes
any application bytes until it has observed `PAIRED`. The client (connect side)
sends its first real bytes (the TLS/WebSocket handshake) only after `PAIRED`;
`motifd` (accept side) likewise stays silent until it receives them. This means
a reader can consume control bytes one at a time up to and including `PAIRED`
without ever swallowing application data.

## Token

The token is a **capability to meet**, not an authentication. It is derived
**one-way** from the 32-byte pairing secret (`psk`) so the relay — which sees
the token — never learns the secret. The secret is the durable value reserved
for the end-to-end layer; it must never appear on the wire.

```
token = HKDF-SHA256(ikm = psk, salt = "" (32 zero bytes), info = "motif-rzv-token-v1")[0..32]
```

Since `L == HashLen`, this is a single HMAC block:
`token = HMAC-SHA256(HMAC-SHA256(0^32, psk), "motif-rzv-token-v1" | 0x01)`.

Reference implementations (kept byte-identical):
`motif_server::rzv::derive_token` (Rust) and `RzvProtocol.deriveToken` (Dart).
Cross-language fixture: `psk = bytes 0..31` ⇒
`token = bb48b13937710e30c1fffa843593313a7d403c44236eb01d6c86842e43bfa7da`.

Future refinement: rotate by binding a coarse epoch into `info` (motifd would
park under adjacent epochs to cover the boundary); not yet implemented.

Trust and access are established separately by the layer above:

- **Encryption + server auth**: end-to-end TLS over the relayed pipe; the client
  pins `motifd`'s cert (`pk`), delivered out-of-band via the pairing QR. The
  relay sees only ciphertext, defeating both the relay and anyone who squats the
  token. This is always on (there is no plaintext-relay mode).
- **Client access**: a bearer derived from `psk` under a distinct HKDF label
  (`motif-auth-bearer-v1`, vs the relay token's `motif-rzv-token-v1`). motifd
  requires it; the client derives the same value from the QR's `psk` and sends
  it inside the TLS channel. So "having the QR" is the single capability — the
  relay never sees the bearer.

## Pairing QR / deep link

First-time pairing is bootstrapped by a single `motif://pair` URI that `motifd`
renders as a QR (client scans it). A server has exactly **one** QR at a time;
the client routes by content. Two forms:

```
# rzv form (relay set): reach motifd through the relay
motif://pair?v=1
  &rzv=<relay host:port>      selects the rzv path
  &psk=<base64url 32 bytes>   pairing secret (→ relay token + access bearer)
  &pk=<base64url 32 bytes>    SHA-256 of motifd's self-signed cert DER (the pin)
  &name=<display name>        optional

# direct form (no relay): reach motifd directly on the LAN/public address
motif://pair?v=1
  &host=<ip1,ip2,…>           comma-separated NIC/advertised hosts to probe
  &port=<port>                motifd's direct port
  &psk=<base64url 32 bytes>   pairing secret (→ access bearer)
  &pk=<base64url 32 bytes>    cert pin
  &name=<display name>        optional
```

`psk`/`pk` are base64url (URL-safe alphabet, padding optional). The absence of
`rzv` is what routes the client to the direct path; it probes `host` candidates
over TLS (pinned by `pk`) and dials whichever is reachable.

**End-to-end TLS (when `pk` is present).** motifd terminates a TLS handshake on
its `accept` side of the relayed pipe using a persisted self-signed identity
cert; the relay only forwards ciphertext. The client, after `PAIRED`, performs a
TLS handshake to motifd and **pins** the presented leaf cert by checking
`SHA-256(cert DER) == pk` from the QR (hostname verification is irrelevant and
disabled). This defeats both the relay and anyone who squats the token: without
motifd's actual cert the handshake the client accepts cannot be produced.
Reference: `motif_server::rzv::load_or_create_identity` (Rust server),
`crates/motif-net` `park_accept` TLS branch, and the pinning client in
`crates/motif-net/tests/rzv_tls.rs`. The same identity (and thus the same `pk`)
backs the direct `--listen` path, so the pin matches whichever way a client
reaches motifd.

## Lifecycle (P1)

```
motifd:  pool of accept-parks held open at the relay (re-park after each pairing)
client:  per logical connection → dial relay → HELLO(connect) → await PAIRED →
         speak HTTP/WS to motifd through the now-transparent pipe
```

On the Flutter client, P1 realises the connect side as a loopback forwarder:
`RzvForwarder` binds `127.0.0.1:<ephemeral>` and runs the handshake per inbound
local connection, so the existing WebSocket/HTTP transport connects to
`http://127.0.0.1:<port>` exactly as it would to a direct server.
