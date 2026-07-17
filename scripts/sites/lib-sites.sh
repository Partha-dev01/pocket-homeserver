# sites/lib-sites.sh — shared helpers for the `sites` static-hosting pipeline.
#
# Implements SPEC-SITES-PIPELINE.md (read that first) §3 AD-1/AD-2/AD-4/AD-5/
# AD-6, §4 (layout), §5 (registry schema), §7 (name validation). Sourced by
# every scripts/sites/*.sh entry point, AFTER scripts/lib/common.sh (this file
# uses say/ok/warn/die and POCKET_STATE_DIR/POCKET_LOG_DIR from it, and does
# NOT re-source it itself — see the sourcing preamble in any sites/*.sh script
# for the exact two-line incantation).
#
# This file is SOURCED, not executed, so it has no shebang — same convention as
# common.sh — but is still shellcheck-clean bash, hence the directive below.
# shellcheck shell=bash

# Guard against double-sourcing, exactly like common.sh: harmless if a script
# (or a future caller) sources this twice.
[ -n "${_POCKET_SITES_LIB_LOADED:-}" ] && return 0
_POCKET_SITES_LIB_LOADED=1

# Pull in RESERVED_SUBS from the sibling file (same directory as this one, NOT
# scripts/lib/ — the sites module owns its own reservation list per §7).
_SITES_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/sites/reserved-subs.sh
. "${_SITES_LIB_DIR}/reserved-subs.sh"

# ── AD-2: path resolution (host-side view of the userland rootfs) ───────────
# PD_BASE mirrors the EXACT pattern already used by ops/backup-all.sh:33 and
# ops/restore.sh:43 — proot-distro's fixed install location. Unlike those two
# scripts (which require Termux's $PREFIX to be set and die otherwise), this
# library falls back to the well-known Termux path so it can be *sourced* on a
# laptop for testing without a live Termux environment. POCKET_SITES_ROOT is
# the documented laptop-test seam (SPEC-SITES-PIPELINE): point it at a tmpdir
# and every path below follows, with zero Termux/proot-distro dependency for
# pure filesystem operations (AD-1's whole point — deploy/rollback/delete never
# touch proot at all in the `none` build tier).
PD_BASE="${PREFIX:-/data/data/com.termux/files/usr}/var/lib/proot-distro/installed-rootfs"
SITES_ROOT="${POCKET_SITES_ROOT:-${PD_BASE}/debian/var/www/sites}"
STAGING="${SITES_ROOT}/.staging"
REGISTRY="${SITES_ROOT}/.registry.json"

# DNS-label regex — reused verbatim from scripts/apps/proxy-routes.sh:98 (kept
# in sync by hand; see the note in reserved-subs.sh about the planned
# proxy-routes.sh follow-up).
SUB_RE='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'

# Release-id regex — SPEC-SITES-PIPELINE §6: new_release_id()/new_job_id() emit
# <UTC-ts>-<4hex> (date +%Y%m%dT%H%M%SZ, so 8 digits + T + 6 digits + Z, plus 4
# lowercase hex chars); the {4,6} on the time component tolerates a shorter
# HHMM-style id too, per the spec's own regex.
RELEASE_ID_RE='^[0-9]{8}T[0-9]{4,6}Z-[0-9a-f]{4}$'

# ── host_to_userland PATH — strip the host-side rootfs prefix ───────────────
# Turns "${PD_BASE}/debian/var/www/sites/foo" into "/var/www/sites/foo" (the
# path Caddy — and, later, a proot-executed build tool — actually sees). Used
# only for log messages today; build_hugo/build_node (site-deploy.sh) also use
# it to hand proot-distro a userland-relative path. A path that does not start
# with the rootfs prefix (e.g. under POCKET_SITES_ROOT in laptop tests) is
# printed unchanged — there is no "userland view" to translate to off-phone.
host_to_userland() {
  local p="$1" prefix="${PD_BASE}/debian"
  case "${p}" in
    "${prefix}"/*) printf '%s' "${p#"${prefix}"}" ;;
    "${prefix}")   printf '/' ;;
    *)             printf '%s' "${p}" ;;
  esac
}

# ── sites_root_init — idempotent SITES_ROOT/.staging/.registry.json seed ────
# Every entry point calls this before touching anything. In production the
# installer (scripts/apps/sites.sh, §10) already does this at install time;
# calling it again here is a cheap, harmless no-op — and it is what makes the
# laptop test suite work without running the installer at all.
sites_root_init() {
  mkdir -p "${SITES_ROOT}" "${STAGING}"
  if [ ! -f "${REGISTRY}" ]; then
    local tmp="${REGISTRY}.tmp"
    printf '{"version": 1, "sites": {}}\n' > "${tmp}"
    mv -f "${tmp}" "${REGISTRY}"
  fi
}

# ── §7 name validation ───────────────────────────────────────────────────────
# validate_site_name NAME — dies with a clear reason on ANY invalid input:
#   1. must match SUB_RE (lowercase DNS label, 1..63 chars, no leading/trailing
#      hyphen — identical rule to a BYO proxy-routes subdomain),
#   2. must not be in RESERVED_SUBS,
#   3. must not already be claimed by a BYO proxy route (checked against the
#      userland Caddy apps dir; SKIPPED when that dir does not exist at all —
#      i.e. every laptop test run, where there is no proot-distro userland to
#      look inside — never a false pass on a real phone, only an inapplicable
#      check off-phone).
# This is the ONLY user-derived argv input across the whole module (§6) besides
# an optional release id (validate_release_id, below) — so this function is the
# single security-load-bearing gate for the entire pipeline.
validate_site_name() {
  local name="$1" r
  [ -n "${name}" ] || die "site name is empty"
  # [[ =~ ]] (not grep -q) on purpose: grep matches PER LINE, so a name with an
  # embedded newline ('good\n../evil') would pass because its first line
  # matches — =~ compiles the anchors against the WHOLE string, so any newline
  # (or other non-class byte) anywhere fails the match.
  [[ ${name} =~ ${SUB_RE} ]] \
    || die "invalid site name '${name}' — must match ${SUB_RE} (lowercase letters/digits/hyphen, 1..63 chars, no leading/trailing hyphen)"
  for r in ${RESERVED_SUBS}; do
    [ "${name}" = "${r}" ] \
      && die "site name '${name}' is reserved (built-in app or infra hostname) — pick a different subdomain, see docs/SITES.md"
  done
  if [ -d "${PD_BASE}/debian" ]; then
    # proxy-routes.sh writes byo-<sub>.caddy (proxy-routes.sh:206); route-<sub>
    # never existed but stays checked as a belt against a future rename.
    [ -e "${PD_BASE}/debian/etc/caddy/apps/byo-${name}.caddy" ] \
      && die "site name '${name}' is already claimed by a BYO proxy route (byo-${name}.caddy) — pick a different subdomain"
    [ -e "${PD_BASE}/debian/etc/caddy/apps/route-${name}.caddy" ] \
      && die "site name '${name}' is already claimed by a BYO proxy route (route-${name}.caddy) — pick a different subdomain"
  fi
  return 0
}

# validate_release_id NAME RELEASE — dies unless RELEASE matches the regex AND
# actually exists as a release directory under NAME's releases/. The existence
# check is what stops an attacker (or a confused caller) from pointing `current`
# at an arbitrary-but-regex-valid path that was never a real, fully-published
# release.
validate_release_id() {
  local name="$1" release="$2"
  [ -n "${release}" ] || die "release id is empty"
  # =~ not grep: whole-string match (see validate_site_name for why).
  [[ ${release} =~ ${RELEASE_ID_RE} ]] \
    || die "invalid release id '${release}' — must match ${RELEASE_ID_RE}"
  [ -d "${SITES_ROOT}/${name}/releases/${release}" ] \
    || die "release '${release}' does not exist for site '${name}'"
  return 0
}

# ── id generators ────────────────────────────────────────────────────────────
# _hex4 — 4 lowercase hex chars from /dev/urandom (od's default hex output is
# already lowercase; -An drops the offset column, -tx1 -N2 reads exactly 2
# bytes = 4 hex chars).
_hex4() { od -An -tx1 -N2 /dev/urandom | tr -d ' \n'; }

new_release_id() { printf '%s-%s' "$(date -u +%Y%m%dT%H%M%SZ)" "$(_hex4)"; }
new_job_id()     { printf '%s-%s' "$(date -u +%Y%m%dT%H%M%SZ)" "$(_hex4)"; }

# ── AD-4: atomic publish primitive ──────────────────────────────────────────
# atomic_swap NAME RELEASE — the "classic two-step" from AD-4 step 3: build the
# NEW symlink under a temp name, then rename it over the live one. `ln -sfn`
# creates current.tmp fresh (never following/editing an existing `current`),
# and `mv -T` is a single rename(2) syscall — on ext4 that is atomic, so a
# concurrent reader (Caddy resolving `current` mid-request) either sees the old
# target or the new one, NEVER a missing/partial symlink. The link target is
# RELATIVE ("releases/<id>", not an absolute host path) per spec — this is what
# keeps the site tree relocatable (e.g. restored from a backup to a different
# path) without every symlink breaking.
atomic_swap() {
  local name="$1" release="$2" site_dir
  site_dir="${SITES_ROOT}/${name}"
  mkdir -p "${site_dir}"
  ( cd "${site_dir}" && ln -sfn "releases/${release}" current.tmp && mv -T current.tmp current )
}

# _site_active_release NAME — prints the release id `current` points at (empty
# + rc 1 if there is no `current` symlink yet, e.g. a brand-new site).
_site_active_release() {
  local name="$1" cur
  cur="${SITES_ROOT}/${name}/current"
  [ -L "${cur}" ] || return 1
  basename "$(readlink "${cur}")"
}

# _site_releases_sorted NAME — one release id per line, NEWEST-FIRST, ordered
# by directory mtime — deliberately NOT a lexical sort of the release-id
# string. Release ids are <UTC-second-timestamp>-<4 random hex>, so two
# releases created within the SAME UTC second (a fast scripted redeploy loop,
# or a panel user mashing "redeploy") get an IDENTICAL timestamp prefix and
# differ only in their trailing hex, which carries no chronological meaning at
# all — sorting the ID string would then silently misorder them. Directory
# mtime (nanosecond-resolution on ext4/most modern filesystems) reflects real
# creation order even in that same-second case, because materializing a
# release necessarily writes into its directory (bumping its mtime) strictly
# before the fsync-rename that finishes it, which itself precedes the NEXT
# release's own mkdir. `ls -t` is the portable primitive for this (unlike
# `find -printf %T@`, a GNU-only extension this file avoids elsewhere).
_site_releases_sorted() {
  local name="$1" releases_dir d base
  releases_dir="${SITES_ROOT}/${name}/releases"
  [ -d "${releases_dir}" ] || return 0
  shopt -s nullglob
  local dirs=("${releases_dir}"/*/)
  shopt -u nullglob
  [ "${#dirs[@]}" -gt 0 ] || return 0
  # `ls -t` IS the mtime-ordering primitive we want here, not a case of
  # parsing `ls` output for names/permissions/etc. (SC2012 warns about the
  # latter footgun; this only ever reads the ORDER `ls` printed entries in).
  # shellcheck disable=SC2012
  while IFS= read -r d; do
    [ -n "${d}" ] || continue
    base="$(basename "${d%/}")"
    case "${base}" in
      *.tmp*) continue ;;  # <id>.tmp AND build-shuffle strays like <id>.tmp.out
    esac
    printf '%s\n' "${base}"
  done < <(ls -1dt -- "${dirs[@]}" 2>/dev/null)
}

# _site_previous_release NAME ACTIVE — prints the release id immediately
# chronologically BEFORE ACTIVE (site-rollback.sh's default target). Empty
# output (rc 0) if ACTIVE is the oldest release on disk, or was not found at
# all — the caller treats "nothing to roll back to" as its own error.
_site_previous_release() {
  local name="$1" active="$2" rel take_next=0
  while IFS= read -r rel; do
    [ -n "${rel}" ] || continue
    if [ "${take_next}" = 1 ]; then
      printf '%s' "${rel}"
      return 0
    fi
    [ "${rel}" = "${active}" ] && take_next=1
  done < <(_site_releases_sorted "${name}")  # newest-first
  return 0
}

# _site_meta_build NAME — the site's recorded build tier from meta.json, or
# "none" if meta.json is absent/unreadable (a fresh site, or a pre-meta.json
# tree reached via `site-list --rebuild`). Used by site-rollback.sh and
# site-gc.sh's post-GC registry refresh, neither of which know the build tier
# on their own (only site-deploy.sh sets it).
_site_meta_build() {
  local name="$1" meta
  meta="${SITES_ROOT}/${name}/meta.json"
  if [ -f "${meta}" ]; then
    python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        print(json.load(f).get('build', 'none'))
except Exception:
    print('none')
" "${meta}" 2>/dev/null || printf 'none'
  else
    printf 'none'
  fi
}

# site_meta_write NAME BUILD PUBLISH_DIR — create/update the site-level
# meta.json (§4 layout: {created, build, publish_dir, spa, quota_mb, notes}).
# `created` is set once and preserved on every later call; `spa`/`quota_mb`/
# `notes` default in but are NOT overwritten if already present (spa is
# "recorded, not enforced" in pre1 per SPEC §14 OQ-4 — this module never reads
# it back, the panel/M2 will).
site_meta_write() {
  local name="$1" build="$2" publish_dir="$3" site_dir meta
  site_dir="${SITES_ROOT}/${name}"
  meta="${site_dir}/meta.json"
  mkdir -p "${site_dir}"
  SITE_META="${meta}" python3 - "${build}" "${publish_dir}" <<'PY'
import datetime
import json
import os
import sys

build, publish_dir = sys.argv[1:3]
path = os.environ["SITE_META"]
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

try:
    with open(path) as f:
        meta = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    meta = {}

meta.setdefault("created", now)
meta["build"] = build
meta["publish_dir"] = publish_dir
meta.setdefault("spa", False)
meta.setdefault("quota_mb", None)
meta.setdefault("notes", None)

tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(meta, f, indent=2, sort_keys=True)
    f.write("\n")
os.replace(tmp, path)
PY
}

# ── AD-5: retention GC ───────────────────────────────────────────────────────
# sites_gc_site NAME — keep the SITES_KEEP_RELEASES most-recent releases;
# ALWAYS additionally keep whichever release `current` points at, even if a
# prior rollback means it is no longer among the N most recent by timestamp
# (spec AD-5: "never GC the release current points at" — an unconditional
# invariant, not "unless it's old"). A no-op (rc 0) for a site with no
# releases/ dir yet, or with <= keep releases.
sites_gc_site() {
  local name="$1" keep="${SITES_KEEP_RELEASES:-5}"
  case "${keep}" in *[!0-9]*|'')
    warn "SITES_KEEP_RELEASES='${keep}' is not a whole number — using the default (5)"
    keep=5 ;;
  esac
  local releases_dir="${SITES_ROOT}/${name}/releases"
  [ -d "${releases_dir}" ] || return 0
  local active rel all=()
  active="$(_site_active_release "${name}" 2>/dev/null || true)"
  while IFS= read -r rel; do
    [ -n "${rel}" ] && all+=("${rel}")
  done < <(_site_releases_sorted "${name}")  # newest-first
  local total=${#all[@]}
  [ "${total}" -le "${keep}" ] && return 0

  # Build the keep-set: the newest $keep entries (array is newest-first, so
  # that's simply the first $keep entries) plus the active release
  # unconditionally.
  local -A keepset=()
  local idx
  for (( idx = 0; idx < keep && idx < total; idx++ )); do
    keepset["${all[${idx}]}"]=1
  done
  [ -n "${active}" ] && keepset["${active}"]=1

  local removed=0
  for rel in "${all[@]}"; do
    if [ -z "${keepset[${rel}]:-}" ]; then
      say "GC: pruning ${name} release ${rel} (retention ${keep}, active=${active:-none})"
      rm -rf "${releases_dir:?}/${rel}"
      removed=$(( removed + 1 ))
    fi
  done

  # Keep the registry's releases[]/bytes fields in sync with what GC just did —
  # otherwise they would only heal on the NEXT deploy (which writes them too)
  # or an explicit `site-list --rebuild`. Skip quietly if the site was never
  # registered or has no active release (nothing meaningful to record).
  if [ "${removed}" -gt 0 ] && [ -n "${active}" ] && [ -n "${DOMAIN:-}" ]; then
    registry_update_site "${name}" "${active}" "$(_site_meta_build "${name}")" "https://${name}.${DOMAIN}" \
      || warn "GC: could not refresh the registry for '${name}' after pruning (non-fatal)"
  fi
  return 0
}

# ── AD-6: job model ──────────────────────────────────────────────────────────
# job_start JOB KIND SITE RELEASE — write the initial "running" job record.
# RELEASE may be empty (deploy doesn't have one yet at job-creation time; it is
# filled in by job_done once the release actually exists).
job_start() {
  local job="$1" kind="$2" site="$3" release="${4:-}" f
  mkdir -p "${POCKET_STATE_DIR}"
  f="${POCKET_STATE_DIR}/site-job-${job}.json"
  python3 - "${job}" "${kind}" "${site}" "${release}" "${f}" <<'PY'
import datetime
import json
import os
import sys

job, kind, site, release, path = sys.argv[1:6]
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
doc = {
    "job": job, "kind": kind, "site": site, "state": "running",
    "release": release or None, "started": now, "ended": None, "error": None,
}
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(doc, f, indent=2, sort_keys=True)
    f.write("\n")
os.replace(tmp, path)
PY
}

# job_done JOB [RELEASE] — mark a job "done". RELEASE (if given) overwrites the
# release field — deploy uses this to record the release id it only knows at
# the very end; rollback/delete pass it (or "") too for symmetry.
job_done() {
  local job="$1" release="${2:-}" f
  f="${POCKET_STATE_DIR}/site-job-${job}.json"
  python3 - "${f}" "${release}" <<'PY'
import datetime
import json
import os
import sys

path, release = sys.argv[1:3]
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
try:
    with open(path) as f:
        doc = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    doc = {}
doc["state"] = "done"
doc["ended"] = now
doc["error"] = None
if release:
    doc["release"] = release
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(doc, f, indent=2, sort_keys=True)
    f.write("\n")
os.replace(tmp, path)
PY
}

# job_fail JOB ERROR — mark a job "failed" with a human-readable ERROR string.
# Called from the EXIT trap in every mutating script (deploy/rollback/delete),
# so this fires on ANY failure path — an explicit `fail`/`die` call, or an
# unexpected command failure under `set -e` that nothing wrapped by hand.
job_fail() {
  local job="$1" errmsg="${2:-unknown error}" f
  f="${POCKET_STATE_DIR}/site-job-${job}.json"
  python3 - "${f}" "${errmsg}" <<'PY'
import datetime
import json
import os
import sys

path, err = sys.argv[1:3]
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
try:
    with open(path) as f:
        doc = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    doc = {}
doc["state"] = "failed"
doc["ended"] = now
doc["error"] = err
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(doc, f, indent=2, sort_keys=True)
    f.write("\n")
os.replace(tmp, path)
PY
}

# job_log JOB MESSAGE... — append a UTC-timestamped line to the per-job log
# (SSE-tailed by the panel in M2) AND echo it via say() so a human running the
# script by hand sees the same narration live on stderr.
job_log() {
  local job="$1"; shift
  local msg="$*"
  mkdir -p "${POCKET_LOG_DIR}"
  printf '[%s] %s\n' "$(date -u +%FT%TZ)" "${msg}" >> "${POCKET_LOG_DIR}/site-deploy-${job}.log"
  say "${msg}"
}

# ── stale job/log purge (site-gc.sh) ────────────────────────────────────────
# sites_job_is_purgeable FILE — rc 0 (purgeable) unless the job's recorded
# state is "running" (never delete evidence of a job that, per its own state
# file, is still in flight — even if the file's mtime looks old, e.g. after a
# long-hung/killed process; an operator should SEE that, not have it vanish
# silently). An unreadable/corrupt job file is treated as purgeable — there is
# nothing worth preserving in it.
sites_job_is_purgeable() {
  local f="$1"
  python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as fh:
        doc = json.load(fh)
except Exception:
    sys.exit(0)
sys.exit(1 if doc.get('state') == 'running' else 0)
" "${f}"
}

# sites_purge_old_jobs DAYS — remove site-job-*.json + their paired
# site-deploy-*.log once older than DAYS (mtime-based; `find -mtime` is a
# POSIX-specified predicate, unlike `-printf`/`-print0`, so this stays portable
# to whatever `find` Termux ships). Job/release ids are entirely
# script-generated (timestamp + hex — see new_job_id), so they never contain
# spaces or newlines; a plain newline-delimited `find` read is safe here.
sites_purge_old_jobs() {
  local days="$1" f base job log
  [ -d "${POCKET_STATE_DIR}" ] || return 0
  mkdir -p "${POCKET_LOG_DIR}" 2>/dev/null || true

  while IFS= read -r f; do
    [ -n "${f}" ] || continue
    if sites_job_is_purgeable "${f}"; then
      base="$(basename "${f}")"
      job="${base#site-job-}"; job="${job%.json}"
      rm -f "${f}"
      log="${POCKET_LOG_DIR}/site-deploy-${job}.log"
      [ -f "${log}" ] && rm -f "${log}"
      say "GC: purged job record + log for ${job} (older than ${days}d)"
    fi
  done < <(find "${POCKET_STATE_DIR}" -maxdepth 1 -type f -name 'site-job-*.json' -mtime "+${days}" 2>/dev/null)

  # Orphaned logs (job json already gone, e.g. a previous GC run purged the
  # json but not a since-rotated log, or the json was hand-deleted).
  if [ -d "${POCKET_LOG_DIR}" ]; then
    while IFS= read -r f; do
      [ -n "${f}" ] || continue
      rm -f "${f}"
    done < <(find "${POCKET_LOG_DIR}" -maxdepth 1 -type f -name 'site-deploy-*.log' -mtime "+${days}" 2>/dev/null)
  fi
}

# ── AD-3: serialized global build lock (hugo/node tiers) ────────────────────
# sites_build_lock_acquire — plain `noclobber` lock (portable; no flock(1)
# dependency), matching the exact pattern ops/backup-all.sh already uses for
# its single-backup lock. Builds must NEVER run concurrently (AD-3: node's RAM
# ceiling assumes it owns the whole userland while it runs). On success sets
# SITES_BUILD_LOCK_HELD to the lock path so the CALLER's own EXIT trap can
# release it on ANY exit path, including a hard `die`/`exit` from inside the
# build — a function-local `trap ... RETURN` would NOT fire in that case, only
# a script-level EXIT trap does.
sites_build_lock_acquire() {
  mkdir -p "${POCKET_STATE_DIR}"
  local lock="${POCKET_STATE_DIR}/site-build.lock"
  if ! (set -o noclobber; : > "${lock}") 2>/dev/null; then
    die "another site build is already in progress (lock: ${lock}) — builds are serialized (AD-3); try again shortly"
  fi
  SITES_BUILD_LOCK_HELD="${lock}"
}
sites_build_lock_release() {
  [ -n "${SITES_BUILD_LOCK_HELD:-}" ] && rm -f "${SITES_BUILD_LOCK_HELD}"
  SITES_BUILD_LOCK_HELD=""
}

# ── §5 registry ops (python3, NOT jq — jq is not guaranteed present on Termux)─
# All three writers are atomic: write to REGISTRY.tmp then os.replace() onto
# REGISTRY (a single rename(2), same durability argument as atomic_swap above).
# Data comes in either via argv (site name / release id / build tier / url —
# all already regex-validated or script-constructed upstream, never raw user
# input) or via a per-command env-var prefix (SITES_ROOT/REGISTRY/DOMAIN) — this
# sidesteps every shell-quoting hazard of building JSON with string
# concatenation, at the cost of shelling out to python3 once per registry write
# (cheap; these are infrequent, human/panel-triggered operations, not a hot
# loop).

# registry_update_site NAME RELEASE BUILD URL — upsert one site's entry. The
# "releases" array is always recomputed from the on-disk releases/ dir (NOT
# passed in) so a call after site-gc.sh has pruned some releases self-heals the
# registry instead of needing a second write. "bytes" is the active release's
# on-disk size (sum of regular-file sizes, symlinks excluded via lstat).
registry_update_site() {
  local name="$1" release="$2" build="$3" url="$4"
  mkdir -p "${SITES_ROOT}"
  SITES_ROOT="${SITES_ROOT}" REGISTRY="${REGISTRY}" \
    python3 - "${name}" "${release}" "${build}" "${url}" <<'PY'
import datetime
import json
import os
import sys

sites_root = os.environ["SITES_ROOT"]
registry_path = os.environ["REGISTRY"]
name, release, build, url = sys.argv[1:5]


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load():
    try:
        with open(registry_path) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {"version": 1, "sites": {}}


def dir_size(path):
    total = 0
    for root, _dirs, files in os.walk(path):
        for fn in files:
            fp = os.path.join(root, fn)
            try:
                total += os.lstat(fp).st_size
            except OSError:
                pass
    return total


reg = load()
sites = reg.setdefault("sites", {})
site = sites.get(name, {})
created = site.get("created", now_iso())

releases_dir = os.path.join(sites_root, name, "releases")
releases = []
if os.path.isdir(releases_dir):
    releases = sorted(
        d for d in os.listdir(releases_dir)
        # ".tmp" in d (not endswith): build-shuffle strays are <id>.tmp.out
        if ".tmp" not in d and os.path.isdir(os.path.join(releases_dir, d))
    )

active_dir = os.path.join(releases_dir, release) if release else ""
bytes_ = dir_size(active_dir) if active_dir and os.path.isdir(active_dir) else site.get("bytes", 0)

site.update({
    "created": created,
    "updated": now_iso(),
    "active_release": release,
    "releases": releases,
    "build": build,
    "bytes": bytes_,
    "url": url,
})
sites[name] = site

tmp = registry_path + ".tmp"
with open(tmp, "w") as f:
    json.dump(reg, f, indent=2, sort_keys=True)
    f.write("\n")
os.replace(tmp, registry_path)
PY
}

# registry_remove_site NAME — drop a site's entry (site-delete.sh). A missing
# registry file is treated as already-empty (nothing to remove, not an error).
registry_remove_site() {
  local name="$1"
  REGISTRY="${REGISTRY}" python3 - "${name}" <<'PY'
import json
import os
import sys

registry_path = os.environ["REGISTRY"]
name = sys.argv[1]
try:
    with open(registry_path) as f:
        reg = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    reg = {"version": 1, "sites": {}}
reg.setdefault("sites", {}).pop(name, None)
tmp = registry_path + ".tmp"
with open(tmp, "w") as f:
    json.dump(reg, f, indent=2, sort_keys=True)
    f.write("\n")
os.replace(tmp, registry_path)
PY
}

# registry_rebuild — reconstruct .registry.json FROM the on-disk tree
# (site-list.sh --rebuild). The registry is DERIVED state (§5): this is the
# self-healing path after a restore, or after any out-of-band filesystem edit.
# A site directory qualifies if it has a releases/ subdirectory; `active` comes
# from resolving the `current` symlink (empty if absent — a half-deployed or
# GC'd-to-nothing site); `build`/`created` come from meta.json when present,
# falling back to "none" / the site directory's ctime.
registry_rebuild() {
  mkdir -p "${SITES_ROOT}"
  SITES_ROOT="${SITES_ROOT}" REGISTRY="${REGISTRY}" DOMAIN="${DOMAIN:-}" \
    python3 - <<'PY'
import datetime
import json
import os

sites_root = os.environ["SITES_ROOT"]
registry_path = os.environ["REGISTRY"]
domain = os.environ.get("DOMAIN", "")


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def dir_size(path):
    total = 0
    for root, _dirs, files in os.walk(path):
        for fn in files:
            fp = os.path.join(root, fn)
            try:
                total += os.lstat(fp).st_size
            except OSError:
                pass
    return total


sites = {}
if os.path.isdir(sites_root):
    for name in sorted(os.listdir(sites_root)):
        if name.startswith("."):
            continue  # .staging, .registry.json itself, any dotfile
        site_dir = os.path.join(sites_root, name)
        releases_dir = os.path.join(site_dir, "releases")
        if not os.path.isdir(releases_dir):
            continue  # not a site tree

        releases = sorted(
            d for d in os.listdir(releases_dir)
            # ".tmp" in d (not endswith): build-shuffle strays are <id>.tmp.out
            if ".tmp" not in d and os.path.isdir(os.path.join(releases_dir, d))
        )

        active = ""
        current = os.path.join(site_dir, "current")
        if os.path.islink(current):
            active = os.path.basename(os.readlink(current).rstrip("/"))

        meta = {}
        meta_path = os.path.join(site_dir, "meta.json")
        if os.path.isfile(meta_path):
            try:
                with open(meta_path) as f:
                    meta = json.load(f)
            except (OSError, json.JSONDecodeError):
                meta = {}

        try:
            created = datetime.datetime.fromtimestamp(
                os.stat(site_dir).st_ctime, tz=datetime.timezone.utc
            ).strftime("%Y-%m-%dT%H:%M:%SZ")
        except OSError:
            created = now_iso()

        active_dir = os.path.join(releases_dir, active) if active else ""
        sites[name] = {
            "created": meta.get("created", created),
            "updated": now_iso(),
            "active_release": active,
            "releases": releases,
            "build": meta.get("build", "none"),
            "bytes": dir_size(active_dir) if active_dir and os.path.isdir(active_dir) else 0,
            "url": f"https://{name}.{domain}" if domain else "",
        }

reg = {"version": 1, "sites": sites}
tmp = registry_path + ".tmp"
with open(tmp, "w") as f:
    json.dump(reg, f, indent=2, sort_keys=True)
    f.write("\n")
os.replace(tmp, registry_path)
PY
}
