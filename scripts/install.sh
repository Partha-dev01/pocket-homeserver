#!/usr/bin/env bash
#
# install.sh — bring up pocket-homeserver from .env.
#
# Usage:
#   scripts/install.sh --check     # validate config + print the plan, run nothing
#   scripts/install.sh             # run the install/bring-up plan
#
# The plan is an ordered list of step scripts. App steps run only when their
# ENABLE_<APP> flag is true. A step that isn't present yet is reported and
# skipped, so the framework can land incrementally without breaking the run.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/common.sh"

CHECK=0
case "${1:-}" in
  --check) CHECK=1 ;;
  "") ;;
  *) die "usage: install.sh [--check]" ;;
esac

load_env

# Required before anything runs.
require_var DOMAIN          "your apex domain (DNS on Cloudflare)"
require_var DATA_DIR        "folder on your large volume / SD card"
require_var CF_TUNNEL_TOKEN "the Cloudflare Tunnel token"
require_var ADMIN_PASSWORD  "the admin panel password"

# Ordered core plan: "label:relative-script-path".
core_steps=(
  "prereqs:steps/00-prereqs.sh"
  "userland:steps/10-install-userland.sh"
  "cloudflared:steps/20-install-cloudflared.sh"
  "caddy:steps/30-install-caddy.sh"
  "render-config:render-config.sh"
  "matrix:steps/40-install-matrix.sh"
  "element:steps/50-install-element.sh"
  "auth-gateway:steps/60-install-auth-gw.sh"
  "admin:steps/70-install-admin.sh"
  "start:start-stack.sh"
)

# Optional apps, in install order, each gated by ENABLE_<APP>.
app_order=(LINKDING PINGVIN FRESHRSS MEMOS VIKUNJA SEARXNG ITTOOLS GATUS)
declare -A app_step=(
  [LINKDING]="apps/linkding.sh"
  [PINGVIN]="apps/pingvin.sh"
  [FRESHRSS]="apps/freshrss.sh"
  [MEMOS]="apps/memos.sh"
  [VIKUNJA]="apps/vikunja.sh"
  [SEARXNG]="apps/searxng.sh"
  [ITTOOLS]="apps/ittools.sh"
  [GATUS]="apps/gatus.sh"
)

run_step() {   # run_step label relpath
  local label="$1" rel="$2" path="$HERE/$2"
  if [ ! -f "$path" ]; then
    warn "step not present yet: $label ($rel) — skipping"
    return 0
  fi
  if [ "$CHECK" -eq 1 ]; then
    say "would run: $label ($rel)"
    return 0
  fi
  say "=== $label ==="
  bash "$path"
}

say "pocket-homeserver install plan for ${DOMAIN}  (check=$CHECK)"
for entry in "${core_steps[@]}"; do
  run_step "${entry%%:*}" "${entry#*:}"
done
for app in "${app_order[@]}"; do
  flag="ENABLE_${app}"
  if [ "${!flag:-false}" = "true" ]; then
    run_step "app:${app,,}" "${app_step[$app]}"
  fi
done
ok "install plan complete (check=$CHECK)"
