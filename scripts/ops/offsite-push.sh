#!/usr/bin/env bash
#
# ops/offsite-push.sh — copy ENCRYPTED backups off the phone to an S3-compatible
# bucket (Cloudflare R2 / Backblaze B2 / AWS S3 / Wasabi / MinIO).
#
# SAFETY: it uploads ONLY age-encrypted artifacts (*.tar.zst.age + their .sha256
# sidecars). If backups are not encrypted (BACKUP_AGE_RECIPIENT unset) it REFUSES
# to run — plaintext backups must never leave the device. The S3 secret never
# touches argv or a log: ops/offsite-s3.py reads it from this script's env, which
# is populated from a 0600 secrets file.
#
# Self-gates on ENABLE_OFFSITE_BACKUP so it is safe to call unconditionally (the
# backup daemon does, after each retention pass) and also by hand / from the panel.
#
# Config: ${DATA_DIR}/secrets/offsite.env (chmod 600):
#   S3_ENDPOINT=https://<acct>.r2.cloudflarestorage.com   (HTTPS required)
#   S3_BUCKET=my-pocket-backups
#   S3_REGION=auto                 # 'auto' for R2; a real region for AWS/B2/Wasabi
#   S3_ACCESS_KEY_ID=...
#   S3_SECRET_ACCESS_KEY=...
#   S3_PREFIX=pocket               # optional key prefix (folder) in the bucket
#
# Remote retention mirrors BACKUP_KEEP_DB / BACKUP_KEEP_ROOTFS. See docs/BACKUPS.md.
#
# Generalized from a working deployment; review before running on a fresh phone.

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env

# ── Self-gate ────────────────────────────────────────────────────────────────
if [ "${ENABLE_OFFSITE_BACKUP:-false}" != "true" ]; then
  ok "offsite backup disabled (ENABLE_OFFSITE_BACKUP != true) — skipping"
  exit 0
fi

require_var DATA_DIR "folder on your large volume / SD card"
require_cmd python3
require_cmd curl

S3PY="${POCKET_ROOT}/scripts/ops/offsite-s3.py"
[ -f "${S3PY}" ] || die "offsite uploader missing: ${S3PY}"

# ── Refuse to push UNENCRYPTED backups off-device (fail-closed) ───────────────
if [ -z "${BACKUP_AGE_RECIPIENT:-}" ]; then
  die "offsite push refuses to run without backup encryption — set BACKUP_AGE_RECIPIENT
in .env so backups are age-encrypted BEFORE they leave the phone. See docs/BACKUPS.md."
fi

# ── Load the S3 secrets (0600 file, exported into env, never argv) ────────────
CONF="${DATA_DIR}/secrets/offsite.env"
[ -s "${CONF}" ] || die "missing ${CONF} — create it (0600) with S3_ENDPOINT/S3_BUCKET/S3_REGION/S3_ACCESS_KEY_ID/S3_SECRET_ACCESS_KEY[/S3_PREFIX]. See docs/BACKUPS.md."
# shellcheck disable=SC1090
set -a; . "${CONF}"; set +a
for v in S3_ENDPOINT S3_BUCKET S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY; do
  [ -n "${!v:-}" ] || die "offsite: ${v} is empty in ${CONF}"
done
case "${S3_ENDPOINT}" in https://*) ;; *) die "offsite: S3_ENDPOINT must be HTTPS (${S3_ENDPOINT})" ;; esac
export S3_ENDPOINT S3_BUCKET S3_REGION="${S3_REGION:-auto}" S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY

# Optional key prefix (folder) inside the bucket.
RPREFIX=""
[ -n "${S3_PREFIX:-}" ] && RPREFIX="${S3_PREFIX%/}/"

# ── Single-instance lock (mirrors the backup scripts) ────────────────────────
LOCK="${POCKET_STATE_DIR}/.offsite.lock"
mkdir -p "${POCKET_STATE_DIR}" 2>/dev/null || true
if ! ( set -C; : > "${LOCK}" ) 2>/dev/null; then
  warn "another offsite push holds ${LOCK} — skipping this run"
  exit 0
fi
trap 'rm -f "${LOCK}"' EXIT

uploaded=0 skipped=0 failed=0

upload_dir() {  # upload_dir <subdir>
  local subdir="$1" localdir="${BACKUP_DIR}/$1" f base key
  [ -d "${localdir}" ] || return 0
  shopt -s nullglob
  for f in "${localdir}"/*.tar.zst.age; do
    base="$(basename "${f}")"
    key="${RPREFIX}${subdir}/${base}"
    if python3 "${S3PY}" head "${key}" >/dev/null 2>&1; then
      skipped=$((skipped + 1)); continue
    fi
    say "uploading ${subdir}/${base}"
    if python3 "${S3PY}" put "${f}" "${key}"; then
      uploaded=$((uploaded + 1))
      # sidecar checksum (best-effort)
      [ -f "${f}.sha256" ] && python3 "${S3PY}" put "${f}.sha256" "${key}.sha256" >/dev/null 2>&1 || true
    else
      failed=$((failed + 1)); warn "offsite upload FAILED: ${subdir}/${base}"
    fi
  done
  shopt -u nullglob
}

prune_remote() {  # prune_remote <subdir> <keep>
  local subdir="$1" keep="$2" k n drop i
  local keys=()
  while IFS= read -r k; do [ -n "${k}" ] && keys+=("${k}"); done \
    < <(python3 "${S3PY}" list "${RPREFIX}${subdir}/" 2>/dev/null | grep -E '\.tar\.zst\.age$' | sort)
  n=${#keys[@]}
  [ "${n}" -gt "${keep}" ] || return 0
  drop=$(( n - keep ))
  say "remote retention (${subdir}): keep ${keep}, deleting ${drop} older"
  for (( i = 0; i < drop; i++ )); do
    python3 "${S3PY}" delete "${keys[$i]}"          >/dev/null 2>&1 || true
    python3 "${S3PY}" delete "${keys[$i]}.sha256"   >/dev/null 2>&1 || true
  done
}

say "offsite push → ${S3_BUCKET} (${S3_ENDPOINT})"
upload_dir db
upload_dir rootfs
prune_remote db     "${BACKUP_KEEP_DB:-3}"
prune_remote rootfs "${BACKUP_KEEP_ROOTFS:-4}"

ok "offsite push done — uploaded ${uploaded}, already-present ${skipped}, failed ${failed}"
[ "${failed}" -eq 0 ] || exit 1
