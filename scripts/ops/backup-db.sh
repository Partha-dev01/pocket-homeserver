#!/usr/bin/env bash
#
# ops/backup-db.sh — snapshot the Matrix homeserver database (conduwuit RocksDB).
#
# The DB lives INSIDE the Debian userland at /var/lib/conduwuit/db (media is on
# the large volume and is NOT included here — back media up with the volume). For
# a consistent RocksDB snapshot we briefly STOP the homeserver (~tens of seconds
# of chat downtime), tar+zstd the db/ directory, then bring it back.
#
# Output:  ${BACKUP_DIR}/db/db-<UTC>.tar.zst  (+ a .sha256 sidecar).
# Optional at-rest encryption: if BACKUP_AGE_RECIPIENT is set AND `age` is on PATH,
# the archive is additionally encrypted to <archive>.age and the plaintext removed.
#
# Idempotent + lock-guarded (one backup at a time). Safe to run from the admin
# panel or by hand. Retention is applied at the end via ops/rotate-backups.sh.
#
# Generalized from a working deployment; review before running on a fresh phone.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env
require_var DATA_DIR "folder on your large volume / SD card"
require_cmd proot-distro

DEST_DIR="${BACKUP_DIR}/db"
LOCK="${POCKET_STATE_DIR}/.backup.lock"
INFLIGHT="db-inflight.tar.zst"          # fixed name inside the bind mount (no quoting)
mkdir -p "${DEST_DIR}" "${POCKET_STATE_DIR}"

# ── Single-backup lock (noclobber) ───────────────────────────────────────────
if ! (set -o noclobber; : > "${LOCK}") 2>/dev/null; then
  die "another backup appears to be in progress (lock: ${LOCK}) — aborting"
fi
trap 'rm -f "${LOCK}" "${DEST_DIR}/${INFLIGHT}"' EXIT

TS="$(date -u +%FT%H-%MZ)"
DEST="${DEST_DIR}/db-${TS}.tar.zst"

# ── Stop the homeserver for a consistent snapshot ─────────────────────────────
say "stopping the homeserver for a consistent DB snapshot"
unsupervise matrix || true
# Give RocksDB a moment to flush + release the lock after the supervisor stop.
sleep 2

# ── tar + zstd the db/ directory from INSIDE the userland ─────────────────────
# The backup dir is bind-mounted in; tar writes to a fixed inflight name (so no
# timestamp crosses the proot-distro command line), then we rename on the host.
say "archiving /var/lib/conduwuit/db (tar + zstd)"
if ! proot-distro login debian \
      --bind "${DEST_DIR}:/pocket-backup" \
      -- bash -lc 'set -e; cd /var/lib/conduwuit && tar --zstd -cf "/pocket-backup/'"${INFLIGHT}"'" db' \
      2>&1 | grep -v 'proot warning' ; then
  : # grep -v returns 1 when there was no non-warning output — not an error here
fi

# ── Bring the homeserver back up (start-stack re-supervises only what's down) ─
say "restarting the homeserver"
bash "${POCKET_ROOT}/scripts/start-stack.sh" >/dev/null 2>&1 || warn "homeserver restart reported a problem — check ${POCKET_LOG_DIR}/matrix.log"

# Fail closed: the archive must exist and be non-empty.
[ -s "${DEST_DIR}/${INFLIGHT}" ] || die "DB archive was not produced (is the userland reachable? see ${POCKET_LOG_DIR})"
mv -f "${DEST_DIR}/${INFLIGHT}" "${DEST}"

# ── Integrity sidecar ─────────────────────────────────────────────────────────
sha256sum "${DEST}" | awk '{print $1}' > "${DEST}.sha256"
SIZE="$(wc -c < "${DEST}")"
HASH="$(cat "${DEST}.sha256")"
ok "DB backup: ${DEST} (${SIZE} bytes, sha256:${HASH:0:12}…)"

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
ok "ops/backup-db done"
