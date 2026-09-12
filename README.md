# DeepSeek Harness (Docker)

> **📖 中文版文档：[README_ZH.md](./README_ZH.md)** · Read this doc in Chinese.

Run the **DeepSeek Harness** web UI in a container with a TLS reverse proxy and
basic-auth front door. The image is built from `debian:bookworm-slim` with:

- **Node.js** 22 (LTS) + **npm** + **pnpm**
- **Python 3** + **pip** + venv
- Full **C/C++ toolchain**: gcc, g++, make, cmake, ninja, autoconf, libtool ...
- **git**, **wget**, **curl**, and other base utilities
- **Caddy** -- HTTPS reverse proxy + local CA + basic auth
- **gosu** -- privilege dropping for the caddy process
- **GitHub CLI (gh)**

Package installation uses the **Tsinghua (TUNA) mirrors** for apt, npm and pip
by default, and automatically falls back to the official upstream sources if
a mirror is unreachable, so builds work anywhere.

At runtime two processes are managed by `docker-entrypoint.sh`:

1. **dsh** web server listening on `127.0.0.1:3080` (runs as **root**)
2. **caddy** reverse proxy on `:8443` (runs as the **caddy** user, HTTPS + basic auth)

---

## Quick start

```bash
cp .env.example .env
# edit .env: HTTPS_ACCESS_HOST, DSH_AUTH_USERNAME, DSH_AUTH_PASSWORD
# Pull the latest published image (default):
docker compose up -d
# Or build from source instead:
# docker compose up -d --build
```

Then open `https://<HTTPS_ACCESS_HOST>:<HTTPS_PORT>` in a browser and accept the
self-signed certificate (or install the local CA at
`./data/caddy/pki/authorities/local/root.crt`).

> **Recommended auth setup:** Caddy runs in rewrite mode by default
> (`DSH_PRESERVE_HOST=false`) and does not add its own basic-auth layer. Install
> the **`dsh-webui-auth` plugin** so dsh authenticates inside the app instead —
> see [Caddy proxy mode](#caddy-proxy-mode-recommended-rewrite--dsh-webui-auth)
> below.

> The container always listens on `:8443`. `HTTPS_PORT` only controls the
> **host-side** port mapping.

---

## Environment variables

| Variable             | Required | Description                                                                  |
| -------------------- | :------: | ---------------------------------------------------------------------------- |
| `HTTPS_ACCESS_HOST`  |   yes    | IP address or hostname reachable from the client. **No** scheme, path, or port (e.g. `harness.example.com` or `192.168.1.10`). |
| `DSH_AUTH_USERNAME`  |   yes    | Basic-auth username. Allowed chars: letters, digits, `.`, `_`, `-`.          |
| `DSH_AUTH_PASSWORD`  |   yes    | Basic-auth password. **At least 12 characters.**                              |
| `HTTPS_PORT`         |    no    | Host port mapped to container `:8443`. Default `8443`.                      |
| `CONTAINER_NAME`     |    no    | Container name. Default `deepseek-harness`.                                 |
| `CPUS` / `MEMORY_LIMIT` |  no   | Optional resource limits (used by `deploy.resources.limits`).               |
| `DSH_PRESERVE_HOST`    |   no    | Proxy mode. Default `false` (recommended): Caddy rewrites Host+Origin to the loopback upstream; pair with the `dsh-webui-auth` plugin. Set `true` to preserve the original Host (passthrough). |

---

## Caddy proxy mode (recommended: rewrite + dsh-webui-auth)

By default Caddy runs in **rewrite mode** (`DSH_PRESERVE_HOST=false`): both the
**Host** and **Origin** headers are rewritten to the loopback upstream
(`127.0.0.1:3080`). dsh therefore sees every request as local / same-origin,
which keeps origin-based same-origin and CORS checks consistent so API calls
work regardless of the client hostname.

Pair this with the **`dsh-webui-auth` plugin**, which authenticates inside dsh
itself — so you don't need Caddy's basic-auth front door (`auth_disabled`).

- `DSH_PRESERVE_HOST=false` (default) → `proxy_local`: Host and Origin are
  rewritten to the loopback upstream.
- `DSH_PRESERVE_HOST=true` → `proxy_passthrough`: only the Host header is
  preserved; everything else keeps Caddy's default forwarding behaviour. Use
  this if you want the real host/domain/SNI kept visible to dsh (e.g. to reach
  the UI through a reverse proxy, your own domain, or a LAN gateway so
  generated links/resources keep that host).
- Caddy only trusts forwarding headers (`X-Forwarded-For`, `X-Real-IP`) from
  private peers (`trusted_proxies static private_ranges`), so client IP
  resolution stays correct even behind another proxy hop.

---

## Build locally (single platform)

> The `docker-compose.yml` pulls the published GHCR image by default. Build from
> source here, then point compose at your local image (see the `build:` block in
> docker-compose.yml) or run the containers manually.

```bash
# latest published dsh version (default)
docker build -t deepseek-harness:local .

# pin a specific version
docker build --build-arg DSH_VERSION=0.1.1-rc.2 -t deepseek-harness:local .

# build a multi-arch image locally
docker buildx build --platform linux/amd64,linux/arm64 -t deepseek-harness:local .
```

Other build args (defaults shown):

| Build arg           | Default      | Description                            |
| ------------------- | ------------ | -------------------------------------- |
| `NODE_MAJOR`        | `22`          | Node.js major version                   |
| `CADDY_VERSION`     | `2.11.4`       | Caddy release to fetch                  |
| `GOSU_VERSION`      | `1.17`        | gosu release to fetch                   |
| `GH_VERSION`        | `latest`      | GitHub CLI (gh) release to install       |
| `DSH_VERSION`       | `0.1.2-rc.1`  | `@deepseek-ai/dsh` version to install   |
| `NPM_REGISTRY`      | `https://registry.npmmirror.com/` | npm registry for the dsh/pnpm install |
| `PNPM_VERSION`      | `10`          | pnpm major version to install globally  |

The `DSH_VERSION` default is pinned to the stable `latest` dist-tag (`0.1.2-rc.1`).
Pinning matters: the pre-release `alpha` channel (`0.1.5-alpha.2`) carries a
plugin tree that fails to boot against the published stable packages. Override
with `--build-arg DSH_VERSION=<ver>` only when you intend to test a specific
pre-release.

The npm registry defaults to npmmirror (fast inside China). GitHub Actions CI
overrides it with the official `registry.npmjs.org`, because GitHub-hosted
runners reach the China mirror slowly and can time out mid-install.

---

## Directory layout (relative to this file)

| Path              | Purpose                                              |
| ----------------- | ---------------------------------------------------- |
| `./data/dsh`      | dsh home / profile state + git/gh auth (via `/root` symlink) |
| `./data/dsh/node-modules` | persistent global dsh dependency/plugin tree (mounted at `/usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules`) |
| `./data/caddy`    | Caddy config + local CA (`pki/authorities/local/root.crt`) |
| `./workspace`     | shared workspace the agents operate in               |

These are created on first start (docker-entrypoint creates them with the
correct ownership). Only `HTTPS_ACCESS_HOST` / `DSH_AUTH_*` need to be set in
`.env`.

> **1Panel / manual installs:** the `./data/dsh/node-modules` mount must be
> added explicitly (host dir `data/dsh/node-modules` → container
> `/usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules`). Without it the
> global dependency tree lives only in the image layer and plugin-market
> packages do not survive upgrades.

> **Dependency state is not persisted.** The profile dependency mirror
> (`./data/dsh/profiles/node_modules`) and each profile's `.dsh-module-fallback`
> are generated by dsh at every boot from the *installed* `@deepseek-ai/dsh`
> version. Because `./data/dsh` is a bind mount, an older image's dependency
> tree can survive an upgrade and break boot if the new dsh version's bundle no
> longer matches it. The entrypoint wipes that generated state before starting
> dsh, so the container always reconciles against the image's own dsh install.
> Packages added with `dsh plugin add` live in each profile's `node_modules`
> and are preserved (the entrypoint does not touch per-profile `node_modules`).

> **Global dependencies / plugins survive upgrades.** The image mounts a
> persistent volume at `/usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules`
> (`./data/dsh/node-modules`), so plugin-market packages installed into the
> global dependency tree survive image upgrades. dsh's own code (`lib/`,
> `package.json`) stays in the image layer and updates with the image; the
> entrypoint seeds the volume from the image's pristine snapshot on first boot
> and merges it on every start (the new image's official packages win, extra
> packages such as user plugins are kept).

> **`/root` points at `/data/dsh`.** The image symlinks `/root` to `/data/dsh`,
> so anything that writes under `$HOME` — git/gh credentials, ssh keys, npm/pnpm
> caches — lands in the persistent volume instead of the container's writable
> layer, and survives container reset / upgrade. To persist auth for a specific
> tool, configure it once while the container is running (e.g. `gh auth login`,
> `git config --global credential.helper store`); the files are written under
> `/root`, i.e. into `./data/dsh`.

---

## CI/CD -- GitHub Actions

The workflow in `.github/workflows/docker-build.yml` builds and publishes a
**multi-arch** image (`linux/amd64` + `linux/arm64`) using **GitHub-hosted
runners**:

| Job    | Runner              | Platform    |
| ------ | ------------------- | ----------- |
| resolve| `ubuntu-latest`       | --           |
| build  | `ubuntu-24.04`     | `linux/amd64` |
| build  | `ubuntu-24.04-arm` | `linux/arm64` (GitHub ARM runner) |
| merge  | `ubuntu-latest`       | --           |

**Triggers**

- **Scheduled**: every day at **03:00 UTC** (`0 3 * * *`).
- **Manual**: **Actions -> docker-build -> Run workflow**. Optionally set
  `dsh_version` to pin a specific version; leave empty to auto-resolve the
  latest.

**How the version is resolved**

1. If a manual `dsh_version` input is provided, that version is used.
2. Otherwise `npm view @deepseek-ai/dsh version` resolves the latest release
   and that becomes the image version tag.

**Tags produced** (for each registry)

- `<version>-amd64` / `<version>-arm64` -- per-architecture images
- `<version>` -- multi-arch manifest combining both
- `latest` -- multi-arch manifest, pushed **only** when the version was
  auto-resolved (a manually pinned version never overwrites `latest`).

**Registries**

- **GitHub Container Registry (GHCR)** -- `ghcr.io/<owner>/<repo>`
  - Always pushed (uses the `GITHUB_TOKEN` automatically; requires
    `permissions: packages: write`, already set in the workflow).
  - For GHCR pull access outside Actions, enable the package visibility
    (Package settings -> Make public) if you want unauthenticated pulls.
- **Docker Hub** -- `<username>/deepseek-harness`
  - Pushed **only when** both secrets are configured. Without them the Docker
    Hub steps are skipped and only GHCR is published.

**Required GitHub secrets** (repo -> Settings -> Secrets and variables -> Actions)

| Secret                  | Required | Purpose                       |
| ----------------------- | :------: | ----------------------------- |
| `GITHUB_TOKEN`          |  auto    | GHCR push (always available)  |
| `DOCKERHUB_USERNAME`    |    no    | Docker Hub username            |
| `DOCKERHUB_TOKEN`       |    no    | Docker Hub access token (not the password) |

> Docker Hub is skipped automatically when `DOCKERHUB_USERNAME` or
> `DOCKERHUB_TOKEN` is missing -- no other change is needed.

---

## Security

- `no-new-privileges: true` is set on the container.
- The dsh process runs as **root** (by design, to operate on the workspace);
  caddy runs as an unprivileged user.
- Basic-auth credentials are required to reach the UI.
- The self-signed certificate is generated per-container by Caddy; install the
  CA (`./data/caddy/pki/authorities/local/root.crt`) on clients to avoid warnings.

---

## License

MIT. See [LICENSE](https://github.com/deepseek-ai/deepseek-harness/blob/main/LICENSE).
