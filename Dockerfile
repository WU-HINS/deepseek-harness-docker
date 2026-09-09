# syntax=docker/dockerfile:1
###############################################################################
# DeepSeek Harness — Debian-based image
#
# Provides: git, wget, curl, Node.js, Caddy (TLS + basic auth), gosu
# Runs two processes via docker-entrypoint.sh:
#   1. dsh  web server   (127.0.0.1:3080)
#   2. caddy reverse proxy  (:8443, HTTPS + basic auth) -> 127.0.0.1:3080
###############################################################################

FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# ---- System tool versions (override with --build-arg) ----
ARG NODE_MAJOR=22
ARG CADDY_VERSION=2.11.4
ARG GOSU_VERSION=1.17

# ---- Base packages: git, wget, curl ----
# Includes the full C/C++ toolchain, Python + pip, and common build headers.
# NOTE: no '#' comments are placed inside the apt argument stream, because a
# '#' in a shell-continued argument list would swallow the rest of the line.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        gnupg \
        curl \
        wget \
        git \
        openssl \
        tar \
        gzip \
        xz-utils \
        jq \
        procps \
        tzdata \
        gcc \
        g++ \
        make \
        cmake \
        ninja-build \
        pkg-config \
        autoconf \
        automake \
        libtool \
        bison \
        flex \
        binutils \
        python3 \
        python3-pip \
        python3-venv \
        python3-dev \
        python3-setuptools \
        python3-wheel \
        libffi-dev \
        libssl-dev \
        libbz2-dev \
        libreadline-dev \
        libsqlite3-dev \
        zlib1g-dev; \
    rm -rf /var/lib/apt/lists/*

# ---- Node.js (NodeSource), installed globally ----
RUN set -eux; \
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" -o /tmp/nodesource_setup.sh; \
    bash /tmp/nodesource_setup.sh; \
    apt-get install -y --no-install-recommends nodejs; \
    rm -f /tmp/nodesource_setup.sh; \
    rm -rf /var/lib/apt/lists/*

# ---- gosu (run processes as unprivileged users) ----
RUN set -eux; \
    arch="$(dpkg --print-architecture | awk -F- '{ print $NF }')"; \
    case "$arch" in \
        amd64)  gosu_arch="amd64" ;; \
        arm64)  gosu_arch="arm64" ;; \
        armhf)  gosu_arch="armhf" ;; \
        *)      echo "Unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/tianon/gosu/releases/download/${GOSU_VERSION}/gosu-${gosu_arch}" -o /usr/local/bin/gosu; \
    chmod +x /usr/local/bin/gosu

# ---- Caddy (includes caddyfile adapter + automatic local PKI) ----
RUN set -eux; \
    arch="$(dpkg --print-architecture | awk -F- '{ print $NF }')"; \
    case "$arch" in \
        amd64)  caddy_arch="amd64" ;; \
        arm64)  caddy_arch="arm64" ;; \
        armhf)  caddy_arch="armv7" ;; \
        *)      echo "Unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_${caddy_arch}.tar.gz" -o /tmp/caddy.tar.gz; \
    tar -xzf /tmp/caddy.tar.gz -C /usr/bin caddy; \
    chmod +x /usr/bin/caddy; \
    rm -f /tmp/caddy.tar.gz; \
    caddy version

# ---- Install @deepseek-ai/dsh (CLI + web UI) globally ----
# DSH_VERSION defaults to "latest"; pass --build-arg DSH_VERSION=<ver> to pin.
# When "latest", npm resolves the newest published @deepseek-ai/dsh.
ARG DSH_VERSION=latest
RUN set -eux; \
    npm install -g --unsafe-perm "@deepseek-ai/dsh@${DSH_VERSION}"; \
    npm install -g --unsafe-perm pnpm; \
    rm -rf /root/.npm; \
    dsh --version && pnpm --version

# ---- Runtime users: caddy (runs reverse proxy). dsh runs as root. ----
# Group name MUST be 'caddy': the entrypoint uses -o caddy -g caddy in install.
RUN set -eux; \
    groupadd --system --gid 1001 caddy && \
    useradd --system --uid 1001 --gid caddy --create-home --shell /usr/sbin/nologin caddy && \
    install -d -m 0700 /data/dsh /data/dsh/home && \
    install -d -m 0750 /workspace && \
    install -d -m 0700 -o caddy -g caddy /data/caddy /data/caddy/config && \
    mkdir -p /etc/caddy

# ---- Caddyfile for the TLS reverse proxy ----
COPY Caddyfile /etc/caddy/Caddyfile

# ---- Entrypoint ----
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# ---- Metadata ----
ENV DSH_HOME=/data/dsh \
    DSH_TELEMETRY_DISABLED=1 \
    HOME=/root \
    XDG_DATA_HOME=/data/caddy \
    XDG_CONFIG_HOME=/data/caddy/config

# Exposed HTTPS port (mapped in docker-compose to PANEL_APP_PORT_HTTPS)
EXPOSE 8443

VOLUME ["/data/dsh", "/data/caddy", "/workspace"]

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
