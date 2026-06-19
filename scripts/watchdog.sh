#!/usr/bin/env bash
#
# watchdog.sh — self-healing stack watchdog.
#
# WHY: every service runs under a supervisor (a detached `while true` respawn
# loop) that only respawns its CHILD. If Android's low-memory killer reaps the
# SUPERVISOR itself — which can happen WITHOUT a reboot — nothing brings it back
# until the next boot. This watchdog closes that gap: it re-runs the IDEMPOTENT
# full-stack bring-up (start-stack.sh), which skips every live service and
# respawns only the dead ones (no running service is bounced, so no periodic
# downtime).
#
# HOW IT'S RUN: registered with Android's JobScheduler by
# scripts/steps/75-install-boot.sh (~15 min period, persisted). JobScheduler is
# owned by the OS, so this fires even if the whole Termux app was killed, and
# survives reboots. The Termux:Boot launcher remains the deterministic boot path;
# this is the belt-and-suspenders heal loop on top of it.
#
# Output: the full start-stack run is OVERWRITTEN into watchdog-last.log (so it
# never grows); a one-line timestamped summary is appended to watchdog.log (kept
# bounded to the last 500 lines).
#
# Usage: bash scripts/watchdog.sh   (normally JobScheduler-invoked)

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

load_env

LOG="${POCKET_LOG_DIR}/watchdog.log"
LAST="${POCKET_LOG_DIR}/watchdog-last.log"
mkdir -p "${POCKET_LOG_DIR}" 2>/dev/null || true

# Re-assert the wake lock every tick — if Android dropped it, this pulls Termux
# back out of the doze that lets it kill our supervisors (best effort).
command -v termux-wake-lock >/dev/null 2>&1 && { termux-wake-lock 2>/dev/null || true; }

echo "$(date -u +%FT%TZ) [watchdog] tick — running start-stack (idempotent)" >> "$LOG"
bash "${POCKET_ROOT}/scripts/start-stack.sh" > "$LAST" 2>&1
rc=$?

# Compact summary: which services start-stack's status section reported DOWN
# (the ones the watchdog just tried to revive this tick).
downs="$(grep -E ': DOWN$' "$LAST" 2>/dev/null | sed 's/^[[:space:]]*//' | tr '\n' ';')"
echo "$(date -u +%FT%TZ) [watchdog] done rc=${rc} downs=[${downs}]" >> "$LOG"

# Keep watchdog.log bounded.
tail -n 500 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG" || true
