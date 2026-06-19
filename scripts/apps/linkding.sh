#!/usr/bin/env bash
#
# apps/linkding.sh — install + supervise Linkding (self-hosted bookmark manager)
# as an OPTIONAL app behind the loopback Caddy edge.
#
# Linkding is a Django web app. There is no single arm64 binary to download (the
# upstream project ships a Docker image, not a release tarball), so we build it
# from the pinned upstream git tag INTO a Python virtualenv at /opt/linkding
# inside the Debian userland, and serve it with gunicorn on
# ${CADDY_BIND}:${LINKDING_PORT}. The core Caddy fronts it; the public hostname
# is links.${DOMAIN}.
#
# What it does (idempotent — safe to re-run):
#   1. ensures the build/runtime apt deps + a Python venv inside the userland and
#      installs Linkding (pinned tag v${LINKDING_VERSION}) into /opt/linkding/.venv,
#   2. builds the frontend static bundle (npm) and runs `collectstatic`,
#   3. generates + persists a Django SECRET_KEY under
#      ${DATA_DIR}/secrets/linkding.env (chmod 600; reused on re-run) so sessions
#      + CSRF tokens are NOT invalidated on every restart,
#   4. runs DB migrations (idempotent) and creates the initial superuser from
#      ${ADMIN_USER}/${ADMIN_PASSWORD} (idempotent — a no-op if it already exists),
#   5. writes a self-contained Caddy vhost to /etc/caddy/apps/linkding.caddy and
#      validates the full Caddyfile fail-closed (it does NOT restart Caddy),
#   6. supervises the gunicorn web service AND a background-task worker (favicons +
#      link preview images) via the shared lib (respawn + identity-checked pid).
#
# AUTH MODEL (default): Linkding keeps its OWN native Django login. Open
# registration is OFF by default in Linkding (LD_ENABLE_REGISTRATION unset), so
# accounts are created only by an admin — we create one initial superuser from
# ${ADMIN_USER}/${ADMIN_PASSWORD}. The public hostname is additionally gated at
# the Cloudflare edge with Cloudflare Access (a policy you add in the Cloudflare
# dashboard — NOT configured by this script). An optional Matrix-SSO gateway
# add-on (single sign-on across apps) is documented in docs/APP_AUTH.md; its
# hooks are present here only as a COMMENTED-OUT block in the Caddy vhost.
#
# Data (the SQLite DB, the persisted SECRET_KEY, favicons + preview images) lives
# on the large volume under ${DATA_DIR}/linkding so the userland rootfs stays
# lean. The userland can't see that path directly, so it is bind-mounted into the
# userland at /opt/linkding/data at supervise time.
#
# Generalized from a working deployment; review before running.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env
require_var DOMAIN         "your public domain, e.g. example.com"
require_var DATA_DIR       "folder on your large volume / SD card"
require_var ADMIN_PASSWORD "the initial Linkding superuser password (set in .env)"
require_cmd proot-distro

# NOTE: enabling/disabling is handled by install.sh (it only runs this script when
# ENABLE_LINKDING=true), so this script does not re-check the flag.

in_debian() { proot-distro login debian -- bash -lc "$1"; }

# ── Pinned release ───────────────────────────────────────────────────────────
# Pin an EXACT upstream git tag (env-overridable) rather than tracking a floating
# branch, so an upgrade is a deliberate bump (and the new-member / source patches
# noted in docs/LINKDING-style notes can be re-reviewed). Version copied verbatim
# from the reference deployment (the upstream clone's version.txt = 1.45.0, git
# tag v1.45.0). Upstream ships NO release tarball + NO published sha256 for a
# source build — it distributes a Docker image — so there is no fetch_verified
# pin here; integrity is the pinned git tag fetched over HTTPS from the canonical
# repo. (Do NOT invent a sha256.)
LINKDING_VERSION="${LINKDING_VERSION:-1.45.0}"
LINKDING_REPO="${LINKDING_REPO:-https://github.com/sissbruecker/linkding.git}"
LINKDING_TAG="${LINKDING_TAG:-v${LINKDING_VERSION}}"

# ── Service-local config ─────────────────────────────────────────────────────
LD_DIR="/opt/linkding"                 # install dir INSIDE the userland (git tree + .venv)
LD_PORT="${LINKDING_PORT:-9090}"       # loopback bind; Caddy fronts the TLS edge
LD_HOST="links.${DOMAIN}"              # public hostname
LD_DATA_HOST="${DATA_DIR}/linkding"    # SQLite DB + SECRET_KEY + favicons/previews (large volume)
LD_DATA_USERLAND="${LD_DIR}/data"      # bind target inside the userland (Linkding's fixed data dir)
SECRETS_FILE="${DATA_DIR}/secrets/linkding.env"

# Linkding's prod settings module + the canonical superuser env contract.
LD_SETTINGS="bookmarks.settings.prod"

mkdir -p "${DATA_DIR}/secrets" "${LD_DATA_HOST}/favicons" "${LD_DATA_HOST}/previews"

# ── Preflight: the userland must exist ───────────────────────────────────────
in_debian 'true' >/dev/null 2>&1 || die "proot-distro debian not reachable — install the userland first (run scripts/install.sh)"

# ── 1. Build/runtime deps inside the userland ────────────────────────────────
# Linkding ${LINKDING_VERSION} requires Python >= 3.13 and Django 6.0; build it
# from source into a venv. git fetches the pinned tag, npm builds the frontend
# bundle, and pip installs the project + its deps. (build-essential/pkg-config/
# libffi/libssl/libicu are needed to compile a few wheels.) UNCERTAINTY: this
# expects the userland's Debian to provide python3 >= 3.13 — confirm with
# `proot-distro login debian -- python3 --version`; on older Debian you may need
# a backport / pyenv. This step does not pin python itself.
run_once linkding-apt -- in_debian \
  "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
     git python3 python3-venv python3-dev \
     build-essential pkg-config libffi-dev libssl-dev libicu-dev libsqlite3-dev \
     nodejs npm curl ca-certificates" \
  || die "could not install Linkding build/runtime deps inside the userland"

# Verify the userland python is new enough (fail closed with a clear message).
in_debian "python3 -c 'import sys; raise SystemExit(0 if sys.version_info[:2] >= (3,13) else 1)'" \
  || die "userland python3 is older than 3.13 ($(in_debian 'python3 --version' 2>/dev/null)) — Linkding ${LINKDING_VERSION} needs >=3.13; upgrade the userland or pin LINKDING_VERSION to a version that supports your python"

# ── 2. Fetch the pinned source + build the venv + frontend (run inside userland) ─
# Idempotent: clone-or-fetch to the exact tag, (re)create the venv only if absent,
# build the JS bundle, then `pip install .` (project + deps from pyproject.toml).
# gunicorn is installed explicitly because it is NOT a Linkding dependency (the
# reference deployment serves with gunicorn rather than upstream's uwsgi).
say "building Linkding ${LINKDING_VERSION} into ${LD_DIR} (git + venv + frontend; first run is slow)"
in_debian "
  set -e
  if [ -d '${LD_DIR}/.git' ]; then
    git -C '${LD_DIR}' fetch --depth 1 origin tag '${LINKDING_TAG}'
  else
    rm -rf '${LD_DIR}'
    git clone --depth 1 --branch '${LINKDING_TAG}' '${LINKDING_REPO}' '${LD_DIR}'
  fi
  cd '${LD_DIR}'
  git -C '${LD_DIR}' checkout -q '${LINKDING_TAG}'
  # Build the frontend static bundle (Linkding ships none prebuilt in the tree).
  if [ ! -f '${LD_DIR}/.frontend-built' ] || [ -n \"\$(git -C '${LD_DIR}' status --porcelain rollup.config.mjs package.json 2>/dev/null)\" ]; then
    npm ci
    npm run build
    : > '${LD_DIR}/.frontend-built'
  fi
  # Python venv + project install (pip, not uv — more portable). Re-runs are cheap.
  [ -x '${LD_DIR}/.venv/bin/python' ] || python3 -m venv '${LD_DIR}/.venv'
  '${LD_DIR}/.venv/bin/pip' install --upgrade pip wheel >/dev/null
  '${LD_DIR}/.venv/bin/pip' install '${LD_DIR}'
  # gunicorn is the WSGI server we run (not a Linkding dependency); install it too.
  '${LD_DIR}/.venv/bin/pip' install gunicorn
" 2>&1 | grep -v 'proot warning' || die "Linkding build failed inside the userland (see output above)"

# Fail closed: the build tree + venv binaries must exist.
in_debian "[ -f '${LD_DIR}/manage.py' ] && [ -x '${LD_DIR}/.venv/bin/python' ] && [ -x '${LD_DIR}/.venv/bin/gunicorn' ]" \
  || die "Linkding build tree incomplete at ${LD_DIR} (need manage.py + .venv/bin/{python,gunicorn})"
ok "Linkding ${LINKDING_VERSION} built at ${LD_DIR}"

# ── 3. Create the data dirs (DB + SECRET_KEY + favicons/previews on the volume) ─
# Linkding's data dir is fixed at <install>/data. The userland sees the large
# volume there via a bind mount created at supervise time (proot-distro login
# --bind). We create both the in-userland mountpoint AND the backing dir.
in_debian "mkdir -p '${LD_DATA_USERLAND}/favicons' '${LD_DATA_USERLAND}/previews'" \
  || die "failed to create ${LD_DATA_USERLAND} in the userland"
mkdir -p "${LD_DATA_HOST}/favicons" "${LD_DATA_HOST}/previews"
ok "Linkding data backing dir ready: ${LD_DATA_HOST} (bind-mounted at ${LD_DATA_USERLAND} at start time)"

# ── 4. Generate + persist a Django SECRET_KEY ────────────────────────────────
# Linkding's prod settings mint a RANDOM secret key per worker start unless one is
# supplied, which logs every user out + breaks CSRF on each restart. This is a
# PER-DEPLOYMENT secret (not a shared operator credential): generate once, persist
# under ${DATA_DIR}/secrets (600), reuse on every re-run. NEVER hardcode it.
# Linkding reads it from data/secretkey.txt (under the bind-mounted data dir), so
# we ALSO write it there; the secrets/ copy is the durable source of truth.
if [ -f "${SECRETS_FILE}" ]; then
  # shellcheck disable=SC1090
  . "${SECRETS_FILE}"
  say "reusing Linkding SECRET_KEY from ${SECRETS_FILE}"
else
  LINKDING_SECRET_KEY="$(in_debian "${LD_DIR}/.venv/bin/python -c 'from django.core.management.utils import get_random_secret_key; print(get_random_secret_key())'" 2>/dev/null | tr -d '\r')"
  [ -n "${LINKDING_SECRET_KEY}" ] || die "failed to generate a Django SECRET_KEY inside the userland"
  umask 077
  cat > "${SECRETS_FILE}" <<EOF
# Per-deployment Linkding Django SECRET_KEY — generated by apps/linkding.sh.
# Keep private. Deleting this file logs every user out on the next restart.
LINKDING_SECRET_KEY=${LINKDING_SECRET_KEY}
EOF
  chmod 600 "${SECRETS_FILE}"
  ok "generated Linkding SECRET_KEY → ${SECRETS_FILE} (chmod 600)"
fi
[ -n "${LINKDING_SECRET_KEY:-}" ] || die "Linkding SECRET_KEY is empty — check ${SECRETS_FILE}"

# Drop the key into the data dir Linkding reads (idempotent; 600). Written to the
# backing dir on the large volume so it survives even before the first bind-mount.
printf '%s\n' "${LINKDING_SECRET_KEY}" > "${LD_DATA_HOST}/secretkey.txt"
chmod 600 "${LD_DATA_HOST}/secretkey.txt" 2>/dev/null || true

# ── 5. Migrate + collectstatic + create the initial superuser (idempotent) ────
# Run inside the userland with the data dir bind-mounted so the SQLite DB lands on
# the large volume. `migrate` + `enable_wal` + `collectstatic` are idempotent;
# `create_initial_superuser` reads LD_SUPERUSER_NAME/LD_SUPERUSER_PASSWORD and is a
# no-op if that user already exists, so re-runs never crash. WAL keeps the web +
# background-task workers' concurrent SQLite access safe.
say "running migrate / enable_wal / collectstatic / create_initial_superuser inside the userland"
proot-distro login debian \
  --bind "${LD_DATA_HOST}:${LD_DATA_USERLAND}" \
  -- bash -lc "
    set -u
    cd '${LD_DIR}' || exit 1
    export DJANGO_SETTINGS_MODULE='${LD_SETTINGS}'
    export LD_CSRF_TRUSTED_ORIGINS='https://${LD_HOST}'
    export LD_DISABLE_BACKGROUND_TASKS=False
    export LD_SUPERUSER_NAME='${ADMIN_USER:-admin}'
    export LD_SUPERUSER_PASSWORD='${ADMIN_PASSWORD}'
    .venv/bin/python manage.py check        || exit 11
    .venv/bin/python manage.py migrate --noinput || exit 12
    .venv/bin/python manage.py enable_wal   || exit 13
    .venv/bin/python manage.py collectstatic --noinput || exit 14
    .venv/bin/python manage.py create_initial_superuser || exit 15
    # Harden the DB + secret-key perms (defence in depth).
    chmod 600 data/db.sqlite3 2>/dev/null || true
    for ext in -wal -shm; do [ -f \"data/db.sqlite3\$ext\" ] && chmod 600 \"data/db.sqlite3\$ext\"; done
    chmod 600 data/secretkey.txt 2>/dev/null || true
  " 2>&1 | grep -v 'proot warning' || die "Linkding init failed (migrate/collectstatic/superuser — see output above)"
ok "Linkding init done (DB + static + superuser '${ADMIN_USER:-admin}')"

# ── 6. Write the in-userland gunicorn + background-worker launchers ───────────
# Kept as files inside the userland to avoid nested-quoting through
# supervise→bash -c→proot-distro→bash -c. The web launcher binds loopback only
# (Caddy fronts the public TLS edge), 1 worker / 4 gthread threads (>1 worker
# deadlocks SQLite + the in-process huey queue). The worker launcher runs
# `run_huey` (favicons + og:image preview fetches; pure requests, no headless
# browser). Background tasks are ENABLED; WAL (set above) keeps web+worker SQLite
# access safe. The SECRET_KEY is read from data/secretkey.txt by prod settings.
say "writing ${LD_DIR}/run-gunicorn.sh + ${LD_DIR}/run-huey.sh launchers"
proot-distro login debian -- bash -lc "umask 077; cat > '${LD_DIR}/run-gunicorn.sh'" <<LAUNCH
#!/bin/bash
# Runs INSIDE the Debian userland; started + kept alive by apps/linkding.sh.
# Serves Linkding on 127.0.0.1:${LD_PORT}; Caddy fronts the public TLS edge.
cd ${LD_DIR} || exit 1
export DJANGO_SETTINGS_MODULE=${LD_SETTINGS}
export LD_CSRF_TRUSTED_ORIGINS=https://${LD_HOST}
export LD_USE_X_FORWARDED_HOST=True
export LD_DISABLE_BACKGROUND_TASKS=False
export LD_REQUEST_TIMEOUT=30
export LD_DISABLE_REQUEST_LOGS=True
# Native Django login stays ON; open self-registration stays OFF (default) so an
# admin creates accounts. The optional Matrix-SSO gateway add-on (mozilla-django
# -oidc) is documented in docs/APP_AUTH.md and intentionally NOT wired here.
exec .venv/bin/gunicorn \\
  --bind 127.0.0.1:${LD_PORT} \\
  --workers 1 --threads 4 --worker-class gthread \\
  --timeout 60 --graceful-timeout 30 \\
  --max-requests 500 --max-requests-jitter 100 \\
  --preload \\
  --access-logfile - --error-logfile - --log-level info \\
  --name linkding \\
  bookmarks.wsgi:application
LAUNCH
in_debian "chmod +x '${LD_DIR}/run-gunicorn.sh'" || die "failed to make ${LD_DIR}/run-gunicorn.sh executable"

proot-distro login debian -- bash -lc "umask 077; cat > '${LD_DIR}/run-huey.sh'" <<LAUNCH
#!/bin/bash
# Runs INSIDE the Debian userland; background-task worker (favicons + previews).
# Consumes the SqliteHuey queue the web worker enqueues to. No network port.
cd ${LD_DIR} || exit 1
export DJANGO_SETTINGS_MODULE=${LD_SETTINGS}
export LD_DISABLE_BACKGROUND_TASKS=False
export HOME=/tmp/home
mkdir -p /tmp/home
exec .venv/bin/python manage.py run_huey -f
LAUNCH
in_debian "chmod +x '${LD_DIR}/run-huey.sh'" || die "failed to make ${LD_DIR}/run-huey.sh executable"
ok "wrote the gunicorn + huey launchers"

# ── 7. Caddy vhost (self-contained site block, imported by the core Caddyfile) ─
# Matches the core Caddyfile listener style EXACTLY: explicit
# http://<host>:${CADDY_PORT} + bind ${CADDY_BIND} (plain HTTP on the shared high
# loopback port; the Cloudflare Tunnel terminates public TLS). The core Caddyfile
# imports /etc/caddy/apps/*.caddy, so dropping this file in is all it takes.
#
# Linkding ships no WhiteNoise and gunicorn won't serve static with DEBUG=0, so
# Caddy serves /static/* directly from the collected static dir + the favicons/
# previews dirs (a 3-dir overlay), and proxies everything else to gunicorn.
# NOTE: Referrer-Policy is strict-origin-when-cross-origin (NOT no-referrer):
# no-referrer makes Chromium send `Origin: null` on form POSTs, which Django's
# strict CSRF rejects.
say "writing the Caddy vhost → /etc/caddy/apps/linkding.caddy"
proot-distro login debian -- bash -lc 'mkdir -p /etc/caddy/apps && cat > /etc/caddy/apps/linkding.caddy' <<EOF
# Linkding (bookmark manager) — optional app vhost for pocket-homeserver.
# Public hostname links.${DOMAIN}; bound to loopback (the Cloudflare Tunnel
# forwards public traffic here). Linkding self-authenticates with its own Django
# login; by default this hostname is ALSO gated at the Cloudflare edge with
# Cloudflare Access (configured in the Cloudflare dashboard).
http://${LD_HOST}:${CADDY_PORT} {
	bind ${CADDY_BIND}

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options nosniff
		X-Frame-Options DENY
		# strict-origin-when-cross-origin (NOT no-referrer): no-referrer makes
		# Chromium send 'Origin: null' on form POSTs, which Django CSRF rejects.
		Referrer-Policy strict-origin-when-cross-origin
		-Server
	}

	# /static serves a 3-dir overlay (app assets, then favicons, then preview
	# images), mirroring Linkding's own static map. MUST precede the proxy so
	# /static/* never reaches gunicorn. Favicons/previews live under the
	# bind-mounted data dir; collected app assets under ${LD_DIR}/static.
	handle_path /static/* {
		@ld_favicon file {
			root ${LD_DATA_USERLAND}/favicons
		}
		handle @ld_favicon {
			root * ${LD_DATA_USERLAND}/favicons
			header Cache-Control "public, max-age=86400"
			file_server
		}
		@ld_preview file {
			root ${LD_DATA_USERLAND}/previews
		}
		handle @ld_preview {
			root * ${LD_DATA_USERLAND}/previews
			header Cache-Control "public, max-age=86400"
			file_server
		}
		handle {
			root * ${LD_DIR}/static
			header Cache-Control "public, max-age=86400"
			file_server
		}
	}

	# /health stays PUBLIC (unauthenticated) — health probes must not be bounced.
	handle /health {
		reverse_proxy 127.0.0.1:${LD_PORT} {
			header_up Host {http.request.host}
			header_up X-Forwarded-Proto https
		}
	}

	# OPTIONAL Matrix-SSO gateway add-on (single sign-on across apps). Disabled by
	# default — the default front door is Linkding's native login + Cloudflare
	# Access at the edge. To enable, run the optional Matrix-auth gateway and
	# uncomment this block (see docs/APP_AUTH.md). The three parts MUST sit before
	# the catch-all handle (after the public /health block above): the /authgw/*
	# handler keeps the login form reachable (else the 302-to-login loops), the
	# request_header strips any client-forged Remote-User before the gate, and
	# forward_auth then gates everything else.
	# handle /authgw/* {
	# 	reverse_proxy 127.0.0.1:9095 {
	# 		header_up X-Real-IP {client_ip}
	# 	}
	# }
	# request_header -Remote-User
	# forward_auth 127.0.0.1:9095 {
	# 	uri /authgw/verify
	# 	copy_headers Remote-User
	# }

	# Everything else → gunicorn (Django). Host + proto forwarded so Django builds
	# correct absolute URLs and CSRF accepts the origin.
	handle {
		reverse_proxy 127.0.0.1:${LD_PORT} {
			header_up Host {http.request.host}
			header_up X-Forwarded-Proto https
		}
	}
}
EOF
ok "wrote /etc/caddy/apps/linkding.caddy"

# Validate the FULL Caddyfile inside the userland (fail closed). We do NOT restart
# Caddy here — print the restart hint instead so an already-running stack picks up
# the new vhost on the operator's schedule.
say "validating the Caddyfile inside the userland"
in_debian 'caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile' \
  || die "caddy validate FAILED — refusing to leave a broken vhost in place (fix /etc/caddy/apps/linkding.caddy)"
ok "Caddyfile still valid with the linkding vhost added"

# ── 8. Supervise the web service + the background-task worker ─────────────────
# The shared supervisor (respawn loop + identity-checked pidfile) runs each
# launcher inside the userland with the large-volume data dir bind-mounted in so
# the SQLite DB + favicons/previews land on ${DATA_DIR}.
supervise linkding -- \
  proot-distro login debian \
  --bind "${LD_DATA_HOST}:${LD_DATA_USERLAND}" \
  -- bash "${LD_DIR}/run-gunicorn.sh"

supervise linkding-tasks -- \
  proot-distro login debian \
  --bind "${LD_DATA_HOST}:${LD_DATA_USERLAND}" \
  -- bash "${LD_DIR}/run-huey.sh"

# ── Closing notes ─────────────────────────────────────────────────────────────
echo
ok "Linkding installed + supervised (web 127.0.0.1:${LD_PORT}; data on ${LD_DATA_HOST})"
say "Liveness (public, unauthenticated): curl -sf http://127.0.0.1:${LD_PORT}/health"
say "Initial superuser: '${ADMIN_USER:-admin}' (password from .env ADMIN_PASSWORD) — change it after first login."
echo
say "Manual Cloudflare steps (in the Cloudflare dashboard — NOT done by this script):"
say "  1. In the Tunnel config, add a Public Hostname:"
say "       ${LD_HOST}  ->  http://localhost:${CADDY_PORT}  (the local Caddy edge, plain HTTP)"
say "  2. Add a Cloudflare Access policy (Zero Trust) protecting ${LD_HOST} so only"
say "     your chosen identities can reach it (Linkding's own login is the inner gate)."
say "  If the core stack is already running, pick up the new vhost with:"
say "       bash ${POCKET_ROOT}/scripts/start-stack.sh --restart"
say "  (brief ingress outage while cloudflared cycles)."

# Generalized from a working deployment; review before running.
