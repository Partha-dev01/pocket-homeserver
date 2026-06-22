#!/usr/bin/env bash
#
# steps/88-install-metrics.sh — install + supervise the system-metrics sampler
# (OPTIONAL observability; off by default).
#
# The sampler (scripts/ops/metrics-sampler.py) is a tiny native python3 process
# that samples cheap host-side numbers (CPU/mem/swap/load/disk/temp/battery + the
# count of DEGRADED services) once a minute into a capped JSONL "ring" file. The
# web admin panel reads that file to draw sparklines, a 24h health strip, and a
# stats history (/metrics). It has NO inbound listener and makes NO network call —
# zero new attack surface.
#
# It runs TERMUX-NATIVE (NOT inside the proot userland) for the same reason the
# admin panel + honeypot watcher do: everything it reads (/proc, /sys, statvfs,
# termux-battery-status) is on the HOST.
#
# Core step that SELF-GATES on ENABLE_METRICS (install.sh runs it unconditionally;
# it no-ops when disabled). ENABLE_METRICS defaults to false.
#
# Storage tier: the ring file is pinned to REAL ext4 ($HOME/.pocket/metrics), NOT
# the exFAT SD card — the sampler trims it via temp+rename, which exFAT/FUSE
# refuses. Same ext4 precedent the honeypot DB uses.
#
# Generalized from a working deployment; review before running on a fresh phone.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env

# ── Self-gate: only run when enabled (default off) ───────────────────────────
if [ "${ENABLE_METRICS:-false}" != "true" ]; then
  ok "metrics sampler disabled (ENABLE_METRICS != true) — skipping"
  exit 0
fi

require_var DATA_DIR "folder on your large volume / SD card"
require_cmd python3

# ── Paths ─────────────────────────────────────────────────────────────────────
SAMPLER="${POCKET_ROOT}/scripts/ops/metrics-sampler.py"

# The ring file lives on ext4 (Termux $HOME), NOT under DATA_DIR (often exFAT).
# POCKET_METRICS_LOG lets an operator override the location if their layout differs.
METRICS_DIR="${POCKET_METRICS_DIR:-$HOME/.pocket/metrics}"
METRICS_LOG="${POCKET_METRICS_LOG:-${METRICS_DIR}/metrics.jsonl}"

mkdir -p "${METRICS_DIR}" "${POCKET_STATE_DIR}" "${POCKET_LOG_DIR}"
chmod 700 "${METRICS_DIR}" 2>/dev/null || true

# ── Preflight: the sampler must be present + parse-clean (fail-closed) ────────
# Catch a broken/missing module at install time, not at first respawn (where it
# would just crash-loop the supervisor).
[ -f "${SAMPLER}" ] || die "metrics sampler missing: ${SAMPLER} — the observability module was not shipped"
python3 -c "import ast,sys; ast.parse(open('${SAMPLER}').read())" \
  || die "metrics-sampler.py failed to parse under python3"
ok "metrics sampler present + parse-clean (${SAMPLER})"

# ── Launcher: pin the ring to ext4 + carry the sample config (off argv) ───────
# A tiny native launcher exports the sampler's config into its env and execs it.
# supervise records THIS launcher in the .cmd, so start-stack.sh and ops/restart.sh
# re-supervise the exact same env-pinned command on every bring-up.
LAUNCHER="${METRICS_DIR}/run-sampler.sh"
say "writing the metrics sampler launcher -> ${LAUNCHER} (ring on ext4)"
( umask 077; cat > "${LAUNCHER}" <<LAUNCH
#!/usr/bin/env bash
# Native metrics sampler launcher — written by steps/88-install-metrics.sh.
# Pins the ring file to ext4 (POCKET_METRICS_LOG) so it NEVER lands on the exFAT
# SD card, carries the sample config, then execs the sampler. No secrets involved.
export POCKET_METRICS_LOG="${METRICS_LOG}"
export POCKET_METRICS_POLL_S="${POCKET_METRICS_POLL_S:-60}"
export POCKET_METRICS_RING="${POCKET_METRICS_RING:-5760}"
export POCKET_METRICS_DISK="${DATA_DIR}"
export POCKET_STATE_DIR="${POCKET_STATE_DIR}"
export POCKET_METRICS_BATTERY="${POCKET_METRICS_BATTERY:-true}"
exec python3 "${SAMPLER}"
LAUNCH
)
chmod 700 "${LAUNCHER}"

# ── Supervise (Termux-native respawn loop + identity-checked pidfile) ─────────
supervise metrics-sampler -- bash "${LAUNCHER}"

# Confirm the python child came up. No port to probe (it only writes a file), so
# we look for the live process by its script path.
say "confirming the metrics sampler came up"
up=0
for _ in $(seq 1 10); do
  if pgrep -f 'metrics-sampler\.py' >/dev/null 2>&1; then up=1; break; fi
  sleep 1
done
[ "${up}" -eq 1 ] && ok "metrics sampler running (python child up)" \
  || warn "metrics sampler did not appear yet — check ${POCKET_LOG_DIR}/metrics-sampler.log"

echo
ok "Metrics sampler installed + supervised (ring: ${METRICS_LOG})"
say "It samples CPU/mem/disk/temp/load once a minute into a capped ring file."
say "View it in the web admin panel: /metrics (sparklines + 24h health strip)."

# Generalized from a working deployment; review before running.
