#!/usr/bin/env bash
#
# ops/user-deactivate.sh <localpart|@user:server> — deactivate (close) an account.
#
# Runs `admin users deactivate <mxid>` via the admin command room. Deactivation is
# effectively irreversible (the user can no longer log in); re-enabling means
# creating the account again. A bare localpart is expanded to
# @<localpart>:${MATRIX_SERVER_NAME}. See docs/USERS.md.
#
# Generalized from a working deployment; review before running on a fresh phone.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env
require_var DATA_DIR "folder on your large volume / SD card"
require_cmd python3

u="${1:-}"
[ -n "${u}" ] || die "usage: $(basename "$0") <localpart|@user:server>"
case "${u}" in
  @*:*) mxid="${u}" ;;
  *) printf '%s' "${u}" | grep -Eq '^[a-z0-9][a-z0-9._=-]{0,63}$' \
       || die "invalid localpart '${u}'"
     mxid="@${u}:${MATRIX_SERVER_NAME:-${DOMAIN}}" ;;
esac
printf '%s' "${mxid}" | grep -Eq '^@[a-z0-9._=/+-]+:[A-Za-z0-9.:-]+$' \
  || die "invalid MXID '${mxid}'"

exec python3 "${POCKET_ROOT}/scripts/lib/matrix_admin.py" users deactivate "${mxid}"
