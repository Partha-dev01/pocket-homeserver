#!/usr/bin/env bash
#
# 10-install-userland.sh — install the Debian userland (proot-distro) and its
# baseline apt dependencies.
#
# What it does:
#   - installs a Debian rootfs via `proot-distro install debian` (skip if present),
#   - seeds working DNS inside it,
#   - installs the baseline apt packages every later step relies on.
#
# Note on paths: proot-distro manages its OWN install location
# ($PREFIX/var/lib/proot-distro/installed-rootfs/debian on current releases), so
# we drive everything through `proot-distro login debian -- ...`. The ${ROOTFS_DIR}
# config value is INFORMATIONAL here (used by docs/backups), not a path we install to.
#
# Generalized from a working deployment; review before running on a fresh phone.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env
require_cmd proot-distro
require_cmd curl

# Run a command inside the Debian userland.
in_debian() { proot-distro login debian -- bash -lc "$1"; }

# ── 1. Install the Debian rootfs (idempotent) ────────────────────────────────
# `proot-distro list` marks installed distros; grep that rather than guessing a path.
if proot-distro list 2>/dev/null | grep -qiE 'debian.*installed' \
   || in_debian 'true' 2>/dev/null; then
  ok "Debian userland already installed (skipping ~250 MB download)"
else
  say "installing Debian userland via proot-distro (~250 MB; a few minutes)"
  proot-distro install debian || die "proot-distro install debian failed"
  ok "Debian userland installed"
fi

# ── 2. Seed working DNS inside the userland ──────────────────────────────────
# proot userlands frequently start with no usable resolver; point at public DNS
# so the apt step below can reach the mirrors.
say "seeding DNS inside the userland"
in_debian 'printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > /etc/resolv.conf' \
  || warn "could not write /etc/resolv.conf in the userland (apt may still work)"

# ── 3. Install baseline apt dependencies ─────────────────────────────────────
# Kept to the common runtime/build prerequisites the stack needs: TLS roots,
# fetch tools, archive tools, the C/C++ runtime libs binaries link against, a
# locale, and Python for the auth gateway / admin panel.
run_once userland-apt -- in_debian '
  set -e
  export DEBIAN_FRONTEND=noninteractive LC_ALL=C
  apt-get update -qq
  apt-get install -y --no-install-recommends \
    ca-certificates curl wget tar unzip file zstd xz-utils \
    libssl3 libstdc++6 libc6 \
    locales tzdata less procps iproute2 \
    python3 python3-pip python3-venv \
    jq openssl
  # Generate a UTF-8 locale so interactive tools and services behave.
  sed -i "s/^# *\(en_US.UTF-8 UTF-8\)/\1/" /etc/locale.gen 2>/dev/null || true
  locale-gen en_US.UTF-8 >/dev/null 2>&1 || true
  echo "baseline packages installed: $(dpkg -l | grep -cE "^ii ") total"
' || die "baseline apt install inside the userland failed"

# ── 4. Apply the configured timezone (best effort) ───────────────────────────
# TZ defaults to Etc/UTC in common.sh; mirror it into the userland.
say "applying timezone ${TZ} inside the userland"
in_debian "ln -sf /usr/share/zoneinfo/${TZ} /etc/localtime 2>/dev/null || true; \
           echo '${TZ}' > /etc/timezone 2>/dev/null || true" \
  || warn "could not set timezone in the userland (non-fatal)"

ok "Debian userland ready"
