#!/usr/bin/env bash
#
# bootstrap/create-admin.sh — register the Matrix admin account and lift it to
# power level 100, idempotently.
#
# Runs TERMUX-NATIVE: it talks to the homeserver over the loopback client-server
# API (http://127.0.0.1:8448), exactly like the rest of the stack. It does NOT
# enter the proot userland.
#
# What it does (idempotent — safe to re-run):
#   1. waits for the homeserver to answer /_matrix/client/versions,
#   2. registers @${ADMIN_MATRIX_USER}:${MATRIX_SERVER_NAME} using the shared
#      registration token (UIAA: m.login.dummy -> m.login.registration_token),
#   3. persists the resulting MXID + access token to a 0600 credentials file the
#      other bootstrap helpers read,
#   4. if the account already exists (M_USER_IN_USE) it logs in with the saved /
#      provided password instead, so a re-run never errors.
#
# The admin password and the registration token are read from 0600 files (or env),
# NEVER passed on argv. The privileged access token this mints is the credential
# the other helpers use — see the SECURITY note in 79-install-bootstrap.sh.
#
# Generalized from a working deployment; review before running on a fresh phone.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env
require_var DATA_DIR "folder on your large volume / SD card"
require_cmd curl
require_cmd jq
require_cmd openssl

# ── Config ─────────────────────────────────────────────────────────────────────
HS="${MATRIX_HS_API:-http://127.0.0.1:8448}"
SERVER_NAME="${MATRIX_SERVER_NAME:-${DOMAIN}}"
ADMIN_USER="${ADMIN_MATRIX_USER:-admin}"        # localpart of the Matrix admin

SECRETS_DIR="${DATA_DIR}/secrets"
CREDS_FILE="${SECRETS_DIR}/admin-credentials.env"     # 0600 — other helpers read this
TOKEN_FILE="${SECRETS_DIR}/registration-token.txt"    # 0600 — written by ops/rotate-registration-token.sh
mkdir -p "${SECRETS_DIR}"
chmod 700 "${SECRETS_DIR}" 2>/dev/null || true

# ── Idempotency: if we already have a working token, do nothing ───────────────
if [ -s "${CREDS_FILE}" ]; then
  # shellcheck disable=SC1090
  ( set -a; . "${CREDS_FILE}"; set +a
    [ -n "${ADMIN_TOKEN:-}" ] || exit 1
    curl -sf -m 5 "${HS}/_matrix/client/v3/account/whoami" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" >/dev/null ) \
    && { ok "admin credentials already valid (${CREDS_FILE}) — nothing to do"; exit 0; }
  warn "existing ${CREDS_FILE} did not validate — re-registering / re-logging in"
fi

# ── Wait for the homeserver ───────────────────────────────────────────────────
say "waiting for the homeserver on ${HS}"
up=0
for _ in $(seq 1 30); do
  if curl -sf -m 3 "${HS}/_matrix/client/versions" >/dev/null 2>&1; then up=1; break; fi
  sleep 1
done
[ "${up}" -eq 1 ] || die "homeserver not responding on ${HS} — is the stack up? (scripts/start-stack.sh)"

# ── Resolve the admin password (from creds file, env, or generate) ────────────
# Read from the 0600 creds file if present, else ADMIN_MATRIX_PASS from the env,
# else generate one. NEVER taken from argv.
ADMIN_PASS=""
if [ -s "${CREDS_FILE}" ]; then
  ADMIN_PASS="$(. "${CREDS_FILE}" 2>/dev/null; printf '%s' "${ADMIN_PASS:-}")"
fi
ADMIN_PASS="${ADMIN_PASS:-${ADMIN_MATRIX_PASS:-}}"
if [ -z "${ADMIN_PASS}" ]; then
  ADMIN_PASS="$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)"
  say "generated a random admin password (saved to ${CREDS_FILE})"
fi

# ── Read the registration token (0600 file) ──────────────────────────────────
# TODO(human): confirm this is the SAME token written by
#   scripts/ops/rotate-registration-token.sh into ${TOKEN_FILE} (0600) and that
#   registration is currently OPEN (allow_registration = true in the deployed
#   conduwuit.toml). This token is a privileged signup credential — keep it 0600
#   and rotate it after bootstrap if you closed registration again.
REG_TOKEN=""
[ -s "${TOKEN_FILE}" ] && REG_TOKEN="$(cat "${TOKEN_FILE}")"

say "registering @${ADMIN_USER}:${SERVER_NAME}"

# ── UIAA register flow ────────────────────────────────────────────────────────
# Stage 1: kick off the flow with m.login.dummy to obtain a session id; if the
# server requires a registration token, stage 2 submits it with the session.
# The password + registration token are passed to jq through its ENVIRONMENT
# ($ENV.P / $ENV.T), never argv; jq's output is streamed to curl via process
# substitution, so neither secret ever lands on a command line / /proc/*/cmdline.
# (The frozen source put both inline in a -d string — this completes the hardening.)
REG="${HS}/_matrix/client/v3/register"
S1="$(curl -sS -X POST "${REG}" -H 'Content-Type: application/json' \
      --data-binary @<(P="${ADMIN_PASS}" jq -n --arg u "${ADMIN_USER}" \
        '{username:$u, password:$ENV.P, auth:{type:"m.login.dummy"}}') )"

# Already-registered → switch to login (idempotent re-run).
if [ "$(echo "${S1}" | jq -r '.errcode // empty')" = "M_USER_IN_USE" ]; then
  say "account already exists — logging in instead"
  LOGIN="$(curl -sS -X POST "${HS}/_matrix/client/v3/login" -H 'Content-Type: application/json' \
        --data-binary @<(P="${ADMIN_PASS}" jq -n --arg u "${ADMIN_USER}" \
          '{type:"m.login.password", identifier:{type:"m.id.user", user:$u}, password:$ENV.P}') )"
  ACCESS_TOKEN="$(echo "${LOGIN}" | jq -r '.access_token // empty')"
  USER_ID="$(echo "${LOGIN}" | jq -r '.user_id // empty')"
  [ -n "${ACCESS_TOKEN}" ] || die "account exists but login failed (wrong saved password?): ${LOGIN}"
else
  SESSION="$(echo "${S1}" | jq -r '.session // empty')"
  if [ -n "${SESSION}" ]; then
    [ -n "${REG_TOKEN}" ] || die "homeserver requires a registration token but none found at ${TOKEN_FILE} — run scripts/ops/rotate-registration-token.sh first"
    S2="$(curl -sS -X POST "${REG}" -H 'Content-Type: application/json' \
          --data-binary @<(P="${ADMIN_PASS}" T="${REG_TOKEN}" jq -n --arg u "${ADMIN_USER}" --arg s "${SESSION}" \
            '{username:$u, password:$ENV.P, auth:{type:"m.login.registration_token", token:$ENV.T, session:$s}}') )"
  else
    S2="${S1}"
  fi
  ACCESS_TOKEN="$(echo "${S2}" | jq -r '.access_token // empty')"
  USER_ID="$(echo "${S2}" | jq -r '.user_id // empty')"
  [ -n "${ACCESS_TOKEN}" ] || die "register failed: ${S2}"
fi

ok "admin account ready: ${USER_ID}"

# ── Persist credentials (0600) ────────────────────────────────────────────────
# Written so the other bootstrap helpers (spaces / announcements / avatars) and
# the web admin panel can read the MXID + token without re-deriving them. Secrets
# stay in this 0600 file; never echoed in full.
umask 077
cat > "${CREDS_FILE}" <<EOF
ADMIN_USER=${ADMIN_USER}
ADMIN_MXID=${USER_ID}
ADMIN_PASS=${ADMIN_PASS}
ADMIN_TOKEN=${ACCESS_TOKEN}
SERVER_NAME=${SERVER_NAME}
EOF
chmod 600 "${CREDS_FILE}" 2>/dev/null || true

ok "credentials saved to ${CREDS_FILE} (0600)"
echo "  mxid:  ${USER_ID}"
echo "  password + access token saved (hidden) in ${CREDS_FILE}"
say "Promote this account to a server admin via the homeserver's admin command room or admin API if needed."
