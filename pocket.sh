#!/usr/bin/env bash
#
# pocket.sh — the interactive control panel (TUI) for pocket-homeserver.
#
# One friendly, menu-driven front door for the whole lifecycle: configure,
# install / bring everything up, see what's installed and running, restart a
# service, take backups, read logs, and stop the stack. Run it again any time —
# the installer remembers what's already done, so re-runs are quick and safe.
#
#     ./pocket.sh
#
# There's nothing magic here: every menu item just runs a script you could run by
# hand (./setup.sh, scripts/install.sh, scripts/ops/*). This is the easy path;
# the underlying commands are shown so you can learn them. See docs/SETUP.md.

set -uo pipefail   # deliberately NOT -e: a failed action returns to the menu.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/scripts/lib/common.sh"   # say/ok/warn/die, load_env, is_done, $POCKET_ROOT

ENV_FILE="$POCKET_ROOT/.env"
have_env() { [ -f "$ENV_FILE" ]; }

# ── Small UI helpers ──────────────────────────────────────────────────────────
screen() { [ -t 1 ] && printf '\033[H\033[2J' || true; }
hr()     { printf '  ────────────────────────────────────────────────────\n'; }
pause()  { printf '\n'; read -r -p "  Press Enter to return to the menu… " _ || true; }
confirm() {  # confirm "prompt" -> 0 if the user typed y/yes
  local p="${1:-Are you sure?}" a=""
  read -r -p "  $p [y/N]: " a || a=""
  case "$a" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}
# run_action cmd... — run a command in the foreground, then wait for Enter.
run_action() {
  printf '\n'
  "$@"
  local rc=$?
  printf '\n'
  if [ "$rc" -eq 0 ]; then ok "finished (exit 0)"; else warn "command exited with status $rc"; fi
  pause
}

# Load .env if it exists (gives DOMAIN, POCKET_STATE_DIR, POCKET_LOG_DIR, …).
load_cfg() { have_env && load_env || true; }

svc_state() {  # svc_state name -> "RUNNING (pid N)" | "DOWN"
  local name="$1" pidfile="${POCKET_STATE_DIR:-}/$1.pid" pid
  [ -n "${POCKET_STATE_DIR:-}" ] && [ -f "$pidfile" ] || { echo "DOWN"; return; }
  pid="$(cat "$pidfile" 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then echo "RUNNING (pid $pid)"; else echo "DOWN"; fi
}

# ── Banner with a quick status line ───────────────────────────────────────────
banner() {
  printf '\n'
  printf '  %spocket-homeserver%s — control panel\n' "$_c_blu" "$_c_rst"
  hr
  if have_env; then
    local up=0 tot=0 pidfile pid
    if [ -n "${POCKET_STATE_DIR:-}" ] && [ -d "${POCKET_STATE_DIR}" ]; then
      shopt -s nullglob
      for pidfile in "${POCKET_STATE_DIR}"/*.pid; do
        tot=$((tot + 1))
        pid="$(cat "$pidfile" 2>/dev/null || true)"
        [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && up=$((up + 1))
      done
      shopt -u nullglob
    fi
    printf '  domain   : %s\n' "${DOMAIN:-<not set>}"
    printf '  services : %s up / %s supervised\n' "$up" "$tot"
  else
    printf '  %sno .env yet%s — choose "Configure" to set things up.\n' "$_c_ylw" "$_c_rst"
  fi
  hr
}

# ── Sub-menus ─────────────────────────────────────────────────────────────────
restart_menu() {
  load_cfg
  local names=() cmdfile
  shopt -s nullglob
  for cmdfile in "${POCKET_STATE_DIR:-/nonexistent}"/*.cmd; do names+=("$(basename "$cmdfile" .cmd)"); done
  shopt -u nullglob
  if [ "${#names[@]}" -eq 0 ]; then
    warn "no services have been started yet — install the stack first"; pause; return
  fi
  screen; banner
  printf '  Restart a service\n\n'
  local i=1 n
  for n in "${names[@]}"; do printf '   %2d) %-16s %s\n' "$i" "$n" "$(svc_state "$n")"; i=$((i + 1)); done
  printf '    b) back\n\n'
  local c=""; read -r -p "  Choose: " c || c=""
  case "$c" in
    b|B|"") return ;;
    *) if [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le "${#names[@]}" ]; then
         run_action bash "$POCKET_ROOT/scripts/ops/restart.sh" "${names[$((c - 1))]}"
       else warn "not a valid choice: $c"; pause; fi ;;
  esac
}

backups_menu() {
  load_cfg
  while :; do
    screen; banner
    printf '  Backups & restore  (output under %s)\n\n' "${BACKUP_DIR:-<set DATA_DIR>}"
    printf '   1) Back up the Matrix database     (quick; brief chat downtime)\n'
    printf '   2) Back up the whole userland      (slow, ~1 GB)\n'
    printf '   3) Apply retention now             (prune old snapshots)\n'
    printf '   4) List existing backups\n'
    printf '   5) Start the scheduled daemon      %s\n' "$(svc_state backup-daemon)"
    printf '   6) Stop the scheduled daemon\n'
    printf '   7) Restore — preview the plan       (dry-run; changes nothing)\n'
    printf '   8) Restore — ERASE & RESTORE        (destructive; needs confirm)\n'
    printf '    b) back\n\n'
    local c=""; read -r -p "  Choose: " c || c=""
    case "$c" in
      1) run_action bash "$POCKET_ROOT/scripts/ops/backup-db.sh" ;;
      2) confirm "Back up the whole userland now (this can take a while)?" && \
           run_action bash "$POCKET_ROOT/scripts/ops/backup-all.sh" ;;
      3) run_action bash "$POCKET_ROOT/scripts/ops/rotate-backups.sh" ;;
      4) if [ -n "${BACKUP_DIR:-}" ] && [ -d "${BACKUP_DIR}" ]; then
           run_action bash -c 'ls -lhR "$1" 2>/dev/null || echo "(no backups yet)"' _ "${BACKUP_DIR}"
         else warn "no backup dir yet (set DATA_DIR and run a backup)"; pause; fi ;;
      5) if [ "$(svc_state backup-daemon)" != "DOWN" ]; then warn "backup-daemon already running"; pause
         else
           say "starting backup-daemon (set ENABLE_BACKUP_DAEMON=true in .env to keep it across reboots)"
           run_action bash -c '. "$1/scripts/lib/common.sh"; load_env; supervise backup-daemon -- bash "$1/scripts/ops/backup-daemon.sh"' _ "$POCKET_ROOT"
         fi ;;
      6) confirm "Stop the scheduled backup daemon?" && \
           run_action bash -c '. "$1/scripts/lib/common.sh"; load_env; unsupervise backup-daemon' _ "$POCKET_ROOT" ;;
      7) run_action bash "$POCKET_ROOT/scripts/ops/restore.sh" ;;
      8) warn "This ERASES the live userland + DB and restores from the latest backup."
         confirm "Restore now — erase the current rootfs and DB?" && \
           run_action bash "$POCKET_ROOT/scripts/ops/restore.sh" --confirm=ERASE-AND-RESTORE ;;
      b|B|"") return ;;
      *) warn "not a valid choice: $c"; pause ;;
    esac
  done
}

# Rotate the credentials the stack uses. The always-available ones (admin
# password, registration token) wrap scripts the admin panel also exposes; the
# tunnel-token paste and the gateway/admin-bot rotations are interactive / gated,
# so the TUI is their natural home.
rotate_menu() {
  load_cfg
  while :; do
    screen; banner
    printf '  Rotate credentials\n\n'
    printf '   1) Admin-panel password\n'
    printf '   2) Matrix registration token        (brief chat restart)\n'
    printf '   3) Cloudflare Tunnel token           (paste a freshly-minted token)\n'
    printf '   4) Rotate ALL of the above at once\n'
    if [ "${ENABLE_AUTH_GATEWAY:-false}" = "true" ]; then
      printf '   5) Auth-gateway RS256 OIDC key       (two-phase: new | finalize)\n'
    fi
    if [ "${ENABLE_ADMINBOT:-false}" = "true" ]; then
      printf '   6) Admin-bot access token\n'
    fi
    printf '    b) back\n\n'
    local c=""; read -r -p "  Choose: " c || c=""
    case "$c" in
      b|B|"") return ;;
      1) run_action bash "$POCKET_ROOT/scripts/ops/rotate-admin-password.sh" ;;
      2) confirm "Rotate the registration token (invalidates the current one)?" && \
           run_action bash "$POCKET_ROOT/scripts/ops/rotate-registration-token.sh" ;;
      3) run_action bash "$POCKET_ROOT/scripts/ops/rotate-tunnel-token.sh" ;;
      4) confirm "Rotate every available credential now?" && \
           run_action bash "$POCKET_ROOT/scripts/ops/rotate-all.sh" ;;
      5) if [ "${ENABLE_AUTH_GATEWAY:-false}" = "true" ]; then
           local p=""; read -r -p "  Phase — 'new' mints + overlaps, 'finalize' drops the old key: " p || p=""
           case "$p" in
             new|finalize) run_action bash "$POCKET_ROOT/scripts/ops/rotate-authgw-rs.sh" "$p" ;;
             *) warn "expected 'new' or 'finalize'"; pause ;;
           esac
         else warn "not a valid choice: $c"; pause; fi ;;
      6) if [ "${ENABLE_ADMINBOT:-false}" = "true" ]; then
           run_action bash "$POCKET_ROOT/scripts/ops/rotate-adminbot-token.sh"
         else warn "not a valid choice: $c"; pause; fi ;;
      *) warn "not a valid choice: $c"; pause ;;
    esac
  done
}

logs_menu() {
  load_cfg
  local logs=() f
  shopt -s nullglob
  for f in "${POCKET_LOG_DIR:-/nonexistent}"/*.log; do logs+=("$f"); done
  shopt -u nullglob
  if [ "${#logs[@]}" -eq 0 ]; then
    warn "no logs yet (${POCKET_LOG_DIR:-<set DATA_DIR>}) — start the stack first"; pause; return
  fi
  screen; banner
  printf '  View a log (last 120 lines)\n\n'
  local i=1
  for f in "${logs[@]}"; do printf '   %2d) %s\n' "$i" "$(basename "$f")"; i=$((i + 1)); done
  printf '    b) back\n\n'
  local c=""; read -r -p "  Choose: " c || c=""
  case "$c" in
    b|B|"") return ;;
    *) if [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le "${#logs[@]}" ]; then
         run_action bash -c 'echo "── $1 ──"; tail -n 120 "$1"' _ "${logs[$((c - 1))]}"
       else warn "not a valid choice: $c"; pause; fi ;;
  esac
}

panic_menu() {
  load_cfg
  screen; banner
  printf '  Stop / panic\n\n'
  printf '   1) Soft  — cut public access (stop the tunnel); keep local services\n'
  printf '   2) Hard  — stop the whole stack (admin panel kept for recovery)\n'
  printf '    b) back\n\n'
  local c=""; read -r -p "  Choose: " c || c=""
  case "$c" in
    1) confirm "Cut public access now (stop the Cloudflare Tunnel)?" && \
         run_action bash "$POCKET_ROOT/scripts/ops/panic-soft.sh" ;;
    2) confirm "Take the WHOLE stack offline now?" && \
         run_action bash "$POCKET_ROOT/scripts/ops/panic-hard.sh" ;;
    b|B|"") return ;;
    *) warn "not a valid choice: $c"; pause ;;
  esac
}

# ── Main menu ─────────────────────────────────────────────────────────────────
main_menu() {
  while :; do
    load_cfg
    screen; banner
    if ! have_env; then
      printf '   1) Configure — first-time setup (writes your .env)\n'
      printf '    q) quit\n\n'
      local c=""; read -r -p "  Choose: " c || c=""
      case "$c" in
        1) run_action bash "$POCKET_ROOT/setup.sh" ;;
        q|Q|"") clear 2>/dev/null || true; exit 0 ;;
        *) warn "not a valid choice: $c"; pause ;;
      esac
      continue
    fi
    printf '   1) Configure / reconfigure        (re-run the setup wizard)\n'
    printf '   2) Install / bring up the stack   (resumes; safe to re-run)\n'
    printf '   3) Re-run everything (force)      (redo every install step)\n'
    printf '   4) Status                         (what is installed & running)\n'
    printf '   5) Restart a service\n'
    printf '   6) Backups & restore\n'
    printf '   7) View logs\n'
    printf '   8) Stop / panic\n'
    printf '   9) Rotate credentials\n'
    printf '    q) quit\n\n'
    local c=""; read -r -p "  Choose: " c || c=""
    case "$c" in
      1) run_action bash "$POCKET_ROOT/setup.sh" ;;
      2) run_action bash "$POCKET_ROOT/scripts/install.sh" ;;
      3) confirm "Re-run every install step from scratch?" && \
           run_action bash "$POCKET_ROOT/scripts/install.sh" --force ;;
      4) run_action bash "$POCKET_ROOT/scripts/install.sh" --status ;;
      5) restart_menu ;;
      6) backups_menu ;;
      7) logs_menu ;;
      8) panic_menu ;;
      9) rotate_menu ;;
      q|Q|"") clear 2>/dev/null || true; exit 0 ;;
      *) warn "not a valid choice: $c"; pause ;;
    esac
  done
}

main_menu
