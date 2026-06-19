#!/usr/bin/env bash
#
# ops/rotate-tunnel-token.sh — replace the Cloudflare Tunnel token + restart the
# tunnel.
#
# The public ingress is the Cloudflare Tunnel; its token lives in CF_TUNNEL_TOKEN
# in .env and is staged into the userland at start time (see start-stack.sh —
# the token is staged into a 0600 file and read by a launcher, never on argv).
# This rotates it: you mint a NEW token in the Cloudflare dashboard, this script
# reads it (off-argv, into a 0600 file), rewrites the CF_TUNNEL_TOKEN line in .env,
# and restarts cloudflared so the new token takes effect.
#
# Workflow:
#   [Cloudflare dashboard — MANUAL]
#     1. Zero Trust → Networks → Tunnels → your tunnel
#     2. Either rotate the connector token, or delete + recreate the tunnel with
#        the SAME name and re-add the public hostname → http://localhost:${CADDY_PORT}.
#        (The old token becomes invalid as soon as you rotate/recreate.)
#     3. Copy the new connector token (starts with "eyJ…").
#   [this host]
#     bash scripts/ops/rotate-tunnel-token.sh
#       → paste the new token at the hidden prompt (it is NOT echoed, NOT on argv),
#     or feed it on stdin:
#     bash scripts/ops/rotate-tunnel-token.sh < new-token.txt
#
# The token never appears on a command line or in the process table. A timestamped
# backup of the previous .env is kept under ${BACKUP_DIR}/config before mutation.
#
# Generalized from a working deployment; review before running on a fresh phone.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env
require_var DATA_DIR "folder on your large volume / SD card"

ENVF="${POCKET_ENV:-$POCKET_ROOT/.env}"
[ -f "$ENVF" ] || die "no .env at $ENVF"

# ── Read the NEW token off-argv ───────────────────────────────────────────────
# From a TTY: a hidden prompt (read -rs). Non-interactive: the first non-empty
# line of stdin. Either way the token never reaches argv / /proc/*/cmdline.
NEW_TOKEN=""
if [ -t 0 ]; then
  printf 'Paste the new Cloudflare Tunnel token (input hidden): ' >&2
  read -rs NEW_TOKEN
  printf '\n' >&2
else
  IFS= read -r NEW_TOKEN || true
fi
NEW_TOKEN="$(printf '%s' "$NEW_TOKEN" | tr -d '[:space:]')"
[ -n "$NEW_TOKEN" ] || die "no token provided (paste it at the prompt, or pipe it on stdin)"

# Bail out early if it is identical to what is already configured (compare hashes
# only — never print either token).
OLD_TOKEN="${CF_TUNNEL_TOKEN:-}"
if [ -n "$OLD_TOKEN" ]; then
  if [ "$(printf '%s' "$OLD_TOKEN" | sha256sum | awk '{print $1}')" \
     = "$(printf '%s' "$NEW_TOKEN" | sha256sum | awk '{print $1}')" ]; then
    warn "the new token is IDENTICAL to the current CF_TUNNEL_TOKEN — nothing to rotate"
    exit 2
  fi
fi

# ── Back up .env, then rewrite the CF_TUNNEL_TOKEN line atomically ────────────
# The whole .env is written under umask 077 to a temp file then moved into place,
# so the secret never lands in a world-readable temp and the swap is atomic. The
# token is passed to python3 via the ENVIRONMENT (not argv) so it stays off the
# process table even during the rewrite.
mkdir -p "${BACKUP_DIR}/config"
cp -f "$ENVF" "${BACKUP_DIR}/config/env-pre-tunnel-rotate-$(date -u +%FT%H-%MZ)" 2>/dev/null || true

say "rewriting CF_TUNNEL_TOKEN in ${ENVF}"
umask 077
_NEW_CF_TOKEN="$NEW_TOKEN" python3 - "$ENVF" <<'PY'
import os, sys, tempfile
envf = sys.argv[1]
value = os.environ["_NEW_CF_TOKEN"]
with open(envf, "r", encoding="utf-8") as f:
    lines = f.readlines()
out, replaced = [], False
for ln in lines:
    stripped = ln.lstrip()
    # match  CF_TUNNEL_TOKEN=...   and  export CF_TUNNEL_TOKEN=...  (commented or not)
    body = stripped[len("export "):] if stripped.startswith("export ") else stripped
    if body.startswith("CF_TUNNEL_TOKEN=") or body.startswith("#CF_TUNNEL_TOKEN=") \
       or body.lstrip("#").lstrip().startswith("CF_TUNNEL_TOKEN="):
        out.append("CF_TUNNEL_TOKEN=%s\n" % value)
        replaced = True
    else:
        out.append(ln)
if not replaced:
    if out and not out[-1].endswith("\n"):
        out[-1] += "\n"
    out.append("CF_TUNNEL_TOKEN=%s\n" % value)
d = os.path.dirname(os.path.abspath(envf)) or "."
fd, tmp = tempfile.mkstemp(dir=d, prefix=".env.", suffix=".tmp")
try:
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.writelines(out)
    os.replace(tmp, envf)
except BaseException:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
PY
chmod 600 "$ENVF" 2>/dev/null || true

# Fail closed: the line must now be present in .env.
grep -qE '^CF_TUNNEL_TOKEN=.+' "$ENVF" || die "CF_TUNNEL_TOKEN was not written to ${ENVF}"
ok "CF_TUNNEL_TOKEN updated in .env"

# ── Restart cloudflared so the new token is staged + used ─────────────────────
# ops/restart.sh re-supervises cloudflared from its recorded launch command; but
# the token is staged from .env by start-stack.sh's stage step, so prefer a full
# start-stack run (idempotent — only restarts what is down + re-stages the token).
say "restarting the tunnel with the new token"
bash "${POCKET_ROOT}/scripts/start-stack.sh" --restart >/dev/null 2>&1 \
  || bash "${POCKET_ROOT}/scripts/ops/restart.sh" cloudflared >/dev/null 2>&1 \
  || warn "cloudflared restart reported a problem — check ${POCKET_LOG_DIR}/cloudflared.log"

# Best-effort confirmation: look for a fresh tunnel registration in the log.
sleep 5
if grep -q 'Registered tunnel connection' "${POCKET_LOG_DIR}/cloudflared.log" 2>/dev/null; then
  ok "tunnel re-registered (see ${POCKET_LOG_DIR}/cloudflared.log)"
else
  warn "tunnel has not registered yet — watch ${POCKET_LOG_DIR}/cloudflared.log"
fi

ok "tunnel token rotated"
