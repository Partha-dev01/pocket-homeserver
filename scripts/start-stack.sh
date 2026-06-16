#!/usr/bin/env bash
#
# start-stack.sh — bring the core stack up (or restart it), in dependency order:
#   1. matrix       — the Matrix homeserver (continuwuity); everything depends on it
#   2. caddy        — the loopback HTTPS edge on ${CADDY_BIND}:${CADDY_PORT}
#   3. cloudflared  — the Cloudflare Tunnel that forwards public traffic to Caddy
#
# Each service runs INSIDE the Debian userland via `proot-distro login` and is
# kept alive by the lib's supervisor (respawns on crash, identity-checked pidfile).
#
# Idempotent: `supervise` no-ops if a service is already running. Pass --restart to
# stop then re-start every service (a brief ingress outage while cloudflared cycles).
#
# The Cloudflare Tunnel token is passed to cloudflared via the TUNNEL_TOKEN
# environment variable — NEVER on argv (it would otherwise show in /proc/*/cmdline).
#
# Generalized from a working deployment; review before running on a fresh phone.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

load_env
require_var DATA_DIR        "folder on your large volume / SD card"
require_var CF_TUNNEL_TOKEN  "the Cloudflare Tunnel token"
require_cmd proot-distro

RESTART=0
case "${1:-}" in
  --restart) RESTART=1 ;;
  "") ;;
  *) die "usage: start-stack.sh [--restart]" ;;
esac

# Acquire a wake-lock so Android doesn't doze the long-running stack (best effort).
command -v termux-wake-lock >/dev/null 2>&1 && { termux-wake-lock 2>/dev/null || true; }

# ── Launch commands (each runs inside the userland) ──────────────────────────
# Matrix: bind the large-volume media dir into the userland so uploads land on
# ${DATA_DIR} (the in-userland DB stays small). CONDUIT_CONFIG points at the
# deployed conduwuit.toml.
matrix_cmd=(
  proot-distro login debian
  --bind "${DATA_DIR}/media:/var/lib/conduwuit/media"
  -- env CONDUIT_CONFIG=/etc/conduwuit/conduwuit.toml /opt/conduwuit/conduwuit
)

# Caddy: serve the deployed Caddyfile (loopback HTTPS edge).
caddy_cmd=(
  proot-distro login debian
  -- caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
)

# cloudflared: keep the tunnel token OFF every argv (/proc/*/cmdline). Stage it
# in a 0600 file inside the userland and read it via a small launcher, so neither
# the supervisor, proot-distro, nor cloudflared expose it on the command line.
# (The token still lives in the launcher's ENVIRON, readable only by the same
# user.) This mirrors the reference deployment's file-based token handling.
stage_cloudflared() {
  proot-distro login debian -- bash -lc '
    mkdir -p /etc/cloudflared && chmod 700 /etc/cloudflared
    cat > /etc/cloudflared/token && chmod 600 /etc/cloudflared/token
    cat > /usr/local/bin/pocket-cloudflared.sh <<"LAUNCH"
#!/bin/bash
export TUNNEL_TOKEN="$(cat /etc/cloudflared/token)"
exec /usr/local/bin/cloudflared tunnel --no-autoupdate --protocol http2 run
LAUNCH
    chmod 700 /usr/local/bin/pocket-cloudflared.sh
  ' <<<"${CF_TUNNEL_TOKEN}"
}
cloudflared_cmd=( proot-distro login debian -- /usr/local/bin/pocket-cloudflared.sh )

# ── --restart: stop everything first (reverse dependency order) ──────────────
if [ "${RESTART}" -eq 1 ]; then
  say "== restarting core stack =="
  unsupervise cloudflared
  unsupervise caddy
  unsupervise matrix
fi

# ── Start in dependency order (supervise no-ops if already running) ──────────
# Stage the cloudflared token + launcher first (idempotent; picks up token changes).
say "staging cloudflared token (0600, kept off argv)"
stage_cloudflared || die "failed to stage the cloudflared token in the userland"

say "== starting core stack =="
supervise matrix      -- "${matrix_cmd[@]}"
supervise caddy       -- "${caddy_cmd[@]}"
supervise cloudflared -- "${cloudflared_cmd[@]}"

# ── Final status ─────────────────────────────────────────────────────────────
echo
say "== stack status =="
status_line() {  # status_line NAME
  local name="$1" pidfile="${POCKET_STATE_DIR}/$1.pid" pid state="DOWN"
  if [ -f "${pidfile}" ]; then
    pid="$(cat "${pidfile}" 2>/dev/null || true)"
    [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null && state="RUNNING (pid ${pid})"
  fi
  printf '  %-14s : %s\n' "${name}" "${state}"
}
status_line matrix
status_line caddy
status_line cloudflared

echo
ok "core stack start complete (logs under ${POCKET_LOG_DIR})"
