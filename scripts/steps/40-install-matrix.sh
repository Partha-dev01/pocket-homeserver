#!/usr/bin/env bash
#
# 40-install-matrix.sh — install the Matrix homeserver (continuwuity, a maintained
# conduwuit fork; RocksDB backend) into the Debian userland.
#
# What it does:
#   - downloads the continuwuity linux-arm64 server binary (pinned version + sha256
#     as a fail-closed supply-chain check) into ${DATA_DIR}/binaries,
#   - installs it into the userland at /opt/conduwuit/conduwuit,
#   - creates /var/lib/conduwuit/{db,media} in the userland and bind-mounts the
#     media dir onto the large volume (${DATA_DIR}/media),
#   - ensures the rendered conduwuit.toml exists (runs render-config.sh if missing)
#     and deploys it into the userland at /etc/conduwuit/conduwuit.toml.
#
# This step does NOT set the registration token. Registration stays closed in the
# rendered config; mint single-use invite tokens out-of-band from the admin.
#
# Generalized from a working deployment; review before running on a fresh phone.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env
require_var DATA_DIR "folder on your large volume / SD card"
require_cmd proot-distro
require_cmd curl

in_debian() { proot-distro login debian -- bash -lc "$1"; }

# ── Pinned release ───────────────────────────────────────────────────────────
# The homeserver is the single riskiest service to upgrade silently (DB schema /
# federation), so pin an EXACT continuwuity version + sha256 rather than tracking
# "latest". A fixed hash also lets us fail closed on a corrupt/tampered download.
#
# IMPORTANT: this is continuwuity (the maintained fork hosted on forgejo.ellis.link),
# NOT the original girlbossceo/conduwuit repo and NOT a floating "latest" tag.
#
# To upgrade: snapshot the DB + keep the current rollback binary FIRST, then bump
# CW_VER and CW_SHA256 *together*. Get the new hash from the release checksums, or
# by hashing a binary you already trust:  sha256sum conduwuit-linux-arm64
# Both can also be overridden from the environment without editing this file.
CW_VER="${CW_VER:-0.5.9}"
CW_SHA256="${CW_SHA256:-d325133456241bf64e4dec5dc905fc0513b1e3fb7eaaa927f51726b801a9d3d2}"
CW_URL="${CW_URL:-https://forgejo.ellis.link/continuwuation/continuwuity/releases/download/v${CW_VER}/conduwuit-linux-arm64}"

CACHE_DIR="${DATA_DIR}/binaries"
CW_LOCAL="${CACHE_DIR}/conduwuit-linux-arm64"
mkdir -p "${CACHE_DIR}"

verify_sha256() {  # verify_sha256 FILE WANT — fail closed (delete) on mismatch
  local f="$1" want="$2" got
  [ -f "$f" ] || die "sha256 verify: file not found: $f"
  got="$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1)"
  if [ "$got" != "$want" ]; then
    rm -f "$f"
    die "sha256 MISMATCH for $(basename "$f") — expected $want, got ${got:-<none>}; refusing to install"
  fi
  ok "sha256 verified: $(basename "$f") (${want})"
}

# ── 1. Download to the cache (re-verify any cached copy against the pin) ──────
need_dl=true
if [ -f "${CW_LOCAL}" ]; then
  if [ "$(sha256sum "${CW_LOCAL}" 2>/dev/null | cut -d' ' -f1)" = "${CW_SHA256}" ]; then
    need_dl=false
    ok "continuwuity cached + sha256-verified (v${CW_VER})"
  else
    warn "cached continuwuity does not match the pinned sha256 — re-downloading v${CW_VER}"
  fi
fi
if [ "${need_dl}" = "true" ]; then
  say "downloading continuwuity v${CW_VER} to cache"
  curl -fsSL --retry 3 -o "${CW_LOCAL}.tmp" "${CW_URL}" || die "continuwuity download failed (${CW_URL})"
  verify_sha256 "${CW_LOCAL}.tmp" "${CW_SHA256}"
  chmod +x "${CW_LOCAL}.tmp"
  mv -f "${CW_LOCAL}.tmp" "${CW_LOCAL}"
  ok "continuwuity v${CW_VER} cached at ${CW_LOCAL} ($(wc -c < "${CW_LOCAL}") bytes)"
fi

# ── 2. Install into the userland ─────────────────────────────────────────────
# proot-distro manages the rootfs path; copy through `proot-distro login` so we
# don't hardcode the install location. Stream the binary in over stdin.
say "installing continuwuity into the userland (/opt/conduwuit/conduwuit)"
in_debian 'mkdir -p /opt/conduwuit'
proot-distro login debian -- bash -lc 'cat > /opt/conduwuit/conduwuit && chmod +x /opt/conduwuit/conduwuit' \
  < "${CW_LOCAL}" || die "failed to copy the continuwuity binary into the userland"
ver="$(in_debian '/opt/conduwuit/conduwuit --version 2>&1 | head -1' || true)"
[ -n "${ver}" ] && ok "continuwuity: ${ver}" || die "continuwuity binary did not run inside the userland"

# ── 3. Create the data dirs + bind media onto the large volume ───────────────
# The DB lives inside the userland (small, RocksDB). Media can be large, so it
# lives on ${DATA_DIR} and is bind-mounted into the userland at runtime by the
# start step (proot-distro login --bind ${DATA_DIR}/media:/var/lib/conduwuit/media).
# We create both the in-userland mountpoint AND the backing dir on the volume.
say "creating conduwuit data dirs (db in userland, media on the large volume)"
in_debian 'mkdir -p /var/lib/conduwuit/db /var/lib/conduwuit/media' \
  || die "failed to create /var/lib/conduwuit/{db,media} in the userland"
mkdir -p "${DATA_DIR}/media" || die "cannot create ${DATA_DIR}/media on the data volume"
ok "media backing dir ready: ${DATA_DIR}/media (bind-mounted at start time)"

# ── 4. Ensure + deploy the rendered conduwuit.toml ───────────────────────────
RENDERED="${POCKET_ROOT}/config/rendered/conduwuit.toml"
if [ ! -f "${RENDERED}" ]; then
  say "rendered conduwuit.toml missing — running render-config.sh"
  bash "${POCKET_ROOT}/scripts/render-config.sh" || die "render-config.sh failed"
fi
[ -f "${RENDERED}" ] || die "rendered conduwuit.toml still missing at ${RENDERED}"

say "deploying rendered conduwuit.toml into the userland (/etc/conduwuit/conduwuit.toml)"
in_debian 'mkdir -p /etc/conduwuit'
proot-distro login debian -- bash -lc 'cat > /etc/conduwuit/conduwuit.toml' < "${RENDERED}" \
  || die "failed to copy conduwuit.toml into the userland"

ok "Matrix homeserver installed (registration stays closed; mint invite tokens from the admin)"
