#!/usr/bin/env bash
#
# ops/backup-daemon.sh — scheduled backup loop (the long-running body, NOT a
# supervisor). It is launched + kept alive by the lib's supervisor, e.g.
#
#     supervise backup-daemon -- bash scripts/ops/backup-daemon.sh
#
# so it never forks its own respawn loop — `supervise` writes the pidfile and
# restarts the body on crash. start-stack.sh starts it (gated on
# ENABLE_BACKUP_DAEMON) and re-supervises it on every bring-up.
#
# Cadence (all UTC) — pocket-homeserver has exactly two backup artifacts, the
# Matrix DB (small, the primary user data) and the full Debian rootfs (large):
#   • Matrix DB → ops/backup-db.sh on BACKUP_DB_CADENCE (daily|weekly|monthly,
#                 default DAILY). DAILY bounds data loss to <=1 day and the tar is
#                 small; the homeserver pauses only for the snapshot (tens of s).
#                 A phone gets reboot/LMK-killed often, so sparse DB backups risk
#                 large loss if the DB is corrupted by an unclean kill — keep it
#                 tight (see docs/RESILIENCE.md, 2026 corruption post-mortem).
#   • Rootfs    → ops/backup-all.sh MONTHLY (the 1st) — heavy, infrequent.
#   • otherwise → wake, run nothing, log, sleep again.
# ops/rotate-backups.sh runs at the end of every wake (a safe no-op when nothing
# is due). backup-db / backup-all already call rotate, so the trailing call is
# belt-and-braces.
#
# The daemon wakes once a day at hour ${BACKUP_DAEMON_HOUR:-4} UTC. It drops itself
# (and every backup child it forks) to idle CPU + best-effort idle IO priority, so
# a heavy monthly rootfs tar can never starve interactive services on a low-RAM
# phone — children inherit both. nice always applies (we only lower our own
# priority); ionice idle-class is best-effort (kernel-scheduler dependent).
#
# Optional heartbeat: if ${BACKUP_DAEMON_HC_URL} is non-empty, the daemon curls it
# after a successful DB backup, or "<url>/fail" when the DB backup failed, so an
# external monitor can distinguish "phone alive but backup failed" from "phone
# unreachable". Empty/unset = no ping (the default).
#
# Generalized from a working deployment; review before running on a fresh phone.

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env
require_var DATA_DIR "folder on your large volume / SD card"
require_cmd date

OPS="${POCKET_ROOT}/scripts/ops"
HOUR="${BACKUP_DAEMON_HOUR:-4}"
HC_URL="${BACKUP_DAEMON_HC_URL:-}"
DB_CADENCE="${BACKUP_DB_CADENCE:-daily}"   # daily | weekly | monthly (DB snapshot)
case "${DB_CADENCE}" in daily|weekly|monthly) ;; *)
  warn "unknown BACKUP_DB_CADENCE='${DB_CADENCE}' — falling back to 'daily'"; DB_CADENCE=daily ;;
esac

# Idle-class self (and every backup child we fork). Guarded — only lowers our own
# priority, so it is allowed unprivileged; absent tools are skipped silently.
command -v renice >/dev/null 2>&1 && renice 19 "$$" >/dev/null 2>&1 \
  && say "renice 19 self (idle CPU priority)" || true
command -v ionice >/dev/null 2>&1 && ionice -c3 -p "$$" >/dev/null 2>&1 \
  && say "ionice idle-class self (best-effort idle IO priority)" || true

say "backup-daemon starting (pid=$$) — wake ${HOUR}:00 UTC · DB cadence=${DB_CADENCE} · rootfs monthly"
if [ -n "${HC_URL}" ]; then
  say "heartbeat enabled (url length ${#HC_URL})"
else
  say "heartbeat NOT configured (set BACKUP_DAEMON_HC_URL in .env to enable)"
fi

# Compute the epoch of the next ${HOUR}:00 UTC strictly after $now.
next_wake() {
  local now today_h
  now="$(date -u +%s)"
  # Today's ${HOUR}:00 UTC; fall back to arithmetic if -d is unavailable.
  today_h="$(date -u -d "$(date -u +%F) ${HOUR}:00:00" +%s 2>/dev/null)" \
    || today_h=$(( (now / 86400) * 86400 + 10#${HOUR} * 3600 ))
  if [ "${now}" -lt "${today_h}" ]; then
    printf '%s\n' "${today_h}"
  else
    printf '%s\n' "$(( today_h + 86400 ))"
  fi
}

while true; do
  now="$(date -u +%s)"
  next="$(next_wake)"
  sleep_s=$(( next - now ))
  [ "${sleep_s}" -gt 0 ] || sleep_s=60   # guard against a clock skew / DST edge
  say "sleeping ${sleep_s}s until $(date -u -d "@${next}" +%FT%TZ 2>/dev/null || echo "next ${HOUR}:00 UTC")"
  sleep "${sleep_s}"

  DOM="$(date -u +%d)"   # day-of-month 01..31 — monthly gate (the 1st)
  DOW="$(date -u +%u)"   # day-of-week  1..7    — weekly gate (7 = Sunday)
  db_ok=1                # 1 = no DB backup attempted-and-failed this wake

  # ── Is a DB snapshot due today, per BACKUP_DB_CADENCE? ──────────────────────
  do_db=0
  case "${DB_CADENCE}" in
    daily)   do_db=1 ;;
    weekly)  [ "${DOW}" = "7" ]  && do_db=1 ;;
    monthly) [ "${DOM}" = "01" ] && do_db=1 ;;
  esac

  if [ "${do_db}" = "1" ]; then
    say "== Matrix DB backup (cadence=${DB_CADENCE}) =="
    if bash "${OPS}/backup-db.sh"; then
      db_ok=1
    else
      db_ok=0
      warn "ops/backup-db.sh failed"
    fi
  fi

  # ── MONTHLY (1st of month, UTC): the heavy full rootfs ──────────────────────
  if [ "${DOM}" = "01" ]; then
    say "== monthly (1st): full rootfs backup (heavy) =="
    bash "${OPS}/backup-all.sh" || warn "ops/backup-all.sh failed"
  fi

  if [ "${do_db}" != "1" ] && [ "${DOM}" != "01" ]; then
    say "nothing scheduled today (DOM=${DOM}, DOW=${DOW}, DB cadence=${DB_CADENCE}) — sleeping again"
  fi

  # ── Retention (safe no-op when nothing is due; belt-and-braces) ─────────────
  bash "${OPS}/rotate-backups.sh" >/dev/null 2>&1 || warn "ops/rotate-backups.sh reported a problem"

  # ── Optional heartbeat ──────────────────────────────────────────────────────
  if [ -n "${HC_URL}" ]; then
    if [ "${db_ok}" = "1" ]; then
      curl -fs -m 10 "${HC_URL}" >/dev/null 2>&1 && say "heartbeat OK" || warn "heartbeat ping failed (network?)"
    else
      curl -fs -m 10 "${HC_URL}/fail" >/dev/null 2>&1 || true
      say "heartbeat /fail sent (DB backup failed)"
    fi
  fi
done
