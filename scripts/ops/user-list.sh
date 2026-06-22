#!/usr/bin/env bash
#
# ops/user-list.sh — list local Matrix users.
#
# Asks continuwuity's admin command room (`admin users list-users`) via
# scripts/lib/matrix_admin.py and prints the bot's reply verbatim. The admin
# access token is read from the 0600 credentials file, never passed on argv.
# Runs TERMUX-NATIVE (loopback client-server API); does not enter the userland.
# See docs/USERS.md.
#
# Generalized from a working deployment; review before running on a fresh phone.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env
require_var DATA_DIR "folder on your large volume / SD card"
require_cmd python3

exec python3 "${POCKET_ROOT}/scripts/lib/matrix_admin.py" users list-users
