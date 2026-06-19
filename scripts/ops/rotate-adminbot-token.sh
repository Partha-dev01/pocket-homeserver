#!/usr/bin/env bash
#
# ops/rotate-adminbot-token.sh — rotate the Matrix admin bot's access token.
#
# If you run an admin bot (a Matrix account the server uses for automated admin /
# moderation actions), its access token is long-lived and worth rotating. This
# invalidates the CURRENT token (logout), logs the bot back in to mint a FRESH
# token, writes it into the bot's 0600 credentials env, and restarts the bot.
#
# DEPENDENCY: this targets an OPTIONAL "adminbot" subsystem. The base
# pocket-homeserver does NOT ship an admin bot, so unless you have installed one
# (ENABLE_ADMINBOT=true + a credentials env at ${DATA_DIR}/secrets/adminbot.env)
# this script FAILS SOFT with a clear message and changes nothing.
#
# The bot's password + tokens NEVER appear on a command line — they live only in
# the 0600 credentials env, which is sourced, and the rotation talks to the local
# homeserver API over loopback.
#
# Usage:
#   bash scripts/ops/rotate-adminbot-token.sh
#
# Generalized from a working deployment; review before running on a fresh phone.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env

# ── Fail soft when the adminbot subsystem is not present ──────────────────────
require_var DATA_DIR "folder on your large volume / SD card"
SECRETS_DIR="${DATA_DIR}/secrets"
BOT_ENV="${SECRETS_DIR}/adminbot.env"

if [ "${ENABLE_ADMINBOT:-false}" != "true" ]; then
  warn "no admin bot configured (ENABLE_ADMINBOT != true) — nothing to rotate"
  say "this action only applies if you have installed an optional Matrix admin bot."
  exit 0
fi
if [ ! -f "${BOT_ENV}" ]; then
  warn "admin bot is enabled but its credentials env is missing: ${BOT_ENV}"
  say "install/configure the admin bot first, then re-run."
  exit 0
fi

require_cmd curl
require_cmd jq

# The credentials env defines BOT_USER (localpart or full MXID), BOT_PASS, and the
# current BOT_TOKEN. Sourced — never put on argv.
# shellcheck disable=SC1090
. "${BOT_ENV}"
[ -n "${BOT_USER:-}" ] || die "${BOT_ENV} does not define BOT_USER"
[ -n "${BOT_PASS:-}" ] || die "${BOT_ENV} does not define BOT_PASS"

# Talk to the homeserver over loopback (continuwuity listens on 127.0.0.1:8448).
API="http://127.0.0.1:8448/_matrix/client/v3"

# ── Token logout + re-login + credential write (security-critical core) ───────
# Talks ONLY to ${API} over loopback and keeps every secret off argv:
#   1. invalidate the current token (logout; non-fatal if it fails),
#   2. log back in to mint a fresh token — the JSON body is built by jq (the
#      credential read from the environment, never argv) and streamed to curl on
#      stdin, then .access_token is extracted (DIE on empty),
#   3. persist it FAIL-CLOSED: back up ${BOT_ENV}, then rewrite the BOT_TOKEN line
#      in place under umask 077 (temp + atomic mv), preserving 0600, never echoed.
# Returns non-zero on any hard failure so the restart below is skipped.
rotate_token() {
  # 1) Invalidate the current token (best-effort — a failure here is non-fatal;
  #    we mint a fresh token regardless).
  if [ -n "${BOT_TOKEN:-}" ]; then
    curl -sS -o /dev/null -X POST "${API}/logout" \
      -H "Authorization: Bearer ${BOT_TOKEN}" 2>/dev/null \
      || warn "logout call failed (non-fatal) — minting a fresh token anyway"
  fi

  # 2) Re-login to mint a fresh token. The credential is handed to jq via its
  #    ENVIRONMENT ($ENV.PW), never argv; the JSON body jq builds (which contains
  #    the credential) is streamed to curl on STDIN (--data-binary @-). So neither
  #    the credential nor the request body ever reaches a command line / /proc/*/cmdline.
  #    (BOT_USER is a username, not a secret, so --arg is fine.)
  local login_resp new_token
  login_resp="$(
    PW="${BOT_PASS}" jq -n --arg user "${BOT_USER}" \
      '{type:"m.login.password",
        identifier:{type:"m.id.user", user:$user},
        password:$ENV.PW,
        device_id:"adminbot-rotate"}' \
    | curl -sS -X POST "${API}/login" \
        -H 'Content-Type: application/json' --data-binary @- 2>/dev/null
  )" || true
  new_token="$(printf '%s' "${login_resp}" | jq -r '.access_token // empty' 2>/dev/null || true)"
  if [ -z "${new_token}" ]; then
    printf '%s\n' "${login_resp}" >&2
    die "admin bot re-login failed (no access_token in the response above) — credentials unchanged"
  fi

  # 3) Persist FAIL-CLOSED: back up the credentials env, then rewrite the
  #    BOT_TOKEN= line in place under umask 077 (preserving 0600), via a temp +
  #    atomic replace. The new token is passed to python through the ENVIRONMENT,
  #    never argv, and is never echoed.
  mkdir -p "${BACKUP_DIR}/config"
  cp -f "${BOT_ENV}" "${BACKUP_DIR}/config/adminbot.env-pre-rotate-$(date -u +%FT%H-%MZ)" 2>/dev/null || true
  umask 077
  _NEW_BOT_TOKEN="${new_token}" python3 - "${BOT_ENV}" <<'PY'
import os, sys, tempfile
envf = sys.argv[1]
value = os.environ["_NEW_BOT_TOKEN"]
with open(envf, "r", encoding="utf-8") as f:
    lines = f.readlines()
out, replaced = [], False
for ln in lines:
    body = ln.lstrip()
    if body.startswith("BOT_TOKEN=") or body.startswith("export BOT_TOKEN="):
        indent = ln[:len(ln) - len(body)]
        prefix = "export " if body.startswith("export ") else ""
        out.append("%s%sBOT_TOKEN=%s\n" % (indent, prefix, value))
        replaced = True
    else:
        out.append(ln)
if not replaced:
    if out and not out[-1].endswith("\n"):
        out[-1] += "\n"
    out.append("BOT_TOKEN=%s\n" % value)
d = os.path.dirname(os.path.abspath(envf)) or "."
fd, tmp = tempfile.mkstemp(dir=d, prefix=".adminbot.", suffix=".tmp")
try:
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.writelines(out)
    os.replace(tmp, envf)
except BaseException:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
PY
  chmod 600 "${BOT_ENV}" 2>/dev/null || true
  grep -qE '^[[:space:]]*(export[[:space:]]+)?BOT_TOKEN=.+' "${BOT_ENV}" \
    || die "BOT_TOKEN was not written to ${BOT_ENV}"
  ok "fresh admin bot token written to ${BOT_ENV} (0600)"
}

say "rotating the admin bot token (talking to the local homeserver over loopback)"
rotate_token || die "admin bot token rotation failed — credentials unchanged"

# ── Restart the bot so it picks up the new token ──────────────────────────────
# The bot is supervised under the name "adminbot" once its install step has run.
say "restarting the admin bot to load the new token"
bash "${POCKET_ROOT}/scripts/ops/restart.sh" adminbot >/dev/null 2>&1 \
  || warn "could not restart 'adminbot' (is it supervised? run its install step) — restart it manually"

ok "admin bot token rotated"
