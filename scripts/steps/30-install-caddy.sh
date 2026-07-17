#!/usr/bin/env bash
#
# 30-install-caddy.sh — install Caddy (the loopback HTTP edge; the Cloudflare
# Tunnel terminates public TLS) into the Debian userland and deploy the rendered
# Caddyfile.
#
# What it does:
#   - apt-installs caddy inside the userland, enforcing a version floor with an
#     official Cloudsmith-repo fallback — "caddy is in main" is NOT enough:
#     Debian trixie main ships a fossilized 2.6.2 that installs fine and then
#     fails `caddy validate` against the rendered config (see CADDY_MIN below),
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

# ── 1. Install Caddy inside the userland (idempotent, version-floored) ───────
# Whether Debian main HAS caddy is the wrong question — the question is whether
# the packaged caddy is new enough for the rendered config. Trixie main ships a
# fossilized 2.6.2, which apt-installs without complaint and then fails
# `caddy validate` below with "unrecognized servers option 'trusted_proxies'"
# (that option landed in caddy v2.6.3), aborting a fresh install — caught by
# the arm64 E2E harness. So: try main, check the floor, and escalate to the
# official Cloudsmith caddy repo (current releases) when the packaged one is
# missing OR too old. A future config change that outgrows a floor-passing
# caddy still fails closed at the validate step — the floor only picks the repo.
run_once caddy-apt -- in_debian '
  set -e
  export DEBIAN_FRONTEND=noninteractive LC_ALL=C
  CADDY_MIN="2.6.3"   # oldest release that accepts the rendered config (servers>trusted_proxies)
  caddy_ok() {
    command -v caddy >/dev/null 2>&1 || return 1
    v="$(caddy version 2>/dev/null | head -1 | sed -n "s/^v\{0,1\}\([0-9][0-9.]*\).*/\1/p")"
    [ -n "$v" ] || return 1
    dpkg --compare-versions "$v" ge "$CADDY_MIN"
  }
  if caddy_ok; then
    echo "caddy already present: $(caddy version | head -1)"
  else
    apt-get update -qq
    apt-get install -y --no-install-recommends caddy 2>/dev/null || true
    if ! caddy_ok; then
      echo "caddy missing from main, or older than ${CADDY_MIN} — adding the Cloudsmith caddy repo"
      apt-get install -y --no-install-recommends \
        debian-keyring debian-archive-keyring apt-transport-https gnupg curl
      curl -1sLf "https://dl.cloudsmith.io/public/caddy/stable/gpg.key" \
        | gpg --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
      echo "deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main" \
        > /etc/apt/sources.list.d/caddy-stable.list
      apt-get update -qq
      apt-get install -y --no-install-recommends caddy
      caddy_ok || { echo "caddy is still older than ${CADDY_MIN} after the Cloudsmith install — cannot continue" >&2; exit 1; }
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
