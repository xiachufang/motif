# motif

A remote dev agent in the spirit of code-server + `tmux attach`: a long-lived
**Session** on a host (workdir + PTY pool + git + file ops) that multiple
lightweight clients can attach to and see *completely mirrored* — same file
tree, same terminals, same diff. v1 is single-user, no LLM.

See [`docs/prd.md`](docs/prd.md) for the full design.

## Layout

```
crates/                  Rust workspace
├─ motif-server          motifd: HTTP /rpc + WS /events + WS /pty/<id>;
│                        embeds the React SPA via rust-embed
├─ motif-tui             ratatui terminal client (reference client)
├─ motif-cast            "cast my terminal to motifd" one-shot
├─ motif-client          shared client transport (HTTP + WS)
├─ motif-proto           wire types — JSON-RPC envelopes, events, RPC schemas
├─ motif-net             low-level net helpers (TLS, framing, SSH/tsnet dial)
└─ motif-tailscale       tsnet integration so motifd can join a tailnet

apps/
├─ web                   React 19 + Vite SPA (browser client, embedded into motifd)
├─ ios                   Swift / SwiftUI iOS app (WKWebView + native panels)
└─ menubar               Tauri menu-bar shell that runs an embedded motifd

docs/                    architecture + protocol
├─ prd.md                product / architecture
├─ rpc.md                JSON-RPC method + event catalog (TUI and web share it)
├─ web-client.md         web SPA details
├─ shell-integration.md  prompt / command block markers (OSC 133 + 777)
├─ tailscale.md          tsnet wiring
└─ ssh-tunnel.md         `motif-tui --via ssh://…`
```

## Build

**Prerequisite (motif-server only):** `motifd` depends on `libghostty-vt`, which
builds the [ghostty](https://github.com/ghostty-org/ghostty) VT engine from source
via **Zig 0.15.2** (pinned by ghostty; 0.16 is rejected). Put a matching `zig` on
`PATH`:
- Linux: install Zig 0.15.x (official tarball works).
- macOS 26 (Tahoe): the official 0.15.x tarball can't link libSystem — use
  `brew install zig@0.15` and build with
  `PATH="/opt/homebrew/opt/zig@0.15/bin:$PATH" SDKROOT="$(xcrun --show-sdk-path)" cargo build`.
- Offline/CI: set `GHOSTTY_SOURCE_DIR` / `GHOSTTY_ZIG_SYSTEM_DIR` to vendor the
  ghostty source and Zig packages.

```bash
# Rust binaries (motifd / motif-tui / motif-cast / motif-menubar)
cargo build --release

# Web SPA — built separately, then embedded by motif-server's build.rs.
pnpm --dir apps/web install
pnpm --dir apps/web build
cargo build -p motif-server --release   # picks up apps/web/dist
```

`crates/motif-server/build.rs` copies `apps/web/dist/` into a `static/` dir,
which `rust-embed` bakes into the `motifd` binary. If `apps/web/dist` doesn't
exist, build.rs writes a placeholder index.html so `cargo build` still works.

## Run

```bash
# Server (insecure-no-auth is for local dev)
./target/release/motifd --listen 0.0.0.0:7777 --insecure-no-auth

# TUI client — auto-discovers ws://127.0.0.1:7777
./target/release/motif-tui

# Browser — open http://localhost:7777
```

For deployments behind a TLS terminator or on a tailnet, see
[`docs/tailscale.md`](docs/tailscale.md) and the `motifd --help` flags.

## Dev mode

`Procfile` runs motifd with `cargo watch` plus the Vite dev server in parallel
(`overmind start` / `foreman start`):

```
motifd: cargo watch ... -x "run -p motif-server --bin motifd -- --listen 0.0.0.0:7777 --insecure-no-auth --tailscale"
vite:   cd apps/web && pnpm dev --host 0.0.0.0 --port 5173
```

Vite proxies `/rpc`, `/events`, `/pty`, `/ping` to motifd, so browsing
`http://localhost:5173/` gives you a hot-reloading web client against the
locally running motifd.

## License

MIT OR Apache-2.0.
