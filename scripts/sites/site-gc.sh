#!/usr/bin/env bash
#
# sites/site-gc.sh — retention GC + stale staging/job cleanup (SPEC-SITES-PIPELINE
# §6, AD-5, AD-6). Read the spec first; this header only orients you.
#
# Usage:
#   site-gc.sh [<name>]
#
#   <name>   optional; GC only this one site's release history. Omitted: GC
#            every site under SITES_ROOT.
#
# This runs automatically at the end of every site-deploy.sh (so history never
# grows unbounded from normal use); this script is the on-demand / cron/panel-
# triggered form, and it does strictly more than the post-deploy hook:
#   1. release-history retention for the target site(s) (AD-5 — same
#      sites_gc_site() the deploy pipeline uses, never touches the active
#      release even if it is older than the retention window),
#   2. purge .staging/ entries — uploaded artifacts (the panel/MCP write into
#      .staging/ themselves) older than SITES_JOB_RETENTION_DAYS,
#   3. purge job state files + their paired per-job logs (AD-6) once older
#      than the same retention window, UNLESS a job's own state is still
#      "running" (never delete evidence of something apparently still in
#      flight, even if its mtime looks stale).
#
# Like site-list.sh, this script's only user-derived argv is an optional site
# NAME, and it is validated + existence-checked exactly like every other entry
# point — never trusted to point rm -rf at something it didn't verify itself.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-sites.sh"

load_env
require_var DOMAIN "your public domain — used to refresh each site's registry URL after pruning"
require_cmd python3

TARGET_NAME="${1:-}"

sites_root_init

if [ -n "${TARGET_NAME}" ]; then
  validate_site_name "${TARGET_NAME}"
  [ -d "${SITES_ROOT}/${TARGET_NAME}" ] || die "no such site: ${TARGET_NAME}"
  say "GC: retention pass for site '${TARGET_NAME}' (keep ${SITES_KEEP_RELEASES:-5})"
  sites_gc_site "${TARGET_NAME}"
else
  say "GC: retention pass for all sites (keep ${SITES_KEEP_RELEASES:-5} each)"
  if [ -d "${SITES_ROOT}" ]; then
    shopt -s nullglob
    for d in "${SITES_ROOT}"/*/; do
      n="$(basename "${d}")"
      case "${n}" in
        .*) continue ;;  # .staging/, and any other dotfile/dotdir
      esac
      [ -d "${d}/releases" ] || continue  # not a site tree
      sites_gc_site "${n}"
    done
    shopt -u nullglob
  fi
fi

# ── stale .staging/ purge ────────────────────────────────────────────────────
RETENTION_DAYS="${SITES_JOB_RETENTION_DAYS:-7}"
# find -mtime "+garbage" fails silently under the 2>/dev/null below — a bad
# env value would quietly disable ALL retention, so fail loud instead.
case "${RETENTION_DAYS}" in
  *[!0-9]*|'') die "SITES_JOB_RETENTION_DAYS must be a whole number of days (got '${RETENTION_DAYS}')" ;;
esac
if [ -d "${STAGING}" ]; then
  say "GC: purging .staging/ entries older than ${RETENTION_DAYS}d"
  find "${STAGING}" -mindepth 1 -maxdepth 1 -mtime "+${RETENTION_DAYS}" -exec rm -rf {} + 2>/dev/null || true
fi

# ── stale job state + per-job log purge (AD-6) ───────────────────────────────
say "GC: purging job records + logs older than ${RETENTION_DAYS}d (state=running is always kept)"
sites_purge_old_jobs "${RETENTION_DAYS}"

ok "GC complete"
