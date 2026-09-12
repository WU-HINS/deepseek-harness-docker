# DeepSeek Harness (Docker) · 中文版

> **一条命令，把 DeepSeek Harness 装进容器，自带 HTTPS 反代与认证。**
> 基于 `debian:bookworm-slim` 镜像，内置 Node.js、Python、完整 C/C++ 工具链、
> Caddy（HTTPS 反代 + 本地 CA + 基础认证）、gosu 与 GitHub CLI（gh）。
> 开箱即用地在任意联网环境构建，为 AI 代理提供一个安全、隔离、可持久化的工作台。

---

## 快速开始

```bash
cp .env.example .env
# 编辑 .env：HTTPS_ACCESS_HOST、DSH_AUTH_USERNAME、DSH_AUTH_PASSWORD
# 拉取最新发布镜像（默认）：
docker compose up -d
# 或者改为从源码构建：
# docker compose up -d --build
```

然后在浏览器打开 `https://<HTTPS_ACCESS_HOST>:<HTTPS_PORT>`，接受自签名证书
（或先安装本地 CA：`./data/caddy/pki/authorities/local/root.crt`）。

> **推荐的认证方案：** Caddy 默认运行在重写模式（`DSH_PRESERVE_HOST=false`），
> 不会自带 BASIC 认证层。请安装 **`dsh-webui-auth` 插件**，让 dsh 在应用内部
> 完成认证——详见下方的 [Caddy 代理模式](#caddy-代理模式推荐重写-dsh-webui-auth)。
>
> 容器始终监听 `:8443`。`HTTPS_PORT` 只控制**宿主机侧**的端口映射。

---

## 容器内运行的两个进程

由 `docker-entrypoint.sh` 管理：

1. **dsh** Web 服务，监听 `127.0.0.1:3080`（以 **root** 运行）
2. **caddy** 反向代理，监听 `:8443`（以 **caddy** 用户运行，HTTPS + 基础认证）

## 镜像内置

- **Node.js** 22（LTS）+ **npm** + **pnpm**
- **Python 3** + **pip** + venv
- 完整 **C/C++ 工具链**：gcc、g++、make、cmake、ninja、autoconf、libtool ...
- **git**、**wget**、**curl** 等基础工具
- **Caddy** —— HTTPS 反向代理 + 本地 CA + 基础认证
- **gosu** —— 用于 caddy 进程的权限降级
- **GitHub CLI (gh)**

> 软件包安装默认使用 **清华 TUNA 镜像**（apt、npm、pip），镜像不可达时自动回退
> 到官方源，因此任何网络环境下都能顺利构建。

---

## 环境变量

| 变量                | 必填 | 说明                                                                    |
| ------------------- | :--: | ----------------------------------------------------------------------- |
| `HTTPS_ACCESS_HOST` | 是   | 客户端可达的 IP 或主机名。**不含** scheme、路径或端口（如 `harness.example.com` 或 `192.168.1.10`）。 |
| `DSH_AUTH_USERNAME` | 是   | 基础认证用户名。允许字符：字母、数字、`.`、`_`、`-`。                    |
| `DSH_AUTH_PASSWORD` | 是   | 基础认证密码。**至少 12 个字符。**                                        |
| `HTTPS_PORT`        | 否   | 映射到容器 `:8443` 的宿主机端口。默认 `8443`。                           |
| `CONTAINER_NAME`    | 否   | 容器名称。默认 `deepseek-harness`。                                      |
| `CPUS` / `MEMORY_LIMIT` | 否 | 可选资源限制（用于 `deploy.resources.limits`）。                          |
| `DSH_PRESERVE_HOST` | 否   | 代理模式。默认 `false`（推荐）：Caddy 把 Host 与 Origin 一并重写为回环上游；配合 `dsh-webui-auth` 插件使用。设为 `true` 则保留原始 Host（透传）。 |

---

## Caddy 代理模式（推荐：重写 + dsh-webui-auth）

默认情况下 Caddy 运行在**重写模式**（`DSH_PRESERVE_HOST=false`）：**Host** 与
**Origin** 两个头都会被重写为回环上游（`127.0.0.1:3080`）。于是 dsh 把每个请求都
看作本地 / 同源请求，Origin 同源与 CORS 校验保持一致，**API 调用无论客户端主机名
如何都能正常工作**。

请配合 **`dsh-webui-auth` 插件**使用，让 dsh 在应用内部完成认证——这样就不需要
Caddy 的 BASIC 认证前置层（`auth_disabled`）。

- `DSH_PRESERVE_HOST=false`（默认）→ `proxy_local`：Host 与 Origin 均重写为回环上游。
- `DSH_PRESERVE_HOST=true` → `proxy_passthrough`：仅保留 Host 头，其余保持 Caddy
  默认转发行为。当你想让 dsh 看到真实的主机 / 域名 / SNI 时使用（例如通过反向代理、
  自有域名或局域网网关访问界面，使生成的链接 / 资源保持该主机名）。
- Caddy 只信任来自私有对端的转发头（`X-Forwarded-For`、`X-Real-IP`，
  `trusted_proxies static private_ranges`），因此即使再经过一层代理，客户端 IP
  解析依然正确。

---

## 本地构建（单平台）

> `docker-compose.yml` 默认拉取发布的 GHCR 镜像。如需从源码构建，可参考这里的
> 命令（构建后把 compose 指向本地镜像，见 `docker-compose.yml` 中的 `build:` 块）
> 或手动运行容器。

```bash
# 最新发布的 dsh 版本（默认）
docker build -t deepseek-harness:local .

# 锁定指定版本
docker build --build-arg DSH_VERSION=0.1.1-rc.2 -t deepseek-harness:local .

# 本地构建多架构镜像
docker buildx build --platform linux/amd64,linux/arm64 -t deepseek-harness:local .
```

其他构建参数（括号内为默认值）：

| 构建参数        | 默认值       | 说明                              |
| --------------- | ------------ | --------------------------------- |
| `NODE_MAJOR`    | `22`          | Node.js 主版本                     |
| `CADDY_VERSION` | `2.11.4`      | 要拉取的 Caddy 版本                |
| `GOSU_VERSION`  | `1.17`        | gosu 版本                          |
| `GH_VERSION`    | `latest`      | 安装的 GitHub CLI（gh）版本         |
| `DSH_VERSION`   | `0.1.2-rc.1`  | 要安装的 `@deepseek-ai/dsh` 版本    |
| `NPM_REGISTRY`  | `https://registry.npmmirror.com/` | dsh/pnpm 安装使用的 npm 源 |
| `PNPM_VERSION`  | `10`          | 全局安装的 pnpm 主版本              |

`DSH_VERSION` 默认锁定在稳定的 `latest` 发行标签（`0.1.2-rc.1`）。锁定很重要：
预发布的 `alpha` 通道（`0.1.5-alpha.2`）携带一套插件树，无法针对已发布的稳定包
正常启动。仅在你有意测试某个预发布版本时，才用 `--build-arg DSH_VERSION=<ver>`
覆盖。

npm 源默认使用 npmmirror（国内速度快）。GitHub Actions CI 会覆盖为官方
`registry.npmjs.org`，因为 GitHub 托管的 runner 访问国内镜像很慢，安装中途可能超时。

---

## 目录结构（相对本文件）

| 路径                | 用途                                                      |
| ------------------- | --------------------------------------------------------- |
| `./data/dsh`        | dsh home / profile 状态 + git/gh 认证（经 `/root` 软链）   |
| `./data/dsh/node-modules` | 持久化的全局 dsh 依赖 / 插件树（挂载于 `/usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules`） |
| `./data/caddy`      | Caddy 配置 + 本地 CA（`pki/authorities/local/root.crt`）    |
| `./workspace`       | 智能体操作的共享工作区                                     |

这些目录在首次启动时创建（docker-entrypoint 会设置正确的属主）。通常只需在 `.env`
中设置 `HTTPS_ACCESS_HOST` / `DSH_AUTH_*`。

> **1Panel / 手动安装：** 必须显式添加 `./data/dsh/node-modules` 挂载（宿主机
> `data/dsh/node-modules` → 容器 `/usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules`）。
> 否则全局依赖树只存在于镜像层，插件市场安装的包无法在升级后保留。

> **依赖状态不持久化。** 每个 profile 的依赖镜像
> （`./data/dsh/profiles/node_modules`）与 `.dsh-module-fallback` 都由 dsh 在每次
> 启动时根据*已安装*的 `@deepseek-ai/dsh` 版本重新生成。因为 `./data/dsh` 是绑定挂载，
> 旧镜像的依赖树可能在升级后残留，并在新 dsh 版本 bundle 不匹配时导致启动失败。
> entrypoint 会在启动 dsh 前清空这些生成状态，确保容器始终与镜像自带的 dsh 安装对齐。
> 用 `dsh plugin add` 添加的包位于每个 profile 的 `node_modules` 中并被保留
> （entrypoint 不会触碰各 profile 的 `node_modules`）。

> **全局依赖 / 插件可跨升级保留。** 镜像把
> `/usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules`
> （`./data/dsh/node-modules`）挂载为持久卷，因此装进全局依赖树的插件市场包在镜像
> 升级后依然存在。dsh 自身代码（`lib/`、`package.json`）留在镜像层随镜像更新；
> entrypoint 首次启动时用镜像的干净快照填充该卷，并在每次启动时合并（新镜像的官方
> 包优先，额外包如用户插件会被保留）。

> **`/root` 指向 `/data/dsh`。** 镜像把 `/root` 软链到 `/data/dsh`，因此任何写入
> `$HOME` 的内容——git/gh 凭据、ssh 密钥、npm/pnpm 缓存——都会落入持久卷而非容器
> 可写层，在容器重置 / 升级后依然存在。若需持久化某工具的认证，可在容器运行时配置
> 一次（如 `gh auth login`、`git config --global credential.helper store`）；文件会
> 写入 `/root`，即 `./data/dsh`。

---

## CI/CD —— GitHub Actions

`.github/workflows/docker-build.yml` 使用 **GitHub 托管的 runner** 构建并发布
**多架构**镜像（`linux/amd64` + `linux/arm64`）：

| Job    | Runner             | 平台              |
| ------ | ------------------ | ----------------- |
| resolve| `ubuntu-latest`       | --                |
| build  | `ubuntu-24.04`     | `linux/amd64`     |
| build  | `ubuntu-24.04-arm` | `linux/arm64`（GitHub ARM runner） |
| merge  | `ubuntu-latest`       | --                |

**触发方式**

- **定时**：每天 **03:00 UTC**（`0 3 * * *`）。
- **手动**：**Actions -> docker-build -> Run workflow**。可选设置 `dsh_version`
  锁定特定版本；留空则自动解析最新。

**版本如何解析**

1. 若提供了手动 `dsh_version` 输入，则使用该版本。
2. 否则执行 `npm view @deepseek-ai/dsh version` 解析最新发行版，并将其作为镜像标签。

**生成的标签**（每个仓库）

- `<version>-amd64` / `<version>-arm64` —— 各架构镜像
- `<version>` —— 合并两者的多架构 manifest
- `latest` —— 多架构 manifest，**仅当**版本为自动解析时推送（手动锁定的版本
  永不覆盖 `latest`）。

**仓库**

- **GitHub Container Registry (GHCR)** —— `ghcr.io/<owner>/<repo>`
  - 始终推送（自动使用 `GITHUB_TOKEN`；需 `permissions: packages: write`，
    工作流中已设置）。
  - 要在 Actions 之外拉取 GHCR，请开启包可见性（Package settings -> Make public）。
- **Docker Hub** —— `<username>/deepseek-harness`
  - **仅当**两个 secret 都配置时才推送。缺失时跳过 Docker Hub 步骤，只发布 GHCR。

**所需的 GitHub secrets**（仓库 -> Settings -> Secrets and variables -> Actions）

| Secret                | 必填 | 用途                          |
| --------------------- | :--: | ----------------------------- |
| `GITHUB_TOKEN`        | 自动 | GHCR 推送（始终可用）            |
| `DOCKERHUB_USERNAME`  | 否   | Docker Hub 用户名               |
| `DOCKERHUB_TOKEN`     | 否   | Docker Hub 访问令牌（非密码）     |

> 当 `DOCKERHUB_USERNAME` 或 `DOCKERHUB_TOKEN` 缺失时，会自动跳过 Docker Hub——
> 无需其他改动。

---

## 安全

- 容器设置了 `no-new-privileges: true`。
- dsh 进程以 **root** 运行（设计如此，为操作工作区）；caddy 以非特权用户运行。
- 访问界面需要基础认证凭据。
- 自签名证书由 Caddy 按容器生成；在客户端安装 CA
  （`./data/caddy/pki/authorities/local/root.crt`）可避免警告。

---

## 许可证

MIT。参见 [LICENSE](https://github.com/deepseek-ai/deepseek-harness/blob/main/LICENSE)。
