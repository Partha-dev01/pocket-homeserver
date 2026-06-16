#!/usr/bin/env bash
#
# 50-install-element.sh — install the Element Web static client into the Debian
# userland and point it at our homeserver.
#
# What it does:
#   - downloads the Element Web release tarball (pinned version + sha256 as a
#     fail-closed supply-chain check) into ${DATA_DIR}/binaries,
#   - extracts it into the userland at /var/www/element (served by Caddy),
#   - writes a MINIMAL config.json whose default homeserver base_url is
#     https://chat.${DOMAIN} and server_name is ${MATRIX_SERVER_NAME}.
#
# Element's config schema is strict and validated CLIENT-SIDE only: a bad bump
# can white-page the SPA while curl still returns 200. After any version bump,
# re-verify the UI in a REAL browser — keep config.json to the minimal schema.
#
# Generalized from a working deployment; review before running on a fresh phone.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env
require_var DATA_DIR "folder on your large volume / SD card"
require_var DOMAIN   "your apex domain (DNS on Cloudflare)"
: "${MATRIX_SERVER_NAME:=$DOMAIN}"
require_cmd proot-distro
require_cmd curl

in_debian() { proot-distro login debian -- bash -lc "$1"; }

# ── Pinned release ───────────────────────────────────────────────────────────
# Pin an EXACT Element Web version + sha256 rather than tracking "latest": an
# unattended bump can break the strict client-side config schema, and a fixed
# hash lets us fail closed on a corrupt/tampered tarball.
#
# To upgrade: bump EL_VER and EL_SHA256 *together* AND re-verify the UI in a real
# browser. Get the hash from the release checksums or by hashing a trusted copy:
#   sha256sum element-vX.Y.Z.tar.gz
# Both can also be overridden from the environment without editing this file.
EL_VER="${EL_VER:-v1.12.15}"
EL_SHA256="${EL_SHA256:-3a729326fe295b3631ba17bda0775db30f41a6bb0ba12a4aff4d5f488d5e91e3}"
EL_URL="${EL_URL:-https://github.com/element-hq/element-web/releases/download/${EL_VER}/element-${EL_VER}.tar.gz}"

CACHE_DIR="${DATA_DIR}/binaries"
EL_LOCAL="${CACHE_DIR}/element-${EL_VER}.tar.gz"
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
if [ -f "${EL_LOCAL}" ]; then
  if [ "$(sha256sum "${EL_LOCAL}" 2>/dev/null | cut -d' ' -f1)" = "${EL_SHA256}" ]; then
    need_dl=false
    ok "Element Web cached + sha256-verified (${EL_VER})"
  else
    warn "cached Element Web does not match the pinned sha256 — re-downloading ${EL_VER}"
  fi
fi
if [ "${need_dl}" = "true" ]; then
  say "downloading Element Web ${EL_VER} to cache"
  curl -fsSL --retry 3 -o "${EL_LOCAL}.tmp" "${EL_URL}" || die "Element Web download failed (${EL_URL})"
  verify_sha256 "${EL_LOCAL}.tmp" "${EL_SHA256}"
  mv -f "${EL_LOCAL}.tmp" "${EL_LOCAL}"
  ok "Element Web ${EL_VER} cached at ${EL_LOCAL} ($(wc -c < "${EL_LOCAL}") bytes)"
fi

# ── 2. Extract into the userland (/var/www/element) ──────────────────────────
# The tarball has a top-level element-<ver>/ dir; --strip-components=1 drops it.
# Stream the tarball over stdin and extract inside the userland so we never
# hardcode the rootfs path. Clean the target first for a deterministic layout.
say "extracting Element Web into the userland (/var/www/element)"
in_debian 'rm -rf /var/www/element && mkdir -p /var/www/element'
proot-distro login debian -- bash -lc 'tar -xzf - --strip-components=1 -C /var/www/element' \
  < "${EL_LOCAL}" || die "failed to extract Element Web into the userland"

# ── 3. Write the minimal config.json ─────────────────────────────────────────
# MINIMAL schema only — Element 1.12.x rejects unknown fields and a strict-schema
# failure white-pages the client. Point at our single homeserver; lock the client
# to it (no custom URLs / guests). server_name is what user IDs are scoped to
# (@alice:${MATRIX_SERVER_NAME}); base_url is where the client talks to it.
say "writing Element config.json (minimal schema; homeserver = https://chat.${DOMAIN})"
proot-distro login debian -- bash -lc 'cat > /var/www/element/config.json' <<EOF
{
    "default_server_config": {
        "m.homeserver": {
            "base_url": "https://chat.${DOMAIN}",
            "server_name": "${MATRIX_SERVER_NAME}"
        }
    },
    "disable_custom_urls": true,
    "disable_guests": true,
    "disable_3pid_login": true,
    "show_labs_settings": true
}
EOF

in_debian 'ls -la /var/www/element/index.html /var/www/element/config.json' \
  || die "Element Web install looks incomplete (index.html / config.json missing)"

ok "Element Web ${EL_VER} installed at /var/www/element (served by Caddy on chat.${DOMAIN})"
