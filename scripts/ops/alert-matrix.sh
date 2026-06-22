#!/usr/bin/env bash
#
# ops/alert-matrix.sh — a POCKET_ALERT_CMD target that posts a crash-loop alert to
# a Matrix room.
#
# The supervisor (scripts/lib/common.sh) runs POCKET_ALERT_CMD once, via `sh -c`,
# when ANY service enters DEGRADED, with the context in the ENVIRONMENT (never on
# argv): POCKET_ALERT_SERVICE / POCKET_ALERT_RC / POCKET_ALERT_FAILS. Point
# POCKET_ALERT_CMD at this script to turn that into a Matrix message:
#
#     POCKET_ALERT_CMD='bash "/abs/path/scripts/ops/alert-matrix.sh"'
#
# (setup.sh writes that for you if you pick the Matrix channel.)
#
# Config is read from a 0600 file so the access token NEVER goes in .env or on a
# command line — the same pattern the honeypot Matrix alert uses:
#
#     ${DATA_DIR}/secrets/alert-matrix.env   (chmod 600)
#       ALERT_MATRIX_HS=http://127.0.0.1:8448          # homeserver base (loopback is fine)
#       ALERT_MATRIX_TOKEN=<access token of a bot/admin account already in the room>
#       ALERT_MATRIX_ROOM=!abcdef:your.domain          # internal room id (NOT an alias)
#
# Best-effort by design: short timeout, never blocks the supervisor, and exits 0
# even when it can't send (a broken alert must not become its own failure).
#
# Generalized from a working deployment; review before running on a fresh phone.

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env

CONF="${DATA_DIR:-}/secrets/alert-matrix.env"
if [ ! -s "${CONF}" ]; then
  echo "alert-matrix: ${CONF} missing — create it (0600) to enable Matrix alerts" >&2
  exit 0
fi
# shellcheck disable=SC1090
set -a; . "${CONF}"; set +a

HS="${ALERT_MATRIX_HS:-http://127.0.0.1:8448}"
TOK="${ALERT_MATRIX_TOKEN:-}"
ROOM="${ALERT_MATRIX_ROOM:-}"
if [ -z "${TOK}" ] || [ -z "${ROOM}" ]; then
  echo "alert-matrix: ALERT_MATRIX_TOKEN / ALERT_MATRIX_ROOM unset in ${CONF}" >&2
  exit 0
fi
command -v curl >/dev/null 2>&1 || { echo "alert-matrix: curl missing" >&2; exit 0; }
command -v jq   >/dev/null 2>&1 || { echo "alert-matrix: jq missing"   >&2; exit 0; }

svc="${POCKET_ALERT_SERVICE:-?}"
rc="${POCKET_ALERT_RC:-?}"
fails="${POCKET_ALERT_FAILS:-?}"
msg="⚠ pocket-homeserver: service '${svc}' is crash-looping (rc=${rc}, ${fails} rapid failures). Check its log + docs/RESILIENCE.md."

# URL-encode the room id (it contains '!' and ':') for the path; build the JSON
# body with jq so the message is properly escaped; the token stays in the header.
ROOM_ENC="$(printf '%s' "${ROOM}" | jq -sRr @uri)"
TXN="$(date -u +%s)$$"

curl -fsS -m 12 -X PUT \
  "${HS%/}/_matrix/client/v3/rooms/${ROOM_ENC}/send/m.room.message/${TXN}" \
  -H "Authorization: Bearer ${TOK}" \
  -H 'Content-Type: application/json' \
  --data-binary @<(M="${msg}" jq -n '{msgtype:"m.text", body:$ENV.M}') \
  >/dev/null 2>&1 || echo "alert-matrix: send failed (best-effort)" >&2

exit 0
