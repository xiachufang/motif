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
│                        embeds the Flutter Web client via rust-embed
├─ motif-cast            "cast my terminal to motifd" one-shot
├─ motif-client          shared client transport (HTTP + WS)
├─ motif-proto           wire types — JSON-RPC envelopes, events, RPC schemas
├─ motif-net             low-level net helpers (TLS, framing, SSH/tsnet dial)
└─ motif-tailscale       tsnet integration so motifd can join a tailnet

apps/
└─ flutter               Flutter client for iOS, macOS, Android, Web, Linux, Windows;
                         desktop builds can run an embedded motifd in-process,
                         controlled from the system tray (crates/motif-embed)

docs/                    architecture + protocol
├─ usage.md              how to use Motif as a remote server or local desktop server
├─ prd.md                product / architecture
├─ rpc.md                JSON-RPC method + event catalog (TUI and web share it)
├─ web-client.md         web SPA details
├─ shell-integration.md  prompt / command block markers (OSC 133 + 777)
├─ tailscale.md          tsnet wiring
├─ ssh-tunnel.md         `motif-tui --via ssh://…`
└─ review-server.md      hardened no-tailscale motifd for App Review (image + VPS deploy)

deploy/
├─ motifd/               production/self-hosted motifd Docker image (GHCR)
├─ rendezvous/           motif-rendezvous relay image
└─ review/               hardened disposable motifd image for App Review
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
# Flutter Web — built separately, then embedded by motif-server's build.rs.
cd apps/flutter
flutter pub get
flutter build web --no-wasm-dry-run
cd ../..

# Rust binaries (motifd / motif-cast / motif-push-relay)
cargo build --release                   # motif-server picks up apps/flutter/build/web
```

`crates/motif-server/build.rs` copies `apps/flutter/build/web/` into a
`static/` dir, which `rust-embed` bakes into the `motifd` binary. If the Flutter
Web build does not exist, build.rs writes a placeholder index.html so
`cargo build` still works.

### Release artifacts

The root `Makefile` is the release entry point:

```bash
make deps
make release-flutter-web
make release-macos       # Rust + Flutter macOS artifacts
make release-linux       # Rust + Flutter Linux artifacts
make release-windows     # Rust + Flutter Windows artifacts
```

Artifacts are written to `dist/release/`. Platform-specific targets are meant for
a CI matrix: each host builds its own artifact and fails fast if it is run on the
wrong OS. Mobile targets intentionally fail early if Android is still using debug
signing or iOS is still configured with development APNs entitlements.

## Run

Motif has two normal usage modes:

- **Run on a server**: start `motifd` as a daemon on a VPS/dev box, then attach
  from the Flutter app or browser.
- **Run on a computer**: use the desktop Flutter app's embedded `motifd`, managed
  from the Server view or system tray.

See [`docs/usage.md`](docs/usage.md) for the full guide, including Direct,
SSH, Tailscale, and rendezvous-pairing connection paths.

Docker image:

```bash
docker run -d --name motifd --restart=unless-stopped \
  -p 7777:7777 \
  -v motifd-data:/data \
  -v "$PWD:/work" \
  -e MOTIFD_TOKEN="$(openssl rand -base64 32)" \
  ghcr.io/<owner>/motifd:latest
```

See [`deploy/motifd/README.md`](deploy/motifd/README.md) for image tags,
configuration, GHCR publishing details, and the currently published platform.

```bash
# Server (insecure-no-auth is for local dev)
./target/release/motifd --listen 0.0.0.0:7777 --insecure-no-auth

# Browser — open http://localhost:7777; the embedded Flutter Web client
# auto-configures itself to the motifd origin on first launch.
```

For deployments behind a TLS terminator or on a tailnet, see
[`docs/tailscale.md`](docs/tailscale.md) and the `motifd --help` flags.

## Dev mode

Two Procfiles (run with `overmind start -f <file>` / `foreman start -f <file>`):

**`Procfile.watch`** — fast iteration. motifd + relay under `cargo watch`
(auto-rebuild on Rust changes) plus the Flutter web-server:

```
motifd: cargo watch ... -x "run -p motif-server --bin motifd -- --listen 0.0.0.0:7777 --insecure-no-auth --tailscale ..."
relay:  cargo watch -w crates/motif-push-relay -x "run -p motif-push-relay -- ..."
web-dev: cd apps/flutter && flutter run -d web-server --web-hostname 0.0.0.0 --web-port 5173
```

Browsing `http://localhost:5173/` gives you Flutter hot reload. Add
`127.0.0.1:7777` as a direct server in that dev UI, or use motifd's own
`http://localhost:7777/` to exercise the embedded snapshot from the last
`flutter build web --no-wasm-dry-run`.

**`Procfile.dev`** — no `cargo watch`. Runs
`flutter build web --no-wasm-dry-run` first, then `cargo run` motifd (whose
`build.rs` embeds the freshly-built
`apps/flutter/build/web`), so `http://localhost:7777/` serves the current web —
the same path a release binary takes. No hot reload: restart the Procfile to pick
up changes.
Use this to exercise the real embedded `:7777` path (and to avoid the session/
device-registration churn that `cargo watch` restarts cause).

## License

MIT OR Apache-2.0.
