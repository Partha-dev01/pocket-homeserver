#!/usr/bin/env bash
#
# ops/rotate-backups.sh — prune old snapshots to the configured retention.
#
# Keeps the newest ${BACKUP_KEEP_DB} DB snapshots and ${BACKUP_KEEP_ROOTFS} rootfs
# snapshots (defaults 3 / 4 from common.sh). Removes each pruned archive together
# with its integrity + encryption sidecars (.sha256 / .age / .age.sha256) so
# opt-in encryption never lingers past the retention window.
#
# Called automatically at the end of backup-db.sh / backup-all.sh, and exposed as
# its own admin-panel action. Safe to run any time (a no-op when nothing is due).
#
# Generalized from a working deployment; review before running on a fresh phone.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env

# Keep the newest N archives in DIR; delete the rest together with their sidecars.
# Archive names embed an ISO-8601 UTC timestamp (db-YYYY-MM-DDThh-mmZ.tar.zst), so
# a plain lexical sort IS chronological — no reliance on mtime or on `ls` (whose
# colorized output can corrupt a pipeline). An encrypted archive (.age) and its
# plaintext counterpart count as ONE snapshot.
rotate() {
  local dir="$1" keep="$2" label="$3"
  [ -d "$dir" ] || return 0
  shopt -s nullglob
  local f bases=()
  for f in "$dir"/*.tar.zst "$dir"/*.tar.zst.age; do
    bases+=("${f%.age}")              # collapse foo.tar.zst.age -> foo.tar.zst
  done
  shopt -u nullglob
  [ "${#bases[@]}" -gt 0 ] || return 0
  local sorted total prune_count
  sorted="$(printf '%s\n' "${bases[@]}" | sort -u)"   # unique, oldest-first
  total="$(printf '%s\n' "$sorted" | grep -c .)"
  prune_count=$(( total - keep ))
  [ "$prune_count" -gt 0 ] || return 0
  printf '%s\n' "$sorted" | head -n "$prune_count" | while IFS= read -r f; do
    [ -n "$f" ] || continue
    say "pruning ${label}: $(basename "$f")"
    rm -f "$f" "$f.sha256" "$f.age" "$f.age.sha256"
  done
}

rotate "${BACKUP_DIR}/db"     "${BACKUP_KEEP_DB:-3}"     "db"
rotate "${BACKUP_DIR}/rootfs" "${BACKUP_KEEP_ROOTFS:-4}" "rootfs"

ok "backup rotation complete (keep db=${BACKUP_KEEP_DB:-3}, rootfs=${BACKUP_KEEP_ROOTFS:-4})"
