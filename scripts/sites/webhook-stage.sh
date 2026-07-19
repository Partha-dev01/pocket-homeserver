#!/usr/bin/env bash
#
# sites/webhook-stage.sh — stage a Forgejo push-event commit into .staging/ as
# a zip, for the git-push-to-deploy webhook receiver (SPEC-DIFFERENTIATORS.md
# §6.4). Read the spec first; this header only orients you.
#
# Usage:
#   webhook-stage.sh <site> <owner/repo> <sha> [--job <id>]
#
#   <site>       subdomain label, validated + reservation-checked (§7 of
#                SPEC-SITES-PIPELINE) — used only to place this stage under
#                the shared .staging/ dir; the archived content itself is not
#                site-scoped — site-deploy.sh (the caller's next step) is what
#                actually publishes it under <site>.
#   <owner/repo> the pushed Forgejo repo's full_name (e.g. "admin/blog") —
#                both path segments are regex-gated, then the resolved bare
#                repo path is realpath-containment- AND existence-checked
#                under the Forgejo repositories root — the same three-layer
#                discipline validate_release_id() already applies to release
#                ids (lib-sites.sh:123-132).
#   <sha>        the pushed commit's full 40-hex object id — a hex-only
#                charset structurally forecloses git argument-injection (no
#                other ref-ish value ever reaches `git archive`).
#   --job ID     reuse a job id the caller (the webhook receiver) already
#                allocated, so this stage step and the eventual
#                site-deploy.sh call share ONE job id; a fresh one is minted
#                (new_job_id) if omitted.
#
# The archive runs IN THE USERLAND via proot-distro, mirroring build_hugo's
# exec pattern (site-deploy.sh:204-205) — the bare repo is created/managed by
# the userland's own git (Forgejo's git backend), so this script never assumes
# a host-side git binary. On success the HOST-side staged zip path is printed
# to stdout (the ONLY thing this script ever writes there — the caller reads
# it back exactly like sites_upload() reads its own server-allocated staged
# path); any failure exits non-zero with a reason on stderr and no zip is left
# behind in .staging/.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-sites.sh"

load_env

[ $# -ge 3 ] || die "usage: webhook-stage.sh <site> <owner/repo> <sha> [--job <id>]"
SITE_NAME="$1"
OWNER_REPO="$2"
SHA="$3"
shift 3

JOB_ID_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --job)
      [ $# -ge 2 ] || die "--job requires an argument"
      JOB_ID_ARG="$2"; shift 2 ;;
    *)
      die "unknown argument: $1" ;;
  esac
done
# A caller-supplied --job id lands verbatim in the staged filename, so it gets
# the same whole-string format gate site-deploy.sh applies to its own --job
# (job ids share the exact <UTC-ts>-<4hex> shape — new_job_id/new_release_id
# are twins in lib-sites.sh).
if [ -n "${JOB_ID_ARG}" ]; then
  [[ ${JOB_ID_ARG} =~ ${RELEASE_ID_RE} ]] \
    || die "invalid --job id '${JOB_ID_ARG}' — must match ${RELEASE_ID_RE} (allocate ids with new_job_id)"
fi

sites_root_init

# §7 — the site name is only used to namespace log messages here (the stage
# itself is not site-scoped); still validated first, matching every other
# sites/*.sh entry point's convention of gating the one user-derived name
# argument before anything else runs.
validate_site_name "${SITE_NAME}"

# ── owner/repo: regex, THEN realpath-containment + existence under the ──────
# Forgejo repositories root. The regex alone is not enough — e.g. "../.."
# passes the char-class check (it contains only '.' characters) but must
# still be caught by the containment check below; this mirrors why
# validate_release_id() layers a regex AND a directory-existence check rather
# than trusting either alone.
OWNER_REPO_RE='^[A-Za-z0-9._-]{1,100}/[A-Za-z0-9._-]{1,100}$'
# [[ =~ ]] (not grep -q): whole-string match, so an embedded newline can't
# sneak a second, differently-shaped line past the anchors (lib-sites.sh's
# validate_site_name explains the same hazard for site names).
[[ ${OWNER_REPO} =~ ${OWNER_REPO_RE} ]] \
  || die "invalid owner/repo '${OWNER_REPO}' — must match ${OWNER_REPO_RE}"
OWNER="${OWNER_REPO%%/*}"
REPO="${OWNER_REPO#*/}"

FORGEJO_REPOS_ROOT="${PD_BASE}/debian/opt/forgejo/data/repositories"
BARE_REPO="${FORGEJO_REPOS_ROOT}/${OWNER}/${REPO}.git"
REAL_REPO="$(realpath -m -- "${BARE_REPO}")"
REAL_ROOT="$(realpath -m -- "${FORGEJO_REPOS_ROOT}")"
case "${REAL_REPO}/" in
  "${REAL_ROOT}/"*) : ;;
  *) die "owner/repo '${OWNER_REPO}' resolves outside the Forgejo repositories root — refusing" ;;
esac
[ -d "${REAL_REPO}" ] \
  || die "no such Forgejo repository: ${OWNER_REPO} (expected a bare repo at ${BARE_REPO})"

# ── sha: strict 40-hex — the hex-only charset is what forecloses git ────────
# argument-injection (a value starting with '-' can never match this).
SHA_RE='^[0-9a-f]{40}$'
[[ ${SHA} =~ ${SHA_RE} ]] \
  || die "invalid sha '${SHA}' — must be a full 40-char lowercase hex object id"

JOB_ID="${JOB_ID_ARG:-$(new_job_id)}"
STAGED_HOST="${STAGING}/webhook-${JOB_ID}.zip"
STAGED_USERLAND="$(host_to_userland "${STAGED_HOST}")"
REPO_USERLAND="$(host_to_userland "${REAL_REPO}")"
rm -f "${STAGED_HOST}"

if ! command -v proot-distro >/dev/null 2>&1 || ! proot-distro login debian -- true >/dev/null 2>&1; then
  die "proot-distro userland not available on this host — webhook staging runs \`git archive\` IN THE USERLAND (mirrors site-deploy.sh's build_hugo/build_node exec pattern) and cannot execute here. Expected on a laptop/dev box; this step is exercised by the arm64-qemu E2E harness, not the laptop test suite."
fi

TIMEOUT_S="${SITES_WEBHOOK_STAGE_TIMEOUT:-60}"
# -c safe.directory=<this exact repo>: the bare repo is owned by the userland's
# `forgejo` service user, and git ≥2.35.2 refuses to read a repo owned by a
# different uid ("dubious ownership", rc 128 — found live by the arm64 E2E).
# The path is already regex-gated + realpath-contained under the Forgejo
# repositories root above, so trusting exactly this path is sound; NEVER widen
# to '*', and per-invocation -c keeps the global git config untouched.
if ! proot-distro login debian -- bash -lc \
    "timeout '${TIMEOUT_S}' git -c safe.directory='${REPO_USERLAND}' -C '${REPO_USERLAND}' archive --format=zip -o '${STAGED_USERLAND}' -- '${SHA}'"; then
  rm -f "${STAGED_HOST}"
  die "git archive failed (site=${SITE_NAME} repo=${OWNER_REPO} sha=${SHA}, timeout ${TIMEOUT_S}s) — bad sha, corrupt repo, or timeout; see the output above"
fi

[ -s "${STAGED_HOST}" ] || die "git archive produced no output at ${STAGED_HOST}"

# The ONLY line this script ever prints to stdout — the caller (the webhook
# receiver) captures it verbatim as the staged artifact path.
printf '%s\n' "${STAGED_HOST}"
