#!/usr/bin/env bash
#
# ops/restart.sh <service> — restart a single supervised service.
#
# Used by the web admin panel's per-service "restart" buttons (and handy by hand).
# It re-supervises the service from the launch command the supervisor recorded at
# start time (${POCKET_STATE_DIR}/<service>.cmd — written by `supervise` in
# lib/common.sh), so there is ONE source of truth for each service's launch line
# and this script never drifts from the install scripts.
#
# Known services: matrix, caddy, cloudflared, auth-gw, adminweb, backup-daemon,
# honeypot-watcher, and any enabled app (linkding, linkding-tasks, pingvin,
# freshrss, freshrss-refresh, searxng, memos, vikunja, gatus). A service that has
# never been started has no recorded command; this script then points you at the
# step/app script that first brings it up.
#
# Generalized from a working deployment; review before running on a fresh phone.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env

svc="${1:-}"
[ -n "$svc" ] || die "usage: ops/restart.sh <service>   (e.g. matrix, caddy, cloudflared, auth-gw, adminweb, linkding, …)"

cmdfile="${POCKET_STATE_DIR}/${svc}.cmd"

if [ -f "$cmdfile" ]; then
  mapfile -t _cmd < "$cmdfile"
  [ "${#_cmd[@]}" -gt 0 ] || die "recorded launch command for '$svc' is empty ($cmdfile)"
  say "restarting '$svc'"
  unsupervise "$svc"
  supervise "$svc" -- "${_cmd[@]}"
  ok "restart issued for '$svc'"
  exit 0
fi

# No recorded command — the service was never supervised on this host. Steer the
# operator to the script that first starts it (which records the command).
case "$svc" in
  matrix|caddy|cloudflared)
    die "'$svc' has no recorded launch command yet — start the core stack first: bash ${POCKET_ROOT}/scripts/start-stack.sh" ;;
  auth-gw)
    die "'auth-gw' has no recorded launch command yet — run: bash ${POCKET_ROOT}/scripts/steps/60-install-auth-gw.sh (needs ENABLE_AUTH_GATEWAY=true)" ;;
  adminweb)
    die "'adminweb' has no recorded launch command yet — run: bash ${POCKET_ROOT}/scripts/steps/70-install-admin.sh" ;;
  *)
    die "'$svc' has no recorded launch command yet — run its install script (scripts/apps/${svc%-*}.sh) or scripts/install.sh first" ;;
esac
