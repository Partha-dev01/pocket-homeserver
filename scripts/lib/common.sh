# common.sh — shared library for pocket-homeserver scripts.
#
# Source it near the top of every script:
#     . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
#
# It loads `.env`, applies sane defaults, and provides logging, validation,
# idempotency markers, and a small process supervisor. Pure bash — no Termux or
# Android dependency at source time, so it can be exercised on any machine.

# This file is SOURCED, not executed, so it has no shebang; tell ShellCheck the
# dialect explicitly instead.
# shellcheck shell=bash

# Guard against double-sourcing.
[ -n "${_POCKET_COMMON_LOADED:-}" ] && return 0
_POCKET_COMMON_LOADED=1

set -o pipefail

# Repo root (this file lives in scripts/lib/, two levels below the root).
POCKET_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export POCKET_ROOT

# ── Logging (color only when stderr is a terminal) ──────────────────────────
if [ -t 2 ]; then
  _c_red=$'\033[31m'; _c_grn=$'\033[32m'; _c_ylw=$'\033[33m'; _c_blu=$'\033[34m'; _c_rst=$'\033[0m'
else
  _c_red=; _c_grn=; _c_ylw=; _c_blu=; _c_rst=
fi
say()  { printf '%s[*]%s %s\n' "$_c_blu" "$_c_rst" "$*" >&2; }
ok()   { printf '%s[+]%s %s\n' "$_c_grn" "$_c_rst" "$*" >&2; }
warn() { printf '%s[!]%s %s\n' "$_c_ylw" "$_c_rst" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$_c_red" "$_c_rst" "$*" >&2; exit 1; }

# ── Config (.env) ───────────────────────────────────────────────────────────
load_env() {
  local envf="${POCKET_ENV:-$POCKET_ROOT/.env}"
  [ -f "$envf" ] || die "no .env at $envf — run: cp .env.example .env  (see docs/SETUP.md)"
  set -a
  # shellcheck disable=SC1090
  . "$envf"
  # Central version/checksum manifest (config/versions.env): sourced AFTER .env so
  # an explicit .env pin still wins, and BEFORE any install step runs so every
  # step/app reads its pin from one place. Absent is fine — each step keeps an
  # inline ${VAR:-default} fallback. See docs/UPDATING.md + scripts/ops/update.sh.
  if [ -f "$POCKET_ROOT/config/versions.env" ]; then
    # shellcheck disable=SC1091
    . "$POCKET_ROOT/config/versions.env"
  fi
  set +a
  _apply_env_defaults
}

_apply_env_defaults() {
  : "${TZ:=Etc/UTC}"
  : "${CADDY_BIND:=127.0.0.1}"
  : "${CADDY_PORT:=8443}"
  : "${MATRIX_SERVER_NAME:=${DOMAIN:-}}"
  : "${ROOTFS_DIR:=$HOME/debian}"
  : "${BACKUP_DIR:=${DATA_DIR:-}/backups}"
  : "${BACKUP_KEEP_DB:=3}"
  : "${BACKUP_KEEP_ROOTFS:=4}"
  POCKET_STATE_DIR="${POCKET_STATE_DIR:-${DATA_DIR:-$POCKET_ROOT/.run}/state}"
  POCKET_LOG_DIR="${POCKET_LOG_DIR:-${DATA_DIR:-$POCKET_ROOT/.run}/logs}"
  export POCKET_STATE_DIR POCKET_LOG_DIR
}

# ── Validation ──────────────────────────────────────────────────────────────
# require_var NAME ["hint"] — fail if empty or still a placeholder value.
require_var() {
  local name="$1" hint="${2:-}" val="${!1:-}"
  [ -n "$val" ] || die "required config '$name' is empty in .env${hint:+ — $hint}"
  case "$val" in
    example.com|*XXXX-XXXX*|changeme|CHANGEME|"")
      die "config '$name' still holds a placeholder ('$val') — set a real value in .env" ;;
  esac
}
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

# ── Supply-chain: verified downloads ─────────────────────────────────────────
# Every binary we fetch is pinned to an exact sha256 and verified fail-closed, so
# a corrupt or tampered download is deleted and the install aborts rather than
# silently running an unknown binary.
#
# verify_sha256 FILE WANT — compare FILE's sha256 to WANT; on mismatch delete
# FILE and die.
verify_sha256() {
  local f="$1" want="$2" got
  [ -f "$f" ] || die "sha256 verify: file not found: $f"
  got="$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1)"
  if [ "$got" != "$want" ]; then
    rm -f "$f"
    die "sha256 MISMATCH for $(basename "$f") — expected $want, got ${got:-<none>}; refusing to use it"
  fi
  ok "sha256 verified: $(basename "$f") ($want)"
}

# fetch_verified URL DEST WANT — download URL to DEST (atomic via .tmp), verifying
# the sha256 fail-closed. If DEST already matches WANT it is reused (cache hit),
# so this is safe to re-run. Requires curl.
fetch_verified() {
  local url="$1" dest="$2" want="$3"
  if [ -f "$dest" ] && [ "$(sha256sum "$dest" 2>/dev/null | cut -d' ' -f1)" = "$want" ]; then
    ok "cached + sha256-verified: $(basename "$dest")"; return 0
  fi
  mkdir -p "$(dirname "$dest")"
  say "downloading $(basename "$dest")"
  curl -fsSL --retry 3 -o "$dest.tmp" "$url" || die "download failed: $url"
  verify_sha256 "$dest.tmp" "$want"
  mv -f "$dest.tmp" "$dest"
}

# ── Idempotency markers ─────────────────────────────────────────────────────
_state_file() { printf '%s/%s.done' "$POCKET_STATE_DIR" "$1"; }
mark_done() { mkdir -p "$POCKET_STATE_DIR"; : > "$(_state_file "$1")"; }
is_done()   { [ -f "$(_state_file "$1")" ]; }
# run_once NAME -- cmd ...   (skip if already marked done)
run_once() {
  local name="$1"; shift; [ "${1:-}" = "--" ] && shift
  if is_done "$name"; then ok "skip (already done): $name"; return 0; fi
  say "step: $name"
  "$@" && mark_done "$name"
}

# ── Process supervision ─────────────────────────────────────────────────────
# supervise NAME -- cmd ...
# Detached respawn loop with a pidfile. On restart it identity-checks the live
# PID's cmdline, so a reused PID (common after an Android reboot) is never
# mistaken for our service.
#
# Crash-loop safety: a child that stays up >= POCKET_HEALTHY_SECS (default 60s)
# is "healthy" — the respawn backoff resets and any DEGRADED marker clears. A
# child that keeps exiting fast is backed off exponentially (POCKET_RESPAWN_MIN
# .. POCKET_RESPAWN_MAX, default 5s..300s) and, after POCKET_CRASHLOOP_FAILS
# (default 5) rapid failures, the supervisor writes a machine-readable
# "$name.degraded" marker (surfaced by the admin panel + status page) and fires
# the OPTIONAL one-shot POCKET_ALERT_CMD. This stops a corrupt-DB crash loop
# from silently hammering storage for hours unnoticed — the failure mode behind
# the RocksDB-corruption post-mortem (see docs/RESILIENCE.md).
supervise() {
  local name="$1"; shift; [ "${1:-}" = "--" ] && shift
  local pidfile="$POCKET_STATE_DIR/$name.pid"
  local log="$POCKET_LOG_DIR/$name.log"
  mkdir -p "$POCKET_STATE_DIR" "$POCKET_LOG_DIR"
  if _supervisor_alive "$pidfile" "$name"; then ok "already running: $name"; return 0; fi
  rm -f "$pidfile"
  # A fresh (re)start clears any stale DEGRADED marker — give the service a clean
  # slate; the loop below re-raises it if it crash-loops again.
  rm -f "$POCKET_STATE_DIR/$name.degraded" 2>/dev/null
  # Record the launch argv (one element per line) so a targeted restart can
  # re-supervise this exact command without each caller having to re-specify it
  # (used by scripts/ops/restart.sh). Best-effort; never fatal.
  printf '%s\n' "$@" > "$POCKET_STATE_DIR/$name.cmd" 2>/dev/null || true
  # Prefer setsid so the supervisor leads its own process group; stopping it can
  # then take down the child too. Fall back to nohup where setsid is absent.
  local launcher=nohup
  command -v setsid >/dev/null 2>&1 && launcher=setsid
  # Inner respawn loop: exponential backoff + crash-loop circuit breaker.
  # Args: _sv NAME PIDFILE STATEDIR ALERTCMD -- service argv...
  "$launcher" bash -c '
    name="$1"; pidfile="$2"; sdir="$3"; alert="$4"; shift 4
    echo $$ > "$pidfile"
    degraded="$sdir/$name.degraded"
    healthy="${POCKET_HEALTHY_SECS:-60}"
    dmin="${POCKET_RESPAWN_MIN:-5}"; dmax="${POCKET_RESPAWN_MAX:-300}"
    loopn="${POCKET_CRASHLOOP_FAILS:-5}"
    delay="$dmin"; fails=0; degr=0
    while true; do
      t0=$(date -u +%s)
      "$@"; rc=$?
      ran=$(( $(date -u +%s) - t0 ))
      if [ "$ran" -ge "$healthy" ]; then
        # Healthy run — reset backoff + clear any crash-loop state.
        delay="$dmin"; fails=0
        if [ "$degr" = 1 ]; then
          rm -f "$degraded" 2>/dev/null
          echo "[$(date -u +%FT%TZ)] supervise:$name RECOVERED (was crash-looping)" >&2
          degr=0
        fi
      else
        fails=$(( fails + 1 ))
        echo "[$(date -u +%FT%TZ)] supervise:$name exited rc=$rc after ${ran}s (rapid fail #$fails) — retry in ${delay}s" >&2
        if [ "$fails" -ge "$loopn" ] && [ "$degr" = 0 ]; then
          # Crash loop confirmed: raise a loud, machine-readable DEGRADED marker
          # and fire the optional one-shot alert (cmd from .env; context off-argv).
          mkdir -p "$sdir" 2>/dev/null
          printf "service=%s\trc=%s\tfails=%s\tsince=%s\n" "$name" "$rc" "$fails" "$(date -u +%FT%TZ)" > "$degraded" 2>/dev/null
          echo "[$(date -u +%FT%TZ)] supervise:$name DEGRADED — crash-looping ($fails rapid failures, last rc=$rc); see this log + docs/RESILIENCE.md" >&2
          if [ -n "$alert" ]; then
            POCKET_ALERT_SERVICE="$name" POCKET_ALERT_RC="$rc" POCKET_ALERT_FAILS="$fails" \
              sh -c "$alert" >/dev/null 2>&1 &
          fi
          degr=1
        fi
      fi
      sleep "$delay"
      # Grow backoff only while unhealthy (reset happens on a healthy run above).
      [ "$fails" -gt 0 ] && { delay=$(( delay * 2 )); [ "$delay" -gt "$dmax" ] && delay="$dmax"; }
    done
  ' _sv "$name" "$pidfile" "$POCKET_STATE_DIR" "${POCKET_ALERT_CMD:-}" "$@" >>"$log" 2>&1 </dev/null &
  disown 2>/dev/null || true
  ok "started: $name (log: $log)"
}
_supervisor_alive() {
  local pidfile="$1" name="$2" pid
  [ -f "$pidfile" ] || return 1
  pid="$(cat "$pidfile" 2>/dev/null || true)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 1
  if [ -r "/proc/$pid/cmdline" ]; then
    tr '\0' ' ' < "/proc/$pid/cmdline" | grep -q -- "$name" || return 1
  fi
  return 0
}
# stop a supervised service by pidfile (kills the verified supervisor only).
unsupervise() {
  local name="$1" pidfile="$POCKET_STATE_DIR/$1.pid" pid
  if _supervisor_alive "$pidfile" "$name"; then
    pid="$(cat "$pidfile")"
    # Prefer killing the whole process group (supervisor + child); fall back to
    # the supervisor pid plus its direct children.
    if ! kill -TERM "-$pid" 2>/dev/null; then
      pkill -TERM -P "$pid" 2>/dev/null || true
      kill -TERM "$pid" 2>/dev/null || true
    fi
    ok "stopped: $name"
  else
    ok "not running: $name"
  fi
  rm -f "$pidfile"
}

# ── Crash-loop / DEGRADED state (raised by supervise's circuit breaker) ──────
# is_degraded NAME    — rc 0 if the service is currently flagged crash-looping.
# degraded_info NAME  — print the marker (service/rc/fails/since) if present.
is_degraded()   { [ -f "$POCKET_STATE_DIR/$1.degraded" ]; }
degraded_info() { cat "$POCKET_STATE_DIR/$1.degraded" 2>/dev/null; }

# ── Storage tier: ext4-vs-exFAT enforcement + one-time migration ─────────────
# Any embedded SQLite DB / WAL / lock / index MUST live on ext4 (the userland),
# NEVER on the exFAT SD card (DATA_DIR): exFAT cannot do POSIX locks, atomic
# rename-over-existing, or durable fsync, so a DB placed there WILL corrupt (a
# verified failure class). The bulk read-mostly content MAY stay on the SD.

# assert_ext4 <path> <human-label>  — die fail-closed if <path> resolves under
# DATA_DIR. Resolves the FULL real path (readlink -f follows a symlinked leaf, so
# a symlink into the SD cannot smuggle the dir onto exFAT); falls back to parent
# pwd -P resolution when readlink is unavailable / the leaf does not exist yet.
assert_ext4() {
  local p="$1" label="${2:-data}" rp rd
  mkdir -p "$(dirname "$p")" 2>/dev/null || true
  rp="$(readlink -f "$p" 2>/dev/null)"
  [ -n "$rp" ] || rp="$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)/$(basename "$p")" || rp="$p"
  if [ -n "${DATA_DIR:-}" ] && [ -d "${DATA_DIR}" ]; then
    rd="$(readlink -f "${DATA_DIR}" 2>/dev/null)"
    [ -n "$rd" ] || rd="$(cd "${DATA_DIR}" 2>/dev/null && pwd -P)" || rd="$DATA_DIR"
    case "${rp}/" in
      "${rd}/"*)
        die "refusing to place ${label} under DATA_DIR (${rd}, the exFAT SD): embedded SQLite/WAL/locks corrupt there. Keep it on ext4 (e.g. \$HOME/.pocket/...)." ;;
    esac
  fi
}

# migrate_backing_to_ext4 <old-dir-on-DATA_DIR> <new-ext4-dir> <human-label>
# ONE-TIME, NON-DESTRUCTIVE relocation for installs that predate the ext4 move:
# if <old> exists + is non-empty AND <new> is absent/empty, back up <old> (plain
# tar alongside, best-effort) then COPY its contents to <new> (the original is
# left in place — the operator deletes it after verifying). If <new> already holds
# data it is never clobbered (idempotent: a warning, then it uses <new>).
migrate_backing_to_ext4() {
  local old="$1" new="$2" label="${3:-data}"
  [ -n "$old" ] && [ -n "$new" ] || return 0
  [ "$old" = "$new" ] && return 0
  [ -d "$old" ] || return 0
  [ -n "$(ls -A "$old" 2>/dev/null)" ] || return 0
  if [ -d "$new" ] && [ -n "$(ls -A "$new" 2>/dev/null)" ]; then
    warn "${label}: both ${old} (old, exFAT) and ${new} (ext4) hold data — leaving ${old} in place; using ${new}. Remove ${old} by hand once ${new} is confirmed good."
    return 0
  fi
  say "migrating ${label} from ${old} (exFAT) -> ${new} (ext4) — one-time relocation"
  mkdir -p "$new" || die "cannot create ${new} on ext4"
  local bk="${old%/}.pre-ext4-migration.$$.tar"
  if tar -cf "$bk" -C "$(dirname "$old")" "$(basename "$old")" 2>/dev/null; then
    ok "backed up ${old} -> ${bk} (delete once ${new} is confirmed good)"
  else
    warn "could not back up ${old} before migration — proceeding (the copy is non-destructive)"
  fi
  # cp -a may exit non-zero merely failing to preserve exFAT perms, yet still copy
  # the bytes — so judge success by the result, not cp's exit code.
  cp -a "$old"/. "$new"/ 2>/dev/null
  if [ -n "$(ls -A "$new" 2>/dev/null)" ]; then
    ok "migrated ${label} to ${new}. Original left at ${old} (exFAT) — remove it by hand after verifying."
  else
    die "migration produced an empty ${new} — fix permissions/space and re-run (nothing was deleted)"
  fi
}
