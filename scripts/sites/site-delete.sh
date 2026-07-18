#!/usr/bin/env bash
#
# sites/site-delete.sh — permanently remove a site + its whole release history
# (SPEC-SITES-PIPELINE §6). Read the spec first; this header only orients you.
#
# Usage:
#   site-delete.sh <name> [--yes]
#
#   <name>   subdomain label, validated + reservation-checked (§7) — reused
#            here purely as an existence/identity check, not to re-derive a
#            new value; a name that isn't a real, currently-registered site
#            dies with a clear "no such site" instead of silently no-op'ing.
#   --yes    skip the interactive confirmation. The panel/MCP pass this AFTER
#            their own confirmation gate (§6) — this script's own prompt is
#            for the operator's direct CLI use only, and REQUIRES a real tty
#            when --yes is absent (a non-interactive caller without --yes is a
#            caller that forgot its own gate, not an invitation to hang on
#            `read`).
#
# There is no "soft delete" here: this removes the site's ENTIRE directory
# tree (every release, meta.json, all history) and its registry entry. The
# wildcard Caddy vhost (AD-1) is never touched — it is a static, one-time
# install — so the host simply starts 404ing (its root directory is gone) the
# moment this completes; there is nothing left to un-route.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-sites.sh"

load_env
require_var DOMAIN "your public domain"
require_cmd python3

[ $# -ge 1 ] || die "usage: site-delete.sh <name> [--yes]"
SITE_NAME="$1"
shift

YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --yes) YES=1; shift ;;
    *) die "unknown argument: $1 (usage: site-delete.sh <name> [--yes])" ;;
  esac
done

sites_root_init
validate_site_name "${SITE_NAME}"

SITE_DIR="${SITES_ROOT}/${SITE_NAME}"
[ -d "${SITE_DIR}" ] || die "no such site: ${SITE_NAME}"

if [ "${YES}" != 1 ]; then
  [ -t 0 ] \
    || die "site-delete.sh requires --yes for non-interactive callers (the panel/MCP must pass it after their own confirmation gate — see §6)"
  printf 'This permanently deletes %s (%s) and ALL its release history.\n' "${SITE_NAME}" "${SITE_DIR}" >&2
  printf 'Type the site name to confirm: ' >&2
  read -r CONFIRM
  [ "${CONFIRM}" = "${SITE_NAME}" ] \
    || die "confirmation did not match '${SITE_NAME}' — aborted, nothing was deleted"
fi

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
    job_fail "${JOB_ID}" "${DEPLOY_ERR:-delete failed unexpectedly (rc=${rc}) — see ${POCKET_LOG_DIR}/site-deploy-${JOB_ID}.log}"
  fi
  exit "${rc}"
}
trap cleanup_on_exit EXIT

job_start "${JOB_ID}" delete "${SITE_NAME}" ""
job_log "${JOB_ID}" "deleting site '${SITE_NAME}' (${SITE_DIR})"

rm -rf "${SITE_DIR:?}" || fail "failed to remove the site directory ${SITE_DIR}"
job_log "${JOB_ID}" "site directory removed"

registry_remove_site "${SITE_NAME}" || fail "failed to remove the registry entry"
job_log "${JOB_ID}" "registry entry removed"

# ── landing-regen hook — no-op until M2 ships scripts/landing/regen-landing.sh
REGEN="${POCKET_ROOT}/scripts/landing/regen-landing.sh"
if [ -x "${REGEN}" ]; then
  job_log "${JOB_ID}" "running the landing-regen hook"
  "${REGEN}" || warn "landing-regen hook failed (non-fatal — the delete itself already succeeded)"
else
  job_log "${JOB_ID}" "landing-regen hook not present yet (no-op until M2 — see SPEC-LANDING-SYNC)"
fi

DEPLOY_OK=1
job_done "${JOB_ID}" ""
ok "deleted site '${SITE_NAME}' — host now 404s (wildcard vhost untouched, job ${JOB_ID})"
