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
5       1     role (0 = accept, 1 = connect)
6       32    token
```

## Pairing & control bytes

Before pairing, the relay may exchange single control bytes with a parked side.
These are valid **only** in the pre-pairing window:

```
0x01  PING    relay → waiter   (keepalive so middleboxes don't drop idle parks)
0x02  PONG    waiter → relay   (keepalive ack)
0x10  PAIRED  relay → both     (sent once to each side at pairing)
```

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

Trust is established separately by the layer above:

- **Today**: plaintext over the relay (no E2E) — the token finds the peer; the
  one-way derivation only keeps the `psk` off the wire.
- **Next (P2)**: TLS over the relayed pipe; the client pins `motifd`'s identity
  public key (`pk`), delivered out-of-band via the pairing QR (see below). This
  defeats both the relay and anyone who guesses/squats the token.

## Pairing QR / deep link

First-time pairing is bootstrapped by a `motif://pair` URI that `motifd`
renders as a QR (client scans it). One-time / short-lived.

```
motif://pair?v=1
  &rzv=<relay host:port>      required
  &psk=<base64url 32 bytes>   required — pairing secret
  &pk=<base64url 32 bytes>    optional in P1, required in P2 — motifd identity key
  &name=<display name>        optional
  &id=<instance id>           optional
```

`psk`/`pk` are base64url (URL-safe alphabet, padding optional).

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
