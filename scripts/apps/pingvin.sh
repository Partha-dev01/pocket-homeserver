#!/usr/bin/env bash
#
# apps/pingvin.sh — build + install + supervise Pingvin Share (self-hosted file
# sharing) as an OPTIONAL app behind the loopback Caddy edge.
#
# Pingvin Share is a NestJS backend + a Next.js frontend. There is no arm64
# release binary, so it is BUILT FROM SOURCE on-device from a pinned upstream tag.
# The backend serves on 127.0.0.1:8080, the frontend on 127.0.0.1:3333; the core
# Caddy fronts both (splitting /api/* to the backend) at share.${DOMAIN}.
#
# ⚠ FIRST RUN IS VERY SLOW: two `npm install`s + a Next.js build + a Nest build +
# `prisma generate` on a phone can take 15–40+ minutes and is the heaviest step in
# the whole stack. Re-runs skip the build (idempotent). The build caps the V8 heap
# so it cannot OOM-kill the live Matrix/Caddy stack while it runs.
#
# ⚠ SECURITY — LOOPBACK BIND PATCH (fail-closed). Upstream's backend main.ts calls
# `app.listen(port)` with NO host argument, so NestJS/Express defaults to 0.0.0.0
# (ALL interfaces) — which would expose the backend on the phone's LAN. This script
# patches main.ts to bind 127.0.0.1 (honoring BIND_HOST) and ABORTS the build if the
# patch cannot be applied, rather than ever shipping a 0.0.0.0-binding backend.
#
# AUTH MODEL (default): Pingvin keeps its OWN native account login (username +
# password). The initial admin is seeded from .env (ADMIN_USER / ADMIN_PASSWORD).
# Self-registration is OFF, and the public hostname is additionally gated at the
# Cloudflare edge with Cloudflare Access (a policy you add in the Cloudflare
# dashboard — NOT configured by this script). An optional Matrix-SSO gateway add-on
# (single sign-on across apps) is documented in docs/APP_AUTH.md; its hooks are
# present here only as a COMMENTED-OUT block in the Caddy vhost.
#
# DATA: uploaded files live on the large volume under ${DATA_DIR}/pingvin/uploads
# (bind-mounted into the userland at /opt/pingvin/data/uploads — uploads can be
# many GB). The SQLite DB stays on the userland rootfs (ext4) for reliable SQLite
# locking — back it up separately; it does NOT live on ${DATA_DIR}.
#
# Generalized from a working deployment; review before running on a fresh phone.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env
require_var DOMAIN         "your public domain, e.g. example.com"
require_var DATA_DIR       "folder on your large volume / SD card"
require_var ADMIN_PASSWORD "the initial Pingvin admin password (set in .env)"
require_cmd proot-distro

# NOTE: enabling/disabling is handled by install.sh (it only runs this script when
# ENABLE_PINGVIN=true), so this script does not re-check the flag.

in_debian() { proot-distro login debian -- bash -lc "$1"; }

# ── Pinned release ───────────────────────────────────────────────────────────
# Pingvin is built from a PINNED upstream git tag (env-overridable). Upstream
# distributes Docker images / a source tree, not a release tarball with a published
# sha256, so integrity here is the pinned tag fetched over HTTPS from the canonical
# repo (do NOT invent a sha256). To upgrade: back up the DB + ${DATA_DIR}/pingvin
# FIRST, then bump PINGVIN_TAG and re-run (the loopback patch re-applies, fail-closed).
PINGVIN_TAG="${PINGVIN_TAG:-v1.19.0}"
PINGVIN_REPO="${PINGVIN_REPO:-https://github.com/smp46/pingvin-share-x.git}"

# ── Service-local config ─────────────────────────────────────────────────────
PV="/opt/pingvin"                              # install dir INSIDE the userland (git tree + build)
PV_BACKEND_PORT="${PINGVIN_BACKEND_PORT:-8080}"   # NestJS backend, loopback
PV_FRONTEND_PORT="${PINGVIN_FRONTEND_PORT:-3333}" # Next.js frontend, loopback
PV_HOST="share.${DOMAIN}"                      # public hostname
PV_APP_NAME="${PINGVIN_APP_NAME:-${DOMAIN} Share}"
PV_ADMIN_USER="${ADMIN_USER:-admin}"
PV_ADMIN_EMAIL="${PINGVIN_ADMIN_EMAIL:-${PV_ADMIN_USER}@${DOMAIN}}"
PV_UPLOADS_HOST="${DATA_DIR}/pingvin/uploads"  # uploaded files (large; on the volume)
PV_UPLOADS_USERLAND="${PV}/data/uploads"       # bind target inside the userland
PV_DBFILE="${PV}/data/pingvin-share.db"        # SQLite DB (stays on the rootfs)
MAIN_TS="${PV}/backend/src/main.ts"

mkdir -p "${PV_UPLOADS_HOST}/shares" "${PV_UPLOADS_HOST}/_temp"

# ── Preflight: the userland must exist ───────────────────────────────────────
in_debian 'true' >/dev/null 2>&1 || die "proot-distro debian not reachable — install the userland first (run scripts/install.sh)"

# ── 1. Build/runtime deps inside the userland (Node + git + a C toolchain) ────
# Pingvin's frontend/backend need Node.js + npm; native npm modules need a C
# toolchain + python3 (node-gyp). git fetches the pinned tag. (Node version note:
# Pingvin v1.19 expects a modern Node — Node 20+. Debian trixie ships a recent
# nodejs; on an older userland you may need a newer Node via NodeSource. We warn,
# not fail, since the build will surface an incompatibility loudly.)
run_once pingvin-apt -- in_debian \
  "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
     git nodejs npm ca-certificates build-essential python3 pkg-config" \
  || die "could not install Pingvin build/runtime deps inside the userland"

node_major="$(in_debian 'node -p "process.versions.node.split(\".\")[0]" 2>/dev/null' | tr -dc '0-9' || true)"
if [ -n "${node_major}" ] && [ "${node_major}" -lt 20 ] 2>/dev/null; then
  warn "userland Node is v${node_major} — Pingvin expects Node 20+. The build may fail;"
  warn "  if so, install a newer Node in the userland (e.g. via NodeSource) and re-run."
fi

# ── 2. Clone the pinned upstream tag (idempotent) ────────────────────────────
if in_debian "[ -d '${PV}/.git' ]"; then
  say "Pingvin source already present at ${PV} (reusing the clone)"
else
  say "cloning Pingvin ${PINGVIN_TAG} -> ${PV}"
  in_debian "set -e; rm -rf '${PV}'; git clone --depth 1 --branch '${PINGVIN_TAG}' '${PINGVIN_REPO}' '${PV}'" \
    || die "git clone of Pingvin ${PINGVIN_TAG} failed"
fi

# ── 3. SECURITY: bind the NestJS backend to LOOPBACK ONLY (fail-closed) ───────
# Upstream main.ts does `app.listen(port)` (defaults to 0.0.0.0). Add a host arg so
# it binds 127.0.0.1 (honoring BIND_HOST, exported by run.sh). If the upstream
# app.listen() signature ever changes so the patch can't apply, ABORT rather than
# ship a 0.0.0.0-binding (LAN-exposed) backend.
in_debian "[ -f '${MAIN_TS}' ]" || die "missing ${MAIN_TS} after clone — cannot apply the loopback bind patch"
if in_debian "grep -q 'BIND_HOST' '${MAIN_TS}'"; then
  ok "main.ts loopback patch already present (backend binds 127.0.0.1)"
else
  say "applying main.ts loopback patch (backend -> 127.0.0.1, honors BIND_HOST)"
  in_debian "sed -i 's#\\(parseInt(process.env.BACKEND_PORT || process.env.PORT || \"8080\"),\\)#\\1\\n    process.env.BIND_HOST || \"127.0.0.1\",#' '${MAIN_TS}'"
  in_debian "grep -q 'BIND_HOST' '${MAIN_TS}'" \
    || die "could not apply the main.ts loopback patch — upstream app.listen() signature changed; refusing to build a 0.0.0.0-binding backend (inspect ${MAIN_TS})"
  # Drop any stale backend build so the patched source is recompiled.
  in_debian "rm -rf '${PV}/backend/dist'"
  ok "main.ts loopback patch applied + stale backend dist cleared (forces rebuild)"
fi

# ── 4. Build the frontend (Next.js) + backend (NestJS) — heavy, idempotent ────
# proot mishandles npm cacache's concurrent atomic renames over a flaky link, so we
# serialize sockets, raise retries, cap the V8 heap (so `next build` can't OOM-kill
# the live stack), and use INCREMENTAL `npm install` (not `npm ci`, which is
# all-or-nothing). Re-runs skip a stage whose output already exists.
say "building Pingvin (this is the heaviest step — 15-40+ minutes on a phone; re-runs skip it)"
in_debian "
  set -e
  export NODE_OPTIONS='--max-old-space-size=1536'
  export NEXT_TELEMETRY_DISABLED=1 CI=1
  npm config set maxsockets 1 2>/dev/null || true
  npm config set fetch-retries 6 2>/dev/null || true
  npm config set fetch-retry-mintimeout 20000 2>/dev/null || true
  npm config set fetch-retry-maxtimeout 180000 2>/dev/null || true
  npm config set fund false 2>/dev/null || true
  npm config set audit false 2>/dev/null || true

  npm_install_retry() {
    local n=1
    while [ \$n -le 8 ]; do
      echo \"[pingvin] npm install attempt \$n (\$(pwd))\"
      if npm install --no-audit --no-fund; then return 0; fi
      npm cache clean --force 2>/dev/null || true
      n=\$((n+1))
    done
    return 1
  }

  # frontend
  cd '${PV}/frontend'
  if [ ! -d node_modules ]; then npm_install_retry || { echo 'FAIL: frontend npm install'; exit 2; }; fi
  if [ ! -f .next/BUILD_ID ] || [ ! -d .next/server ]; then npm run build || { echo 'FAIL: frontend build'; exit 3; }; fi

  # backend
  cd '${PV}/backend'
  npm_install_retry || { echo 'FAIL: backend npm install'; exit 4; }
  npx prisma generate || { echo 'FAIL: prisma generate'; exit 5; }
  if [ ! -f dist/src/main.js ]; then npm run build || { echo 'FAIL: backend build'; exit 6; }; fi
  npx tsc prisma/seed/config.seed.ts --outDir dist/prisma/seed --rootDir prisma/seed || echo 'WARN: seed tsc non-zero (often ok)'
" 2>&1 | grep -v 'proot warning' || die "Pingvin build failed inside the userland (see output above)"

# Fail closed: both build outputs must exist.
in_debian "[ -f '${PV}/backend/dist/src/main.js' ] && [ -f '${PV}/frontend/.next/BUILD_ID' ] && [ -d '${PV}/frontend/.next/server' ]" \
  || die "Pingvin build incomplete (need backend/dist/src/main.js + frontend/.next/{BUILD_ID,server})"
ok "Pingvin built (frontend .next + backend dist present)"

# ── 5. initUser seeding guard (avoid the P2002 crash loop) ───────────────────
# Pingvin re-creates the seed admin on EVERY boot unless exactly one admin exists;
# if admin-count != 1 it tries to create initUser and dies with a P2002 duplicate-
# email crash loop. So enable seeding ONLY for a genuinely fresh DB (zero admins).
INIT_USER_ENABLED=true
if in_debian "[ -f '${PV_DBFILE}' ]"; then
  INIT_USER_ENABLED=false
  admin_count="$(in_debian "cd '${PV}/backend' && DATABASE_URL='file:${PV_DBFILE}' node -e 'const{PrismaClient}=require(\"@prisma/client\");const p=new PrismaClient();p.user.count({where:{isAdmin:true}}).then(n=>{process.stdout.write(String(n));return p.\$disconnect();}).catch(()=>process.stdout.write(\"ERR\"));'" 2>/dev/null | tr -dc '0-9' || true)"
  [ "${admin_count:-}" = "0" ] && INIT_USER_ENABLED=true
  say "initUser guard: existing DB, admin-count='${admin_count:-?}' -> initUser.enabled=${INIT_USER_ENABLED}"
else
  say "initUser guard: fresh DB (no file) -> initUser.enabled=true"
fi

# ── 6. Hardened config.yaml (written into the userland, chmod 600) ────────────
# Native password login is the default front door (OIDC is OFF; SMTP/LDAP/S3 off).
# disablePassword stays FALSE: setting it true auto-redirects the sign-in form to
# OIDC, which makes sign-OUT impossible (you bounce straight back in). Self-
# registration is OFF; the initial admin is seeded from .env (see the guard above).
# The optional Matrix-SSO gateway add-on would flip oidc-enabled on — see APP_AUTH.md.
say "writing hardened ${PV}/config.yaml"
proot-distro login debian -- bash -lc "umask 077; cat > '${PV}/config.yaml'" <<EOF
# Generated by apps/pingvin.sh — hardened, single-tenant deploy.
general:
  appName: "${PV_APP_NAME}"
  appUrl: "https://${PV_HOST}"
  secureCookies: "true"
  showHomePage: "true"
  sessionDuration: 3 months
share:
  allowRegistration: "false"
  allowUnauthenticatedShares: "false"
  maxExpiration: 7 days
  shareIdLength: "8"
  maxSize: "5000000000"
  zipCompressionLevel: "9"
  chunkSize: "10000000"
  autoOpenShareModal: "false"
email:
  enableShareEmailRecipients: "false"
smtp:
  enabled: "false"
ldap:
  enabled: "false"
oauth:
  allowRegistration: "false"
  # disablePassword MUST stay false — true auto-redirects sign-in to OIDC and makes
  # sign-out impossible. The optional Matrix-SSO gateway add-on (docs/APP_AUTH.md)
  # would set the oidc-* keys below; by default OIDC is OFF and password login is on.
  disablePassword: "false"
  ignoreTotp: "false"
  github-enabled: "false"
  google-enabled: "false"
  microsoft-enabled: "false"
  discord-enabled: "false"
  oidc-enabled: "false"
s3:
  enabled: "false"
initUser:
  enabled: ${INIT_USER_ENABLED}
  username: "${PV_ADMIN_USER}"
  email: "${PV_ADMIN_EMAIL}"
  password: "${ADMIN_PASSWORD}"
  isAdmin: true
EOF
in_debian "chmod 600 '${PV}/config.yaml'" || true
ok "wrote ${PV}/config.yaml (chmod 600)"

# ── 7. run.sh launcher (backend :8080 + frontend :3333, both loopback) ────────
# The supervisor bind-mounts ${DATA_DIR}/pingvin/uploads onto /opt/pingvin/data/
# uploads BEFORE this runs. `prisma migrate deploy` + the config seed are idempotent
# and run before serving. Both processes are backgrounded; if either dies we take
# the other down so the supervisor respawns the pair cleanly.
say "writing ${PV}/run.sh launcher"
proot-distro login debian -- bash -lc "cat > '${PV}/run.sh'" <<LAUNCH
#!/bin/bash
# Runs INSIDE the Debian userland; started + kept alive by apps/pingvin.sh.
# Backend (NestJS) 127.0.0.1:${PV_BACKEND_PORT}; frontend (Next.js) 127.0.0.1:${PV_FRONTEND_PORT}.
set -u
export NODE_ENV=production
export NEXT_TELEMETRY_DISABLED=1
export CONFIG_FILE=${PV}/config.yaml
export DATA_DIRECTORY=${PV}/data
export DATABASE_URL="file:${PV_DBFILE}?connection_limit=1"
export BACKEND_PORT=${PV_BACKEND_PORT}
export BIND_HOST=127.0.0.1               # honored by the main.ts loopback patch
export API_URL=http://127.0.0.1:${PV_BACKEND_PORT}

mkdir -p ${PV}/data/uploads/shares ${PV}/data/uploads/_temp

# DB migrate + config seed (idempotent) before serving.
cd ${PV}/backend || exit 1
./node_modules/.bin/prisma migrate deploy || exit 20
node dist/prisma/seed/config.seed.js || exit 21

# backend
node dist/src/main &
BE=\$!
# frontend (next start, loopback)
cd ${PV}/frontend || exit 1
./node_modules/.bin/next start -p ${PV_FRONTEND_PORT} -H 127.0.0.1 &
FE=\$!

trap 'kill \$BE \$FE 2>/dev/null' TERM INT
# if either process dies, take the other down so the supervisor respawns both
wait -n
kill \$BE \$FE 2>/dev/null
exit 1
LAUNCH
in_debian "chmod +x '${PV}/run.sh'" || die "failed to make ${PV}/run.sh executable"
ok "wrote ${PV}/run.sh"

# ── 8. Caddy vhost (self-contained site block, imported by the core Caddyfile) ─
# Matches the core Caddyfile listener style EXACTLY: explicit
# http://<host>:${CADDY_PORT} + bind ${CADDY_BIND} (plain HTTP on the shared high
# loopback port; the Cloudflare Tunnel terminates public TLS). /api/* goes to the
# backend (flush_interval -1 + long timeouts stream large uploads/zips without
# buffering); everything else goes to the Next.js frontend. The frontend builds
# absolute redirects from its listen address, so we rewrite localhost:${PV_FRONTEND_PORT}
# in Location headers back to the public origin on the way out.
say "writing the Caddy vhost -> /etc/caddy/apps/pingvin.caddy"
proot-distro login debian -- bash -lc 'mkdir -p /etc/caddy/apps && cat > /etc/caddy/apps/pingvin.caddy' <<EOF
# Pingvin Share (file sharing) — optional app vhost for pocket-homeserver.
# Public hostname share.${DOMAIN}; bound to loopback (the Cloudflare Tunnel
# forwards public traffic here). Pingvin self-authenticates with its own account
# login; by default this hostname is ALSO gated at the Cloudflare edge with
# Cloudflare Access (configured in the Cloudflare dashboard).
http://${PV_HOST}:${CADDY_PORT} {
	bind ${CADDY_BIND}

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options nosniff
		Referrer-Policy strict-origin-when-cross-origin
		X-Frame-Options DENY
		Cross-Origin-Opener-Policy same-origin
		-Server
	}

	# OPTIONAL Matrix-SSO gateway add-on (single sign-on across apps). Disabled by
	# default — the default front door is Pingvin's own login + Cloudflare Access at
	# the edge. To enable, run the optional Matrix-auth gateway, flip the oidc-* keys
	# in config.yaml, and uncomment this block (see docs/APP_AUTH.md). It must
	# precede the catch-all so unauthenticated requests are redirected to login.
	# forward_auth 127.0.0.1:9095 {
	# 	uri /authgw/verify
	# 	copy_headers Remote-User
	# }

	# API -> NestJS backend. flush_interval -1 streams large file/zip downloads
	# without buffering; long timeouts allow big uploads.
	handle /api/* {
		reverse_proxy 127.0.0.1:${PV_BACKEND_PORT} {
			flush_interval -1
			transport http {
				read_timeout 300s
				write_timeout 300s
			}
			header_up Host {http.request.host}
			header_up X-Forwarded-Proto https
		}
	}

	# Everything else -> Next.js frontend. Rewrite the frontend's localhost-based
	# redirect Location headers back to the public origin on the way out.
	handle {
		reverse_proxy 127.0.0.1:${PV_FRONTEND_PORT} {
			header_up Host {http.request.host}
			header_up X-Forwarded-Proto https
			header_down Location "https?://localhost:${PV_FRONTEND_PORT}" "https://${PV_HOST}"
			header_down Location "https?://127\.0\.0\.1:${PV_FRONTEND_PORT}" "https://${PV_HOST}"
		}
	}
}
EOF
ok "wrote /etc/caddy/apps/pingvin.caddy"

# Validate the FULL Caddyfile inside the userland (fail closed). We do NOT restart
# Caddy here — print the restart hint instead so an already-running stack picks up
# the new vhost on the operator's schedule.
say "validating the Caddyfile inside the userland"
in_debian 'caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile' \
  || die "caddy validate FAILED — refusing to leave a broken vhost in place (fix /etc/caddy/apps/pingvin.caddy)"
ok "Caddyfile still valid with the pingvin vhost added"

# ── 9. Supervise the service ─────────────────────────────────────────────────
# The shared supervisor (respawn loop + identity-checked pidfile) runs run.sh
# inside the userland, with the large-volume uploads dir bind-mounted in. run.sh
# launches BOTH the backend and the frontend and ties their lifetimes together.
supervise pingvin -- \
  proot-distro login debian \
  --bind "${PV_UPLOADS_HOST}:${PV_UPLOADS_USERLAND}" \
  -- bash "${PV}/run.sh"

# ── Closing notes ─────────────────────────────────────────────────────────────
echo
ok "Pingvin installed + supervised (backend 127.0.0.1:${PV_BACKEND_PORT}, frontend 127.0.0.1:${PV_FRONTEND_PORT})"
say "Liveness: curl -sf http://127.0.0.1:${PV_BACKEND_PORT}/api/health  (backend);  curl -sf http://127.0.0.1:${PV_FRONTEND_PORT}/  (frontend)"
say "Initial admin: '${PV_ADMIN_USER}' / email '${PV_ADMIN_EMAIL}' (password from .env ADMIN_PASSWORD) — change it after first login."
echo
say "Manual Cloudflare steps (in the Cloudflare dashboard — NOT done by this script):"
say "  1. In the Tunnel config, add a Public Hostname:"
say "       ${PV_HOST}  ->  http://localhost:${CADDY_PORT}  (the local Caddy edge, plain HTTP)"
say "  2. Add a Cloudflare Access policy (Zero Trust) protecting ${PV_HOST}."
say "  If the core stack is already running, pick up the new vhost with:"
say "       bash ${POCKET_ROOT}/scripts/start-stack.sh --restart"
echo
warn "Uploads live on ${PV_UPLOADS_HOST}; the SQLite DB stays on the userland rootfs"
warn "    at ${PV_DBFILE} (back it up separately — it is NOT on \${DATA_DIR})."

# Generalized from a working deployment; review before running.
