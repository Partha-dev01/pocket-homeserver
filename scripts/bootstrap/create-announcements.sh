#!/usr/bin/env bash
#
# bootstrap/create-announcements.sh — create a public #announcements room where
# everyone can READ but only the admin (power level 100) can POST, link it into
# the hub Space, and post a one-time welcome message. Idempotent: an existing
# announcements room (by alias) is reused and the welcome is not re-posted.
#
# It locks posting down via power_level_content_override.events_default = 100, so
# only users at power 100 (the admin) can send messages or state.
#
# Runs TERMUX-NATIVE: it talks to the homeserver over the loopback client-server
# API (http://127.0.0.1:8448). It does NOT enter the proot userland.
#
# The admin access token is read from the 0600 credentials file written by
# create-admin.sh and is NEVER passed on argv. The hub Space id is read from the
# audit trail written by create-spaces.sh.
#
# Generalized from a working deployment; review before running on a fresh phone.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env
require_var DATA_DIR "folder on your large volume / SD card"
require_cmd curl
require_cmd jq

HS="${MATRIX_HS_API:-http://127.0.0.1:8448}"
API="${HS}/_matrix/client/v3"
SERVER_NAME="${MATRIX_SERVER_NAME:-${DOMAIN}}"

SECRETS_DIR="${DATA_DIR}/secrets"
CREDS_FILE="${SECRETS_DIR}/admin-credentials.env"
STATE_FILE="${POCKET_STATE_DIR}/matrix-space-structure.json"

ANN_ALIAS="${MATRIX_ANNOUNCE_ALIAS:-announcements}"
ANN_NAME="${MATRIX_ANNOUNCE_NAME:-announcements}"
ANN_TOPIC="${MATRIX_ANNOUNCE_TOPIC:-Server announcements — admin only can post. Everyone can read.}"
ANN_WELCOME="${MATRIX_ANNOUNCE_WELCOME:-Welcome to #announcements. Only the admin can post here. Everyone can read.}"

# ── Read admin credentials (token NEVER on argv) ─────────────────────────────
# TODO(human): ADMIN_TOKEN sourced here is a privileged homeserver token. Confirm
# the creds file is 0600 and that you accept any reader of it can create rooms.
[ -s "${CREDS_FILE}" ] || die "admin credentials missing at ${CREDS_FILE} — run scripts/bootstrap/create-admin.sh first"
# shellcheck disable=SC1090
ADMIN_TOKEN="$(set -a; . "${CREDS_FILE}"; printf '%s' "${ADMIN_TOKEN:-}")"
ADMIN_MXID="$(set -a; . "${CREDS_FILE}"; printf '%s' "${ADMIN_MXID:-}")"
[ -n "${ADMIN_TOKEN}" ] || die "ADMIN_TOKEN empty in ${CREDS_FILE}"
[ -n "${ADMIN_MXID}" ]  || ADMIN_MXID="@${ADMIN_MATRIX_USER:-admin}:${SERVER_NAME}"
AUTH="Authorization: Bearer ${ADMIN_TOKEN}"

resolve_alias() {
  local localpart="$1" alias enc resp
  alias="#${localpart}:${SERVER_NAME}"
  enc="$(jq -rn --arg a "${alias}" '$a|@uri')"
  resp="$(curl -sS "${API}/directory/room/${enc}" -H "${AUTH}")"
  echo "${resp}" | jq -r '.room_id // empty'
}

# ── 1. Create (or reuse) the announcements room ──────────────────────────────
ANN_ID="$(resolve_alias "${ANN_ALIAS}")"
EXISTED=0
if [ -n "${ANN_ID}" ]; then
  ok "#${ANN_ALIAS} already exists -> ${ANN_ID}"
  EXISTED=1
else
  say "creating #${ANN_ALIAS} (public read, admin-only posting)"
  BODY="$(jq -n --arg admin "${ADMIN_MXID}" --arg name "${ANN_NAME}" \
            --arg topic "${ANN_TOPIC}" --arg alias "${ANN_ALIAS}" '{
    name:$name, topic:$topic, visibility:"public", preset:"public_chat",
    room_alias_name:$alias,
    power_level_content_override:{
      users:{($admin):100}, users_default:0, events_default:100, state_default:100,
      ban:50, kick:50, redact:50, invite:50,
      events:{
        "m.room.name":100, "m.room.power_levels":100, "m.room.history_visibility":100,
        "m.room.canonical_alias":100, "m.room.avatar":100, "m.room.topic":100,
        "m.room.encryption":100
      }
    }
  }')"
  RESP="$(curl -sS -X POST "${API}/createRoom" -H "${AUTH}" \
            -H 'Content-Type: application/json' --data-binary "${BODY}")"
  ANN_ID="$(echo "${RESP}" | jq -r '.room_id // empty')"
  [ -n "${ANN_ID}" ] || { echo "${RESP}" >&2; die "createRoom for #${ANN_ALIAS} failed"; }
  ok "announcements room: ${ANN_ID}"
fi

# ── 2. Link into the hub Space (best-effort; needs the spaces audit trail) ───
if [ -s "${STATE_FILE}" ]; then
  SPACE_ID="$(jq -r '.space.id // empty' "${STATE_FILE}")"
  if [ -n "${SPACE_ID}" ]; then
    say "linking #${ANN_ALIAS} into the hub Space"
    VIA="$(jq -rn --arg s "${SERVER_NAME}" '$s')"
    sp="$(jq -rn --arg r "${SPACE_ID}" '$r|@uri')"
    ch="$(jq -rn --arg r "${ANN_ID}" '$r|@uri')"
    curl --globoff -sS -o /dev/null -w '  m.space.child:  HTTP %{http_code}\n' -X PUT \
        "${API}/rooms/${sp}/state/m.space.child/${ch}" -H "${AUTH}" \
        -H 'Content-Type: application/json' \
        --data-binary "$(jq -n --arg v "${VIA}" '{via:[$v], suggested:true}')"
    curl --globoff -sS -o /dev/null -w '  m.space.parent: HTTP %{http_code}\n' -X PUT \
        "${API}/rooms/${ch}/state/m.space.parent/${sp}" -H "${AUTH}" \
        -H 'Content-Type: application/json' \
        --data-binary "$(jq -n --arg v "${VIA}" '{via:[$v], canonical:true}')"
    # Record the announcements room in the audit trail (idempotent: drop any prior
    # entry with the same id first).
    TMP="$(mktemp)"
    jq --arg id "${ANN_ID}" --arg alias "#${ANN_ALIAS}:${SERVER_NAME}" '
        .public_rooms = ((.public_rooms // []) | map(select(.id != $id)))
                        + [{alias:$alias, id:$id, posting:"admin-only"}]
      ' "${STATE_FILE}" > "${TMP}" && mv "${TMP}" "${STATE_FILE}"
  fi
else
  warn "no space structure at ${STATE_FILE} — created the room but did not link it into a Space (run create-spaces.sh first)"
fi

# ── 3. Post the one-time welcome (only on first creation) ────────────────────
if [ "${EXISTED}" -eq 0 ]; then
  say "posting the welcome announcement"
  TXN="$(date +%s%N)"
  ch="$(jq -rn --arg r "${ANN_ID}" '$r|@uri')"
  curl -sS -o /dev/null -X PUT "${API}/rooms/${ch}/send/m.room.message/${TXN}" \
      -H "${AUTH}" -H 'Content-Type: application/json' \
      --data-binary "$(jq -n --arg b "${ANN_WELCOME}" '{msgtype:"m.text", body:$b}')"
fi

ok "announcements ready — #${ANN_ALIAS}:${SERVER_NAME} (admin-post-only)"
