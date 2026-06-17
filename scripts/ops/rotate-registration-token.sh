#!/usr/bin/env bash
#
# ops/rotate-registration-token.sh — mint a fresh Matrix registration token and
# enable token-gated signup.
#
# Matrix accounts are created with a single shared registration token. This mints
# a new random token, writes it into the DEPLOYED conduwuit config inside the
# userland (/etc/conduwuit/conduwuit.toml) with `allow_registration = true`, then
# restarts the homeserver so it takes effect. The new token is persisted (0600) to
# ${DATA_DIR}/secrets/registration-token.txt and printed once.
#
# DANGER: the OLD token stops working immediately; already-registered users are
# unaffected, but anyone mid-signup needs the new token. Restarting the homeserver
# causes ~tens of seconds of chat downtime.
#
# NOTE: re-running scripts/install.sh (which re-renders + re-deploys the config
# from the template) resets registration to CLOSED — re-run this afterwards if you
# want token-gated signup to stay on. See docs/ADMIN.md.
#
# Generalized from a working deployment; review before running on a fresh phone.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env
require_var DATA_DIR "folder on your large volume / SD card"
require_cmd proot-distro
require_cmd openssl

QUIET=false
[ "${1:-}" = "-q" ] && QUIET=true

SECRETS_DIR="${DATA_DIR}/secrets"
TOKEN_FILE="${SECRETS_DIR}/registration-token.txt"
mkdir -p "${SECRETS_DIR}"
chmod 700 "${SECRETS_DIR}" 2>/dev/null || true

OLD="$(cat "${TOKEN_FILE}" 2>/dev/null || true)"
NEW="$(openssl rand -hex 16)"

# Persist the new token FIRST (0600), then read it back inside the userland from
# the bind-mounted secrets dir — so the token never appears on any command line.
umask 077
printf '%s\n' "${NEW}" > "${TOKEN_FILE}"
chmod 600 "${TOKEN_FILE}" 2>/dev/null || true

# ── Rewrite the deployed conduwuit.toml inside the userland ───────────────────
# Edits the live config: set allow_registration = true and set/insert the token.
# Handles a commented (`# registration_token = …`) or absent token line. A backup
# of the toml is kept under ${BACKUP_DIR}/config before mutation.
mkdir -p "${BACKUP_DIR}/config"
say "rewriting registration_token in the deployed conduwuit.toml"
if ! proot-distro login debian \
      --bind "${SECRETS_DIR}:/pocket-secrets" \
      --bind "${BACKUP_DIR}/config:/pocket-config-backup" \
      -- bash -lc '
        set -e
        TOML=/etc/conduwuit/conduwuit.toml
        [ -f "$TOML" ] || { echo "conduwuit.toml not found at $TOML" >&2; exit 3; }
        NEW="$(cat /pocket-secrets/registration-token.txt)"
        [ -n "$NEW" ] || { echo "new token is empty" >&2; exit 4; }
        cp "$TOML" "/pocket-config-backup/conduwuit.toml-pre-rotate-$(date -u +%FT%H-%MZ)"
        # Enable registration.
        if grep -qE "^[#[:space:]]*allow_registration[[:space:]]*=" "$TOML"; then
          sed -i -E "s|^[#[:space:]]*allow_registration[[:space:]]*=.*|allow_registration = true|" "$TOML"
        else
          sed -i "/^\[global\]/a allow_registration = true" "$TOML"
        fi
        # Set / insert the token (replace a commented or live line, else append).
        if grep -qE "^[#[:space:]]*registration_token[[:space:]]*=" "$TOML"; then
          sed -i -E "s|^[#[:space:]]*registration_token[[:space:]]*=.*|registration_token = \"${NEW}\"|" "$TOML"
        else
          sed -i "/^\[global\]/a registration_token = \"${NEW}\"" "$TOML"
        fi
        grep -qE "^registration_token[[:space:]]*=" "$TOML" || { echo "failed to set registration_token" >&2; exit 5; }
      ' 2>&1 | grep -v 'proot warning'; then
  : # grep -v exits 1 when there is no non-warning output; the set -e body above
    # is what actually fails closed (its non-zero exit is preserved by pipefail).
fi

# Fail closed: verify the token landed in the live config.
proot-distro login debian -- bash -lc 'grep -qE "^registration_token[[:space:]]*=" /etc/conduwuit/conduwuit.toml' \
  || die "registration_token was not written to the deployed conduwuit.toml"

# ── Restart the homeserver so the new token takes effect ──────────────────────
say "restarting the homeserver to load the new token"
bash "${POCKET_ROOT}/scripts/ops/restart.sh" matrix >/dev/null 2>&1 \
  || bash "${POCKET_ROOT}/scripts/start-stack.sh" >/dev/null 2>&1 \
  || warn "homeserver restart reported a problem — check ${POCKET_LOG_DIR}/matrix.log"

ok "registration token rotated"
if [ "${QUIET}" != "true" ]; then
  echo
  echo "  old: ${OLD:0:8}… (now invalid)"
  echo "  new: ${NEW}"
  echo
  echo "NEXT: share the new token with people you are inviting (private channel)."
  echo "      Already-registered users are unaffected."
fi
