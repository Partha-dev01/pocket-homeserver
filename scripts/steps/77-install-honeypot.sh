#!/usr/bin/env bash
#
# steps/77-install-honeypot.sh — install + supervise the honeypot/scanner-detection
# watcher (OPTIONAL, alert-only by default).
#
# The watcher (scripts/honeypot/honeypot-watcher.py) is a native python3 process
# that TAILS the core Caddy JSON access log on the host, classifies high-confidence
# scanner probes (/.env, /.git, /wp-login.php, /phpmyadmin, …) by the real client
# IP, and writes a JSONL audit ledger (${POCKET_LOG_DIR}/honeypot.log). The web
# admin panel reads that ledger to render the Security console.
#
# It runs TERMUX-NATIVE (NOT inside the proot userland) for the same reason the
# admin panel does: it tails the HOST-side Caddy log file and may (optionally) call
# the Cloudflare API and the loopback Matrix client-server API. None of that needs
# the userland.
#
# It has NO inbound listener and makes NO Caddy change — ZERO new attack surface.
#
# This is a core step that SELF-GATES on ENABLE_HONEYPOT (install.sh runs it
# unconditionally; it no-ops when disabled). ENABLE_HONEYPOT defaults to false.
#
# What it does (idempotent — safe to re-run):
#   1. ensures ${DATA_DIR}/secrets exists (0700) and the log dir exists,
#   2. seeds ${DATA_DIR}/secrets/honeypot.mode = alert (0600) if absent,
#   3. seeds a ${DATA_DIR}/secrets/honeypot-safelist.txt template (0600) if absent,
#   4. touches the ledger ${POCKET_LOG_DIR}/honeypot.log (0600),
#   5. fail-closed checks that the watcher + cf_actions modules are present,
#   6. supervises the watcher Termux-native (records its .cmd so start-stack.sh
#      re-supervises it on every bring-up).
#
# DEFAULTS (security): alert-only. Matrix alerting and Cloudflare edge blocking are
# BOTH off until the operator opts in via 0600 files under ${DATA_DIR}/secrets
# (NOT via .env — secrets never go in .env). See docs/HONEYPOT.md.
#
# Generalized from a working deployment; review before running on a fresh phone.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env

# ── Self-gate: only run when enabled (default off) ───────────────────────────
if [ "${ENABLE_HONEYPOT:-false}" != "true" ]; then
  ok "honeypot disabled (ENABLE_HONEYPOT != true) — skipping"
  exit 0
fi

require_var DATA_DIR "folder on your large volume / SD card"
require_cmd python3

# ── Paths ─────────────────────────────────────────────────────────────────────
SECRETS_DIR="${DATA_DIR}/secrets"
HP_DIR="${POCKET_ROOT}/scripts/honeypot"
WATCHER="${HP_DIR}/honeypot-watcher.py"
CF_ACTIONS="${HP_DIR}/cf_actions.py"
MODE_FILE="${SECRETS_DIR}/honeypot.mode"
SAFELIST="${SECRETS_DIR}/honeypot-safelist.txt"
ALLOW_BLOCK_MARKER="${SECRETS_DIR}/honeypot-allow-blocking"
ALERT_ENV="${SECRETS_DIR}/honeypot-alert.env"
CF_ENV="${SECRETS_DIR}/cf-honeypot.env"
LEDGER="${POCKET_LOG_DIR}/honeypot.log"

mkdir -p "${SECRETS_DIR}" "${POCKET_LOG_DIR}" "${POCKET_STATE_DIR}"
chmod 700 "${SECRETS_DIR}" 2>/dev/null || true

# ── Preflight: the watcher + its CF helper must be present (fail-closed) ──────
# Check BOTH before touching the running instance — a deploy that forgot to ship
# cf_actions.py must refuse to (re)start rather than crash-loop the respawn (which
# would silently take an already-running, blocking-capable watcher offline). Both
# are stdlib-only native python; no userland needed.
[ -f "${WATCHER}" ]    || die "honeypot watcher missing: ${WATCHER} — the honeypot module was not shipped"
[ -f "${CF_ACTIONS}" ] || die "honeypot CF helper missing: ${CF_ACTIONS} (honeypot-watcher.py imports it)"

# Fail-closed parse check so a broken module is caught at install time, not at
# first respawn (where it would just loop).
python3 -c "import ast,sys; ast.parse(open('${WATCHER}').read())" \
  || die "honeypot-watcher.py failed to parse under python3"
python3 -c "import ast,sys; ast.parse(open('${CF_ACTIONS}').read())" \
  || die "cf_actions.py failed to parse under python3"
ok "honeypot modules present + parse-clean (${HP_DIR})"

# ── 1. Mode file: default to alert-only if unset ─────────────────────────────
# The watcher hot-reloads this file. Default (and the only value that ships) is
# `alert`: ledger + (optional) Matrix, never an edge action. challenge/block are
# additionally gated by the opt-in marker AND the CF token-scope self-check below.
if [ ! -s "${MODE_FILE}" ]; then
  printf 'alert\n' > "${MODE_FILE}"
  chmod 600 "${MODE_FILE}" 2>/dev/null || true
  say "initialized ${MODE_FILE} = alert (alert-only; see docs/HONEYPOT.md to enable challenge/block)"
else
  say "keeping existing mode file ${MODE_FILE} ($(head -n1 "${MODE_FILE}" 2>/dev/null || echo '?'))"
fi

# ── 2. Safelist template (operator IPs/CIDRs never alerted or blocked) ───────
# Loopback + all Cloudflare edge ranges are built into the watcher; this file is
# for the operator's own egress / known-good IPs or CIDRs (one per line).
if [ ! -e "${SAFELIST}" ]; then
  {
    echo "# honeypot safelist — operator IPs/CIDRs never alerted on or blocked."
    echo "# Loopback + all Cloudflare edge ranges are ALREADY built in."
    echo "# One IPv4/IPv6 address or CIDR per line; '#' comments allowed."
  } > "${SAFELIST}"
  chmod 600 "${SAFELIST}" 2>/dev/null || true
  say "seeded the safelist template ${SAFELIST}"
fi

# ── 3. The ledger (0600; the panel reads it; the watcher appends to it) ──────
touch "${LEDGER}" 2>/dev/null || true
chmod 600 "${LEDGER}" 2>/dev/null || true

# ── 4. Surface the opt-in state so the operator knows what is actually active ─
# Alerting state (ledger-only vs Matrix).
if [ -f "${ALERT_ENV}" ]; then
  say "Matrix alert config present (${ALERT_ENV}) — the watcher will also POST alerts to your Matrix room"
else
  say "Matrix alerting OFF — ledger-only. Create ${ALERT_ENV} (HP_MATRIX_HS/HP_MATRIX_TOKEN/HP_MATRIX_ROOM, chmod 600) to enable it (see docs/HONEYPOT.md)"
fi

# Blocking state (the triple gate: mode + marker + token-scope self-check).
if [ -f "${ALLOW_BLOCK_MARKER}" ] && [ -f "${CF_ENV}" ]; then
  warn "blocking opt-in PRESENT (${ALLOW_BLOCK_MARKER}) + ${CF_ENV} — challenge/block modes CAN take effect (subject to the watcher's CF token over-scope self-check)"
else
  say "edge blocking OFF (alert-only). To enable: create ${CF_ENV} (CF_API_TOKEN/CF_ACCOUNT_ID) AND the marker ${ALLOW_BLOCK_MARKER}, then set ${MODE_FILE} to challenge/block (see docs/HONEYPOT.md)"
fi

# ── 5. Watcher launcher: pin the SQLite DB to the INTERNAL ext4 filesystem ───
# honeypot_db.py defaults its SQLite DB to ${POCKET_STATE_DIR}/honeypot.db, which
# sits under DATA_DIR — and DATA_DIR is typically the exFAT SD card, where SQLite
# WAL/locking misbehaves (and can corrupt). It honors an HP_DB env override, so we
# point it at the Termux home, which is real ext4 — the SAME $HOME/.pocket ext4
# precedent the boot watchdog uses for exec-safe files. The watcher runs
# Termux-native, so $HOME here is the Termux ext4 home. POCKET_HONEYPOT_DB lets an
# operator override the location if their layout differs.
HP_DB_PATH="${POCKET_HONEYPOT_DB:-$HOME/.pocket/honeypot/honeypot.db}"
mkdir -p "$(dirname "${HP_DB_PATH}")"
chmod 700 "$(dirname "${HP_DB_PATH}")" 2>/dev/null || true

# A tiny native launcher exports HP_DB into the watcher's env (never on argv) and
# execs it. supervise records THIS launcher in the .cmd, so start-stack.sh and
# ops/restart.sh re-supervise the exact same env-pinned command on every bring-up.
HP_LAUNCHER="$HOME/.pocket/honeypot/run-watcher.sh"
say "writing the honeypot watcher launcher -> ${HP_LAUNCHER} (HP_DB on ext4)"
( umask 077; cat > "${HP_LAUNCHER}" <<LAUNCH
#!/usr/bin/env bash
# Native honeypot watcher launcher — written by steps/77-install-honeypot.sh.
# Pins the SQLite DB to ext4 (HP_DB) so it NEVER lands on the exFAT SD card, then
# execs the watcher. No secrets on argv (the watcher reads its own 0600 files).
export HP_DB="${HP_DB_PATH}"
exec python3 "${WATCHER}"
LAUNCH
)
chmod 700 "${HP_LAUNCHER}"

# ── 6. Supervise the watcher (Termux-native respawn loop + identity-checked pid) ─
# The shared supervisor records the launch argv to ${POCKET_STATE_DIR}/honeypot-watcher.cmd
# so start-stack.sh re-supervises it on every bring-up and ops/restart.sh can
# restart it. The watcher reads its OPTIONAL Matrix token from the 0600
# honeypot-alert.env file itself (never on argv); we pass it nothing sensitive.
supervise honeypot-watcher -- bash "${HP_LAUNCHER}"

# Confirm the python child came up. There is no port to probe (it is a log tailer),
# so we look for the live process by its script path.
say "confirming the honeypot watcher came up"
up=0
for _ in $(seq 1 10); do
  if pgrep -f 'honeypot-watcher\.py' >/dev/null 2>&1; then
    up=1; break
  fi
  sleep 1
done
[ "${up}" -eq 1 ] && ok "honeypot watcher running (python child up)" \
  || warn "honeypot watcher did not appear yet — check ${POCKET_LOG_DIR}/honeypot-watcher.log"

# ── Closing notes ─────────────────────────────────────────────────────────────
echo
ok "Honeypot watcher installed + supervised (alert-only; ledger ${LEDGER})"
say "It tails the core Caddy access log and ledgers high-confidence scanner probes."
say "Read the Security console in the web admin panel (/honeypot) to review hits."
say "Alert-only by default. To enable Matrix alerts or Cloudflare edge blocking,"
say "create the 0600 opt-in files under ${SECRETS_DIR} — see docs/HONEYPOT.md."

# Generalized from a working deployment; review before running.
