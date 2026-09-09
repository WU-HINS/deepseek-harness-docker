# DeepSeek Harness (Docker)

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
docker compose up -d --build
```

Then open `https://<HTTPS_ACCESS_HOST>:<HTTPS_PORT>` in a browser and accept the
self-signed certificate (or install the local CA at
`./data/caddy/pki/authorities/local/root.crt`).

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

---

## Build locally (single platform)

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
| `DSH_VERSION`       | `latest`      | `@deepseek-ai/dsh` version to install   |

When `DSH_VERSION` is `latest`, npm resolves and installs the newest published
`@deepseek-ai/dsh` automatically.

---

## Directory layout (relative to this file)

| Path              | Purpose                                              |
| ----------------- | ---------------------------------------------------- |
| `./data/dsh`      | dsh home / profile state                             |
| `./data/caddy`    | Caddy config + local CA (`pki/authorities/local/root.crt`) |
| `./workspace`     | shared workspace the agents operate in               |

These are created on first start (docker-entrypoint creates them with the
correct ownership). Only `HTTPS_ACCESS_HOST` / `DSH_AUTH_*` need to be set in
`.env`.

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
