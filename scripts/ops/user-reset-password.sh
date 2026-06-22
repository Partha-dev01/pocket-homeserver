#!/usr/bin/env bash
#
# ops/user-reset-password.sh <localpart> — reset a local user's password.
#
# Runs `admin users reset-password <localpart>` via the admin command room. The
# server generates the NEW password and returns it in its reply (which lands in
# the admin room history — treat that room as sensitive). See docs/USERS.md.
#
# Generalized from a working deployment; review before running on a fresh phone.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env
require_var DATA_DIR "folder on your large volume / SD card"
require_cmd python3

u="${1:-}"
[ -n "${u}" ] || die "usage: $(basename "$0") <localpart>   (e.g. alice)"
printf '%s' "${u}" | grep -Eq '^[a-z0-9][a-z0-9._=-]{0,63}$' \
  || die "invalid localpart '${u}' — allowed: a-z 0-9 . _ = -  (1–64 chars, lowercase)"

warn "the new password will be shown in the admin room history — treat it as sensitive (docs/USERS.md)"
exec python3 "${POCKET_ROOT}/scripts/lib/matrix_admin.py" users reset-password "${u}"
