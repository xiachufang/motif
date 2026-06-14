# syntax=docker/dockerfile:1
#
# Standalone motif rendezvous relay. The relay is a token-paired TCP byte pipe:
# motifd parks an `accept` waiter and a client `connect`s; matching tokens get
# spliced together. With motifd's default end-to-end TLS it only ever sees
# ciphertext, so the plaintext port can be exposed directly on a public host.
#
# Pure Rust — no Zig/Go/ghostty/tailscale — so this is a small, fast build.
#
# Build:  docker build -f deploy/rendezvous/Dockerfile -t motif-rendezvous .
#         (build context must be the repo root — it's a workspace member)
# Run:    docker run -d --restart=unless-stopped -p 8765:8765 motif-rendezvous

############################  builder  ############################
FROM rust:1-bookworm AS builder
WORKDIR /src
COPY . .
# apps/ (the Flutter client, not a Cargo package) is excluded from the build
# context by .dockerignore, so drop the `apps/*` workspace-members glob that
# would otherwise fail to resolve. crates/* + Cargo.lock are unaffected.
RUN sed -i 's#, *"apps/\*"##' Cargo.toml && ! grep -q '"apps/\*"' Cargo.toml
# Build just the relay (and its deps); BuildKit caches the registry + target
# dirs across runs. Copy the binary out while the cache mount is still live.
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/src/target \
    cargo build --release -p motif-rendezvous && \
    cp target/release/motif-rendezvous /usr/local/bin/motif-rendezvous

############################  runtime  ############################
FROM debian:bookworm-slim
# A glibc-dynamic binary; bookworm-slim matches the builder's libc. No extra
# packages — the relay makes no outbound TLS and reads no files.
COPY --from=builder /usr/local/bin/motif-rendezvous /usr/local/bin/

# Unprivileged; the default port (8765) is > 1024 so no capabilities needed.
USER 10001:10001
EXPOSE 8765
ENTRYPOINT ["motif-rendezvous"]
CMD ["--listen", "0.0.0.0:8765"]
