#!/usr/bin/env bash
#
# 20-install-cloudflared.sh — install the Cloudflare Tunnel connector
# (cloudflared) into the Debian userland.
#
# What it does:
#   - downloads the cloudflared linux-arm64 binary (pinned version + sha256),
#   - caches it under ${DATA_DIR}/binaries so re-runs / rebuilds don't re-fetch,
#   - copies it into the userland's /usr/local/bin and marks it executable,
#   - verifies `cloudflared --version` runs inside the userland.
#
# This step does NOT touch the tunnel token. The token (CF_TUNNEL_TOKEN) is read
# only at start time by the start-stack step — it is never written to disk here.
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
# Pin an EXACT cloudflared version + sha256 rather than tracking "latest": the
# tunnel is the auth-critical ingress, so we don't want it silently upgrading on
# every rebuild, and a fixed hash lets us fail closed on a corrupt/tampered file.
#
# To upgrade: bump CF_VER and CF_SHA256 *together*. Get the new hash from the
# release's checksums, or by hashing the downloaded binary once you trust it:
#   sha256sum cloudflared-linux-arm64
# Both can also be overridden from the environment without editing this file.
CF_VER="${CF_VER:-2026.3.0}"
CF_SHA256="${CF_SHA256:-0755ba4cbab59980e6148367fcf53a8f3ec85a97deefd63c2420cf7850769bee}"
CF_URL="https://github.com/cloudflare/cloudflared/releases/download/${CF_VER}/cloudflared-linux-arm64"

CACHE_DIR="${DATA_DIR}/binaries"
CF_LOCAL="${CACHE_DIR}/cloudflared-linux-arm64"
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
if [ -x "${CF_LOCAL}" ]; then
  if [ "$(sha256sum "${CF_LOCAL}" 2>/dev/null | cut -d' ' -f1)" = "${CF_SHA256}" ]; then
    need_dl=false
    ok "cloudflared cached + sha256-verified (${CF_VER})"
  else
    warn "cached cloudflared does not match the pinned sha256 — re-downloading ${CF_VER}"
  fi
fi
if [ "${need_dl}" = "true" ]; then
  say "downloading cloudflared ${CF_VER} to cache"
  curl -fsSL -o "${CF_LOCAL}.tmp" "${CF_URL}" || die "cloudflared download failed (${CF_URL})"
  verify_sha256 "${CF_LOCAL}.tmp" "${CF_SHA256}"
  chmod +x "${CF_LOCAL}.tmp"
  mv -f "${CF_LOCAL}.tmp" "${CF_LOCAL}"
  ok "cloudflared ${CF_VER} cached at ${CF_LOCAL} ($(wc -c < "${CF_LOCAL}") bytes)"
fi

# ── 2. Install into the userland ─────────────────────────────────────────────
# proot-distro manages the rootfs path; copy through `proot-distro login` so we
# don't hardcode the install location. Stream the binary in over stdin.
say "installing cloudflared into the userland (/usr/local/bin)"
in_debian 'mkdir -p /usr/local/bin'
proot-distro login debian -- bash -lc 'cat > /usr/local/bin/cloudflared && chmod +x /usr/local/bin/cloudflared' \
  < "${CF_LOCAL}" || die "failed to copy cloudflared into the userland"

# ── 3. Verify ────────────────────────────────────────────────────────────────
say "verifying cloudflared inside the userland"
ver="$(in_debian '/usr/local/bin/cloudflared --version 2>&1 | head -1' || true)"
[ -n "${ver}" ] && ok "cloudflared: ${ver}" || die "cloudflared did not run inside the userland"

ok "cloudflared installed (token is read at start time from CF_TUNNEL_TOKEN, not stored here)"
