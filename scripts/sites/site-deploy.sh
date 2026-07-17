#!/usr/bin/env bash
#
# sites/site-deploy.sh — publish one release of a static site (SPEC-SITES-PIPELINE
# §6, §8, AD-3, AD-4). Read the spec first; this header only orients you.
#
# Usage:
#   site-deploy.sh <name> <staged-artifact> [--build none|hugo|node] [--job <id>] [--allow-no-index]
#
#   <name>              subdomain label, validated + reservation-checked (§7).
#   <staged-artifact>   a directory (copied) or a .zip (safe-extracted). Under a
#                        non-interactive caller (no tty on stdin — the panel/MCP
#                        surface) it MUST realpath-resolve inside .staging/; an
#                        operator running this by hand from a real shell may pass
#                        any path (§6 — "CLI convenience without widening the
#                        panel/MCP surface").
#   --build MODE         none (default, AD-3) | hugo | node.
#   --job ID              reuse a job id the caller (panel/MCP) already
#                        allocated, instead of minting a fresh one.
#   --allow-no-index      skip the "publish root must contain index.html" sanity
#                        check (§6) — e.g. a site whose entrypoint is a
#                        different filename via a future SPA-fallback config.
#
# Pipeline (every step job_log'd to ${POCKET_LOG_DIR}/site-deploy-<job>.log):
#   validate name -> allocate release+job -> stage (copy dir | safe-extract zip)
#   -> build tier -> sanity check -> fsync-rename tmp release -> atomic swap
#   -> meta.json + registry update -> landing-regen hook (no-op until M2)
#   -> post-deploy GC -> job done.
# On ANY failure: job marked "failed" with a reason, the half-built
# releases/<id>.tmp is removed, and the script exits 1 — `current` is NEVER
# touched until the new release is fully materialized (AD-4's whole point).

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-sites.sh"

load_env
require_var DOMAIN "your public domain — used to build this site's https://<name>.<DOMAIN> URL"
require_cmd python3

# ── argv ──────────────────────────────────────────────────────────────────────
[ $# -ge 2 ] || die "usage: site-deploy.sh <name> <staged-artifact> [--build none|hugo|node] [--job <id>] [--allow-no-index]"
SITE_NAME="$1"
ARTIFACT="$2"
shift 2

BUILD_MODE="none"
JOB_ID_ARG=""
ALLOW_NO_INDEX=0
while [ $# -gt 0 ]; do
  case "$1" in
    --build)
      [ $# -ge 2 ] || die "--build requires an argument (none|hugo|node)"
      BUILD_MODE="$2"; shift 2 ;;
    --job)
      [ $# -ge 2 ] || die "--job requires an argument"
      JOB_ID_ARG="$2"; shift 2 ;;
    --allow-no-index)
      ALLOW_NO_INDEX=1; shift ;;
    *)
      die "unknown argument: $1" ;;
  esac
done
case "${BUILD_MODE}" in
  none|hugo|node) : ;;
  *) die "invalid --build '${BUILD_MODE}' (must be none|hugo|node)" ;;
esac

# A caller-supplied --job id lands verbatim in state/log file paths
# (site-job-<id>.json, site-deploy-<id>.log), so it gets the same whole-string
# format gate as a release id — job ids share the exact <UTC-ts>-<4hex> shape
# (new_job_id/new_release_id are twins in lib-sites.sh).
if [ -n "${JOB_ID_ARG}" ]; then
  [[ ${JOB_ID_ARG} =~ ${RELEASE_ID_RE} ]] \
    || die "invalid --job id '${JOB_ID_ARG}' — must match ${RELEASE_ID_RE} (allocate ids with new_job_id)"
fi

sites_root_init

# §7 — the ONE user-derived argv input, validated before anything is allocated.
validate_site_name "${SITE_NAME}"

[ -e "${ARTIFACT}" ] || die "staged artifact not found: ${ARTIFACT}"

# §6 — staging containment. A real interactive tty on stdin is the operator
# running this by hand; anything else (the panel/MCP calling it as a
# subprocess) MUST have staged the artifact under .staging/ itself.
if [ ! -t 0 ]; then
  REAL_ARTIFACT="$(realpath -m -- "${ARTIFACT}")"
  REAL_STAGING="$(realpath -m -- "${STAGING}")"
  case "${REAL_ARTIFACT}/" in
    "${REAL_STAGING}/"*) : ;;
    *) die "non-interactive callers must stage artifacts under ${STAGING} (got: ${ARTIFACT}) — an operator running this by hand from a real terminal is exempt (tty check)" ;;
  esac
fi

JOB_ID="${JOB_ID_ARG:-$(new_job_id)}"

# ── failure handling: one EXIT trap is the single source of truth ───────────
# DEPLOY_OK flips to 1 only once the release is fully live + recorded; every
# other exit path (an explicit `fail`, or an unwrapped command failing under
# `set -e`) leaves it 0, so the trap below always cleans up the same way:
# remove the half-built .tmp release, release the build lock if one was held,
# and write job_fail with the best error string available.
DEPLOY_ERR=""
RELEASE_ID=""
RELEASE_TMP=""
DEPLOY_OK=0

fail() {
  DEPLOY_ERR="$*"
  job_log "${JOB_ID}" "ERROR: $*"
  die "$*"
}

cleanup_on_exit() {
  local rc=$?
  if [ "${DEPLOY_OK}" != 1 ]; then
    if [ -n "${SITES_BUILD_LOCK_HELD:-}" ]; then
      sites_build_lock_release
    fi
    if [ -n "${RELEASE_TMP}" ] && [ -d "${RELEASE_TMP}" ]; then
      job_log "${JOB_ID}" "cleaning up incomplete release: ${RELEASE_TMP}"
      rm -rf "${RELEASE_TMP}"
    fi
    job_fail "${JOB_ID}" "${DEPLOY_ERR:-deploy failed unexpectedly (rc=${rc}) — see ${POCKET_LOG_DIR}/site-deploy-${JOB_ID}.log}"
  fi
  exit "${rc}"
}
trap cleanup_on_exit EXIT

# ── build tier scaffolding (AD-3) ────────────────────────────────────────────
# Defined here, BEFORE the pipeline body below calls them (bash resolves a
# function name at CALL time against whatever has been defined so far in
# top-to-bottom execution order — unlike the rest of this file's control flow,
# where reading top-to-bottom mirrors the deploy narrative, these two need to
# be registered before the "build tier" case block near the bottom reaches
# them, so they live up here instead).
#
# M1 SCOPE: `none` (the case block's default arm) is the only tier the laptop
# test suite exercises end-to-end. `hugo`/`node` below are fully implemented —
# lazy pinned-tool install (AD-3), the global build lock, the rlimit/timeout
# plumbing, and the userland dispatch are all live — but on any host with no
# proot-distro userland (this laptop, any dev box, CI) they fail immediately
# with a clear reason instead of pretending to build. They are exercised by
# the arm64-qemu E2E harness (§12), not here.

# build_hugo SRC — build a Hugo site in place: SRC currently holds the staged
# Hugo *source* tree (content/, config, themes/...); on return SRC must hold
# ONLY the built output, because `current` always points at the WHOLE release
# directory (never a subpath — AD-4), so "hugo builds to public/" has to be
# reconciled into "the release root IS the output" before this function
# returns.
build_hugo() {
  local src="$1" userland_src out
  local hugo_dir hugo_bin ver_file cache_dir url tarball tmp_extract
  sites_build_lock_acquire
  if ! command -v proot-distro >/dev/null 2>&1 || ! proot-distro login debian -- true >/dev/null 2>&1; then
    sites_build_lock_release
    fail "proot-distro userland not available on this host — hugo builds run *in the userland* against the pinned binary (config/versions.env HUGO_VERSION/HUGO_SHA256, fetched via fetch_verified per AD-3) and cannot execute here. Expected on a laptop/dev box; this tier is exercised by the arm64-qemu E2E harness (§12), not the laptop test suite."
  fi

  # Never install an unpinned binary (§11.2) — both halves of the pin must be
  # set in config/versions.env before this tier can do anything.
  if [ -z "${HUGO_VERSION:-}" ] || [ -z "${HUGO_SHA256:-}" ]; then
    sites_build_lock_release
    fail "HUGO_VERSION/HUGO_SHA256 are unset — pin the Hugo release in config/versions.env before deploying with --build hugo (fetch_verified refuses to fetch anything unpinned)"
  fi

  # Lazy install (AD-3): the pinned binary + a version stamp live host-side
  # under the userland rootfs (AD-2 — plain file I/O, no proot round-trip for
  # placement); only EXECUTING it, below, goes through proot-distro. Re-installs
  # whenever the binary is missing or the stamp doesn't match HUGO_VERSION
  # exactly (e.g. after a version bump in config/versions.env).
  hugo_dir="${PD_BASE}/debian/opt/hugo"
  hugo_bin="${hugo_dir}/hugo"
  ver_file="${hugo_dir}/.version"
  if [ -x "${hugo_bin}" ] && [ "$(cat "${ver_file}" 2>/dev/null || true)" = "${HUGO_VERSION}" ]; then
    job_log "${JOB_ID}" "hugo: pinned binary ${HUGO_VERSION} already installed at ${hugo_bin}"
  else
    job_log "${JOB_ID}" "hugo: installing pinned hugo ${HUGO_VERSION} into the userland"
    url="https://github.com/gohugoio/hugo/releases/download/v${HUGO_VERSION}/hugo_${HUGO_VERSION}_linux-arm64.tar.gz"
    cache_dir="${hugo_dir}/.cache"
    tarball="${cache_dir}/hugo_${HUGO_VERSION}_linux-arm64.tar.gz"
    mkdir -p "${cache_dir}"
    fetch_verified "${url}" "${tarball}" "${HUGO_SHA256}" \
      || { sites_build_lock_release; fail "hugo download/sha256-verify failed (${url})"; }
    # Extract JUST the `hugo` binary (the release tarball's only other members
    # are LICENSE/README) — never trust a bare `tar -x` of the whole archive
    # into a shared dir.
    tmp_extract="${cache_dir}/extract.$$"
    rm -rf "${tmp_extract}"
    mkdir -p "${tmp_extract}"
    tar -xzf "${tarball}" -C "${tmp_extract}" hugo \
      || { rm -rf "${tmp_extract}"; sites_build_lock_release; fail "could not extract the hugo binary out of ${tarball}"; }
    mv -f "${tmp_extract}/hugo" "${hugo_bin}"
    rm -rf "${tmp_extract}"
    chmod 0755 "${hugo_bin}"
    printf '%s\n' "${HUGO_VERSION}" > "${ver_file}"
    job_log "${JOB_ID}" "hugo: installed ${HUGO_VERSION} at ${hugo_bin}"
  fi

  userland_src="$(host_to_userland "${src}")"
  job_log "${JOB_ID}" "hugo: building ${userland_src} in the userland (timeout ${SITES_BUILD_TIMEOUT:-900}s, nice -n 10)"
  if ! proot-distro login debian -- bash -lc \
      "cd '${userland_src}' && timeout '${SITES_BUILD_TIMEOUT:-900}' nice -n 10 /opt/hugo/hugo --minify"; then
    sites_build_lock_release
    fail "hugo build exited non-zero (see ${POCKET_LOG_DIR}/site-deploy-${JOB_ID}.log)"
  fi
  if [ ! -d "${src}/public" ]; then
    sites_build_lock_release
    fail "hugo build produced no public/ directory"
  fi
  out="${src}.out"
  rm -rf "${out}"
  mv "${src}/public" "${out}"
  rm -rf "${src}"
  mv "${out}" "${src}"
  sites_build_lock_release
}

# build_node SRC — same in-place reconciliation as build_hugo, but for a
# node/npm project: tries SITES_NODE_PUBLISH_DIR (default dist), then build,
# then out, and records which one it used in _NODE_PUBLISH_DIR_USED for the
# caller's meta.json write.
build_node() {
  local src="$1" userland_src ram timeout_s publish_dir d out
  local node_major node_desc
  sites_build_lock_acquire
  if ! command -v proot-distro >/dev/null 2>&1 || ! proot-distro login debian -- true >/dev/null 2>&1; then
    sites_build_lock_release
    fail "proot-distro userland not available on this host — node builds run *in the userland* (apt nodejs/npm, node >=20 — same precedent as apps/pingvin.sh:98) and cannot execute here. Expected on a laptop/dev box; this tier is exercised by the arm64-qemu E2E harness (§12), not the laptop test suite."
  fi

  # Lazy install (AD-3): same apt mechanism (Debian's own repo, not NodeSource)
  # as apps/pingvin.sh:98. `command -v` is a shell builtin, not an executable,
  # so the presence probe — like every other in-userland check in this file —
  # goes through `bash -lc` rather than a bare proot-distro exec.
  if proot-distro login debian -- bash -lc 'command -v node' >/dev/null 2>&1; then
    job_log "${JOB_ID}" "node: already present in the userland"
  else
    job_log "${JOB_ID}" "node: not found in the userland — installing nodejs/npm (apt; apps/pingvin.sh:98 mechanism)"
    if ! proot-distro login debian -- bash -lc \
        "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends git nodejs npm ca-certificates build-essential python3 pkg-config"; then
      sites_build_lock_release
      fail "apt-get install of nodejs/npm failed inside the userland"
    fi
    job_log "${JOB_ID}" "node: nodejs/npm installed"
  fi

  # Re-check the version floor even when node was already present (an operator
  # may have a stale userland Node) — unlike pingvin.sh (which only warns), a
  # site build has no interactive fallback, so this fails closed.
  node_major="$(proot-distro login debian -- bash -lc 'node -p "process.versions.node.split(\".\")[0]"' 2>/dev/null | tr -dc '0-9' || true)"
  if [ -z "${node_major}" ] || [ "${node_major}" -lt 20 ] 2>/dev/null; then
    node_desc="unreadable"
    [ -n "${node_major}" ] && node_desc="v${node_major}"
    sites_build_lock_release
    fail "userland node is ${node_desc} — node builds need Node >= 20 (same floor as apps/pingvin.sh); upgrade node in the userland and re-run"
  fi
  job_log "${JOB_ID}" "node: version check passed (v${node_major} >= 20)"

  userland_src="$(host_to_userland "${src}")"
  ram="${SITES_BUILD_MAX_RAM_MB:-1024}"
  timeout_s="${SITES_BUILD_TIMEOUT:-900}"
  publish_dir="${SITES_NODE_PUBLISH_DIR:-dist}"
  job_log "${JOB_ID}" "node: building ${userland_src} in the userland (ulimit -v ${ram}MB, timeout ${timeout_s}s, publish_dir=${publish_dir})"
  if ! proot-distro login debian -- bash -lc \
      "cd '${userland_src}' && ulimit -v $(( ram * 1024 )) && timeout '${timeout_s}' npm ci --no-audit --no-fund && timeout '${timeout_s}' npm run build"; then
    sites_build_lock_release
    fail "node build exited non-zero (see ${POCKET_LOG_DIR}/site-deploy-${JOB_ID}.log — a kill from the RAM ceiling or the timeout both land here too)"
  fi
  for d in "${publish_dir}" build out; do
    if [ -d "${src}/${d}" ]; then
      out="${src}.out"
      rm -rf "${out}"
      mv "${src}/${d}" "${out}"
      rm -rf "${src}"
      mv "${out}" "${src}"
      _NODE_PUBLISH_DIR_USED="${d}"
      sites_build_lock_release
      return 0
    fi
  done
  sites_build_lock_release
  fail "node build produced none of the expected publish dirs (${publish_dir}, build, out)"
}

# ── the actual pipeline ──────────────────────────────────────────────────────

job_start "${JOB_ID}" deploy "${SITE_NAME}" ""
job_log "${JOB_ID}" "deploy starting: site=${SITE_NAME} artifact=${ARTIFACT} build=${BUILD_MODE}"

SITE_DIR="${SITES_ROOT}/${SITE_NAME}"
RELEASES_DIR="${SITE_DIR}/releases"
mkdir -p "${RELEASES_DIR}"

# Previous active release, captured BEFORE this deploy touches anything — used
# both for hardlink-dedupe (below) and purely informational logging.
PREV_RELEASE="$(_site_active_release "${SITE_NAME}" 2>/dev/null || true)"

RELEASE_ID="$(new_release_id)"
RELEASE_TMP="${RELEASES_DIR}/${RELEASE_ID}.tmp"
job_log "${JOB_ID}" "allocated release ${RELEASE_ID} (previous: ${PREV_RELEASE:-none})"
rm -rf "${RELEASE_TMP}"
mkdir -p "${RELEASE_TMP}"

# ── stage: copy a directory artifact, or safe-extract a zip ─────────────────
if [ -d "${ARTIFACT}" ]; then
  # Hardlink-dedupe (AD-5) against the previous release when one exists AND
  # rsync is available: `--link-dest` makes every byte-identical file in the
  # new release a hardlink to the old one instead of a fresh copy, so release
  # history stays cheap. Without rsync we fall back to a plain `cp -a` — no
  # dedupe, each release costs its full size on disk — which is a real
  # regression but a safe, always-available one; rsync ships as a normal apt
  # package so this only bites a truly bare userland.
  #
  # --checksum is NOT optional here: rsync's DEFAULT "quick check" decides
  # whether a file is "unchanged" (and therefore safe to hardlink from
  # link-dest) using only size + mtime, never content. Two site artifacts
  # produced back-to-back by the same build/editor commonly land on the exact
  # same file size with mtimes inside rsync's comparison granularity (this bit
  # us for real during testing: a v1/v2 index.html of equal length, deployed
  # seconds apart, quick-checked as "identical" and got silently hardlinked to
  # the STALE v1 bytes). --checksum forces an actual content hash comparison —
  # slower (reads every file), but a deploy pipeline whose whole premise is
  # "what got published is really what you just uploaded" cannot trade that
  # correctness for speed.
  #
  # -rlpgoD (NOT -a) is equally deliberate: -a would include -t, and
  # --link-dest refuses to hardlink unless the candidate matches in EVERY
  # preserved attribute — with -t that includes mtime, and a fresh upload's
  # files always carry fresh mtimes, so same-content files would silently
  # never link and each "deduped" release would cost its full size (the arm64
  # E2E caught exactly that: nlink=1 on an unchanged asset). Dropping -t takes
  # mtime out of the preserved set: content identity comes from --checksum,
  # link eligibility from perms/owner (safe_extract normalizes modes to
  # 0644/0755, so same-content files DO match). Changed files simply carry the
  # deploy time as mtime — release trees are immutable, so nothing downstream
  # depends on source mtimes (Caddy's Last-Modified just reflects the deploy).
  if [ -n "${PREV_RELEASE}" ] && command -v rsync >/dev/null 2>&1; then
    job_log "${JOB_ID}" "staging: rsync --checksum --link-dest against ${PREV_RELEASE} (hardlink-dedupe)"
    rsync -rlpgoD --checksum --link-dest="${RELEASES_DIR}/${PREV_RELEASE}/" "${ARTIFACT}/" "${RELEASE_TMP}/" \
      || fail "rsync copy of the directory artifact failed"
  else
    [ -n "${PREV_RELEASE}" ] && warn "rsync not found — falling back to a plain copy (no hardlink-dedupe; this release costs its full size on disk)"
    job_log "${JOB_ID}" "staging: cp -a (no previous release to dedupe against, or rsync absent)"
    cp -a "${ARTIFACT}/." "${RELEASE_TMP}/" || fail "cp copy of the directory artifact failed"
  fi
elif [ -f "${ARTIFACT}" ] && [ "${ARTIFACT##*.}" = "zip" ]; then
  # §8 — zip safety lives ENTIRELY in safe_extract.py (traversal/symlink/bomb
  # guards, streamed extraction, realpath-containment under RELEASE_TMP). This
  # script never inspects zip entries itself.
  SAFE_EXTRACT="${_SITES_LIB_DIR}/safe_extract.py"
  [ -f "${SAFE_EXTRACT}" ] || fail "safe_extract.py not found at ${SAFE_EXTRACT} (should ship alongside site-deploy.sh)"
  job_log "${JOB_ID}" "staging: safe-extracting zip via ${SAFE_EXTRACT}"
  python3 "${SAFE_EXTRACT}" "${ARTIFACT}" "${RELEASE_TMP}" || fail "zip extraction failed a safety check (traversal/symlink/bomb/size — see the log above)"
else
  fail "artifact is neither a directory nor a .zip file: ${ARTIFACT}"
fi

# ── build tier dispatch (AD-3) ────────────────────────────────────────────────
PUBLISH_DIR_META="."
case "${BUILD_MODE}" in
  none)
    job_log "${JOB_ID}" "build: none — serving the staged artifact as-is"
    ;;
  hugo)
    job_log "${JOB_ID}" "build: hugo — acquiring the global build lock"
    build_hugo "${RELEASE_TMP}"
    PUBLISH_DIR_META="public"
    ;;
  node)
    job_log "${JOB_ID}" "build: node — acquiring the global build lock"
    build_node "${RELEASE_TMP}"
    PUBLISH_DIR_META="${_NODE_PUBLISH_DIR_USED:-${SITES_NODE_PUBLISH_DIR:-dist}}"
    ;;
esac

# ── sanity check ──────────────────────────────────────────────────────────────
if [ "${ALLOW_NO_INDEX}" != 1 ] && [ ! -f "${RELEASE_TMP}/index.html" ]; then
  fail "publish root has no index.html (pass --allow-no-index to publish anyway): ${RELEASE_TMP}"
fi
job_log "${JOB_ID}" "sanity check passed (index.html present, or --allow-no-index)"

# ── AD-4: fsync-then-rename, then the atomic pointer swap ──────────────────
# `sync -f` = syncfs(2) on the filesystem containing RELEASE_TMP. The plain
# `sync FILE` form fsyncs only the named directory INODE — the files inside it
# would not be durable across a power cut, and `current` must never point at a
# release whose bytes could vanish. Fall back to a global `sync` if the local
# `sync` build lacks -f (harmless, just machine-wide).
sync -f -- "${RELEASE_TMP}" 2>/dev/null || sync
mv -T "${RELEASE_TMP}" "${RELEASES_DIR}/${RELEASE_ID}" || fail "fsync-rename of the release directory failed"
job_log "${JOB_ID}" "release ${RELEASE_ID} materialized at ${RELEASES_DIR}/${RELEASE_ID}"

atomic_swap "${SITE_NAME}" "${RELEASE_ID}" || fail "atomic pointer swap failed"
job_log "${JOB_ID}" "current -> releases/${RELEASE_ID} (site is live)"

# ── meta.json + registry ─────────────────────────────────────────────────────
site_meta_write "${SITE_NAME}" "${BUILD_MODE}" "${PUBLISH_DIR_META}" \
  || fail "writing meta.json failed"

SITE_URL="https://${SITE_NAME}.${DOMAIN}"
registry_update_site "${SITE_NAME}" "${RELEASE_ID}" "${BUILD_MODE}" "${SITE_URL}" \
  || fail "registry update failed"
job_log "${JOB_ID}" "registry updated (active_release=${RELEASE_ID}, build=${BUILD_MODE})"

# ── landing-regen hook — no-op until M2 ships scripts/landing/regen-landing.sh
REGEN="${POCKET_ROOT}/scripts/landing/regen-landing.sh"
if [ -x "${REGEN}" ]; then
  job_log "${JOB_ID}" "running the landing-regen hook"
  "${REGEN}" || warn "landing-regen hook failed (non-fatal — the deploy itself already succeeded)"
else
  job_log "${JOB_ID}" "landing-regen hook not present yet (no-op until M2 — see SPEC-LANDING-SYNC)"
fi

# ── post-deploy GC (AD-5) — never touches the release we just published ────
sites_gc_site "${SITE_NAME}" || warn "post-deploy GC for '${SITE_NAME}' hit a problem (non-fatal — the deploy itself already succeeded)"
job_log "${JOB_ID}" "post-deploy GC complete (keep=${SITES_KEEP_RELEASES:-5})"

DEPLOY_OK=1
job_done "${JOB_ID}" "${RELEASE_ID}"
job_log "${JOB_ID}" "deploy done: ${SITE_URL} (release ${RELEASE_ID})"
ok "deployed ${SITE_NAME} -> ${SITE_URL} (release ${RELEASE_ID}, job ${JOB_ID})"
