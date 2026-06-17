#!/usr/bin/env bash
#
# ops/panic-soft.sh — SOFT kill switch: cut public access, keep everything local.
#
# Stops ONLY the Cloudflare Tunnel (cloudflared), so nothing is reachable from the
# internet any more. Matrix, Caddy, the apps, and the admin panel all keep running
# on loopback, so you can still administer the box locally (or over an ssh -L
# tunnel) and investigate. Fully reversible.
#
# Recover with:  bash scripts/start-stack.sh     (re-starts the tunnel)
#
# Generalized from a working deployment; review before running on a fresh phone.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env

warn "SOFT PANIC: stopping the Cloudflare Tunnel — public access goes OFF"
unsupervise cloudflared

ok "SOFT PANIC done — the box is no longer reachable from the internet."
say "Local/loopback services are still running. Recover public access with:"
say "  bash ${POCKET_ROOT}/scripts/start-stack.sh"
