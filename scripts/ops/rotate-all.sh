#!/usr/bin/env bash
#
# ops/rotate-all.sh — rotate every credential that can be rotated unattended, in
# one pass.
#
# Always rotates:
#   * the web admin panel password   (ops/rotate-admin-password.sh)
#   * the Matrix registration token   (ops/rotate-registration-token.sh)
# Additionally, when their subsystem is enabled (otherwise skipped):
#   * the auth-gateway RS256 OIDC key (ops/rotate-authgw-rs.sh new)  — ENABLE_AUTH_GATEWAY
#   * the Matrix admin-bot token       (ops/rotate-adminbot-token.sh) — ENABLE_ADMINBOT
#
# DELIBERATELY NOT rotated here: the Cloudflare Tunnel token — that needs a manual
# step in the Cloudflare dashboard first, so run ops/rotate-tunnel-token.sh on its
# own when you want it.
#
# Each rotation is INDEPENDENT: a failure in one is recorded and the rest still
# run, then a summary is printed and the script exits non-zero if anything failed.
# Several of these restart services, so expect brief interruptions.
#
# Usage:
#   bash scripts/ops/rotate-all.sh
#
# Generalized from a working deployment; review before running on a fresh phone.

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env

OPS="${POCKET_ROOT}/scripts/ops"

# Track results for the summary. Parallel arrays keep it bash-3-safe.
_names=()
_results=()
_record() { _names+=("$1"); _results+=("$2"); }

# run_step LABEL -- cmd...   — run a rotation, record OK/SKIP/FAIL, never abort the
# orchestrator on a single failure.
run_step() {
  local label="$1"; shift; [ "${1:-}" = "--" ] && shift
  echo
  say "--- ${label} ---"
  if "$@"; then
    _record "${label}" "OK"
  else
    warn "${label} reported a failure (continuing with the rest)"
    _record "${label}" "FAIL"
  fi
  sleep 2
}

say "=== rotate-all begin ==="

# ── Always-available rotations ────────────────────────────────────────────────
run_step "admin panel password"  -- bash "${OPS}/rotate-admin-password.sh"
run_step "registration token"    -- bash "${OPS}/rotate-registration-token.sh"

# ── Conditional rotations (each self-gates + fails soft when disabled) ────────
# Both helpers no-op cleanly (exit 0) when their subsystem is not enabled, so we
# can just call them; they record OK when they skip, which is the right outcome.
if [ "${ENABLE_AUTH_GATEWAY:-false}" = "true" ]; then
  run_step "auth-gw RS256 key (phase 1)" -- bash "${OPS}/rotate-authgw-rs.sh" new
else
  _record "auth-gw RS256 key" "SKIP (ENABLE_AUTH_GATEWAY != true)"
fi

if [ "${ENABLE_ADMINBOT:-false}" = "true" ]; then
  run_step "admin-bot token" -- bash "${OPS}/rotate-adminbot-token.sh"
else
  _record "admin-bot token" "SKIP (ENABLE_ADMINBOT != true)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
say "=== rotate-all summary ==="
failed=0
i=0
while [ "$i" -lt "${#_names[@]}" ]; do
  printf '  %-32s : %s\n' "${_names[$i]}" "${_results[$i]}" >&2
  case "${_results[$i]}" in FAIL*) failed=1 ;; esac
  i=$((i + 1))
done
echo
say "NOTE: the Cloudflare Tunnel token is NOT rotated here (needs a manual"
say "      dashboard step) — run ops/rotate-tunnel-token.sh separately if needed."

if [ "$failed" -eq 1 ]; then
  die "rotate-all finished WITH FAILURES — see the summary above"
fi
ok "=== rotate-all done (all rotations succeeded or were skipped) ==="
