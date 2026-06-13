# syntax=docker/dockerfile:1
#
# Hardened, throwaway motifd image for App Review (and any "hand a stranger a
# shell" demo). It builds motifd with `--no-default-features`, which drops
# motif-server's `tailscale` feature entirely (no motif-tailscale, no Go
# libtailscale linked): the review server is fronted by a reverse proxy /
# Cloudflare Tunnel, so the tailnet transport isn't needed or wanted. As a
# result the builder needs only Rust + Zig, not Go.
#
# motifd itself does NOT terminate TLS — run this behind your VPS reverse proxy
# or `cloudflared tunnel`, which gives the iOS client a trusted wss:// endpoint.
#
# Build:  docker build -f deploy/review/Dockerfile -t motifd:review .
#         (build context must be the repo root)
#
# Run:    deploy/review/run-review.sh   (do NOT `docker run` by hand — the
#         launcher applies the cap-drop / read-only / network-isolation that
#         makes exposing a remote shell survivable)

############################  builder  ############################
FROM rust:1-bookworm AS builder

# Zig 0.15.2 — pinned by ghostty; libghostty-vt's build.rs compiles the VT
# engine from source with it. On Linux the official tarball links fine (the
# Tahoe libSystem problem is macOS-only). Note the 0.15 naming order: <arch>-<os>.
# TARGETARCH (amd64/arm64, provided by BuildKit) -> zig arch (x86_64/aarch64) so
# the image builds natively on both an x86_64 VPS and an Apple-Silicon laptop.
ARG TARGETARCH
ARG ZIG_VERSION=0.15.2
RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) ZIG_ARCH=x86_64 ;; \
        arm64) ZIG_ARCH=aarch64 ;; \
        *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    apt-get update; \
    apt-get install -y --no-install-recommends cmake pkg-config xz-utils ca-certificates; \
    rm -rf /var/lib/apt/lists/*; \
    curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz; \
    mkdir -p /opt/zig; \
    tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1; \
    rm /tmp/zig.tar.xz; \
    /opt/zig/zig version
ENV PATH="/opt/zig:${PATH}"

WORKDIR /src
COPY . .

# Drop the `apps/*` workspace-members glob. apps/ holds only the Flutter client
# (already `exclude`d from the workspace and pruned by .dockerignore), so it
# contributes no Cargo crates — but the bare glob makes cargo fail to resolve
# the workspace once apps/ is absent from the build context. Removing it is a
# no-op for what builds here.
RUN sed -i 's#, *"apps/\*"##' Cargo.toml \
 && ! grep -q '"apps/\*"' Cargo.toml

# Only the server binary, and `--no-default-features` so motif-server links no
# tailscale (motif-tailscale) at all — that's what keeps the builder Go-free.
# motif-server/build.rs embeds apps/flutter/build/web if present; it's absent
# here, so the binary ships without the web client — fine, the iOS app talks the
# RPC/WS protocol directly.
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/src/target \
    cargo build --release -p motif-server --bin motifd --no-default-features \
 && cp /src/target/release/motifd /usr/local/bin/motifd \
 && strip /usr/local/bin/motifd || true

############################  runtime  ############################
FROM debian:bookworm-slim AS runtime

# Runtime needs: a shell for PTYs (bash), git (motifd shells out for diff/status),
# tini as PID 1 so reaped PTY children don't zombie, ca-certificates for any
# outbound TLS the demo shell attempts. Deliberately minimal — remember the file
# tree follows the PTY cwd "anywhere on disk", so the smaller the image, the less
# a token holder can read.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends bash git ca-certificates tini less; \
    rm -rf /var/lib/apt/lists/*

# Unprivileged user. uid/gid 10001 so it never collides with a host user.
RUN groupadd -g 10001 demo && useradd -m -u 10001 -g 10001 -s /bin/bash demo

# A read-only seed for the demo workspace. entrypoint.sh copies it into the
# (writable tmpfs) /home/demo/work at start, so the rootfs can stay read-only
# while the reviewer still gets a working, editable git repo.
RUN set -eux; \
    mkdir -p /opt/demo-seed; \
    printf '# Motif demo workspace\n\nThis is a throwaway sandbox for App Review.\nOpen a terminal, browse the tree, edit a file, and check the git diff.\n' > /opt/demo-seed/README.md; \
    printf 'fn main() {\n    println!("hello from motif");\n}\n' > /opt/demo-seed/main.rs; \
    git -C /opt/demo-seed -c init.defaultBranch=main init -q; \
    git -C /opt/demo-seed -c user.email=demo@motif.local -c user.name=demo add -A; \
    git -C /opt/demo-seed -c user.email=demo@motif.local -c user.name=demo commit -q -m "seed demo workspace"; \
    printf '\n// reviewer: this uncommitted line shows up in git diff\n' >> /opt/demo-seed/main.rs; \
    chown -R demo:demo /opt/demo-seed

COPY --from=builder /usr/local/bin/motifd /usr/local/bin/motifd
COPY deploy/review/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/motifd

ENV SHELL=/bin/bash \
    HOME=/home/demo \
    MOTIFD_LOG=info \
    MOTIFD_TOKEN_FILE=/run/secrets/motifd_token \
    MOTIFD_LISTEN=0.0.0.0:8080
EXPOSE 8080
USER demo
# WORKDIR is /home/demo, not /home/demo/work: at runtime /home/demo is a fresh
# tmpfs (see run-review.sh), so /home/demo/work does not exist yet when the
# process starts — entrypoint.sh creates and seeds it. Pointing WORKDIR at the
# tmpfs mountpoint itself (always present) avoids a chdir-on-start failure.
WORKDIR /home/demo

# tini reaps zombies; entrypoint seeds the workspace then execs motifd.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
