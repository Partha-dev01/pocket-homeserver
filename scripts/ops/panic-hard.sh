#!/usr/bin/env bash
#
# ops/panic-hard.sh — HARD kill switch: take the whole stack offline.
#
# Stops cloudflared FIRST (cut public access), then every other supervised
# service (Caddy, Matrix, the auth gateway, and all apps) — EXCEPT the admin panel
# itself, which is preserved so you can still reach the box on loopback / over an
# ssh -L tunnel and recover. Discovered generically from the supervisor pidfiles,
# so it stops whatever is actually running.
#
# Recover with:  bash scripts/start-stack.sh   (restores the whole stack — core
#                AND every installed app, re-supervised from their recorded
#                launch commands)
#
# Generalized from a working deployment; review before running on a fresh phone.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env

# Services we must NOT stop — the recovery surface.
PRESERVE="adminweb"

warn "HARD PANIC: taking the whole stack offline (admin panel preserved for recovery)"

# 1) Cut public ingress first.
unsupervise cloudflared

# 2) Stop everything else still supervised, except the preserved set + cloudflared.
shopt -s nullglob
for pidfile in "${POCKET_STATE_DIR}"/*.pid; do
  name="$(basename "${pidfile}" .pid)"
  case " ${PRESERVE} cloudflared " in
    *" ${name} "*) continue ;;
  esac
  unsupervise "${name}"
done
shopt -u nullglob

ok "HARD PANIC done — only the admin panel survives (loopback)."
say "Recover the whole stack (core + every installed app) with:"
say "  bash ${POCKET_ROOT}/scripts/start-stack.sh"
