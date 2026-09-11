#!/usr/bin/env bash
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

is_access_host() {
  node -e '
    const { isIPv4 } = require("node:net");
    const value = process.argv[1];
    const hostname = value.length <= 253 && !/^[0-9.]+$/.test(value) &&
      value.split(".").every((label) => /^(?!-)[A-Za-z0-9-]{1,63}(?<!-)$/.test(label));
    process.exit(isIPv4(value) || hostname ? 0 : 1);
  ' "$1"
}

version_ge() {
  node -e '
    const parse = (v) => {
      const m = String(v).trim().match(/^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?/);
      return m ? { maj:+m[1], min:+m[2], pat:+m[3], pre:m[4]||"" } : null;
    };
    const cmpPre = (a, b) => {
      if (a === b) return 0;
      if (a === "") return 1;
      if (b === "") return -1;
      const as = a.split("."), bs = b.split(".");
      for (let i = 0; i < Math.max(as.length, bs.length); i++) {
        const x = as[i], y = bs[i];
        if (x === undefined) return -1;
        if (y === undefined) return 1;
        const xn = /^\d+$/.test(x), yn = /^\d+$/.test(y);
        if (xn && yn) { if (+x !== +y) return +x < +y ? -1 : 1; }
        else if (xn !== yn) return xn ? -1 : 1;
        else if (x !== y) return x < y ? -1 : 1;
      }
      return 0;
    };
    const a = parse(process.argv[1]), b = parse(process.argv[2]);
    if (!a || !b) process.exit(2);
    let c;
    if (a.maj !== b.maj) c = a.maj < b.maj ? -1 : 1;
    else if (a.min !== b.min) c = a.min < b.min ? -1 : 1;
    else if (a.pat !== b.pat) c = a.pat < b.pat ? -1 : 1;
    else c = cmpPre(a.pre, b.pre);
    process.exit(c >= 0 ? 0 : 1);
  ' "$1" "$2"
}

is_loopback_host() {
  case "${1,,}" in
    127.*|localhost|::1|\[::1\]) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------

if [[ "${1:-}" == "--self-test" ]]; then
  is_access_host 203.0.113.10
  is_access_host dsh.example.com
  ! is_access_host https://dsh.example.com
  ! is_access_host 203.0.113.10:10443
  ! is_access_host 203.0.113.999
  version_ge 0.1.5-rc.1 0.1.5-rc.1
  version_ge 0.1.5      0.1.5-rc.1
  version_ge 0.1.6      0.1.5-rc.1
  version_ge 0.2.0      0.1.5-rc.1
  ! version_ge 0.1.4      0.1.5-rc.1
  ! version_ge 0.1.2-rc.1 0.1.5-rc.1
  is_loopback_host 127.0.0.1
  is_loopback_host localhost
  is_loopback_host ::1
  ! is_loopback_host 0.0.0.0
  ! is_loopback_host 192.168.1.10
  echo "self-test: OK"
  exit 0
fi

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------

printf '\033[1;32m%s\033[0m\n' 'This image is maintained by WUHINS.'
printf '\033[1;33m%s\033[0m\n' 'For support or issue discussion, please visit:'
printf '\033[1;36m%s\033[0m\n' 'https://github.com/WU-HINS/deepseek-harness-docker'

# ---------------------------------------------------------------------------
# Input validation
# ---------------------------------------------------------------------------

access_host="${HTTPS_ACCESS_HOST:-}"
auth_username="${DSH_AUTH_USERNAME:-}"
auth_password="${DSH_AUTH_PASSWORD:-}"

if ! is_access_host "$access_host"; then
  printf 'HTTPS_ACCESS_HOST must be an IPv4 address or hostname without a scheme, path, or port.\n' >&2
  exit 1
fi

if [[ ! "$auth_username" =~ ^[A-Za-z0-9._-]+$ ]]; then
  printf 'DSH_AUTH_USERNAME must contain only letters, numbers, dot, underscore, or hyphen.\n' >&2
  exit 1
fi

if (( ${#auth_password} < 12 )); then
  printf 'DSH_AUTH_PASSWORD must contain at least 12 characters.\n' >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# dsh listen address (default local; override via DSH_HOST / DSH_PORT)
# ---------------------------------------------------------------------------
# Default 127.0.0.1:3080 keeps dsh reachable only inside the container; Caddy
# is the single ingress. Set DSH_HOST to a non-loopback address (e.g. 0.0.0.0)
# when other paths must reach dsh directly; Caddy then switches to passthrough
# mode and stops rewriting Host / X-Real-IP / X-Forwarded-For.

dsh_host="${DSH_HOST:-127.0.0.1}"
dsh_port="${DSH_PORT:-3080}"

if [[ ! "$dsh_host" =~ ^[0-9A-Za-z._:\[\]-]+$ ]]; then
  printf 'DSH_HOST must be an IP address or hostname (got: %s).\n' "$dsh_host" >&2
  exit 1
fi
if [[ ! "$dsh_port" =~ ^[0-9]+$ ]] || (( dsh_port < 1 || dsh_port > 65535 )); then
  printf 'DSH_PORT must be an integer between 1 and 65535 (got: %s).\n' "$dsh_port" >&2
  exit 1
fi

dsh_addr="${dsh_host}:${dsh_port}"

dsh_trusted_host="${DSH_TRUSTED_HOST:-$dsh_addr}"

DSH_UPSTREAM="$dsh_addr"
export DSH_UPSTREAM

# ---------------------------------------------------------------------------
# Choose Caddy proxy mode based on the listen address
# ---------------------------------------------------------------------------
# loopback  -> proxy_local: Caddy is the only ingress, it owns the forwarding
#              headers (standard reverse_proxy behaviour).
# otherwise -> proxy_passthrough: dsh is reachable via other paths too, so
#              Caddy must not rewrite Host / X-Real-IP / X-Forwarded-For.
#              X-Real-IP is still trusted (and resolved by Caddy) only when
#              the direct peer is on a private network (see Caddyfile
#              trusted_proxies / client_ip_headers).

if is_loopback_host "$dsh_host"; then
  DSH_PROXY_SNIPPET=proxy_local
else
  DSH_PROXY_SNIPPET=proxy_passthrough
  echo "dsh listen address ${dsh_addr} is not loopback: Caddy will pass through Host/X-Real-IP/X-Forwarded-For (X-Real-IP trusted for private peers only)."
fi
export DSH_PROXY_SNIPPET

echo "dsh will listen on ${dsh_addr} (trusted-host: ${dsh_trusted_host}, ${access_host})"

# ---------------------------------------------------------------------------
# Resolve dsh version (drives Caddy auth mode)
# ---------------------------------------------------------------------------

DSH_VER="$(node -p "require('/usr/local/lib/node_modules/@deepseek-ai/dsh/package.json').version" 2>/dev/null || echo unknown)"

AUTH_SELF_MANAGED_MIN="0.1.5-rc.1"

if version_ge "$DSH_VER" "$AUTH_SELF_MANAGED_MIN"; then
  echo "dsh ${DSH_VER} >= ${AUTH_SELF_MANAGED_MIN}: dsh handles auth; disabling Caddy basic auth."
  DSH_AUTH_SNIPPET=auth_disabled
  DSH_AUTH_USERNAME=""
  DSH_AUTH_PASSWORD_HASH=""
else
  echo "dsh ${DSH_VER} < ${AUTH_SELF_MANAGED_MIN}: enabling Caddy basic auth."
  DSH_AUTH_SNIPPET=auth_protected
  DSH_AUTH_USERNAME="$auth_username"
  DSH_AUTH_PASSWORD_HASH="$(caddy hash-password --algorithm argon2id --plaintext "$auth_password")"
fi

# Drop plaintext secrets only. Keep the Caddy-facing vars (possibly empty) so
# {$DSH_AUTH_USERNAME} / {$DSH_AUTH_PASSWORD_HASH} always resolve — Caddy
# treats an undefined {$VAR} as a config-load error.
unset HTTPS_ACCESS_HOST DSH_AUTH_PASSWORD auth_password

export DSH_AUTH_SNIPPET
export DSH_AUTH_USERNAME
export DSH_AUTH_PASSWORD_HASH

# ---------------------------------------------------------------------------
# Directories
# ---------------------------------------------------------------------------

install -d -m 0700 -o root  -g root  /data/dsh /data/dsh/home
install -d -m 0750 -o root  -g root  /workspace
install -d -m 0700 -o caddy -g caddy /data/caddy /data/caddy/config

# ---------------------------------------------------------------------------
# Dependency tree: wipe generated state, then seed/merge the persistent volume
# ---------------------------------------------------------------------------

if [[ -d /data/dsh/profiles ]]; then
  rm -rf /data/dsh/profiles/node_modules
  find /data/dsh/profiles -mindepth 2 -maxdepth 2 -type d \
    -name .dsh-module-fallback -exec rm -rf {} + 2>/dev/null || true
fi

DSH_NM=/usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules
PRISTINE=/opt/dsh-pristine/node_modules
DSH_STAMP="$DSH_NM/.dsh-merged-version"
if [[ -d "$PRISTINE" ]]; then
  mkdir -p "$DSH_NM"
  if [[ ! -f "$DSH_STAMP" ]] || [[ "$(cat "$DSH_STAMP" 2>/dev/null)" != "$DSH_VER" ]]; then
    cp -a "$PRISTINE/." "$DSH_NM/"
    printf '%s' "$DSH_VER" > "$DSH_STAMP"
    echo "Merged dsh ${DSH_VER} node_modules into the persistent volume."
  else
    echo "Persistent node_modules already at dsh ${DSH_VER}; skipping merge."
  fi
else
  echo "WARNING: /opt/dsh-pristine/node_modules missing; global node_modules not seeded." >&2
fi

test -f /usr/local/lib/node_modules/@deepseek-ai/dsh/lib/bin.js || {
  echo "ERROR: /usr/local/lib/node_modules/@deepseek-ai/dsh/lib/bin.js is missing" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Process management
# ---------------------------------------------------------------------------

pids=()
cleanup() {
  if (( ${#pids[@]} )); then
    kill -TERM "${pids[@]}" 2>/dev/null || true
    wait "${pids[@]}" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

# ---------------------------------------------------------------------------
# 1. dsh web server
# ---------------------------------------------------------------------------

env \
  HOME=/root \
  DSH_HOME=/data/dsh \
  DSH_TELEMETRY_DISABLED=1 \
  node --expose-internals /usr/local/lib/node_modules/@deepseek-ai/dsh/lib/bin.js \
    web --no-open --host "$dsh_host" --port "$dsh_port" \
      --trusted-host "$dsh_trusted_host" "$access_host" &
dsh_pid=$!
pids+=("$dsh_pid")

# ---------------------------------------------------------------------------
# 2. Readiness gate (always runs)
# ---------------------------------------------------------------------------
# dsh's `/` returns 401/403 once the web server is up (auth enforced), so
# `curl -f` would treat a healthy server as a failure. Accept 200/401/403.
# When DSH_HOST is 0.0.0.0 or ::, curl the loopback form instead.
probe_host="$dsh_host"
case "$probe_host" in
  0.0.0.0) probe_host=127.0.0.1 ;;
  ::|\[::\]) probe_host='[::1]' ;;
esac
probe_url="http://${probe_host}:${dsh_port}/"

ready=false
code=""
for _ in {1..60}; do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$probe_url" || true)"
  case "$code" in
    200|401|403) ready=true; break ;;
  esac
  if ! kill -0 "$dsh_pid" 2>/dev/null; then
    wait "$dsh_pid"
    exit $?
  fi
  sleep 1
done

if [[ "$ready" != true ]]; then
  printf 'DeepSeek Harness did not become ready within 60 seconds on %s (last HTTP code: %s).\n' \
    "$probe_url" "${code:-none}" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 3. Caddy reverse proxy (:8443, HTTPS) -> $DSH_UPSTREAM
# ---------------------------------------------------------------------------

gosu caddy env \
  XDG_DATA_HOME=/data/caddy \
  XDG_CONFIG_HOME=/data/caddy/config \
  CADDY_ACCESS_HOST="$access_host" \
  DSH_UPSTREAM="$DSH_UPSTREAM" \
  DSH_PROXY_SNIPPET="$DSH_PROXY_SNIPPET" \
  DSH_AUTH_SNIPPET="$DSH_AUTH_SNIPPET" \
  DSH_AUTH_USERNAME="$DSH_AUTH_USERNAME" \
  DSH_AUTH_PASSWORD_HASH="$DSH_AUTH_PASSWORD_HASH" \
  caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &
caddy_pid=$!
pids+=("$caddy_pid")

printf 'DeepSeek Harness is available at https://%s:8443 inside the container.\n' "$access_host"
printf 'The local CA certificate is stored at /data/caddy/pki/authorities/local/root.crt.\n'

status=0
wait -n "$dsh_pid" "$caddy_pid" || status=$?
exit "$status"
