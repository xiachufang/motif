# Throwaway motifd for App Review

A hardened, disposable motifd you can hand to Apple's App Review (or any "let a
stranger drive a terminal" demo) without exposing your host.

`motifd` is, by design, a remote shell: whoever has the bearer token can run
arbitrary commands and read any file the process can reach (the file tree
follows the PTY cwd anywhere on disk). For review you put the token in the
review notes, so treat it as public — and contain it accordingly.

## What's here

| file | role |
|------|------|
| `Dockerfile`     | builds motifd **without** bundled Tailscale (no Go needed), ships a minimal non-root runtime with a seeded demo git repo |
| `entrypoint.sh`  | seeds the writable demo workspace, then execs motifd (token-gated, no TLS) |
| `run-review.sh`  | the launcher — applies all the isolation and tears everything down on exit |

## Use

```sh
# from the repo root
deploy/review/run-review.sh --build --tunnel
```

That builds the image, starts the container locked down, opens a Cloudflare
quick tunnel, and prints a ready-to-paste review-notes block with the
`wss://…trycloudflare.com` URL and a random token. Ctrl-C tears down the
container, network, firewall rules, and shreds the token.

Without `--tunnel` it prints the local `ws://127.0.0.1:8080` and you point your
own reverse proxy / `cloudflared` at it. iOS ATS needs a **trusted-cert wss://**,
so always go through the tunnel/proxy — never the plaintext port directly.

## Isolation applied (run-review.sh)

- non-root, `--cap-drop=ALL`, `--security-opt=no-new-privileges`
- read-only rootfs; writable bits are tmpfs (`/home/demo`, `/tmp` noexec, `/run`)
- `--pids-limit`, `--memory`, `--cpus` caps
- isolated docker network + `DOCKER-USER` egress firewall: the container cannot
  reach `169.254.169.254` (cloud metadata) or any RFC1918 LAN address; public
  internet stays reachable. `--egress none` drops all outbound.
- gVisor (`runsc`) runtime used automatically if installed — recommended here

For maximum safety run this on a **dedicated throwaway VPS** so even a full
container escape only lands on a disposable box. Revoke the token (it's
single-shot per run anyway) and destroy the box after review.

## Notes

- The build downgrades `motif-server`'s forced `tailscale-bundled` dependency to
  the `tailscale` stub (compiles without Go). If upstream changes that line and
  the build then needs Go, install `golang` in the builder stage and drop the
  `sed`.
- Zig is pinned to 0.15.2 (`ZIG_VERSION` build arg) to match ghostty.
- The demo workspace (`/home/demo/work`) is a seeded git repo on tmpfs — wiped
  on exit. Nothing the reviewer types persists.
