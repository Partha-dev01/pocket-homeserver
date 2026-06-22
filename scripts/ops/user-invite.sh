#!/usr/bin/env bash
#
# ops/user-invite.sh [N] — mint N single-use registration (invite) tokens.
#
# Thin wrapper around scripts/bootstrap/mint-invite-token.sh (the homeserver admin
# token API), so the whole user lifecycle lives under ops/user-*. Each token is
# one-use and self-expires after INVITE_TOKEN_DAYS days. See docs/USERS.md.
#
# Generalized from a working deployment; review before running on a fresh phone.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env
require_var DATA_DIR "folder on your large volume / SD card"

n="${1:-1}"
case "${n}" in
  ''|*[!0-9]*) die "usage: $(basename "$0") [N]   (N = positive integer, default 1)" ;;
esac
[ "${n}" -ge 1 ] || die "N must be >= 1"

exec bash "${POCKET_ROOT}/scripts/bootstrap/mint-invite-token.sh" "${n}"
