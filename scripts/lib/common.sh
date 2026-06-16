# common.sh — shared library for pocket-homeserver scripts.
#
# Source it near the top of every script:
#     . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
#
# It loads `.env`, applies sane defaults, and provides logging, validation,
# idempotency markers, and a small process supervisor. Pure bash — no Termux or
# Android dependency at source time, so it can be exercised on any machine.

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
supervise() {
  local name="$1"; shift; [ "${1:-}" = "--" ] && shift
  local pidfile="$POCKET_STATE_DIR/$name.pid"
  local log="$POCKET_LOG_DIR/$name.log"
  mkdir -p "$POCKET_STATE_DIR" "$POCKET_LOG_DIR"
  if _supervisor_alive "$pidfile" "$name"; then ok "already running: $name"; return 0; fi
  rm -f "$pidfile"
  # Prefer setsid so the supervisor leads its own process group; stopping it can
  # then take down the child too. Fall back to nohup where setsid is absent.
  local launcher=nohup
  command -v setsid >/dev/null 2>&1 && launcher=setsid
  "$launcher" bash -c '
    name="$1"; pidfile="$2"; shift 2
    echo $$ > "$pidfile"
    while true; do
      "$@"
      echo "[$(date -u +%FT%TZ)] supervise:$name child exited rc=$? — respawn in 5s" >&2
      sleep 5
    done
  ' _sv "$name" "$pidfile" "$@" >>"$log" 2>&1 </dev/null &
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
