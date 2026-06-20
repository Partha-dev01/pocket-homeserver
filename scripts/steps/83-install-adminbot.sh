#!/usr/bin/env bash
#
# steps/83-install-adminbot.sh — install + supervise the operator admin bot
# (OPTIONAL, off by default).
#
# The bot (scripts/adminbot/bot.py) is a native python3 process that connects to
# the Matrix homeserver on loopback (http://127.0.0.1:8448), listens in ONE admin
# room (ADMIN_ROOM), and accepts `!commands` ONLY from the operator's MXID
# (ADMIN_MXID). Safe commands run the repo's ops scripts (scripts/ops/*) via a
# FIXED dispatch table (no shell=True, no chat input ever reaches a shell); a few
# read-only commands query the loopback client-server API; and the private-users
# list is edited in-process. See docs/ADMINBOT.md.
#
# It runs TERMUX-NATIVE (NOT inside the proot userland) for the same reason the
# admin panel does: it orchestrates the HOST — it shells out to the host-side ops
# scripts and reads the loopback Matrix API. None of that needs the userland.
#
# It has NO inbound listener and makes NO Caddy change — ZERO new attack surface.
#
# This is a core step that SELF-GATES on ENABLE_ADMINBOT (install.sh runs it
# unconditionally; it no-ops when disabled). ENABLE_ADMINBOT defaults to false.
#
# What it does (idempotent — safe to re-run):
#   1. ensures ${DATA_DIR}/secrets exists (0700) + the log/state dirs exist,
#   2. seeds a ${DATA_DIR}/secrets/adminbot.env TEMPLATE (0600) if absent and
#      then stops with instructions (the operator fills in BOT_TOKEN/ADMIN_ROOM/
#      ADMIN_MXID — secrets never go in .env, never on argv),
#   3. fail-closed checks the bot module is present + parses,
#   4. supervises the bot Termux-native (records its .cmd so start-stack.sh
#      re-supervises it on every bring-up and ops/restart.sh can restart it).
#
# SECRETS: the bot's access token, the admin room id, and the operator MXID live
# ONLY in the 0600 ${DATA_DIR}/secrets/adminbot.env that the launcher SOURCES —
# they are never put in .env and never passed on the command line.
#
# Generalized from a working deployment; review before running on a fresh phone.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env

# ── Self-gate: only run when enabled (default off) ───────────────────────────
if [ "${ENABLE_ADMINBOT:-false}" != "true" ]; then
  ok "adminbot disabled (ENABLE_ADMINBOT != true) — skipping"
  exit 0
fi

require_var DATA_DIR "folder on your large volume / SD card"
require_cmd python3

# ── Paths ─────────────────────────────────────────────────────────────────────
SECRETS_DIR="${DATA_DIR}/secrets"
BOT_DIR="${POCKET_ROOT}/scripts/adminbot"
BOT="${BOT_DIR}/bot.py"
BOT_ENV="${SECRETS_DIR}/adminbot.env"

mkdir -p "${SECRETS_DIR}" "${POCKET_LOG_DIR}" "${POCKET_STATE_DIR}"
chmod 700 "${SECRETS_DIR}" 2>/dev/null || true

# ── Preflight: the bot module must be present + parse-clean (fail-closed) ─────
# Catch a broken/forgotten module at install time, not at first respawn (where it
# would just crash-loop). stdlib-only native python; no userland needed.
[ -f "${BOT}" ] || die "adminbot module missing: ${BOT} — the adminbot module was not shipped"
python3 -c "import ast,sys; ast.parse(open('${BOT}').read())" \
  || die "bot.py failed to parse under python3"
ok "adminbot module present + parse-clean (${BOT})"

# ── 1. Secrets template: seed it (0600) then stop until the operator fills it ─
# The bot needs three secrets the install step CANNOT derive: the @adminbot
# access token, the admin-ops room id, and the operator's own MXID. These live in
# this 0600 file ONLY (never in .env, never on argv). The launcher sources it.
if [ ! -e "${BOT_ENV}" ]; then
  umask 077
  cat > "${BOT_ENV}" <<EOF
# adminbot secrets — 0600, sourced by the supervised launcher. NEVER commit.
#
# Create an @adminbot Matrix account (e.g. register it with your registration
# token), get its access token, and create a PRIVATE admin-ops room that ONLY
# you and the bot are in. Then fill these in:

# REQUIRED — the bot's own access token (used to sync + send). Off-argv.
BOT_TOKEN=

# REQUIRED — the room id (!opaque:${MATRIX_SERVER_NAME:-your.server}) the bot
# listens in. The bot acts ONLY on messages here, ONLY from ADMIN_MXID.
ADMIN_ROOM=

# REQUIRED — your operator MXID. ONLY this sender may issue ! commands.
ADMIN_MXID=@admin:${MATRIX_SERVER_NAME:-your.server}

# OPTIONAL — an access token with ADMIN scope, for privileged queries
# (e.g. !users listing). Leave empty to disable those; they then fail loud
# instead of silently downgrading to the bot's own scope.
ADMIN_TOKEN=
EOF
  chmod 600 "${BOT_ENV}" 2>/dev/null || true
  ok "seeded the adminbot secrets template ${BOT_ENV} (0600)"
  warn "Fill in BOT_TOKEN, ADMIN_ROOM and ADMIN_MXID in ${BOT_ENV}, then re-run this step."
  say  "See docs/ADMINBOT.md for how to create the @adminbot account + admin-ops room."
  exit 0
fi

# Fail-closed: refuse to start with an unfilled template (empty required keys).
# We source it in a SUBSHELL only to validate presence — values never leave it.
chmod 600 "${BOT_ENV}" 2>/dev/null || true
if ! ( set -a; . "${BOT_ENV}"; set +a
       [ -n "${BOT_TOKEN:-}" ] && [ -n "${ADMIN_ROOM:-}" ] && [ -n "${ADMIN_MXID:-}" ] ); then
  die "adminbot secrets incomplete in ${BOT_ENV} — set BOT_TOKEN, ADMIN_ROOM and ADMIN_MXID (see docs/ADMINBOT.md)"
fi
ok "adminbot secrets present (${BOT_ENV})"

# ── 2. Supervise the bot (Termux-native respawn loop + identity-checked pid) ──
# The launcher SOURCES the 0600 secrets file in its own subshell so the secrets
# reach the bot via the environment ONLY — never on argv, never in the recorded
# .cmd. The shared supervisor records the (secret-free) launch argv to
# ${POCKET_STATE_DIR}/adminbot.cmd so start-stack.sh re-supervises it on every
# bring-up and ops/restart.sh can restart it.
LAUNCHER="${BOT_DIR}/run.sh"
cat > "${LAUNCHER}" <<EOF
#!/usr/bin/env bash
# adminbot launcher — sources the 0600 secrets file so BOT_TOKEN/ADMIN_* reach
# the python bot via the environment ONLY (never on argv). Generated by
# steps/83-install-adminbot.sh; regenerated on every (re)install.
set -u
# Non-secret config the bot reads from the environment (baked at install time):
# DATA_DIR locates the private-users list + registration token, POCKET_LOG_DIR
# the append-only audit log, MATRIX_SERVER_NAME the :server half of MXIDs. Export
# them BEFORE the secrets file so !invite-token / !private-list and the audit log
# actually work (they silently no-op when these are unset).
export DATA_DIR='${DATA_DIR}'
export POCKET_LOG_DIR='${POCKET_LOG_DIR}'
export MATRIX_SERVER_NAME='${MATRIX_SERVER_NAME:-$DOMAIN}'
set -a
. "${BOT_ENV}"
set +a
exec python3 "${BOT}"
EOF
chmod 755 "${LAUNCHER}" 2>/dev/null || true

supervise adminbot -- bash "${LAUNCHER}"

# Confirm the python child came up. There is no port to probe (it is a Matrix
# sync client), so we look for the live process by its script path + wait for the
# "booting" log line.
say "confirming the adminbot came up"
up=0
for _ in $(seq 1 15); do
  if grep -q 'booting' "${POCKET_LOG_DIR}/adminbot.log" 2>/dev/null \
     || pgrep -f 'adminbot/bot\.py' >/dev/null 2>&1; then
    up=1; break
  fi
  sleep 1
done
[ "${up}" -eq 1 ] && ok "adminbot running (python child up)" \
  || warn "adminbot did not appear yet — check ${POCKET_LOG_DIR}/adminbot.log"

# ── Closing notes ─────────────────────────────────────────────────────────────
echo
ok "Admin bot installed + supervised"
say "Issue '!help' in your admin-ops room (only ${ADMIN_MXID:-the operator MXID} is obeyed)."
say "Safe commands run scripts/ops/*; a few read-only commands query Matrix on loopback."
say "Restart it with: bash ${POCKET_ROOT}/scripts/ops/restart.sh adminbot"

# Generalized from a working deployment; review before running.
