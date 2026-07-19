#!/usr/bin/env bash
#
# bootstrap/mint-invite-token.sh — mint N single-use Matrix registration (invite)
# tokens via the homeserver admin API, and append them (one per line, with their
# expiry) to a 0600 file you can hand out.
#
# Runs TERMUX-NATIVE: it talks to the homeserver over the loopback admin API
# (http://127.0.0.1:8448/_synapse/admin/v1/registration_tokens/new), the same API
# continuwuity/conduwuit exposes for token management. It does NOT enter the proot
# userland.
#
# Usage:  scripts/bootstrap/mint-invite-token.sh [N]      (default N=1)
#         INVITE_TOKEN_DAYS=7 scripts/bootstrap/mint-invite-token.sh 5
#
# Each token is one-use and self-expires after INVITE_TOKEN_DAYS days. The admin
# access token is read from the 0600 credentials file written by create-admin.sh
# and is NEVER passed on argv.
#
# Generalized from a working deployment; review before running on a fresh phone.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env
require_var DATA_DIR "folder on your large volume / SD card"
require_cmd curl
require_cmd jq
require_cmd openssl

N="${1:-1}"
[ "${N}" -gt 0 ] 2>/dev/null || die "usage: $(basename "$0") <N>  (positive integer)"
DAYS="${INVITE_TOKEN_DAYS:-7}"

HS="${MATRIX_HS_API:-http://127.0.0.1:8448}"
SECRETS_DIR="${DATA_DIR}/secrets"
CREDS_FILE="${SECRETS_DIR}/admin-credentials.env"
OUT="${SECRETS_DIR}/invite-tokens.txt"

# ── Read the admin token from the 0600 creds file (NEVER from argv) ──────────
# OPERATOR NOTE: the value sourced here (ADMIN_TOKEN) is a privileged homeserver
# access token — it can create accounts and read the admin API. Confirm the file
# is 0600, owned by you, and that you are comfortable that any process able to
# read ${CREDS_FILE} can mint signup tokens.
[ -s "${CREDS_FILE}" ] || die "admin credentials missing at ${CREDS_FILE} — run scripts/bootstrap/create-admin.sh first"
# shellcheck disable=SC1090
ADMIN_TOKEN="$(set -a; . "${CREDS_FILE}"; printf '%s' "${ADMIN_TOKEN:-}")"
[ -n "${ADMIN_TOKEN}" ] || die "ADMIN_TOKEN empty in ${CREDS_FILE}"

EXPIRY_MS=$(( ($(date +%s) + DAYS * 86400) * 1000 ))

mkdir -p "${SECRETS_DIR}"
chmod 700 "${SECRETS_DIR}" 2>/dev/null || true
umask 077
touch "${OUT}"; chmod 600 "${OUT}" 2>/dev/null || true

say "minting ${N} invite token(s) (${DAYS}-day expiry, 1 use each)"
minted=0
for _ in $(seq 1 "${N}"); do
  TOK="$(openssl rand -hex 16)"
  RESP="$(curl -sS -X POST "${HS}/_synapse/admin/v1/registration_tokens/new" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" \
      -H 'Content-Type: application/json' \
      --data-binary @<(T="${TOK}" jq -n --argjson exp "${EXPIRY_MS}" \
        '{token:$ENV.T, uses_allowed:1, expiry_time:$exp}') )"
  GOT="$(echo "${RESP}" | jq -r '.token // empty')"
  if [ -n "${GOT}" ]; then
    printf '%s  # expires %s\n' "${GOT}" "$(date -ud "@$((EXPIRY_MS/1000))" +%FT%TZ)" >> "${OUT}"
    minted=$((minted+1))
    printf '.' >&2
  else
    echo >&2; warn "mint failed: ${RESP}"
  fi
done
echo >&2

[ "${minted}" -gt 0 ] || die "no tokens minted — check the admin token and that the homeserver admin API is reachable"
ok "minted ${minted} token(s) -> ${OUT} (0600)"
say "Share one line per invited user over a private channel; each self-expires after a single use or ${DAYS} days."
