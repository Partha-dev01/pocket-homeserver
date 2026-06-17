#!/usr/bin/env bash
#
# ops/status.sh — print a quick up/down summary of every supervised service.
#
# Reads the supervisor pidfiles under ${POCKET_STATE_DIR} and reports whether each
# service's supervisor is alive. Used by the admin panel's "status" action and
# handy on the command line. Read-only; safe to run any time.
#
# Generalized from a working deployment; review before running on a fresh phone.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env

echo "pocket-homeserver — supervised services (${POCKET_STATE_DIR})"
echo

shopt -s nullglob
any=0
for pidfile in "${POCKET_STATE_DIR}"/*.pid; do
  any=1
  name="$(basename "${pidfile}" .pid)"
  pid="$(cat "${pidfile}" 2>/dev/null || true)"
  if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
    printf '  %-16s RUNNING (pid %s)\n' "${name}" "${pid}"
  else
    printf '  %-16s DOWN\n' "${name}"
  fi
done
shopt -u nullglob

[ "${any}" -eq 0 ] && echo "  (no supervised services yet — run scripts/install.sh)"
echo
ok "status complete"
