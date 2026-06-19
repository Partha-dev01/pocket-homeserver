#!/usr/bin/env bash
#
# steps/78-install-filters.sh — install + supervise the OPTIONAL privacy/media
# loopback filter proxies that sit in front of the Matrix homeserver on a few
# specific routes.
#
# Two independent, independently-gated filters:
#
#   user-filter  (scripts/filters/user-filter.py, ENABLE_USER_FILTER)
#       A loopback HTTP proxy on 127.0.0.1:${USER_FILTER_PORT} (default 8449).
#       Caddy routes ONLY the Matrix user-directory search endpoint through it;
#       it forwards to the homeserver loopback, strips any MXID listed in
#       ${DATA_DIR}/secrets/private-users.txt from the JSON results, and FAILS
#       OPEN on any error. Lets the operator hide chosen accounts from member
#       search without touching the homeserver. (Flask — already present for the
#       admin panel.)
#
#   media-filter (scripts/filters/media-filter.py, ENABLE_MEDIA_FILTER)
#       A stdlib-only loopback proxy on 127.0.0.1:${MEDIA_FILTER_PORT} (default
#       8450). Caddy routes ONLY the Matrix media download/thumbnail/preview_url
#       routes through it; it sniffs Content-Type from magic bytes when the
#       homeserver omits it (so native mobile clients render thumbnails), and
#       streams the body straight through.
#
# Both run TERMUX-NATIVE (NOT inside the proot userland) — they are plain
# loopback proxies in front of the homeserver's loopback listener, the same
# pattern as the admin panel and the honeypot watcher; neither needs the
# userland. Each has an inbound loopback listener ONLY (127.0.0.1) — Caddy is
# the only thing that reaches them; the public edge never does.
#
# This is a core step that SELF-GATES: it runs if EITHER ENABLE_USER_FILTER OR
# ENABLE_MEDIA_FILTER is true, and no-ops otherwise. Both default to false.
#
# What it does (idempotent — safe to re-run):
#   1. ensures ${DATA_DIR}/secrets exists (0700) and the log/state dirs exist,
#   2. (user-filter) seeds ${DATA_DIR}/secrets/private-users.txt (0600) if absent,
#   3. fail-closed checks the enabled filter module(s) are present + parse-clean,
#   4. supervises ONLY the enabled filter(s) Termux-native with python3 (records
#      each .cmd so start-stack.sh re-supervises it on every bring-up),
#   5. probes each enabled filter's /healthz on loopback.
#
# Caddy routing is a CORE Caddyfile change (these filters intercept routes on the
# EXISTING chat/Matrix vhost, NOT a fresh subdomain) — see docs/FILTERS.md and the
# install integration notes; this step does NOT edit Caddy.
#
# Generalized from a working deployment; review before running on a fresh phone.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env

# ── Self-gate: run if EITHER filter is enabled (both default off) ────────────
if [ "${ENABLE_USER_FILTER:-false}" != "true" ] \
   && [ "${ENABLE_MEDIA_FILTER:-false}" != "true" ]; then
  ok "privacy/media filters disabled (ENABLE_USER_FILTER + ENABLE_MEDIA_FILTER != true) — skipping"
  exit 0
fi

require_var DATA_DIR "folder on your large volume / SD card"
require_cmd python3

# ── Paths ─────────────────────────────────────────────────────────────────────
SECRETS_DIR="${DATA_DIR}/secrets"
FILTER_DIR="${POCKET_ROOT}/scripts/filters"
USER_FILTER="${FILTER_DIR}/user-filter.py"
MEDIA_FILTER="${FILTER_DIR}/media-filter.py"
PRIVATE_FILE="${PRIVATE_USERS_FILE:-${SECRETS_DIR}/private-users.txt}"

mkdir -p "${SECRETS_DIR}" "${POCKET_LOG_DIR}" "${POCKET_STATE_DIR}"
chmod 700 "${SECRETS_DIR}" 2>/dev/null || true

# ── user-filter ─────────────────────────────────────────────────────────────
if [ "${ENABLE_USER_FILTER:-false}" = "true" ]; then
  # Preflight: module present + parse-clean (fail-closed) so a broken/missing
  # module is caught at install time, not at first respawn (a crash-loop would
  # otherwise silently 502 member search while Caddy keeps routing to it).
  [ -f "${USER_FILTER}" ] || die "user-filter missing: ${USER_FILTER} — the filters module was not shipped"
  python3 -c "import ast; ast.parse(open('${USER_FILTER}').read())" \
    || die "user-filter.py failed to parse under python3"
  # Flask is required (already present for the admin panel). Fail loud if absent.
  python3 -c "import flask" 2>/dev/null \
    || die "user-filter needs Flask (install the admin panel first, or: python3 -m pip install --user flask)"
  ok "user-filter present + parse-clean (${USER_FILTER})"

  # Seed the private-users list (0600) if absent. The proxy re-reads it on every
  # request, so the operator can edit it live (one MXID per line).
  if [ ! -e "${PRIVATE_FILE}" ]; then
    {
      echo "# private-users — MXIDs hidden from the Matrix user-directory search."
      echo "# One MXID per line, e.g.  @alice:${MATRIX_SERVER_NAME:-example.com}"
      echo "# Lines starting with '#' and blank lines are ignored."
      echo "# Re-read on every request — edit freely; no restart needed."
    } > "${PRIVATE_FILE}"
    chmod 600 "${PRIVATE_FILE}" 2>/dev/null || true
    say "seeded the private-users template ${PRIVATE_FILE}"
  else
    say "keeping existing private-users file ${PRIVATE_FILE}"
  fi

  # Supervise Termux-native. PRIVATE_USERS_FILE/USER_FILTER_PORT/MATRIX_LOOPBACK
  # are read from the inherited environment (load_env exported them via set -a);
  # nothing sensitive is on argv. The shared supervisor records the launch argv
  # to ${POCKET_STATE_DIR}/user-filter.cmd so start-stack.sh re-supervises it on
  # every bring-up and ops/restart.sh can restart it.
  supervise user-filter -- python3 "${USER_FILTER}"

  uf_port="${USER_FILTER_PORT:-8449}"
  say "confirming user-filter on 127.0.0.1:${uf_port}"
  up=0
  for _ in $(seq 1 15); do
    if curl -sf -m 2 "http://127.0.0.1:${uf_port}/healthz" >/dev/null 2>&1; then
      up=1; break
    fi
    sleep 1
  done
  [ "${up}" -eq 1 ] && ok "user-filter listening on 127.0.0.1:${uf_port}" \
    || warn "user-filter did not answer /healthz yet — check ${POCKET_LOG_DIR}/user-filter.log"
else
  ok "user-filter disabled (ENABLE_USER_FILTER != true) — skipping"
fi

# ── media-filter ────────────────────────────────────────────────────────────
if [ "${ENABLE_MEDIA_FILTER:-false}" = "true" ]; then
  [ -f "${MEDIA_FILTER}" ] || die "media-filter missing: ${MEDIA_FILTER} — the filters module was not shipped"
  python3 -c "import ast; ast.parse(open('${MEDIA_FILTER}').read())" \
    || die "media-filter.py failed to parse under python3"
  ok "media-filter present + parse-clean (${MEDIA_FILTER})"

  # Supervise Termux-native (stdlib only — no Flask needed). MEDIA_FILTER_PORT /
  # MATRIX_LOOPBACK come from the inherited environment; nothing on argv.
  supervise media-filter -- python3 "${MEDIA_FILTER}"

  mf_port="${MEDIA_FILTER_PORT:-8450}"
  say "confirming media-filter on 127.0.0.1:${mf_port}"
  up=0
  for _ in $(seq 1 15); do
    if curl -sf -m 2 "http://127.0.0.1:${mf_port}/healthz" >/dev/null 2>&1; then
      up=1; break
    fi
    sleep 1
  done
  [ "${up}" -eq 1 ] && ok "media-filter listening on 127.0.0.1:${mf_port}" \
    || warn "media-filter did not answer /healthz yet — check ${POCKET_LOG_DIR}/media-filter.log"
else
  ok "media-filter disabled (ENABLE_MEDIA_FILTER != true) — skipping"
fi

# ── Closing notes ─────────────────────────────────────────────────────────────
echo
ok "Privacy/media filters installed + supervised (enabled ones only)."
say "These intercept SPECIFIC routes on the EXISTING chat/Matrix vhost — they need"
say "a CORE Caddyfile change to route those routes through the loopback proxies."
say "Weave the handle/reverse_proxy blocks into config/Caddyfile.tmpl, re-render,"
say "then apply with: scripts/start-stack.sh --restart   (see docs/FILTERS.md)."

# Generalized from a working deployment; review before running.
