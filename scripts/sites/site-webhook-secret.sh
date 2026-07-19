#!/usr/bin/env bash
#
# sites/site-webhook-secret.sh — mint/read/rotate a per-site Forgejo webhook
# HMAC secret (SPEC-DIFFERENTIATORS.md §6.4). Read the spec first; this header
# only orients you.
#
# Usage:
#   site-webhook-secret.sh <site> [--rotate]
#
#   <site>     subdomain label, validated + reservation-checked (§7 of
#              SPEC-SITES-PIPELINE) — the site itself need not already exist:
#              a webhook-triggered deploy can CREATE a brand-new site on its
#              first push (§6.4), so provisioning its secret ahead of the
#              first push is a normal, supported order of operations.
#   --rotate   regenerate unconditionally, invalidating whatever secret is
#              already pasted into Forgejo's webhook config. Without it, an
#              existing secret is reused — idempotent, so re-running the
#              panel's "show my webhook secret" action doesn't invalidate an
#              already-configured webhook.
#
# The secret (32 random bytes, `openssl rand -hex 32` — a
# secrets.token_hex(32)-equivalent) is written 0600 under
# ${POCKET_STATE_DIR}/sites-webhook/<site>.secret (ext4, never DATA_DIR —
# AD-4), directory 0700. Printed to stdout EXACTLY ONCE per invocation — its
# whole purpose is to be shown to the operator/panel caller, mirroring
# rotate-admin-pass's "shown ONCE on the result page" convention
# (admin/app.py:265). Never echoed via say/ok/warn/die, never logged.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-sites.sh"

load_env
require_cmd openssl

[ $# -ge 1 ] || die "usage: site-webhook-secret.sh <site> [--rotate]"
SITE_NAME="$1"
shift

ROTATE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --rotate) ROTATE=1; shift ;;
    *) die "unknown argument: $1 (usage: site-webhook-secret.sh <site> [--rotate])" ;;
  esac
done

validate_site_name "${SITE_NAME}"

SECRET_DIR="${POCKET_STATE_DIR}/sites-webhook"
SECRET_FILE="${SECRET_DIR}/${SITE_NAME}.secret"
mkdir -p "${SECRET_DIR}"
chmod 700 "${SECRET_DIR}"

if [ "${ROTATE}" != 1 ] && [ -s "${SECRET_FILE}" ]; then
  cat -- "${SECRET_FILE}"
  exit 0
fi

SECRET="$(openssl rand -hex 32)"
[ -n "${SECRET}" ] || die "openssl rand failed to produce a webhook secret"

umask 077
printf '%s\n' "${SECRET}" > "${SECRET_FILE}.tmp"
mv -f "${SECRET_FILE}.tmp" "${SECRET_FILE}"
chmod 600 "${SECRET_FILE}"

printf '%s\n' "${SECRET}"
