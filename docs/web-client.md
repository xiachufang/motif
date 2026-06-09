# Motif — Flutter Web Client

> Web client is the Flutter app in `apps/flutter`, built for web and served by
> `motifd` from the same origin as the protocol endpoints.

## Context

`motifd` is both the protocol server and the web host:

- HTTP RPC: `POST /rpc/<method>`
- event stream: `GET /events?session=<sid>&since=<seq>[&token=<token>]`
- PTY stream: `GET /pty/<id>?session=<sid>[&since=<cursor>][&token=<token>]`
- static Flutter Web files: `/`, `flutter_bootstrap.js`, `main.dart.js`,
  `assets/*`, `icons/*`, `canvaskit/*`, `ghostty_vt.js`, `ghostty-vt.wasm`

The browser uses the same protocol surface as native clients. The one web-only
auth difference is that browser WebSocket APIs cannot set upgrade headers, so
`motifd` accepts the bearer token in the WebSocket query string as well.

## Source Layout

```
apps/flutter/
├─ lib/main.dart
├─ lib/motif/
│  ├─ net/rpc_client.dart          HTTP RPC + /events + /pty transport
│  ├─ state/app_state.dart         persisted stores + connection lifecycle
│  ├─ state/embedded_web_server.dart
│  ├─ platform/web_launch*.dart    Web-only origin/token bootstrap
│  ├─ terminal/wasm_terminal_web.dart
│  └─ ui/
├─ web/
│  ├─ index.html
│  ├─ ghostty_vt.js
│  └─ ghostty-vt.wasm
└─ build/web/                      `flutter build web --no-wasm-dry-run` output
```

`crates/motif-server/build.rs` copies `apps/flutter/build/web` into
`crates/motif-server/static`, and `rust-embed` bakes that directory into the
`motifd` binary.

## Build And Embed

```bash
cd apps/flutter
flutter pub get
flutter build web --no-wasm-dry-run
cd ../..

cargo build -p motif-server --release
```

If `apps/flutter/build/web` is missing, `build.rs` still lets Rust compile and
embeds a small placeholder page that tells the operator to run
`flutter build web --no-wasm-dry-run`.

## Runtime Behavior

When opened from `http://host:port/` or `https://host/`, Flutter Web seeds an
initial server config only if the user has no saved servers yet:

- `host` and `port` come from the current page origin.
- `scheme` is preserved, so HTTPS deployments use `https` for RPC and `wss` for
  WebSockets.
- `?token=<value>` is read into the server config, then removed from the address
  bar with `history.replaceState`.

This is what makes a release binary work as a one-step browser client:

```bash
./target/release/motifd --listen 0.0.0.0:7777 --insecure-no-auth
# open http://localhost:7777
```

If a server list already exists in local browser storage, launch bootstrap does
not overwrite it.

## Development

For hot reload:

```bash
cd apps/flutter
flutter run -d web-server --web-hostname 0.0.0.0 --web-port 5173
```

Run `motifd` separately on `127.0.0.1:7777`, then add that address as a direct
server in the Flutter UI. For the real embedded release path, use
`Procfile.dev` or run `flutter build web --no-wasm-dry-run` followed by
`cargo run -p motif-server --bin motifd`.

## Server Routes

The axum router lives in `crates/motif-server/src/ws.rs`:

```rust
Router::new()
    .route("/", get(crate::embed::serve_index))
    .route("/ping", get(ping))
    .route("/assets/{*p}", get(crate::embed::serve_assets))
    .route("/rpc/{method}", axum::routing::post(http_rpc::rpc_dispatch))
    .route("/events", get(crate::events_ws::events_upgrade))
    .route("/pty/{pty_id}", get(crate::pty_ws::pty_upgrade))
    .fallback(crate::embed::serve_spa_fallback)
```

The fallback first serves a real embedded file when one exists, then falls back
to `index.html` for client-side routes. This matters for Flutter Web because
many runtime files live at the web root rather than under `/assets`.

## Related Docs

- [`rpc.md`](./rpc.md): method list and wire protocol.
- [`tailscale.md`](./tailscale.md): serving `motifd` over a tailnet.
- [`shell-integration.md`](./shell-integration.md): OSC markers parsed by the
  terminal clients.
