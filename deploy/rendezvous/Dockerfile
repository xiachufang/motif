# syntax=docker/dockerfile:1
#
# Standalone authenticated WebSocket rendezvous relay. An external HTTPS proxy
# terminates WSS; the JWT/rate configuration is mounted read-only.
#
# Pure Rust — no Zig/Go/ghostty/tailscale — so this is a small, fast build.
#
# Build:  docker build -f deploy/rendezvous/Dockerfile -t motif-rendezvous .
#         (build context must be the repo root — it's a workspace member)
# Run:    docker run -d -p 8765:8765 -v /etc/motif-rzv:/run/secrets:ro motif-rendezvous

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
# A glibc-dynamic binary; bookworm-slim matches the builder's libc.
COPY --from=builder /usr/local/bin/motif-rendezvous /usr/local/bin/

# Unprivileged; the default port (8765) is > 1024 so no capabilities needed.
USER 10001:10001
EXPOSE 8765

# Liveness via the binary's own probe — no nc/curl/python in the slim runtime.
# The protocol pairing path is covered by Rust integration tests; the runtime
# healthcheck verifies that the internal WebSocket listener remains bound.
HEALTHCHECK --interval=30s --timeout=5s --start-period=3s --retries=3 \
    CMD ["motif-rendezvous", "healthcheck", "--addr", "127.0.0.1:8765"]

ENTRYPOINT ["motif-rendezvous"]
CMD ["--listen", "0.0.0.0:8765", "--auth-config", "/run/secrets/auth.json"]
