#!/usr/bin/env bash
#
# bootstrap/create-spaces.sh — create a default Matrix Space (a community hub) with
# a handful of public child rooms plus one private, end-to-end-encrypted room, and
# link the public rooms into the Space. Idempotent: existing rooms are detected by
# their alias and reused instead of recreated.
#
# Runs TERMUX-NATIVE: it talks to the homeserver over the loopback client-server
# API (http://127.0.0.1:8448). It does NOT enter the proot userland.
#
# The structure is a TEMPLATE — edit the SPACE_* / room arrays below to suit your
# community. Room names, topics, and aliases all default to neutral placeholders
# and can be overridden from the environment.
#
# The admin access token is read from the 0600 credentials file written by
# create-admin.sh and is NEVER passed on argv.
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
STATE_FILE="${POCKET_STATE_DIR}/matrix-space-structure.json"   # audit trail (host-side)

# ── Read admin credentials (token NEVER on argv) ─────────────────────────────
# OPERATOR NOTE: ADMIN_TOKEN sourced here is a privileged homeserver token. Confirm
# the creds file is 0600 and that you accept any reader of it can create rooms.
[ -s "${CREDS_FILE}" ] || die "admin credentials missing at ${CREDS_FILE} — run scripts/bootstrap/create-admin.sh first"
# shellcheck disable=SC1090
ADMIN_TOKEN="$(set -a; . "${CREDS_FILE}"; printf '%s' "${ADMIN_TOKEN:-}")"
ADMIN_MXID="$(set -a; . "${CREDS_FILE}"; printf '%s' "${ADMIN_MXID:-}")"
[ -n "${ADMIN_TOKEN}" ] || die "ADMIN_TOKEN empty in ${CREDS_FILE}"
[ -n "${ADMIN_MXID}" ]  || ADMIN_MXID="@${ADMIN_MATRIX_USER:-admin}:${SERVER_NAME}"
AUTH="Authorization: Bearer ${ADMIN_TOKEN}"

# ── Structure template (override via env; neutral defaults) ──────────────────
# The hub Space.
SPACE_ALIAS="${MATRIX_SPACE_ALIAS:-hub}"
SPACE_NAME="${MATRIX_SPACE_NAME:-Community Hub}"
SPACE_TOPIC="${MATRIX_SPACE_TOPIC:-The landing space for community chat.}"

# Public child rooms — "alias|name|topic" rows. Edit freely.
PUBLIC_ROOMS=(
  "general|general|General chat — be kind, stay on-topic."
  "tech|technology|Tech, software, hardware, projects."
  "random|random|Off-topic and watercooler."
)

# A private, invite-only, E2EE room (the admin is invited). Set
# MATRIX_PRIVATE_ROOM_ALIAS="" to skip it.
PRIVATE_ROOM_ALIAS="${MATRIX_PRIVATE_ROOM_ALIAS:-private}"
PRIVATE_ROOM_NAME="${MATRIX_PRIVATE_ROOM_NAME:-Private room}"
PRIVATE_ROOM_TOPIC="${MATRIX_PRIVATE_ROOM_TOPIC:-Invite-only, end-to-end encrypted.}"

say "homeserver: ${SERVER_NAME}  admin: ${ADMIN_MXID}"

# ── Helpers ───────────────────────────────────────────────────────────────────
# resolve_alias ALIAS_LOCALPART -> prints room_id (empty if unresolved).
resolve_alias() {
  local localpart="$1" alias enc resp
  alias="#${localpart}:${SERVER_NAME}"
  enc="$(jq -rn --arg a "${alias}" '$a|@uri')"
  resp="$(curl -sS "${API}/directory/room/${enc}" -H "${AUTH}")"
  echo "${resp}" | jq -r '.room_id // empty'
}

# create_room BODY_JSON LABEL -> prints room_id; idempotent via the alias.
create_room() {
  local body="$1" label="$2" resp rid
  resp="$(curl -sS -X POST "${API}/createRoom" -H "${AUTH}" \
            -H 'Content-Type: application/json' --data-binary "${body}")"
  rid="$(echo "${resp}" | jq -r '.room_id // empty')"
  if [ -z "${rid}" ]; then
    # Alias already taken => the room exists from a previous run: reuse it.
    if [ "$(echo "${resp}" | jq -r '.errcode // empty')" = "M_ROOM_IN_USE" ]; then
      rid="$(resolve_alias "${label}")"
      [ -n "${rid}" ] && { ok "reusing existing ${label} -> ${rid}"; echo "${rid}"; return 0; }
    fi
    warn "create ${label} failed: ${resp}"
    return 1
  fi
  ok "created ${label} -> ${rid}"
  echo "${rid}"
}

# link_space_child SPACE_ID CHILD_ID [SUGGESTED] — m.space.child + reverse parent.
link_space_child() {
  local space="$1" child="$2" suggested="${3:-true}" via sp ch
  via="$(jq -rn --arg s "${SERVER_NAME}" '$s')"
  sp="$(jq -rn --arg r "${space}" '$r|@uri')"
  ch="$(jq -rn --arg r "${child}" '$r|@uri')"
  curl --globoff -sS -o /dev/null -X PUT \
      "${API}/rooms/${sp}/state/m.space.child/${ch}" -H "${AUTH}" \
      -H 'Content-Type: application/json' \
      --data-binary "$(jq -n --arg v "${via}" --argjson sug "${suggested}" '{via:[$v], suggested:$sug}')"
  curl --globoff -sS -o /dev/null -X PUT \
      "${API}/rooms/${ch}/state/m.space.parent/${sp}" -H "${AUTH}" \
      -H 'Content-Type: application/json' \
      --data-binary "$(jq -n --arg v "${via}" '{via:[$v], canonical:true}')"
}

# ── 1. The hub Space ──────────────────────────────────────────────────────────
say "creating the hub Space (#${SPACE_ALIAS}:${SERVER_NAME})"
SPACE_ID="$(resolve_alias "${SPACE_ALIAS}")"
if [ -n "${SPACE_ID}" ]; then
  ok "hub Space already exists -> ${SPACE_ID}"
else
  SPACE_ID="$(create_room "$(jq -n \
      --arg name "${SPACE_NAME}" --arg topic "${SPACE_TOPIC}" --arg alias "${SPACE_ALIAS}" '{
        name:$name, topic:$topic, visibility:"public", preset:"public_chat",
        room_alias_name:$alias, creation_content:{type:"m.space"},
        initial_state:[{type:"m.room.history_visibility", state_key:"",
                        content:{history_visibility:"world_readable"}}]
      }')" "${SPACE_ALIAS}")" || die "hub Space creation failed"
fi

# ── 2. Public child rooms ─────────────────────────────────────────────────────
declare -a PUB_IDS=() PUB_ALIASES=()
for row in "${PUBLIC_ROOMS[@]}"; do
  IFS='|' read -r r_alias r_name r_topic <<<"${row}"
  say "creating #${r_alias}"
  rid="$(resolve_alias "${r_alias}")"
  if [ -z "${rid}" ]; then
    rid="$(create_room "$(jq -n --arg name "${r_name}" --arg topic "${r_topic}" --arg alias "${r_alias}" '{
            name:$name, topic:$topic, visibility:"public", preset:"public_chat", room_alias_name:$alias
          }')" "${r_alias}")" || { warn "skipping #${r_alias}"; continue; }
  else
    ok "#${r_alias} already exists -> ${rid}"
  fi
  PUB_IDS+=("${rid}"); PUB_ALIASES+=("#${r_alias}:${SERVER_NAME}")
done

# ── 3. Private, invite-only, E2EE room ────────────────────────────────────────
PRIV_ID=""
if [ -n "${PRIVATE_ROOM_ALIAS}" ]; then
  say "creating private #${PRIVATE_ROOM_ALIAS} (invite-only, E2EE)"
  PRIV_ID="$(resolve_alias "${PRIVATE_ROOM_ALIAS}")"
  if [ -z "${PRIV_ID}" ]; then
    PRIV_ID="$(create_room "$(jq -n \
        --arg name "${PRIVATE_ROOM_NAME}" --arg topic "${PRIVATE_ROOM_TOPIC}" \
        --arg alias "${PRIVATE_ROOM_ALIAS}" --arg admin "${ADMIN_MXID}" '{
          name:$name, topic:$topic, visibility:"private", preset:"private_chat",
          room_alias_name:$alias, invite:[$admin],
          initial_state:[{type:"m.room.encryption", state_key:"",
                          content:{algorithm:"m.megolm.v1.aes-sha2"}}]
        }')" "${PRIVATE_ROOM_ALIAS}")" || warn "private room creation failed"
  else
    ok "private #${PRIVATE_ROOM_ALIAS} already exists -> ${PRIV_ID}"
  fi
fi

# ── 4. Link public rooms into the Space (the private room stays hidden) ──────
say "linking public rooms into the hub Space"
for rid in "${PUB_IDS[@]}"; do
  [ -n "${rid}" ] && link_space_child "${SPACE_ID}" "${rid}" true
done

# ── 5. Write the audit trail (host-side state) ───────────────────────────────
mkdir -p "${POCKET_STATE_DIR}"
{
  printf '{\n'
  printf '  "created_at": "%s",\n' "$(date -u +%FT%TZ)"
  printf '  "server_name": "%s",\n' "${SERVER_NAME}"
  printf '  "admin": "%s",\n' "${ADMIN_MXID}"
  printf '  "space": {"alias": "#%s:%s", "id": "%s"},\n' "${SPACE_ALIAS}" "${SERVER_NAME}" "${SPACE_ID}"
  printf '  "public_rooms": ['
  for i in "${!PUB_IDS[@]}"; do
    [ "${i}" -gt 0 ] && printf ','
    printf '{"alias": "%s", "id": "%s"}' "${PUB_ALIASES[$i]}" "${PUB_IDS[$i]}"
  done
  printf '],\n'
  printf '  "private_rooms": ['
  [ -n "${PRIV_ID}" ] && printf '{"alias": "#%s:%s", "id": "%s", "encryption": "m.megolm.v1.aes-sha2"}' \
      "${PRIVATE_ROOM_ALIAS}" "${SERVER_NAME}" "${PRIV_ID}"
  printf ']\n}\n'
} > "${STATE_FILE}"
# Pretty-print + validate (fail loud if our hand-built JSON is malformed).
jq '.' "${STATE_FILE}" >/dev/null || die "wrote invalid JSON to ${STATE_FILE}"

ok "space structure saved to ${STATE_FILE}"
say "Space: #${SPACE_ALIAS}:${SERVER_NAME}  (${#PUB_IDS[@]} public room(s)$( [ -n "${PRIV_ID}" ] && echo ' + 1 private E2EE room'))"
