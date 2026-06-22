#!/usr/bin/env bash
#
# steps/70-install-admin.sh — install + supervise the web admin panel.
#
# The panel (admin/app.py) is a small Flask app that gives you a phone-friendly
# control panel for the stack: live health + device stats, a log viewer, service
# restarts, backups, the registration token, and a guarded danger zone.
#
# It runs TERMUX-NATIVE (NOT inside the proot userland), because its whole job is
# to orchestrate the host: it shells out to scripts/ (proot-distro restarts, the
# backup/rotation/panic scripts), reads the supervisor pidfiles under
# ${POCKET_STATE_DIR}, and pgrep's the host processes for health. None of that is
# possible from inside the proot userland. Caddy (in the userland) reaches the
# Termux-native panel over loopback (proot shares the host network namespace).
#
# This is a core step that SELF-GATES on ENABLE_ADMIN (install.sh runs it
# unconditionally; it no-ops when disabled). ENABLE_ADMIN defaults to true — the
# panel is a headline feature — but advanced users can turn it off.
#
# What it does (idempotent — safe to re-run):
#   1. ensures a Termux Python venv at ~/pocket-admin/.venv with Flask + gunicorn,
#   2. copies admin/app.py -> ~/pocket-admin/app.py (the `app:app` entrypoint),
#   3. generates (0600, reused on re-run) the scrypt password hash from
#      ADMIN_PASSWORD + lets the panel mint its own session secret,
#   4. writes the Caddy vhost (admin.${DOMAIN} -> the loopback panel) + validates,
#   5. supervises gunicorn (SINGLE worker, NO --preload) + health-checks it.
#
# Generalized from a working deployment; review before running on a fresh phone.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env

# ── Self-gate: only run when enabled (default on) ────────────────────────────
if [ "${ENABLE_ADMIN:-true}" != "true" ]; then
  ok "admin panel disabled (ENABLE_ADMIN != true) — skipping"
  exit 0
fi

require_var DOMAIN         "your public domain, e.g. example.com"
require_var DATA_DIR       "folder on your large volume / SD card"
require_var ADMIN_PASSWORD "the admin panel login password (set in .env)"
require_cmd python3
require_cmd proot-distro    # for writing + validating the Caddy vhost in the userland

in_debian() { proot-distro login debian -- bash -lc "$1"; }

# ── Config ───────────────────────────────────────────────────────────────────
ADMIN_DIR="${HOME}/pocket-admin"                 # Termux-native install dir
ADMIN_VENV="${ADMIN_DIR}/.venv"
ADMIN_SRC="${POCKET_ROOT}/admin/app.py"
ADMIN_PORT="${ADMINWEB_PORT:-9000}"              # loopback bind; Caddy fronts the edge
ADMIN_VHOST_HOST="${ADMIN_HOST:-admin.${DOMAIN}}"
SECRETS_DIR="${DATA_DIR}/secrets"
HASH_FILE="${SECRETS_DIR}/adminweb-password.hash"

[ -f "${ADMIN_SRC}" ] || die "admin source missing: ${ADMIN_SRC}"
mkdir -p "${ADMIN_DIR}" "${SECRETS_DIR}"
chmod 700 "${SECRETS_DIR}" 2>/dev/null || true

# ── 1. Python venv with Flask + gunicorn (Termux-native) ─────────────────────
# A venv keeps the panel's deps off the system Python. Versions float (pip
# verifies each wheel's hash against PyPI); pin them here if you want determinism.
if [ ! -x "${ADMIN_VENV}/bin/python" ]; then
  say "creating the admin venv at ${ADMIN_VENV}"
  python3 -m venv "${ADMIN_VENV}" || die "failed to create the admin venv (is python3-venv installed?)"
fi
say "installing Flask + gunicorn into the admin venv (first run downloads them)"
"${ADMIN_VENV}/bin/pip" install --upgrade pip wheel >/dev/null 2>&1 || warn "pip self-upgrade reported a problem (continuing)"
# segno is a tiny pure-Python QR lib used by the optional Radicale "connect device"
# card (/dav). The panel lazy-imports it and degrades gracefully if it is absent,
# so this install is best-effort — never fatal.
"${ADMIN_VENV}/bin/pip" install flask gunicorn >/dev/null \
  || die "could not install Flask + gunicorn into the admin venv"
"${ADMIN_VENV}/bin/pip" install segno >/dev/null 2>&1 \
  || warn "could not install segno into the admin venv — the Radicale /dav QR will degrade to a URL card (non-fatal)"
"${ADMIN_VENV}/bin/python" -c 'import flask, gunicorn' \
  || die "Flask/gunicorn import failed in the admin venv"
ok "admin venv ready ($("${ADMIN_VENV}/bin/python" -c 'import flask,importlib.metadata as m; print("flask",m.version("flask"),"gunicorn",m.version("gunicorn"))' 2>/dev/null))"

# ── 2. Copy the panel into place + fail-closed parse check ───────────────────
# The supervisor runs gunicorn with `app:app`, so the file must be named app.py.
install -m 644 "${ADMIN_SRC}" "${ADMIN_DIR}/app.py" || die "failed to copy the panel to ${ADMIN_DIR}/app.py"
"${ADMIN_VENV}/bin/python" -c "import ast,sys; ast.parse(open('${ADMIN_DIR}/app.py').read())" \
  || die "the copied panel failed to parse under the venv python"
ok "panel installed at ${ADMIN_DIR}/app.py"

# ── 3. Generate the scrypt password hash (0600; reused on re-run) ────────────
# The panel only VERIFIES the hash (it never stores the plaintext). We generate it
# from ADMIN_PASSWORD with the exact params the panel checks (n=2^14, r=8, p=1,
# dklen=32; "salthex:hashhex"). Reused if present, so a password rotated from the
# panel's danger zone is preserved across re-runs. The password is read from the
# environment inside python — never placed on a command line.
if [ -s "${HASH_FILE}" ]; then
  say "reusing existing admin password hash at ${HASH_FILE}"
else
  say "generating the admin password hash → ${HASH_FILE} (0600)"
  ADMIN_PASSWORD="${ADMIN_PASSWORD}" "${ADMIN_VENV}/bin/python" - "${HASH_FILE}" <<'PY' \
    || die "failed to generate the admin password hash"
import os, sys, secrets, hashlib
hash_file = sys.argv[1]
pw = os.environ.get("ADMIN_PASSWORD", "")
if not pw:
    raise SystemExit("ADMIN_PASSWORD is empty")
salt = secrets.token_bytes(16)
digest = hashlib.scrypt(pw.encode(), salt=salt, n=2 ** 14, r=8, p=1, dklen=32)
fd = os.open(hash_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
try:
    os.write(fd, (salt.hex() + ":" + digest.hex()).encode())
finally:
    os.close(fd)
PY
  chmod 600 "${HASH_FILE}" 2>/dev/null || true
fi
[ -s "${HASH_FILE}" ] || die "admin password hash is missing at ${HASH_FILE}"

# ── 4. Write the Termux launcher (bakes the panel's non-secret env contract) ─
# gunicorn: SINGLE worker (the in-memory brute-force counters MUST NOT diverge),
# NO --preload (each worker re-imports app.py so it re-reads the persisted
# counters on respawn). The launcher exports only what the panel reads — never the
# Cloudflare Tunnel token. The ops scripts the panel runs re-read .env themselves.
say "writing the launcher → ${ADMIN_DIR}/run.sh"
cat > "${ADMIN_DIR}/run.sh" <<LAUNCH
#!/data/data/com.termux/files/usr/bin/bash
# Runs the admin panel TERMUX-NATIVE; started + kept alive by steps/70-install-admin.sh.
export POCKET_ROOT='${POCKET_ROOT}'
export DATA_DIR='${DATA_DIR}'
export POCKET_STATE_DIR='${POCKET_STATE_DIR}'
export POCKET_LOG_DIR='${POCKET_LOG_DIR}'
export BACKUP_DIR='${BACKUP_DIR}'
export DOMAIN='${DOMAIN}'
export ADMIN_HOST='${ADMIN_VHOST_HOST}'
export ADMIN_USER='${ADMIN_USER:-admin}'
export ADMIN_BRAND='${ADMIN_BRAND:-${DOMAIN}}'
export ADMINWEB_PORT='${ADMIN_PORT}'
export ADMIN_IDLE_MINUTES='${ADMIN_IDLE_MINUTES:-30}'
export ADMINWEB_SECURE_COOKIE='${ADMINWEB_SECURE_COOKIE:-0}'
export CADDY_BIND='${CADDY_BIND}'
export CADDY_PORT='${CADDY_PORT}'
export AUTHGW_PORT='${AUTHGW_PORT:-9095}'
export ENABLE_AUTH_GATEWAY='${ENABLE_AUTH_GATEWAY:-false}'
export ENABLE_LINKDING='${ENABLE_LINKDING:-false}'
export ENABLE_PINGVIN='${ENABLE_PINGVIN:-false}'
export ENABLE_FRESHRSS='${ENABLE_FRESHRSS:-false}'
export ENABLE_MEMOS='${ENABLE_MEMOS:-false}'
export ENABLE_VIKUNJA='${ENABLE_VIKUNJA:-false}'
export ENABLE_SEARXNG='${ENABLE_SEARXNG:-false}'
export ENABLE_ITTOOLS='${ENABLE_ITTOOLS:-false}'
export ENABLE_GATUS='${ENABLE_GATUS:-false}'
export ENABLE_HONEYPOT='${ENABLE_HONEYPOT:-false}'
export ENABLE_BACKUP_DAEMON='${ENABLE_BACKUP_DAEMON:-false}'
export ENABLE_CLOUD_BOTS='${ENABLE_CLOUD_BOTS:-false}'
export ENABLE_EXOBOT='${ENABLE_EXOBOT:-false}'
export EXOBOT_UI='${EXOBOT_UI:-false}'
export ENABLE_STICKERS='${ENABLE_STICKERS:-false}'
export ENABLE_ADMINBOT='${ENABLE_ADMINBOT:-false}'
export ENABLE_EMAIL='${ENABLE_EMAIL:-false}'
export ENABLE_MCP='${ENABLE_MCP:-false}'
export MCP_TRANSPORT='${MCP_TRANSPORT:-stdio}'
export ENABLE_USER_FILTER='${ENABLE_USER_FILTER:-false}'
export ENABLE_MEDIA_FILTER='${ENABLE_MEDIA_FILTER:-false}'
export ENABLE_METRICS='${ENABLE_METRICS:-false}'
export ENABLE_USER_ADMIN='${ENABLE_USER_ADMIN:-false}'
export ENABLE_OFFSITE_BACKUP='${ENABLE_OFFSITE_BACKUP:-false}'
export ENABLE_WALLABAG='${ENABLE_WALLABAG:-false}'
export ENABLE_RADICALE='${ENABLE_RADICALE:-false}'
export ENABLE_TRILIUM='${ENABLE_TRILIUM:-false}'
export ENABLE_VAULTWARDEN='${ENABLE_VAULTWARDEN:-false}'
# Optional Cloudflare Access JWT validation (also reads \${DATA_DIR}/secrets/cf-access.env).
export CF_ACCESS_MODE='${CF_ACCESS_MODE:-log}'
export CF_ACCESS_TEAM_DOMAIN='${CF_ACCESS_TEAM_DOMAIN:-}'
export CF_ACCESS_AUD='${CF_ACCESS_AUD:-}'
cd '${ADMIN_DIR}' || exit 1
exec '${ADMIN_VENV}/bin/gunicorn' \\
  --chdir '${ADMIN_DIR}' \\
  --bind '127.0.0.1:${ADMIN_PORT}' \\
  --workers 1 --threads 4 --worker-class gthread \\
  --timeout 60 --graceful-timeout 30 \\
  --max-requests 500 --max-requests-jitter 100 \\
  --log-level info --name adminweb \\
  app:app
LAUNCH
chmod 700 "${ADMIN_DIR}/run.sh"
ok "wrote the launcher"

# ── 5. Caddy vhost (written + validated inside the userland) ─────────────────
# admin.${DOMAIN} -> the loopback panel. The panel sets its own CSP + X-Frame
# DENY, so the vhost only adds HSTS + nosniff and forwards the proxy headers the
# panel's ProxyFix + CSRF need. Default protection is Cloudflare Access at the edge
# (a policy you add in the Cloudflare dashboard) + the panel's own login.
say "writing the Caddy vhost → /etc/caddy/apps/admin.caddy"
proot-distro login debian -- bash -lc 'mkdir -p /etc/caddy/apps && cat > /etc/caddy/apps/admin.caddy' <<EOF
# Web admin panel — core vhost for pocket-homeserver.
# Public hostname ${ADMIN_VHOST_HOST}; bound to loopback (the Cloudflare Tunnel
# forwards public traffic here). The panel runs Termux-native on the loopback
# port below. Protect this hostname with Cloudflare Access in the Cloudflare
# dashboard; the panel's own scrypt login is the inner gate.
http://${ADMIN_VHOST_HOST}:${CADDY_PORT} {
	bind ${CADDY_BIND}

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options nosniff
		-Server
	}

	reverse_proxy 127.0.0.1:${ADMIN_PORT} {
		header_up Host {http.request.host}
		header_up X-Forwarded-Proto https
	}
}
EOF
say "validating the Caddyfile inside the userland"
in_debian 'caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile' \
  || die "caddy validate FAILED — refusing to leave a broken vhost (fix /etc/caddy/apps/admin.caddy)"
ok "Caddyfile still valid with the admin vhost added"

# ── 6. Supervise gunicorn (Termux-native) + health-check ─────────────────────
supervise adminweb -- bash "${ADMIN_DIR}/run.sh"

say "waiting for the admin panel health endpoint"
healthy=0
for _ in $(seq 1 20); do
  if curl -fsS -o /dev/null "http://127.0.0.1:${ADMIN_PORT}/login" 2>/dev/null; then
    healthy=1; break
  fi
  sleep 1
done
[ "${healthy}" -eq 1 ] && ok "admin panel healthy on 127.0.0.1:${ADMIN_PORT}/login" \
  || warn "admin panel did not answer on 127.0.0.1:${ADMIN_PORT} yet — check ${POCKET_LOG_DIR}/adminweb.log"

# ── Closing notes ─────────────────────────────────────────────────────────────
echo
ok "Web admin panel installed + supervised (loopback 127.0.0.1:${ADMIN_PORT})"
say "Login user: '${ADMIN_USER:-admin}' (password from .env ADMIN_PASSWORD). Rotate it from the danger zone after first login."
echo
say "Manual Cloudflare steps (in the Cloudflare dashboard — NOT done by this script):"
say "  1. Tunnel public hostname:  ${ADMIN_VHOST_HOST}  ->  http://localhost:${CADDY_PORT}"
say "  2. Add a Cloudflare Access policy protecting ${ADMIN_VHOST_HOST} (only your identities)."
say "  If the core stack is already running, pick up the new vhost with:"
say "     bash ${POCKET_ROOT}/scripts/start-stack.sh --restart"

# Generalized from a working deployment; review before running.
