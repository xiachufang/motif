# motif-push-relay

The author-operated APNs push relay for Motif. It holds the APNs `.p8` signing
keys (which must **never** ship in `motifd` or the iOS app), signs ES256
provider JWTs, and forwards motifd's **encrypted** notification payloads to
Apple over HTTP/2.

It only ever sees ciphertext — notification content is end-to-end encrypted
between motifd and the device's Notification Service Extension. The relay never
gets the per-device key.

## Prerequisites (Apple Developer portal)

1. App ID `io.allsunday.motif` with **Push Notifications** enabled.
2. Two **APNs Auth Keys** (`.p8`, "Apple Push Notifications service"): one for
   sandbox sends and one for production sends. Note each **Key ID** and the
   shared **Team ID**. Keep the `.p8` files secret — they live only here.

## Run

```sh
cargo run -p motif-push-relay -- \
  --apns-sandbox-key-path /secure/AuthKey_SANDBOXK1.p8 \
  --apns-sandbox-key-id SANDBOXK1 \
  --apns-production-key-path /secure/AuthKey_PRODKEY22.p8 \
  --apns-production-key-id PRODKEY22 \
  --apns-team-id UWNR93L682 \
  --apns-topic io.allsunday.motif \
  --listen 127.0.0.1:8088
```

All flags also read from env (`APNS_SANDBOX_KEY_PATH`,
`APNS_SANDBOX_KEY_ID`, `APNS_PRODUCTION_KEY_PATH`,
`APNS_PRODUCTION_KEY_ID`, `APNS_TEAM_ID`, `APNS_TOPIC`). Both signers are
validated at startup, so a bad key fails fast.

TLS: the relay does **not** terminate TLS (same stance as motifd). Run it on
loopback / a trusted segment and front it with a TLS-terminating reverse proxy
(Caddy/nginx). Then point motifd at it:

```sh
motifd --push-relay-url https://relay.example.com/v1/push  ...
```

(motifd's client accepts `http://` too, for a local end-to-end test where both
run on the same host.)

## API

- `GET /healthz` → `ok`
- `POST /v1/push` — body sent by motifd:
  ```json
  { "device_token": "<hex>", "environment": "sandbox|production",
    "e": "<base64 ciphertext‖tag>", "n": "<base64 12-byte nonce>" }
  ```
  Responses: `200` delivered · `410 Gone` → **motifd prunes the token**
  (BadDeviceToken in every environment, or Unregistered) · `429` rate-limited ·
  `502` transient/APNs error.

The relay builds the APNs payload itself:
`{"aps":{"alert":{"body":"🔒 New notification"},"mutable-content":1,"sound":"default"}, "e":…, "n":…}`.
`mutable-content:1` is what launches the Notification Service Extension to
decrypt `e`/`n` on device; the placeholder body shows only if decryption can't
run.

## Environment routing & fallback

It sends to `api.push.apple.com` (production) with the production signer, or
`api.sandbox.push.apple.com` (sandbox) with the sandbox signer, based on the
`environment` hint. On `BadDeviceToken`, it automatically retries the other
environment using that environment's signer — so an occasional
client/entitlement mismatch self-heals. Only when the token is bad in **both**
does it return `410` to prune.

## Security

No shared auth secret with motifd by design (motifd is open-source; a baked-in
secret would just leak). Abuse is bounded by: device tokens being capabilities a
caller must already know, per-token rate limiting (`--rate-limit-per-min`,
default 30), and E2E encryption (a forged push without the device key yields
only the placeholder). For more, front the relay with an IP allowlist.
