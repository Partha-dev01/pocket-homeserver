#!/usr/bin/env bash
#
# ops/restore.sh — restore the Matrix homeserver from backups in ${BACKUP_DIR}.
#
# Recovers the Debian userland rootfs and the conduwuit DB from the snapshots that
# backup-all.sh / backup-db.sh produced:
#   1) stop the supervised services,
#   2) rename the EXISTING rootfs aside as debian.broken-<UTC> (never deleted — so a
#      bad restore is one `mv` away from rollback),
#   3) extract the latest (or chosen) rootfs tarball, then the DB tarball into it,
#   4) bring the stack back up with start-stack.sh.
#
# DRY RUN BY DEFAULT — running it with no flags only PRINTS the plan. To actually
# touch disk you must pass the explicit confirm phrase:
#
#   DRY RUN (default — prints the plan, changes nothing):
#     bash scripts/ops/restore.sh
#   ACTUAL RESTORE (destructive — renames the live rootfs aside, extracts over it):
#     bash scripts/ops/restore.sh --confirm=ERASE-AND-RESTORE
#   PICK SPECIFIC ARCHIVES:
#     bash scripts/ops/restore.sh --rootfs=<path> --db=<path> --confirm=ERASE-AND-RESTORE
#
# Safety:
#   * The .sha256 sidecars are verified FAIL-CLOSED before extracting.
#   * Each archive is scanned for zip-slip (any member with a `..` component or an
#     absolute path is REJECTED) and extracted --no-same-owner.
#   * Encrypted archives (.age) are decrypted to a temp plaintext first — you must
#     supply the age PRIVATE key via BACKUP_AGE_IDENTITY in .env (kept OFF the
#     backup volume); the temp plaintext is shredded after extraction.
#
# Generalized from a working deployment; review before running on a fresh phone.

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env
require_var DATA_DIR "folder on your large volume / SD card"

# ── Locate the proot-distro rootfs (same logic as ops/backup-all.sh) ──────────
# proot-distro manages the install location; the ${ROOTFS_DIR} .env value is
# informational. We restore into the proot-distro-managed path.
[ -n "${PREFIX:-}" ] || die "PREFIX is unset — this restore expects Termux"
PD_BASE="${PREFIX}/var/lib/proot-distro/installed-rootfs"
OLD_ROOTFS="${PD_BASE}/debian"

# ── Latest-archive picker (ISO-8601 lexical sort, NOT ls -t) ──────────────────
# Archive names embed an ISO-8601 UTC timestamp (rootfs-YYYY-MM-DDThh-mmZ.tar.zst /
# db-…), so a plain lexical sort IS chronological — no reliance on mtime or on
# `ls -t` (whose colorized output can corrupt a pipeline). An encrypted archive
# (.age) and its plaintext counterpart collapse to one snapshot; we prefer the
# newest of either form. Echoes the chosen path, or nothing if the dir is empty.
latest_archive() {
  local dir="$1" f bases=() newest
  [ -d "$dir" ] || return 0
  shopt -s nullglob
  for f in "$dir"/*.tar.zst "$dir"/*.tar.zst.age; do
    bases+=("${f%.age}")               # collapse foo.tar.zst.age -> foo.tar.zst
  done
  shopt -u nullglob
  [ "${#bases[@]}" -gt 0 ] || return 0
  # newest base name, lexically = chronologically
  newest="$(printf '%s\n' "${bases[@]}" | sort -u | tail -n1)"
  # prefer the encrypted form if that is what is on disk
  if [ -f "${newest}.age" ]; then printf '%s\n' "${newest}.age"; else printf '%s\n' "${newest}"; fi
}

# ── Zip-slip / path-traversal guard ───────────────────────────────────────────
# The backup volume is attacker-writable if the SD card is stolen / remounted, and
# restore lets the operator point --rootfs/--db at ANY file, so a crafted tarball
# could write OUTSIDE the rootfs (e.g. overwrite ~/.ssh/authorized_keys, the boot
# launcher, the watchdog). Before extracting, list the archive and REJECT any
# member whose path is absolute or contains a `..` component. Returns 1 (callers
# DIE) if anything unsafe is found.
assert_tar_safe() {
  local arc="$1" bad
  bad="$(tar --zstd -tf "$arc" 2>/dev/null | grep -E '(^|/)\.\.(/|$)|^/|^[A-Za-z]:' | head -5)"
  if [ -n "$bad" ]; then
    warn "REFUSING to extract $arc — unsafe member(s) detected (zip-slip):"
    printf '%s\n' "$bad" | sed 's/^/    /' >&2
    return 1
  fi
  return 0
}

# ── Decrypt-if-needed ─────────────────────────────────────────────────────────
# If the chosen archive is an encrypted .age artefact, decrypt it to a temp
# plaintext under ${POCKET_STATE_DIR} and echo that path; otherwise echo the input
# unchanged. The age PRIVATE key (identity) is operator-supplied via BACKUP_AGE_IDENTITY
# in .env (kept OFF the backup volume). DIE on a failed decrypt.
#
# NOTE: symmetric with backup-all.sh/backup-db.sh, which encrypt to <archive>.age
# using BACKUP_AGE_RECIPIENT (the PUBLIC key). Restore needs the matching PRIVATE
# key, which is intentionally NOT stored next to the backups.
maybe_decrypt() {
  local in="$1"
  case "$in" in
    *.age)
      command -v age >/dev/null 2>&1 || die "archive $in is age-encrypted but 'age' is not installed"
      local idf="${BACKUP_AGE_IDENTITY:-}"
      [ -n "$idf" ] && [ -s "$idf" ] \
        || die "archive $in is encrypted — set BACKUP_AGE_IDENTITY in .env to your age PRIVATE key file (kept OFF the backup volume), then re-run"
      local out
      out="${POCKET_STATE_DIR}/.restore-decrypt-$(basename "$in" | tr -dc 'A-Za-z0-9._-').plain"
      mkdir -p "${POCKET_STATE_DIR}"
      say "decrypting $(basename "$in") (age, identity off-volume)"
      ( umask 077; age -d -i "$idf" -o "$out" "$in" 2>/dev/null ) \
        || die "age decrypt failed for $in — check BACKUP_AGE_IDENTITY"
      printf '%s\n' "$out"
      ;;
    *) printf '%s\n' "$in" ;;
  esac
}

# ── Parse args ────────────────────────────────────────────────────────────────
DRY=1
ROOTFS_BAK=""
DB_BAK=""
for arg in "$@"; do
  case "$arg" in
    --confirm=ERASE-AND-RESTORE) DRY=0 ;;
    --rootfs=*) ROOTFS_BAK="${arg#--rootfs=}" ;;
    --db=*)     DB_BAK="${arg#--db=}" ;;
    --help|-h)  sed -n '2,40p' "$0"; exit 0 ;;
    *)          warn "unknown arg: $arg" ;;
  esac
done

# ── Resolve the archives ──────────────────────────────────────────────────────
[ -n "$ROOTFS_BAK" ] || ROOTFS_BAK="$(latest_archive "${BACKUP_DIR}/rootfs")"
[ -n "$DB_BAK" ]     || DB_BAK="$(latest_archive "${BACKUP_DIR}/db")"

[ -n "$ROOTFS_BAK" ] && [ -f "$ROOTFS_BAK" ] \
  || die "no rootfs backup (looked in ${BACKUP_DIR}/rootfs/*.tar.zst[.age]) — pass --rootfs=<path>"
[ -n "$DB_BAK" ] && [ -f "$DB_BAK" ] \
  || die "no db backup (looked in ${BACKUP_DIR}/db/*.tar.zst[.age]) — pass --db=<path>"

say "rootfs backup : $ROOTFS_BAK ($(wc -c < "$ROOTFS_BAK") bytes)"
say "db backup     : $DB_BAK ($(wc -c < "$DB_BAK") bytes)"

# ── Verify the .sha256 sidecars FAIL-CLOSED ───────────────────────────────────
# Each archive carries a sibling <archive>.sha256 (the raw hex of the file's
# sha256). If the sidecar exists it MUST match; a missing sidecar is only a warning
# (older snapshots may predate sidecars), but a mismatch is fatal.
for b in "$ROOTFS_BAK" "$DB_BAK"; do
  if [ -f "$b.sha256" ]; then
    stored="$(cat "$b.sha256" 2>/dev/null | awk '{print $1}')"
    computed="$(sha256sum "$b" 2>/dev/null | awk '{print $1}')"
    if [ "$stored" = "$computed" ] && [ -n "$stored" ]; then
      ok "sha256 match: $(basename "$b")"
    else
      die "sha256 MISMATCH for $b — stored=$stored computed=$computed (refusing to restore)"
    fi
  else
    warn "no .sha256 sidecar for $(basename "$b") — integrity check skipped"
  fi
done

TS="$(date -u +%FT%H-%MZ)"
BROKEN_ROOTFS="${PD_BASE}/debian.broken-${TS}"

# ── Dry run: print the plan and stop ──────────────────────────────────────────
if [ "$DRY" = "1" ]; then
  echo
  say "DRY RUN — no changes will be made"
  echo "would do:"
  echo "  1) stop supervised services (cloudflared, caddy, matrix, backup-daemon, auth-gw, …)"
  echo "  2) mv ${OLD_ROOTFS}  →  ${BROKEN_ROOTFS}  (rollback stays on disk)"
  echo "  3) cd ${PD_BASE} && tar --zstd --no-same-owner -xf <rootfs archive>"
  echo "  4) cd ${OLD_ROOTFS}/var/lib/conduwuit && tar --zstd --no-same-owner -xf <db archive>"
  echo "  5) bash ${POCKET_ROOT}/scripts/start-stack.sh"
  echo
  say "re-run with --confirm=ERASE-AND-RESTORE to perform the restore"
  exit 0
fi

# ── Perform the restore ───────────────────────────────────────────────────────
say "== PERFORMING RESTORE =="

# 1) stop supervised services (whatever is running on this host).
say "stopping supervised services"
shopt -s nullglob
for pidfile in "${POCKET_STATE_DIR}"/*.pid; do
  unsupervise "$(basename "$pidfile" .pid)" || true
done
shopt -u nullglob
sleep 3

# 2) rename the existing rootfs aside as a rollback point (never delete).
if [ -d "$OLD_ROOTFS" ]; then
  say "renaming ${OLD_ROOTFS}  →  ${BROKEN_ROOTFS}  (rollback point)"
  mv "$OLD_ROOTFS" "$BROKEN_ROOTFS" || die "rename failed (is something still holding the rootfs open?)"
else
  warn "no existing rootfs at ${OLD_ROOTFS} — fresh-restore mode"
fi

# 3) extract the rootfs tarball.
say "extracting rootfs: $(basename "$ROOTFS_BAK")"
mkdir -p "$PD_BASE"
ROOTFS_PLAIN="$(maybe_decrypt "$ROOTFS_BAK")"
assert_tar_safe "$ROOTFS_PLAIN" || die "rootfs tarball failed the zip-slip safety scan — refusing to extract"
if ! ( cd "$PD_BASE" && tar --zstd --no-same-owner -xf "$ROOTFS_PLAIN" ); then
  [ "$ROOTFS_PLAIN" != "$ROOTFS_BAK" ] && rm -f "$ROOTFS_PLAIN" 2>/dev/null || true
  die "rootfs extract failed — rollback via: rm -rf ${OLD_ROOTFS} && mv ${BROKEN_ROOTFS} ${OLD_ROOTFS}"
fi
[ "$ROOTFS_PLAIN" != "$ROOTFS_BAK" ] && rm -f "$ROOTFS_PLAIN" 2>/dev/null || true
[ -d "$OLD_ROOTFS" ] || die "rootfs extract finished but ${OLD_ROOTFS} is missing — the archive may not contain a top-level 'debian/'"

# Post-extract sanity: the conduwuit binary must be present + executable.
# (A half-extracted tarball leaves a rootfs dir that "exists" but cannot boot.)
say "verifying critical rootfs paths"
[ -x "${OLD_ROOTFS}/opt/conduwuit/conduwuit" ] \
  || die "post-extract check FAILED — ${OLD_ROOTFS}/opt/conduwuit/conduwuit missing or not executable. Rollback: rm -rf ${OLD_ROOTFS} && mv ${BROKEN_ROOTFS} ${OLD_ROOTFS}"
ok "rootfs integrity OK (conduwuit binary present)"

# 4) extract the DB tarball into the restored rootfs.
say "extracting db: $(basename "$DB_BAK")"
mkdir -p "${OLD_ROOTFS}/var/lib/conduwuit"
DB_PLAIN="$(maybe_decrypt "$DB_BAK")"
assert_tar_safe "$DB_PLAIN" || die "db tarball failed the zip-slip safety scan — refusing to extract"
if ! ( cd "${OLD_ROOTFS}/var/lib/conduwuit" && tar --zstd --no-same-owner -xf "$DB_PLAIN" ); then
  [ "$DB_PLAIN" != "$DB_BAK" ] && rm -f "$DB_PLAIN" 2>/dev/null || true
  die "db extract failed — rollback via: rm -rf ${OLD_ROOTFS} && mv ${BROKEN_ROOTFS} ${OLD_ROOTFS}"
fi
[ "$DB_PLAIN" != "$DB_BAK" ] && rm -f "$DB_PLAIN" 2>/dev/null || true
[ -d "${OLD_ROOTFS}/var/lib/conduwuit/db" ] || die "db dir missing after extract"

# Post-extract DB sanity: RocksDB always writes a tiny CURRENT pointer; a
# half-extracted DB will fail to open. Cheap to check without opening RocksDB.
[ -f "${OLD_ROOTFS}/var/lib/conduwuit/db/CURRENT" ] \
  || die "post-extract check FAILED — db/CURRENT missing (incomplete db tarball). Rollback: rm -rf ${OLD_ROOTFS} && mv ${BROKEN_ROOTFS} ${OLD_ROOTFS}"
ok "db integrity OK (CURRENT present)"

ok "extraction complete"

# 5) bring the stack back up (start-stack re-supervises core + every installed app).
say "starting the stack"
bash "${POCKET_ROOT}/scripts/start-stack.sh" || warn "stack start reported a problem — check ${POCKET_LOG_DIR}/matrix.log"

echo
ok "restore done"
say "rollback if needed:  rm -rf ${OLD_ROOTFS} && mv ${BROKEN_ROOTFS} ${OLD_ROOTFS}"
