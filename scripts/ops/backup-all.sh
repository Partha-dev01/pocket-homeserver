#!/usr/bin/env bash
#
# ops/backup-all.sh — full snapshot of the Debian userland rootfs.
#
# This tars the ENTIRE proot-distro Debian rootfs (all installed binaries +
# configs + the conduwuit DB, which lives inside the rootfs). It is large
# (often ~1 GB) and slow, so the admin panel launches it DETACHED — watch
# progress in ${POCKET_LOG_DIR}/backup-all.log or on the panel's /backups page.
#
# App *data* (Linkding/Pingvin/etc.) lives on the large volume under ${DATA_DIR},
# NOT in the rootfs, so it is captured by backing up the volume itself — it is
# deliberately out of scope here. The homeserver is stopped during the tar for a
# consistent DB; other apps keep running (their on-rootfs SQLite, e.g. Pingvin's,
# is captured best-effort — stop those apps too if you need a fully quiescent
# snapshot). See docs/BACKUPS.md.
#
# Output:  ${BACKUP_DIR}/rootfs/rootfs-<UTC>.tar.zst  (+ a .sha256 sidecar).
# Optional at-rest encryption with BACKUP_AGE_RECIPIENT + `age` (as in backup-db).
#
# Generalized from a working deployment; review before running on a fresh phone.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env
require_var DATA_DIR "folder on your large volume / SD card"

# ── Locate the proot-distro rootfs ────────────────────────────────────────────
# proot-distro manages the install location; on current Termux releases that is
# $PREFIX/var/lib/proot-distro/installed-rootfs/debian. (The ${ROOTFS_DIR} .env
# value is informational and need not match this.)
[ -n "${PREFIX:-}" ] || die "PREFIX is unset — this step expects Termux"
PD_BASE="${PREFIX}/var/lib/proot-distro/installed-rootfs"
ROOTFS="${PD_BASE}/debian"
[ -d "${ROOTFS}" ] || die "Debian rootfs not found at ${ROOTFS} — install the userland first (scripts/install.sh)"

DEST_DIR="${BACKUP_DIR}/rootfs"
LOCK="${POCKET_STATE_DIR}/.backup.lock"
mkdir -p "${DEST_DIR}" "${POCKET_STATE_DIR}"

# ── Single-backup lock (shared with backup-db) ───────────────────────────────
if ! (set -o noclobber; : > "${LOCK}") 2>/dev/null; then
  die "another backup appears to be in progress (lock: ${LOCK}) — aborting"
fi
trap 'rm -f "${LOCK}"' EXIT

TS="$(date -u +%FT%H-%MZ)"
DEST="${DEST_DIR}/rootfs-${TS}.tar.zst"

# ── Stop the homeserver for a consistent DB inside the rootfs ─────────────────
say "stopping the homeserver for a consistent rootfs snapshot"
unsupervise matrix || true
sleep 2

# ── tar + zstd the whole rootfs (from the Termux side) ────────────────────────
# Tar from the parent dir so the archive contains a single top-level 'debian/'.
say "archiving the Debian rootfs (${ROOTFS}) — this can take several minutes"
if tar --zstd -cf "${DEST}.tmp" -C "${PD_BASE}" debian; then
  mv -f "${DEST}.tmp" "${DEST}"
else
  rm -f "${DEST}.tmp"
  # Always try to bring the homeserver back even on failure.
  bash "${POCKET_ROOT}/scripts/start-stack.sh" >/dev/null 2>&1 || true
  die "rootfs tar failed"
fi

# ── Bring the homeserver back up ──────────────────────────────────────────────
say "restarting the homeserver"
bash "${POCKET_ROOT}/scripts/start-stack.sh" >/dev/null 2>&1 || warn "homeserver restart reported a problem — check ${POCKET_LOG_DIR}/matrix.log"

# ── Integrity sidecar ─────────────────────────────────────────────────────────
[ -s "${DEST}" ] || die "rootfs archive was not produced at ${DEST}"
sha256sum "${DEST}" | awk '{print $1}' > "${DEST}.sha256"
SIZE="$(wc -c < "${DEST}")"
HASH="$(cat "${DEST}.sha256")"
ok "rootfs backup: ${DEST} (${SIZE} bytes, sha256:${HASH:0:12}…)"

# ── Optional at-rest encryption (age) ─────────────────────────────────────────
if [ -n "${BACKUP_AGE_RECIPIENT:-}" ]; then
  if command -v age >/dev/null 2>&1; then
    say "encrypting the archive to ${DEST}.age (age recipient set)"
    if age -r "${BACKUP_AGE_RECIPIENT}" -o "${DEST}.age" "${DEST}"; then
      sha256sum "${DEST}.age" | awk '{print $1}' > "${DEST}.age.sha256"
      rm -f "${DEST}" "${DEST}.sha256"
      ok "encrypted backup: ${DEST}.age (plaintext removed)"
    else
      warn "age encryption failed — keeping the plaintext archive"
    fi
  else
    warn "BACKUP_AGE_RECIPIENT is set but 'age' is not installed — leaving the archive unencrypted"
  fi
fi

# ── Retention ─────────────────────────────────────────────────────────────────
bash "${POCKET_ROOT}/scripts/ops/rotate-backups.sh" >/dev/null 2>&1 || true
ok "ops/backup-all done"
