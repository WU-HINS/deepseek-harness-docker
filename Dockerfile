# syntax=docker/dockerfile:1
###############################################################################
# DeepSeek Harness - Debian-based image
#
# Provides: git, wget, curl, Node.js(+npm/pnpm), Python(+pip), full C/C++
#          toolchain, Caddy (TLS + basic auth), gosu, GitHub CLI (gh).
#
# Package mirrors: Tsinghua (TUNA) mirrors preferred for apt / npm / pip;
# every external fetch falls back to the official source if the mirror
# is unreachable, so builds keep working anywhere.
#
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
ARG GH_VERSION=latest

# ---- apt: Tsinghua (TUNA) mirrors + base packages ----
# Mirrors follow the well-known linuxmirrors.cn approach: detect whether the
# image ships deb822 (sources.list.d/debian.sources) or one-line sources,
# back up whatever exists, write TUNA sources (incl. updates/backports/
# security), then update; on failure the official Debian sources are
# restored and apt falls back to upstream.
RUN set -eux; \
    rm -rf /tmp/apt-backup; \
    mkdir -p /tmp/apt-backup; \
    if [ -f /etc/apt/sources.list ]; then cp -a /etc/apt/sources.list /tmp/apt-backup/; fi; \
    if [ -d /etc/apt/sources.list.d ]; then cp -a /etc/apt/sources.list.d /tmp/apt-backup/; fi; \
    printf '%s\n' \
        'deb https://mirrors.tuna.tsinghua.edu.cn/debian/ bookworm main contrib non-free non-free-firmware' \
        'deb https://mirrors.tuna.tsinghua.edu.cn/debian/ bookworm-updates main contrib non-free non-free-firmware' \
        'deb https://mirrors.tuna.tsinghua.edu.cn/debian/ bookworm-backports main contrib non-free non-free-firmware' \
        'deb https://mirrors.tuna.tsinghua.edu.cn/debian-security/ bookworm-security main contrib non-free non-free-firmware' \
        > /etc/apt/sources.list; \
    if ! apt-get -o Acquire::Retries=3 update; then \
        echo "TUNA mirror unreachable, restoring official Debian sources"; \
        rm -rf /etc/apt/sources.list /etc/apt/sources.list.d; \
        cp -a /tmp/apt-backup/. /etc/apt/ 2>/dev/null || true; \
        install -d /etc/apt/sources.list.d; \
        apt-get -o Acquire::Retries=3 update; \
    fi; \
    rm -rf /tmp/apt-backup

# ---- Base packages: git, wget, curl ----
# Includes the full C/C++ toolchain, Python + pip, and common build headers.
# NOTE: no '#' comments are placed inside the apt argument stream, because a
# '#' in a shell-continued argument list would swallow the rest of the line.
RUN set -eux; \
    apt-get -o Acquire::Retries=3 update; \
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
# ---- pip: use Tsinghua (TUNA) PyPI mirror ----
RUN set -eux; \
    pip config set global.index-url https://pypi.tuna.tsinghua.edu.cn/simple; \
    pip config set global.trusted-host pypi.tuna.tsinghua.edu.cn

# ---- Node.js (NodeSource) - TUNA mirror first, official fallback ----
RUN set -eux; \
    if curl -fsSL --max-time 20 "https://mirrors.tuna.tsinghua.edu.cn/nodesource/gpgkey/nodesource.gpg.key" -o /tmp/ns.key 2>/dev/null; then \
        install -d -m 0755 /usr/share/keyrings /etc/apt/sources.list.d; \
        gpg --dearmor -o /usr/share/keyrings/nodesource.gpg < /tmp/ns.key; \
        echo "deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://mirrors.tuna.tsinghua.edu.cn/nodesource/deb bookworm main" > /etc/apt/sources.list.d/nodesource.list; \
        if ! (apt-get update && apt-cache show nodejs >/dev/null 2>&1); then \
            echo "TUNA nodesource mirror invalid, falling back to official"; \
            rm -f /etc/apt/sources.list.d/nodesource.list /usr/share/keyrings/nodesource.gpg; \
        fi; \
    fi; \
    if [ ! -f /etc/apt/sources.list.d/nodesource.list ]; then \
        curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" -o /tmp/nodesource_setup.sh; \
        bash /tmp/nodesource_setup.sh; \
    fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends nodejs; \
    rm -f /tmp/ns.key /tmp/nodesource_setup.sh; \
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
    if ! curl -fsSL --max-time 60 "https://mirrors.tuna.tsinghua.edu.cn/github-release/tianon/gosu/v${GOSU_VERSION}/gosu-${gosu_arch}" -o /usr/local/bin/gosu; then \
        curl -fsSL "https://github.com/tianon/gosu/releases/download/${GOSU_VERSION}/gosu-${gosu_arch}" -o /usr/local/bin/gosu; \
    fi; \
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
    if ! curl -fsSL --max-time 120 "https://mirrors.tuna.tsinghua.edu.cn/github-release/caddyserver/caddy/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_${caddy_arch}.tar.gz" -o /tmp/caddy.tar.gz; then \
        curl -fsSL "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_${caddy_arch}.tar.gz" -o /tmp/caddy.tar.gz; \
    fi; \
    tar -xzf /tmp/caddy.tar.gz -C /usr/bin caddy; \
    chmod +x /usr/bin/caddy; \
    rm -f /tmp/caddy.tar.gz; \
    caddy version

# ---- GitHub CLI (gh) - TUNA github-release mirror first, official fallback ----
RUN set -eux; \
    arch="$(dpkg --print-architecture | awk -F- '{ print $NF }')"; \
    case "$arch" in \
        amd64)  gh_arch="amd64" ;; \
        arm64)  gh_arch="arm64" ;; \
        armhf)  gh_arch="armv7" ;; \
        *)      echo "Unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    if [ "${GH_VERSION}" = "latest" ]; then \
        GH_VERSION="$(curl -fsSL --max-time 20 https://api.github.com/repos/cli/cli/releases/latest | grep -oE '\"tag_name\":[^,]*' | grep -oE 'v[0-9.]+' | head -1)"; \
    fi; \
    VER="${GH_VERSION#v}"; \
    if ! curl -fsSL --max-time 120 "https://mirrors.tuna.tsinghua.edu.cn/github-release/cli/cli/v${VER}/gh_${VER}_linux_${gh_arch}.tar.gz" -o /tmp/gh.tar.gz; then \
        curl -fsSL --max-time 300 "https://github.com/cli/cli/releases/download/v${VER}/gh_${VER}_linux_${gh_arch}.tar.gz" -o /tmp/gh.tar.gz; \
    fi; \
    tar -xzf /tmp/gh.tar.gz -C /usr/bin --strip-components=2 "gh_${VER}_linux_${gh_arch}/bin/gh"; \
    chmod +x /usr/bin/gh; \
    rm -f /tmp/gh.tar.gz; \
    gh --version

# ---- Install @deepseek-ai/dsh (CLI + web UI) globally via npmmirror ----
# TUNA's npm mirror does not carry the scoped @deepseek-ai packages (404), so
# npm uses npmmirror (registry.npmmirror.com), which mirrors the full registry.
# DSH_VERSION defaults to the stable `latest` dist-tag (0.1.2-rc.1) and is pinned
# explicitly so the build can never drift onto the pre-release `alpha` channel
# (0.1.5-alpha.2), whose web bundle references a plugin tree that fails to boot
# against the published stable packages. Pass --build-arg DSH_VERSION=<ver> to
# override.
ARG DSH_VERSION=0.1.2-rc.1
RUN set -eux; \
    npm config set registry https://registry.npmmirror.com/; \
    npm install -g --no-audit --no-fund --unsafe-perm "@deepseek-ai/dsh@${DSH_VERSION}"; \
    npm install -g --no-audit --no-fund --unsafe-perm pnpm; \
    rm -rf /root/.npm; \
    # Fail the build loudly instead of shipping an image whose `dsh` shim points
    # at a missing entry point (Cannot find module .../dsh/lib/bin.js).
    test -f /usr/local/lib/node_modules/@deepseek-ai/dsh/lib/bin.js || { \
        echo "ERROR: @deepseek-ai/dsh@${DSH_VERSION} installed without lib/bin.js" >&2; \
        ls -la /usr/local/lib/node_modules/@deepseek-ai/dsh/ /usr/local/lib/node_modules/@deepseek-ai/dsh/lib/ >&2; \
        exit 1; \
    }; \
    installed="$(dsh --version)"; \
    echo "installed dsh: ${installed} (wanted ${DSH_VERSION})"; \
    pnpm --version

# ---- Runtime users: caddy (runs reverse proxy). dsh runs as root. ----
# Group name MUST be 'caddy': the entrypoint uses -o caddy -g caddy in install.
RUN set -eux; \
    groupadd --system --gid 1001 caddy && \
    useradd --system --uid 1001 --gid caddy --create-home --shell /usr/sbin/nologin caddy && \
    install -d -m 0700 /data/dsh /data/dsh/home && \
    install -d -m 0750 /workspace && \
    install -d -m 0700 -o caddy -g caddy /data/caddy /data/caddy/config && \
    mkdir -p /etc/caddy

# ---- /root -> /data/dsh: keep auth and $HOME state in the persistent volume ----
# git/gh credentials, ssh keys, npm/pnpm caches and every other tool that
# writes under $HOME default to /root (the container writable layer), which is
# lost on container reset. /data/dsh is a mounted volume, so point /root at it:
# the running container always sees the volume there, while the image keeps a
# normal root home for the build itself.
RUN set -eux; \
    rm -rf /root; \
    ln -s /data/dsh /root

# ---- Pristine copy of the dsh dependency tree (upgrade/seed base) ----
# At runtime the container mounts a persistent volume over
# /usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules so plugin-market
# packages and dependencies survive image upgrades (dsh's own lib/ and
# package.json stay in the image layer and update with the image). Keep a
# pristine snapshot of the image's dependency tree here; the entrypoint seeds
# the volume from it on first boot and merges it on upgrades (new image's
# official packages win, extra packages such as user plugins are kept).
# The version stamp lets an anonymous volume (docker run) skip a redundant
# first-boot copy, while an empty bind mount (docker-compose) still seeds.
RUN set -eux; \
    install -d /opt/dsh-pristine; \
    cp -a /usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules /opt/dsh-pristine/node_modules; \
    node -p "require('/usr/local/lib/node_modules/@deepseek-ai/dsh/package.json').version" \
      > /usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/.dsh-merged-version

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

# Persistent state. The dsh node_modules volume keeps plugin-market packages and
# their dependencies across image upgrades; docker-compose bind-mounts it at
# ./data/dsh/node-modules, and the entrypoint seeds/merges it from
# /opt/dsh-pristine on start.
VOLUME ["/data/dsh", "/data/caddy", "/workspace", "/usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules"]

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
