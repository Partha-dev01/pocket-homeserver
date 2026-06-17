#!/usr/bin/env bash
#
# apps/vikunja.sh — install + supervise Vikunja (self-hosted tasks / kanban / GTD)
# as an OPTIONAL app behind the loopback Caddy edge.
#
# Vikunja ships a single Go arm64 binary: the "-full" build bundles the REST API
# AND the embedded Vue frontend, so there is no separate web server. We run that
# one binary INSIDE the Debian userland at /opt/vikunja and front it with the core
# Caddy on ${CADDY_BIND}:${CADDY_PORT}; the public hostname is tasks.${DOMAIN}.
#
# What it does (idempotent — safe to re-run):
#   1. downloads + sha256-verifies (fail-closed) the pinned arm64 "-full" zip into
#      ${DATA_DIR}/binaries, then installs the single binary into the userland,
#   2. generates + persists Vikunja's own service/JWT secrets under
#      ${DATA_DIR}/secrets/vikunja.env (chmod 600; reused on re-run) so users are
#      NOT logged out on every restart,
#   3. writes a hardened /opt/vikunja/config.yml into the userland (SQLite + files
#      on the large volume, loopback bind, registration OFF, local login ON),
#   4. writes a tiny migrate-then-exec launcher (/opt/vikunja/run.sh),
#   5. writes a self-contained Caddy vhost to /etc/caddy/apps/vikunja.caddy and
#      validates the full Caddyfile fail-closed (it does NOT restart Caddy),
#   6. supervises the service via the shared lib (respawn + identity-checked pid).
#
# AUTH MODEL (default): Vikunja keeps its OWN native login, and the public hostname
# is gated at the Cloudflare edge with Cloudflare Access (a policy you add in the
# Cloudflare dashboard — NOT configured by this script). Self-signup is OFF, so
# accounts are created by an admin from inside Vikunja. An optional Matrix-SSO
# gateway add-on (single sign-on across apps) is documented in docs/APP_AUTH.md;
# the hooks are present here only as a COMMENTED-OUT block in the Caddy vhost.
#
# Data (the SQLite DB + uploaded attachments) lives on the large volume under
# ${DATA_DIR}/vikunja so the userland rootfs stays lean. The userland can't see
# that path directly, so it is bind-mounted into the userland at supervise time.
#
# Generalized from a working deployment; review before running.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env
require_var DOMAIN   "your public domain, e.g. example.com"
require_var DATA_DIR "folder on your large volume / SD card"
require_cmd proot-distro
require_cmd curl
require_cmd openssl

# NOTE: enabling/disabling is handled by install.sh (it only runs this script when
# ENABLE_VIKUNJA=true), so this script does not re-check the flag.

in_debian() { proot-distro login debian -- bash -lc "$1"; }

# ── Pinned release ───────────────────────────────────────────────────────────
# Pin an EXACT Vikunja version + sha256 (env-overridable) rather than tracking a
# floating release, so a corrupt or tampered download fails closed. To upgrade:
# back up ${DATA_DIR}/vikunja FIRST, then bump VIKUNJA_VERSION and VIKUNJA_SHA256
# *together* (get the new hash from the release checksums or by hashing a binary
# you already trust: sha256sum vikunja-...-linux-arm64-full).
#
# Version + sha256 copied verbatim from the reference deployment's installer.
VIKUNJA_VERSION="${VIKUNJA_VERSION:-2.3.0}"
VIKUNJA_SHA256="${VIKUNJA_SHA256:-62863bddd7d29e7437e9ea019010540c53cd71a205354952b5cd47bec28863cb}"
ZIP_NAME="vikunja-v${VIKUNJA_VERSION}-linux-arm64-full.zip"
# dl.vikunja.io is Vikunja's canonical release CDN.
VIKUNJA_URL="${VIKUNJA_URL:-https://dl.vikunja.io/vikunja/v${VIKUNJA_VERSION}/${ZIP_NAME}}"

# ── Service-local config ─────────────────────────────────────────────────────
VK_DIR="/opt/vikunja"                  # install dir INSIDE the userland
VK_PORT="${VIKUNJA_PORT:-9111}"        # loopback bind; Caddy fronts the TLS edge
VK_HOST="tasks.${DOMAIN}"              # public hostname
VK_DATA_HOST="${DATA_DIR}/vikunja"     # SQLite DB + attachments (large volume)
VK_DATA_USERLAND="/opt/vikunja/data"   # bind target inside the userland
CACHE_DIR="${DATA_DIR}/binaries"
ZIP_LOCAL="${CACHE_DIR}/${ZIP_NAME}"
SECRETS_FILE="${DATA_DIR}/secrets/vikunja.env"

mkdir -p "${CACHE_DIR}" "${DATA_DIR}/secrets" "${VK_DATA_HOST}/files"

# ── Preflight: the userland must exist ───────────────────────────────────────
in_debian 'true' >/dev/null 2>&1 || die "proot-distro debian not reachable — install the userland first (run scripts/install.sh)"

# ── 1. Download + sha256-verify the pinned zip (fail-closed, cache-aware) ─────
# fetch_verified (from common.sh) reuses a cached copy that already matches the
# pin, and deletes + aborts on any mismatch.
fetch_verified "${VIKUNJA_URL}" "${ZIP_LOCAL}" "${VIKUNJA_SHA256}"
ok "vikunja v${VIKUNJA_VERSION} zip ready at ${ZIP_LOCAL} ($(wc -c < "${ZIP_LOCAL}") bytes)"

# ── 2. Unzip + install the single binary into the userland ───────────────────
# The "-full" zip bundles the (multi-MB) binary plus a small .sha256 + LICENSE, so
# we select the only real (>1M) vikunja* file and exclude the checksum/signature.
# Unzipping happens INSIDE the userland (it has its own unzip, and the binary must
# match the userland's glibc/arch — proot-Debian is arm64 like the host).
say "installing the vikunja binary into the userland (${VK_DIR}/vikunja)"
in_debian "command -v unzip >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y --no-install-recommends unzip; }" \
  || die "could not ensure unzip is present inside the userland"
in_debian "mkdir -p ${VK_DIR}"
# Stream the zip in over stdin so we never hardcode the rootfs path, then unpack
# + install the binary atomically inside the userland.
proot-distro login debian -- bash -lc "
  set -e
  tmpzip=\$(mktemp /tmp/vikunja.XXXXXX.zip)
  cat > \"\$tmpzip\"
  tmpdir=\$(mktemp -d /tmp/vikunja-unzip.XXXXXX)
  unzip -o \"\$tmpzip\" -d \"\$tmpdir\" >/dev/null
  bin=\$(find \"\$tmpdir\" -maxdepth 2 -type f -name 'vikunja*' ! -name '*.sha256' ! -name '*.asc' -size +1M | head -1)
  [ -n \"\$bin\" ] || { echo 'could not find the vikunja binary in the zip' >&2; exit 30; }
  install -m 0755 \"\$bin\" ${VK_DIR}/vikunja
  rm -rf \"\$tmpdir\" \"\$tmpzip\"
" < "${ZIP_LOCAL}" || die "failed to unpack/install the vikunja binary into the userland"

# Verify the installed binary actually runs inside the userland (fail closed).
ver="$(in_debian "${VK_DIR}/vikunja version 2>&1 | head -1" || true)"
[ -n "${ver}" ] || die "the vikunja binary did not run inside the userland"
ok "vikunja installed: ${ver}"

# ── 3. Create the data dirs (DB + files on the large volume) ─────────────────
# The DB + attachments live on ${DATA_DIR}; the userland sees them via a bind
# mount created at supervise time (proot-distro login --bind). We create both the
# in-userland mountpoint AND the backing dir on the volume.
in_debian "mkdir -p ${VK_DATA_USERLAND}/files" || die "failed to create ${VK_DATA_USERLAND} in the userland"
mkdir -p "${VK_DATA_HOST}/files"
ok "vikunja data backing dir ready: ${VK_DATA_HOST} (bind-mounted at start time)"

# ── 4. Generate + persist Vikunja's own service/JWT secrets ──────────────────
# Vikunja signs its OWN API JWTs (service.JWTSecret) and HMACs links/invites
# (service.secret). If left blank it regenerates random ones per boot, which logs
# every user out on each restart. These are PER-DEPLOYMENT secrets (not shared
# operator credentials): generate once, persist under ${DATA_DIR}/secrets (600),
# and reuse on every re-run. NEVER hardcode them.
if [ -f "${SECRETS_FILE}" ]; then
  # shellcheck disable=SC1090
  . "${SECRETS_FILE}"
  say "reusing vikunja service/JWT secrets from ${SECRETS_FILE}"
else
  VIKUNJA_SERVICE_SECRET="$(openssl rand -hex 32)"
  VIKUNJA_JWT_SECRET="$(openssl rand -hex 32)"
  umask 077
  cat > "${SECRETS_FILE}" <<EOF
# Per-deployment Vikunja secrets — generated by apps/vikunja.sh. Keep private.
# Deleting this file invalidates every active session on the next restart.
VIKUNJA_SERVICE_SECRET=${VIKUNJA_SERVICE_SECRET}
VIKUNJA_JWT_SECRET=${VIKUNJA_JWT_SECRET}
EOF
  chmod 600 "${SECRETS_FILE}"
  ok "generated vikunja service/JWT secrets → ${SECRETS_FILE} (chmod 600)"
fi
VIKUNJA_SERVICE_SECRET="${VIKUNJA_SERVICE_SECRET:-}"
VIKUNJA_JWT_SECRET="${VIKUNJA_JWT_SECRET:-}"
[ -n "${VIKUNJA_SERVICE_SECRET}" ] && [ -n "${VIKUNJA_JWT_SECRET}" ] \
  || die "vikunja service/JWT secrets are empty — check ${SECRETS_FILE}"

# ── 5. Hardened config.yml (interpolates the secrets; written into userland) ──
# Bound to loopback only; Caddy fronts the public TLS edge. Self-signup is OFF and
# local login is ON, so the default front door is: gate tasks.${DOMAIN} at the
# Cloudflare edge (Cloudflare Access) + log in with a Vikunja account an admin
# creates from inside the app. There is intentionally NO auth.openid block here —
# Matrix-SSO single sign-on is an optional add-on documented in docs/APP_AUTH.md.
say "writing hardened ${VK_DIR}/config.yml"
proot-distro login debian -- bash -lc "umask 077; cat > ${VK_DIR}/config.yml" <<EOF
# Generated by apps/vikunja.sh — hardened, single-tenant deploy.
service:
  # Public origin (used for CORS, absolute links, CalDAV discovery).
  publicurl: "https://${VK_HOST}/"
  # Random-but-persistent secrets (else every restart logs everyone out).
  secret: "${VIKUNJA_SERVICE_SECRET}"
  JWTSecret: "${VIKUNJA_JWT_SECRET}"
  # Self-signup OFF — an admin creates accounts from inside Vikunja.
  enableregistration: false
  # No public task lists / link shares unless an authed user opts in per project.
  enablepublicteams: false
  enabletaskattachments: true
  enabletaskcomments: true
  enableemailreminders: false
  timezone: ${TZ}
  # Bind loopback only; Caddy fronts the public TLS edge.
  interface: "127.0.0.1:${VK_PORT}"

database:
  type: sqlite
  path: "${VK_DATA_USERLAND}/vikunja.db"

files:
  basepath: "${VK_DATA_USERLAND}/files"
  maxsize: 20MB

cors:
  enable: true
  origins:
    - "https://${VK_HOST}"

log:
  level: INFO
  database: false
  http: false

auth:
  # Native username/password login stays ON: with self-signup off and the public
  # hostname gated at the Cloudflare edge, this is the default way in. (Optional:
  # add an auth.openid provider to wire Matrix-SSO — see docs/APP_AUTH.md.)
  local:
    enabled: true
EOF
in_debian "chmod 600 ${VK_DIR}/config.yml" || true
ok "wrote ${VK_DIR}/config.yml (chmod 600)"

# ── 6. migrate-then-exec launcher (run inside the userland) ──────────────────
# The supervisor bind-mounts ${DATA_DIR}/vikunja into the userland at
# ${VK_DATA_USERLAND} BEFORE this runs; config.yml points the DB + files there.
# `vikunja migrate` is idempotent (a no-op when the schema is current) and MUST
# run before serving, so the launcher migrates then execs the server.
say "writing ${VK_DIR}/run.sh launcher"
proot-distro login debian -- bash -lc "cat > ${VK_DIR}/run.sh" <<LAUNCH
#!/bin/bash
# Runs INSIDE the Debian userland; started + kept alive by apps/vikunja.sh.
# Serves the bundled API + frontend on 127.0.0.1:${VK_PORT} (config.yml interface).
set -u
cd ${VK_DIR} || exit 1
export VIKUNJA_SERVICE_ROOTPATH=${VK_DIR}
mkdir -p ${VK_DATA_USERLAND}/files
# Idempotent schema migration (safe on every start; no-op when up to date).
./vikunja migrate || exit 20
exec ./vikunja
LAUNCH
in_debian "chmod +x ${VK_DIR}/run.sh" || die "failed to make ${VK_DIR}/run.sh executable"
ok "wrote ${VK_DIR}/run.sh"

# ── 7. Caddy vhost (self-contained site block, imported by the core Caddyfile) ─
# Matches the core Caddyfile listener style EXACTLY: explicit
# http://<host>:${CADDY_PORT} + bind ${CADDY_BIND} (plain HTTP on the shared high
# loopback port; the Cloudflare Tunnel terminates public TLS). The core Caddyfile
# imports /etc/caddy/apps/*.caddy, so dropping this file in is all it takes.
say "writing the Caddy vhost → /etc/caddy/apps/vikunja.caddy"
proot-distro login debian -- bash -lc 'mkdir -p /etc/caddy/apps && cat > /etc/caddy/apps/vikunja.caddy' <<EOF
# Vikunja (tasks / kanban) — optional app vhost for pocket-homeserver.
# Public hostname tasks.${DOMAIN}; bound to loopback (the Cloudflare Tunnel
# forwards public traffic here). By default this hostname is gated at the
# Cloudflare edge with Cloudflare Access (configured in the Cloudflare dashboard).
http://${VK_HOST}:${CADDY_PORT} {
	bind ${CADDY_BIND}

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options nosniff
		X-Frame-Options SAMEORIGIN
		Referrer-Policy no-referrer
		-Server
	}

	# OPTIONAL Matrix-SSO gateway add-on (single sign-on across apps). Disabled by
	# default — the default front door is Cloudflare Access at the edge. To enable,
	# run the optional Matrix-auth gateway and uncomment this block (see
	# docs/APP_AUTH.md). It must precede the reverse_proxy so unauthenticated
	# requests are redirected to login before reaching Vikunja.
	# forward_auth 127.0.0.1:9095 {
	# 	uri /authgw/verify
	# 	copy_headers Remote-User
	# }

	reverse_proxy 127.0.0.1:${VK_PORT}
}
EOF
ok "wrote /etc/caddy/apps/vikunja.caddy"

# Validate the FULL Caddyfile inside the userland (fail closed). We do NOT restart
# Caddy here — print the restart hint instead so an already-running stack picks up
# the new vhost on the operator's schedule.
say "validating the Caddyfile inside the userland"
in_debian 'caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile' \
  || die "caddy validate FAILED — refusing to leave a broken vhost in place (removed nothing; fix /etc/caddy/apps/vikunja.caddy)"
ok "Caddyfile still valid with the vikunja vhost added"

# ── 8. Supervise the service ─────────────────────────────────────────────────
# The shared supervisor (respawn loop + identity-checked pidfile) runs the
# migrate-then-exec launcher inside the userland, with the large-volume data dir
# bind-mounted in so the SQLite DB + attachments land on ${DATA_DIR}.
supervise vikunja -- \
  proot-distro login debian \
  --bind "${VK_DATA_HOST}:${VK_DATA_USERLAND}" \
  -- bash "${VK_DIR}/run.sh"

# ── Closing notes ─────────────────────────────────────────────────────────────
echo
ok "Vikunja installed + supervised (loopback 127.0.0.1:${VK_PORT}; data on ${VK_DATA_HOST})"
say "Liveness (public, unauthenticated): curl -sf http://127.0.0.1:${VK_PORT}/api/v1/info"
echo
say "Manual Cloudflare steps (in the Cloudflare dashboard — NOT done by this script):"
say "  1. In the Tunnel config, add a Public Hostname:"
say "       ${VK_HOST}  ->  http://localhost:${CADDY_PORT}  (the local Caddy edge)"
say "  2. Add a Cloudflare Access policy (Zero Trust) protecting ${VK_HOST} so only"
say "     your chosen identities can reach it (this is the default front door)."
say "  If the core stack is already running, pick up the new vhost with:"
say "       bash ${POCKET_ROOT}/scripts/start-stack.sh --restart"
say "  (brief ingress outage while cloudflared cycles)."

# Generalized from a working deployment; review before running.
