#!/usr/bin/env bash
#
# steps/60-install-auth-gw.sh — install + supervise the OPTIONAL Matrix-SSO auth
# gateway (matrix-auth-gw), so your users can sign into the apps with their
# Matrix username + password (single sign-on) instead of a separate per-app
# account. This is an ADVANCED add-on; the default app protection is Cloudflare
# Access + each app's own login (see docs/APP_AUTH.md).
#
# It is a core step that SELF-GATES on ENABLE_AUTH_GATEWAY (install.sh runs it
# unconditionally; it no-ops unless you opt in), so a default install never
# touches it.
#
# What it does (idempotent — safe to re-run):
#   1. ensures python3 in the Debian userland (the gateway is stdlib-only),
#   2. copies the gateway + its RSA-keygen helper into /opt/matrix-auth-gw,
#   3. generates + persists, on the large volume (chmod 600, reused on re-run):
#        - the HMAC session-signing secret,
#        - an RSA key for the RS256 OIDC realm (go-oidc clients; inert if unused),
#        - the global session-epoch file (a bump = cheap global logout),
#   4. writes an in-userland launcher that wires config from .env and keeps any
#      OIDC client secrets in a 0600 file (NEVER on argv / in /proc/*/cmdline),
#   5. supervises the gateway on 127.0.0.1:${AUTHGW_PORT} and health-checks it.
#
# The gateway does NOT get its own Caddy vhost: it is reached through each app's
# vhost (the commented `forward_auth` + `/authgw/*` block — see docs/APP_AUTH.md
# and docs/MATRIX_AUTH_GW.md for how to turn it on per app).
#
# Generalized from a working deployment; review before running on a fresh phone.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env

# ── Self-gate: only run when explicitly enabled ──────────────────────────────
if [ "${ENABLE_AUTH_GATEWAY:-false}" != "true" ]; then
  ok "auth gateway disabled (ENABLE_AUTH_GATEWAY != true) — skipping (this is the default)"
  exit 0
fi

require_var DOMAIN   "your public domain, e.g. example.com"
require_var DATA_DIR "folder on your large volume / SD card"
require_cmd proot-distro

in_debian() { proot-distro login debian -- bash -lc "$1"; }

# ── Config ───────────────────────────────────────────────────────────────────
GW_PORT="${AUTHGW_PORT:-9095}"                  # loopback bind; reached via Caddy
GW_DIR="/opt/matrix-auth-gw"                    # install dir INSIDE the userland
GW_DATA_USERLAND="${GW_DIR}/data"               # bind target (secrets + state)
GW_DATA_HOST="${DATA_DIR}/auth-gw"              # backing dir on the large volume
GW_SRC="${POCKET_ROOT}/scripts/gateway/matrix-auth-gw.py"
GW_KEYGEN_SRC="${POCKET_ROOT}/scripts/gateway/rsa-der-to-jwk.py"

# Matrix server_name (the ':server' half of an MXID). Defaults to ${DOMAIN} via
# common.sh; the gateway uses it for the OIDC `sub` claim (@localpart:server).
GW_SERVER_NAME="${MATRIX_SERVER_NAME:-${DOMAIN}}"
# Login-page brand. Keep it simple (no single quotes).
GW_BRAND="${AUTHGW_BRAND:-${DOMAIN}}"
# Parent-domain cookie => ONE Matrix login across every *.${DOMAIN} app. Set
# AUTHGW_COOKIE_DOMAIN="" to revert to host-only (each subdomain its own login).
GW_COOKIE_DOMAIN="${AUTHGW_COOKIE_DOMAIN-${DOMAIN}}"
GW_TTL="${AUTHGW_TTL:-2592000}"                 # session lifetime (default 30d)
# Localparts auto-granted the OIDC "admin" role + Remote-Admin header. Empty by
# default (nobody is auto-admin). Bare localparts or full MXIDs, comma-separated.
GW_ADMINS="${AUTHGW_ADMINS:-}"

# Public origins trusted on the login POST (login-CSRF defence). Each gated app's
# own host is auto-trusted by the gateway, but we also list every ENABLED app's
# https origin so the OIDC cross-host authorize flow and any login served from a
# different host are covered. Derived from the ENABLE_* flags in .env.
declare -A _app_host=(
  [ENABLE_LINKDING]="links"   [ENABLE_PINGVIN]="share"  [ENABLE_FRESHRSS]="rss"
  [ENABLE_MEMOS]="notes"      [ENABLE_VIKUNJA]="tasks"   [ENABLE_SEARXNG]="search"
  [ENABLE_ITTOOLS]="tools"    [ENABLE_GATUS]="status"
)
_origins=()
for flag in "${!_app_host[@]}"; do
  if [ "${!flag:-false}" = "true" ]; then
    _origins+=("https://${_app_host[$flag]}.${DOMAIN}")
  fi
done
# Always include the admin host (a portal/landing page may read /authgw/verify).
[ -n "${ADMIN_HOST:-}" ] && _origins+=("https://${ADMIN_HOST}")
GW_PUBLIC_ORIGINS="$(IFS=,; echo "${_origins[*]:-}")"

# ── Preflight: the userland + the source files must exist ────────────────────
[ -f "${GW_SRC}" ]        || die "gateway source missing: ${GW_SRC}"
[ -f "${GW_KEYGEN_SRC}" ] || die "keygen helper missing: ${GW_KEYGEN_SRC}"
in_debian 'true' >/dev/null 2>&1 || die "proot-distro debian not reachable — run scripts/install.sh first"

mkdir -p "${GW_DATA_HOST}"
chmod 700 "${GW_DATA_HOST}" 2>/dev/null || true

# ── 1. python3 in the userland (the gateway is stdlib-only) ──────────────────
run_once authgw-apt -- in_debian \
  "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
     python3 openssl ca-certificates" \
  || die "could not install python3/openssl inside the userland"

# ── 2. Copy the gateway + keygen helper into the userland ────────────────────
# Piped over stdin (not a heredoc) so the Python source crosses verbatim with no
# shell-quoting hazards. The script + launcher live in the rootfs; only the
# secrets/state dir (GW_DATA_USERLAND) is bind-mounted from the large volume.
say "installing the gateway into ${GW_DIR} (inside the userland)"
in_debian "mkdir -p '${GW_DIR}'" || die "could not create ${GW_DIR} in the userland"
proot-distro login debian -- bash -lc "umask 022; cat > '${GW_DIR}/matrix-auth-gw.py'" < "${GW_SRC}" \
  || die "failed to copy the gateway into the userland"
proot-distro login debian -- bash -lc "umask 022; cat > '${GW_DIR}/rsa-der-to-jwk.py'" < "${GW_KEYGEN_SRC}" \
  || die "failed to copy the keygen helper into the userland"
in_debian "python3 -c 'import ast,sys; ast.parse(open(\"${GW_DIR}/matrix-auth-gw.py\").read())'" \
  || die "the copied gateway failed to parse under the userland python3"
ok "gateway installed at ${GW_DIR}"

# ── 3. Generate + persist secrets on the large volume (chmod 600, reused) ─────
# Run inside the userland (openssl + python3 are guaranteed there) with the
# backing dir bind-mounted, so the secrets land on ${DATA_DIR} and survive a
# rootfs rebuild. Each is generated ONCE and reused on every re-run:
#   * authgw-secret.key    — HMAC session-signing secret (rotating it logs all out)
#   * authgw-rsa.json      — RS256 OIDC signing key (inert unless a go-oidc client
#                            is configured); pure {n,e,d} JSON the gateway loads
#   * authgw-session-epoch — seeded to 0; `echo <n+1> > it` = cheap global logout
say "generating gateway secrets under ${GW_DATA_HOST} (chmod 600; reused on re-run)"
proot-distro login debian \
  --bind "${GW_DATA_HOST}:${GW_DATA_USERLAND}" \
  -- bash -lc "
    set -e
    umask 077
    d='${GW_DATA_USERLAND}'
    mkdir -p \"\$d\"
    if [ ! -s \"\$d/authgw-secret.key\" ]; then
      openssl rand -base64 48 | tr -d '\n' > \"\$d/authgw-secret.key\"
      chmod 600 \"\$d/authgw-secret.key\"
    fi
    if [ ! -s \"\$d/authgw-rsa.json\" ]; then
      if openssl genrsa 2048 2>/dev/null \
           | openssl rsa -outform DER -traditional 2>/dev/null \
           | python3 '${GW_DIR}/rsa-der-to-jwk.py' > \"\$d/authgw-rsa.json.tmp\" 2>/dev/null \
         && [ -s \"\$d/authgw-rsa.json.tmp\" ]; then
        mv \"\$d/authgw-rsa.json.tmp\" \"\$d/authgw-rsa.json\"
        chmod 600 \"\$d/authgw-rsa.json\"
      else
        rm -f \"\$d/authgw-rsa.json.tmp\"
        echo 'WARN: RS256 key generation failed — go-oidc clients (e.g. Vikunja/Gatus) OIDC will be inert' >&2
      fi
    fi
    if [ ! -s \"\$d/authgw-session-epoch\" ]; then
      echo 0 > \"\$d/authgw-session-epoch\"
      chmod 600 \"\$d/authgw-session-epoch\"
    fi
  " 2>&1 | grep -v 'proot warning' || true
# Fail closed: the signing secret MUST exist (the gateway refuses to start
# without it). Checked on the HOST path — the userland bind mount only exists
# during the gen command above, not under a plain `in_debian` call.
[ -s "${GW_DATA_HOST}/authgw-secret.key" ] \
  || die "signing secret was not generated at ${GW_DATA_HOST}/authgw-secret.key"
ok "gateway secrets ready under ${GW_DATA_HOST}"

# ── 4. Write the in-userland launcher ────────────────────────────────────────
# All non-secret config is exported here (known at install time). Any OIDC client
# registrations (which embed client SECRETS as id=secret pairs) are NOT written
# here: drop them into ${GW_DATA_HOST}/oidc-clients.env (0600) and the launcher
# sources that file, so secrets stay in a file and never reach argv. See
# docs/MATRIX_AUTH_GW.md for the OIDC client format.
say "writing the launcher → ${GW_DIR}/run.sh"
proot-distro login debian -- bash -lc "umask 077; cat > '${GW_DIR}/run.sh'" <<LAUNCH
#!/bin/bash
# Runs INSIDE the Debian userland; started + kept alive by steps/60-install-auth-gw.sh.
# The gateway binds 127.0.0.1:${GW_PORT}; Caddy fronts the public TLS edge.
export AUTHGW_HOST=127.0.0.1
export AUTHGW_PORT=${GW_PORT}
export AUTHGW_HS_API=http://127.0.0.1:8448/_matrix/client/v3
export AUTHGW_SERVER_NAME='${GW_SERVER_NAME}'
export AUTHGW_BRAND='${GW_BRAND}'
export AUTHGW_COOKIE_DOMAIN='${GW_COOKIE_DOMAIN}'
export AUTHGW_TTL=${GW_TTL}
export AUTHGW_SECRET_FILE=${GW_DATA_USERLAND}/authgw-secret.key
export AUTHGW_SESSION_EPOCH_FILE=${GW_DATA_USERLAND}/authgw-session-epoch
export AUTHGW_OIDC_RS_KEY_FILE=${GW_DATA_USERLAND}/authgw-rsa.json
export AUTHGW_PUBLIC_ORIGINS='${GW_PUBLIC_ORIGINS}'
export AUTHGW_OIDC_ADMINS='${GW_ADMINS}'
export AUTHGW_OIDC_EMAIL_DOMAIN='${DOMAIN}'
# Optional OIDC client registrations (advanced). Keep client secrets in this
# 0600 file — it is sourced here so they reach the gateway via the environment,
# never via argv. It may export AUTHGW_OIDC_CLIENT_ID/SECRET,
# AUTHGW_OIDC_EXTRA_CLIENTS, AUTHGW_OIDC_RS_CLIENTS, AUTHGW_OIDC_PUBLIC_BASE,
# AUTHGW_OIDC_REDIRECT_URIS, AUTHGW_OIDC_RS_OLD_KEYS.
if [ -f ${GW_DATA_USERLAND}/oidc-clients.env ]; then
  set -a; . ${GW_DATA_USERLAND}/oidc-clients.env; set +a
fi
exec python3 ${GW_DIR}/matrix-auth-gw.py
LAUNCH
in_debian "chmod 700 '${GW_DIR}/run.sh'" || die "failed to make ${GW_DIR}/run.sh executable"
ok "wrote the launcher"

# ── 5. Supervise + health-check ──────────────────────────────────────────────
# The shared supervisor (respawn loop + identity-checked pidfile) runs the
# launcher inside the userland with the secrets/state dir bind-mounted in.
supervise auth-gw -- \
  proot-distro login debian \
  --bind "${GW_DATA_HOST}:${GW_DATA_USERLAND}" \
  -- bash "${GW_DIR}/run.sh"

# Wait for health (probe from inside the userland — python3 is guaranteed there).
say "waiting for the gateway health endpoint"
healthy=0
for _ in $(seq 1 20); do
  if in_debian "python3 -c 'import urllib.request; urllib.request.urlopen(\"http://127.0.0.1:${GW_PORT}/authgw/health\", timeout=3).read()'" >/dev/null 2>&1; then
    healthy=1; break
  fi
  sleep 1
done
[ "${healthy}" -eq 1 ] || warn "gateway did not become healthy on 127.0.0.1:${GW_PORT} yet — check ${POCKET_LOG_DIR}/auth-gw.log"
[ "${healthy}" -eq 1 ] && ok "gateway healthy on 127.0.0.1:${GW_PORT}/authgw/health"

# ── Closing notes ─────────────────────────────────────────────────────────────
echo
ok "Matrix-SSO auth gateway installed + supervised (loopback 127.0.0.1:${GW_PORT})"
say "Cookie scope: ${GW_COOKIE_DOMAIN:-host-only}  |  admins: ${GW_ADMINS:-none}"
echo
say "To actually GATE an app with it, edit that app's vhost in /etc/caddy/apps/<app>.caddy:"
say "  1. add a  handle /authgw/* { reverse_proxy 127.0.0.1:${GW_PORT} { header_up X-Real-IP {client_ip} } }"
say "     block BEFORE the catch-all, so the login page + verify endpoint stay reachable;"
say "  2. uncomment the  forward_auth 127.0.0.1:${GW_PORT} { uri /authgw/verify; copy_headers Remote-User }"
say "     block (it must precede the app's reverse_proxy/handle);"
say "  3. validate + reload:  bash ${POCKET_ROOT}/scripts/start-stack.sh --restart"
say "The full per-app recipe (incl. the header-ordering gotcha) is in docs/MATRIX_AUTH_GW.md + docs/APP_AUTH.md."
echo
say "Advanced (native OIDC for apps that speak it): see docs/MATRIX_AUTH_GW.md for the"
say "  ${GW_DATA_HOST}/oidc-clients.env client-registration format."

# Generalized from a working deployment; review before running.
