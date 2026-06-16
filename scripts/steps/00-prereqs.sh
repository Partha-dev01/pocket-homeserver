#!/usr/bin/env bash
#
# 00-prereqs.sh — verify the Termux environment and lay down the data tree.
#
# What it does:
#   - confirms we are on Termux with the base tools present,
#   - `pkg install`s the handful of extra Termux packages the stack needs,
#   - confirms ${DATA_DIR} (your large volume / SD card) exists and is writable,
#   - creates the canonical data layout under ${DATA_DIR}.
#
# Generalized from a working deployment; review before running on a fresh phone.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env
require_var DATA_DIR "folder on your large volume / SD card"

# ── 1. Confirm we are on Termux ──────────────────────────────────────────────
# `pkg` is the Termux package manager; its presence is our Termux signal.
if ! command -v pkg >/dev/null 2>&1; then
  die "this step expects Termux (the 'pkg' command is missing). Run it on the phone, inside Termux over SSH."
fi
ok "Termux detected ($(command -v pkg))"

# ── 2. Install the extra base Termux packages ────────────────────────────────
# These are needed beyond what Termux ships by default. proot-distro hosts the
# Debian userland; the rest are used by later steps and the supervisor/backups.
# termux-api is optional (wake-lock etc.) and never fatal if it won't install.
say "updating Termux package index (pkg update)"
pkg update -y >/dev/null 2>&1 || warn "pkg update reported a problem (continuing)"

PKGS=(proot-distro rsync jq openssl-tool python curl wget tar zstd termux-api)
say "ensuring Termux packages: ${PKGS[*]}"
for p in "${PKGS[@]}"; do
  # `pkg list-installed` is slow/locking-prone; probe with dpkg query instead.
  if dpkg -s "$p" >/dev/null 2>&1; then
    ok "already installed: $p"
    continue
  fi
  if pkg install -y "$p" >/dev/null 2>&1; then
    ok "installed: $p"
  else
    warn "could not install '$p' (continuing; install it by hand if a later step needs it)"
  fi
done

# Re-verify the commands that later steps hard-depend on.
say "verifying required commands"
require_cmd proot-distro
require_cmd rsync
require_cmd jq
require_cmd curl
require_cmd python3
ok "required commands present"

# ── 3. Confirm the data volume is mounted + writable ─────────────────────────
# DATA_DIR lives on the SD card / large volume (e.g. /storage/XXXX-XXXX/...).
say "checking data volume: ${DATA_DIR}"
mkdir -p "${DATA_DIR}" 2>/dev/null || die "cannot create ${DATA_DIR} — is the SD card mounted?"
[ -d "${DATA_DIR}" ] || die "${DATA_DIR} is not a directory"
_probe="${DATA_DIR}/.pocket_writable_test.$$"
if ! ( : > "${_probe}" ) 2>/dev/null; then
  die "${DATA_DIR} is not writable — check the mount and Termux storage permission (termux-setup-storage)"
fi
rm -f "${_probe}"
ok "data volume mounted + writable: ${DATA_DIR}"

# ── 4. Create the canonical data layout ──────────────────────────────────────
# state/    idempotency markers + pidfiles (POCKET_STATE_DIR)
# logs/     rotating service logs       (POCKET_LOG_DIR)
# backups/  compressed snapshots
# media/    large/served media blobs
# binaries/ pinned binary cache (cloudflared, etc.)
say "creating data layout under ${DATA_DIR}"
for d in state logs backups media binaries; do
  mkdir -p "${DATA_DIR}/${d}"
done
ok "data layout ready: state/ logs/ backups/ media/ binaries/"

# Acquire a wake-lock so Android doesn't doze the long-running stack (best effort).
if command -v termux-wake-lock >/dev/null 2>&1; then
  termux-wake-lock 2>/dev/null && ok "wake-lock acquired" || warn "wake-lock unavailable (non-fatal)"
fi

ok "prereqs satisfied"
