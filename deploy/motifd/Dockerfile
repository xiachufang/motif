# syntax=docker/dockerfile:1
#
# Production/self-hosted motifd image. Unlike deploy/review/Dockerfile, this
# image embeds the Flutter Web client and keeps motif-server's default
# Tailscale support enabled. It is meant for your own server/VPS/workstation,
# not for handing a stranger a disposable sandbox.
#
# Build: docker build --platform linux/amd64 -f deploy/motifd/Dockerfile -t motifd .
# Run:   docker run -p 7777:7777 -v motifd-data:/data -v "$PWD:/work" motifd

############################  flutter web  ############################
FROM debian:bookworm-slim AS web-builder

ARG TARGETARCH
ARG FLUTTER_VERSION=stable
ENV PATH="/opt/flutter/bin:${PATH}"

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates curl git unzip xz-utils zip; \
    rm -rf /var/lib/apt/lists/*; \
    git clone --depth 1 --branch "${FLUTTER_VERSION}" https://github.com/flutter/flutter.git /opt/flutter; \
    flutter --version; \
    flutter config --enable-web; \
    flutter precache --web

WORKDIR /src
COPY apps/flutter/pubspec.yaml apps/flutter/pubspec.lock ./apps/flutter/
COPY apps/flutter/web ./apps/flutter/web
COPY apps/flutter/lib ./apps/flutter/lib
COPY apps/flutter/hook ./apps/flutter/hook
COPY apps/flutter/analysis_options.yaml ./apps/flutter/

WORKDIR /src/apps/flutter
RUN --mount=type=cache,target=/root/.pub-cache \
    flutter pub get && \
    flutter build web --no-wasm-dry-run

############################  rust builder  ############################
FROM rust:1-bookworm AS builder

ARG TARGETARCH
ARG ZIG_VERSION=0.15.2
ARG ZIG_BUILD_SEED=1
ARG GO_VERSION=1.25.5
ARG LIBGHOSTTY_VT_SYS_OPTIMIZE=ReleaseFast
ENV PATH="/usr/local/go/bin:/opt/zig:${PATH}"

RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) ZIG_ARCH=x86_64; GO_ARCH=amd64 ;; \
        arm64) ZIG_ARCH=aarch64; GO_ARCH=arm64 ;; \
        *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates curl cmake git pkg-config xz-utils; \
    rm -rf /var/lib/apt/lists/*; \
    curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz; \
    mkdir -p /opt/zig; \
    tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1; \
    rm /tmp/zig.tar.xz; \
    mv /opt/zig/zig /opt/zig/zig-real; \
    { \
      echo '#!/usr/bin/env sh'; \
      echo 'if [ "${1:-}" = "build" ]; then'; \
      echo '  shift'; \
      echo "  exec /opt/zig/zig-real build --seed ${ZIG_BUILD_SEED} \"\$@\""; \
      echo 'fi'; \
      echo 'exec /opt/zig/zig-real "$@"'; \
    } > /opt/zig/zig; \
    chmod 0755 /opt/zig/zig; \
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${GO_ARCH}.tar.gz" -o /tmp/go.tar.gz; \
    rm -rf /usr/local/go; \
    tar -C /usr/local -xzf /tmp/go.tar.gz; \
    rm /tmp/go.tar.gz; \
    zig version; \
    go version

WORKDIR /src
COPY . .
COPY --from=web-builder /src/apps/flutter/build/web ./apps/flutter/build/web

# apps/flutter is a Flutter project, not a Cargo package. In Docker contexts we
# keep apps/ so motif-server can embed build/web, but Cargo's workspace glob
# would still try to resolve apps/* as workspace members. Drop that glob for
# this container build only.
RUN sed -i 's#, *"apps/\*"##' Cargo.toml && ! grep -q '"apps/\*"' Cargo.toml

RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/src/target \
    set -eux; \
    LIBGHOSTTY_VT_SYS_OPTIMIZE="${LIBGHOSTTY_VT_SYS_OPTIMIZE}" cargo build --release -p motif-server --bin motifd; \
    cp /src/target/release/motifd /usr/local/bin/motifd; \
    strip /usr/local/bin/motifd || true

############################  runtime  ############################
FROM debian:bookworm-slim AS runtime

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      bash ca-certificates git less openssh-client tini; \
    rm -rf /var/lib/apt/lists/*; \
    groupadd -g 10001 motif; \
    useradd -m -u 10001 -g 10001 -s /bin/bash motif; \
    mkdir -p /data /work /run/secrets; \
    chown -R motif:motif /data /work /run/secrets

COPY --from=builder /usr/local/bin/motifd /usr/local/bin/motifd
COPY deploy/motifd/entrypoint.sh /usr/local/bin/motifd-entrypoint
RUN chmod 0755 /usr/local/bin/motifd /usr/local/bin/motifd-entrypoint

ENV HOME=/home/motif \
    SHELL=/bin/bash \
    XDG_DATA_HOME=/data \
    MOTIFD_LISTEN=0.0.0.0:7777 \
    MOTIFD_LOG=info

EXPOSE 7777
VOLUME ["/data", "/work"]
USER motif
WORKDIR /work

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/motifd-entrypoint"]
