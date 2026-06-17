#!/usr/bin/env bash
#
# 30-install-caddy.sh — install Caddy (the loopback HTTP edge; the Cloudflare
# Tunnel terminates public TLS) into the Debian userland and deploy the rendered
# Caddyfile.
#
# What it does:
#   - apt-installs caddy inside the userland (with a Cloudsmith-repo fallback for
#     Debian releases that don't ship it in main),
#   - ensures the rendered Caddyfile exists (runs render-config.sh if missing),
#   - copies config/rendered/Caddyfile into the userland's /etc/caddy/Caddyfile,
#   - runs `caddy validate` inside the userland to fail closed on a bad config.
#
# This step CONSUMES the rendered config; it never regenerates it from scratch.
# Edit config/Caddyfile.tmpl + re-run render-config.sh to change the edge config.
#
# Generalized from a working deployment; review before running on a fresh phone.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env
require_cmd proot-distro

in_debian() { proot-distro login debian -- bash -lc "$1"; }

# ── 1. Install Caddy inside the userland (idempotent) ────────────────────────
# Current Debian (trixie+) ships caddy in main. Fall back to the official
# Cloudsmith caddy repo for releases that don't.
run_once caddy-apt -- in_debian '
  set -e
  export DEBIAN_FRONTEND=noninteractive LC_ALL=C
  if command -v caddy >/dev/null 2>&1; then
    echo "caddy already present: $(caddy version | head -1)"
  else
    apt-get update -qq
    if ! apt-get install -y --no-install-recommends caddy 2>/dev/null; then
      echo "caddy not in main repos — adding the Cloudsmith caddy repo"
      apt-get install -y --no-install-recommends \
        debian-keyring debian-archive-keyring apt-transport-https gnupg curl
      curl -1sLf "https://dl.cloudsmith.io/public/caddy/stable/gpg.key" \
        | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
      echo "deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main" \
        > /etc/apt/sources.list.d/caddy-stable.list
      apt-get update -qq
      apt-get install -y --no-install-recommends caddy
    fi
    caddy version
  fi
  # /etc/caddy/apps holds one self-contained site block per optional app; the
  # core Caddyfile imports it with a glob (empty glob = no-op, not an error).
  mkdir -p /etc/caddy /etc/caddy/apps /var/log/caddy
' || die "caddy install inside the userland failed"

# ── 2. Ensure the rendered Caddyfile exists ──────────────────────────────────
RENDERED="${POCKET_ROOT}/config/rendered/Caddyfile"
if [ ! -f "${RENDERED}" ]; then
  say "rendered Caddyfile missing — running render-config.sh"
  bash "${POCKET_ROOT}/scripts/render-config.sh" || die "render-config.sh failed"
fi
[ -f "${RENDERED}" ] || die "rendered Caddyfile still missing at ${RENDERED}"

# ── 3. Deploy it into the userland (/etc/caddy/Caddyfile) ────────────────────
# Stream the rendered file over stdin so we never hardcode the rootfs path.
say "deploying rendered Caddyfile into the userland (/etc/caddy/Caddyfile)"
in_debian 'mkdir -p /etc/caddy'
proot-distro login debian -- bash -lc 'cat > /etc/caddy/Caddyfile' < "${RENDERED}" \
  || die "failed to copy the Caddyfile into the userland"

# ── 4. Validate inside the userland (fail closed) ────────────────────────────
say "validating the Caddyfile inside the userland"
in_debian 'caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile' \
  || die "caddy validate FAILED — refusing to leave a broken Caddyfile in place"

ok "Caddy installed + rendered Caddyfile deployed and validated"
