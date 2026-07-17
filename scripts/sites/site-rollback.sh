#!/usr/bin/env bash
#
# sites/site-rollback.sh — instant pointer-swap rollback (SPEC-SITES-PIPELINE §6,
# AD-4 step 4). Read the spec first; this header only orients you.
#
# Usage:
#   site-rollback.sh <name> [<release-id>]
#
#   <name>         subdomain label, validated + reservation-checked (§7) — the
#                  same rule as a deploy, even though a rollback creates
#                  nothing new; it's still the one piece of user-derived argv.
#   <release-id>   optional; must already exist under <name>/releases/ (§6 —
#                  validated by regex AND existence, never trusted blind).
#                  Default: the release immediately before the currently
#                  active one, in chronological order.
#
# This is DELIBERATELY the smallest script in the module: rollback never
# rebuilds, never copies, never touches the filesystem tree beyond the
# `current` symlink itself — it is pure atomic_swap (AD-4) + a registry
# refresh + a job record. That is the whole point of the release-history
# design: a bad deploy is undone in the time it takes to run one `mv -T`.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-sites.sh"

load_env
require_var DOMAIN "your public domain — used to refresh this site's registry URL"
require_cmd python3

[ $# -ge 1 ] || die "usage: site-rollback.sh <name> [<release-id>]"
SITE_NAME="$1"
TARGET_RELEASE="${2:-}"

sites_root_init
validate_site_name "${SITE_NAME}"

SITE_DIR="${SITES_ROOT}/${SITE_NAME}"
[ -d "${SITE_DIR}" ] || die "no such site: ${SITE_NAME}"

ACTIVE="$(_site_active_release "${SITE_NAME}" 2>/dev/null || true)"
[ -n "${ACTIVE}" ] || die "site '${SITE_NAME}' has no active release to roll back from"

if [ -n "${TARGET_RELEASE}" ]; then
  validate_release_id "${SITE_NAME}" "${TARGET_RELEASE}"
else
  TARGET_RELEASE="$(_site_previous_release "${SITE_NAME}" "${ACTIVE}")"
  [ -n "${TARGET_RELEASE}" ] \
    || die "site '${SITE_NAME}' has no earlier release to roll back to (only ${ACTIVE} exists) — pass an explicit <release-id> if you meant something else"
fi

[ "${TARGET_RELEASE}" = "${ACTIVE}" ] \
  && warn "rolling back to the CURRENTLY active release (${ACTIVE}) — this is a no-op pointer swap"

JOB_ID="$(new_job_id)"
DEPLOY_ERR=""
DEPLOY_OK=0

fail() {
  DEPLOY_ERR="$*"
  job_log "${JOB_ID}" "ERROR: $*"
  die "$*"
}

cleanup_on_exit() {
  local rc=$?
  if [ "${DEPLOY_OK}" != 1 ]; then
    job_fail "${JOB_ID}" "${DEPLOY_ERR:-rollback failed unexpectedly (rc=${rc}) — see ${POCKET_LOG_DIR}/site-deploy-${JOB_ID}.log}"
  fi
  exit "${rc}"
}
trap cleanup_on_exit EXIT

job_start "${JOB_ID}" rollback "${SITE_NAME}" "${TARGET_RELEASE}"
job_log "${JOB_ID}" "rollback starting: site=${SITE_NAME} ${ACTIVE} -> ${TARGET_RELEASE}"

atomic_swap "${SITE_NAME}" "${TARGET_RELEASE}" || fail "atomic pointer swap failed"
job_log "${JOB_ID}" "current -> releases/${TARGET_RELEASE}"

BUILD="$(_site_meta_build "${SITE_NAME}")"
SITE_URL="https://${SITE_NAME}.${DOMAIN}"
registry_update_site "${SITE_NAME}" "${TARGET_RELEASE}" "${BUILD}" "${SITE_URL}" \
  || fail "registry update failed"
job_log "${JOB_ID}" "registry updated (active_release=${TARGET_RELEASE})"

DEPLOY_OK=1
job_done "${JOB_ID}" "${TARGET_RELEASE}"
ok "rolled back ${SITE_NAME}: ${ACTIVE} -> ${TARGET_RELEASE} (job ${JOB_ID})"
