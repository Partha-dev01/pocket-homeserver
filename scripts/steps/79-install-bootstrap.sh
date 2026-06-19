#!/usr/bin/env bash
#
# steps/79-install-bootstrap.sh — OPT-IN Matrix bootstrap. After the homeserver is
# up, this seeds the things a fresh server usually wants: an admin account, a
# community hub Space with a few rooms, an admin-only announcements room, and
# (optionally) avatars. Every helper is idempotent, so this is safe to re-run.
#
# It runs TERMUX-NATIVE: the helpers talk to the homeserver over the loopback
# client-server API (http://127.0.0.1:8448), the same way start-stack.sh runs it.
# They do NOT enter the proot userland.
#
# This is a core step that SELF-GATES on ENABLE_BOOTSTRAP (install.sh runs it
# unconditionally; it no-ops unless you opt in). ENABLE_BOOTSTRAP defaults to
# false, so a default install never touches your rooms.
#
# What it does (idempotent — safe to re-run):
#   1. waits for the homeserver to answer on the loopback API,
#   2. create-admin.sh        — register @${ADMIN_MATRIX_USER}:${MATRIX_SERVER_NAME}
#                               (or log in if it already exists); saves a 0600
#                               credentials file the rest of the helpers read,
#   3. create-spaces.sh       — create the hub Space + default rooms (detects + reuses existing),
#   4. create-announcements.sh— create the admin-only announcements room + link it,
#   5. (optional) avatars     — make-avatars.py + set-avatars.py when BOOTSTRAP_AVATARS=true
#                               and Pillow is available.
#
# SECRETS: the admin password and the registration token are read from 0600 files
# under ${DATA_DIR}/secrets (or env), NEVER passed on argv. The admin access token
# the helpers mint is the privileged credential they reuse — see the TODO(human)
# markers in the helpers.
#
# PREREQS: the homeserver must be running, and registration must be OPEN with a
# token. Mint/enable one first with:  scripts/ops/rotate-registration-token.sh
# (it writes ${DATA_DIR}/secrets/registration-token.txt, 0600).
#
# Generalized from a working deployment; review before running on a fresh phone.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env

# ── Self-gate: only run when explicitly enabled (default off) ────────────────
if [ "${ENABLE_BOOTSTRAP:-false}" != "true" ]; then
  ok "matrix bootstrap disabled (ENABLE_BOOTSTRAP != true) — skipping (this is the default)"
  exit 0
fi

require_var DATA_DIR "folder on your large volume / SD card"
require_cmd curl
require_cmd jq

HS="${MATRIX_HS_API:-http://127.0.0.1:8448}"
BOOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bootstrap"

CREATE_ADMIN="${BOOT_DIR}/create-admin.sh"
CREATE_SPACES="${BOOT_DIR}/create-spaces.sh"
CREATE_ANN="${BOOT_DIR}/create-announcements.sh"
MAKE_AVATARS="${BOOT_DIR}/make-avatars.py"
SET_AVATARS="${BOOT_DIR}/set-avatars.py"

# ── Preflight: helpers present (fail-closed) ─────────────────────────────────
for f in "${CREATE_ADMIN}" "${CREATE_SPACES}" "${CREATE_ANN}"; do
  [ -f "${f}" ] || die "bootstrap helper missing: ${f} — the bootstrap module was not shipped"
done

# ── Wait for the homeserver ───────────────────────────────────────────────────
say "waiting for the homeserver on ${HS}"
up=0
for _ in $(seq 1 30); do
  if curl -sf -m 3 "${HS}/_matrix/client/versions" >/dev/null 2>&1; then up=1; break; fi
  sleep 1
done
[ "${up}" -eq 1 ] || die "homeserver not responding on ${HS} — bring the stack up first (scripts/start-stack.sh)"

# ── Run the helpers in order (each is idempotent) ────────────────────────────
say "=== create-admin ==="
bash "${CREATE_ADMIN}" || die "create-admin.sh failed"

say "=== create-spaces ==="
bash "${CREATE_SPACES}" || die "create-spaces.sh failed"

say "=== create-announcements ==="
bash "${CREATE_ANN}" || die "create-announcements.sh failed"

# ── Optional: avatars (needs Pillow to generate the PNGs) ────────────────────
if [ "${BOOTSTRAP_AVATARS:-false}" = "true" ]; then
  say "=== avatars ==="
  if [ ! -f "${MAKE_AVATARS}" ] || [ ! -f "${SET_AVATARS}" ]; then
    warn "avatar helpers missing — skipping avatars"
  elif ! python3 -c 'import PIL' >/dev/null 2>&1; then
    warn "Pillow not installed (pip install Pillow) — skipping avatar generation"
  else
    if python3 "${MAKE_AVATARS}"; then
      python3 "${SET_AVATARS}" || warn "set-avatars.py reported a problem (avatars may be partial)"
    else
      warn "make-avatars.py failed — skipping avatar upload"
    fi
  fi
else
  say "avatars skipped (set BOOTSTRAP_AVATARS=true to generate + upload them; needs Pillow)"
fi

echo
ok "Matrix bootstrap complete (admin + hub Space + announcements)."
say "Mint invite tokens for your users with:  scripts/bootstrap/mint-invite-token.sh <N>"

# Generalized from a working deployment; review before running.
