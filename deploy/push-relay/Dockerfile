# syntax=docker/dockerfile:1
#
# Author-operated APNs push relay image. This container holds no APNs keys by
# itself; mount the .p8 files or inject them via your container platform's
# secret mechanism at runtime.
#
# Build: docker build -f deploy/push-relay/Dockerfile -t motif-push-relay .
# Run:   docker run -p 8088:8088 ... motif-push-relay

############################  builder  ############################
FROM rust:1-bookworm AS builder
WORKDIR /src
COPY . .
# apps/ (the Flutter client, not a Cargo package) is excluded from the build
# context by .dockerignore, so drop the `apps/*` workspace-members glob that
# would otherwise fail to resolve. crates/* + Cargo.lock are unaffected.
RUN sed -i 's#, *"apps/\*"##' Cargo.toml && ! grep -q '"apps/\*"' Cargo.toml
# Build just the push relay (and its deps); BuildKit caches the registry +
# target dirs across runs. Copy the binary out while the cache mount is live.
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/src/target \
    cargo build --release -p motif-push-relay && \
    cp target/release/motif-push-relay /usr/local/bin/motif-push-relay

############################  runtime  ############################
FROM debian:bookworm-slim
COPY --from=builder /usr/local/bin/motif-push-relay /usr/local/bin/

# Unprivileged; the default port (8088) is > 1024 so no capabilities needed.
# Mounted APNs keys must be readable by this uid, or override --user at runtime.
USER 10001:10001
EXPOSE 8088

ENTRYPOINT ["motif-push-relay"]
CMD ["--listen", "0.0.0.0:8088"]
