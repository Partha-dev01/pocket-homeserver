#!/usr/bin/env bash
#
# apps/wallabag.sh — install + supervise Wallabag (self-hosted read-later /
# article saver) as an OPTIONAL app behind the loopback Caddy edge, on
# read.${DOMAIN}.
#
# Wallabag is a PHP/Symfony app (no single arm64 binary — pure PHP, so the same
# package runs on any CPU). We install the pinned upstream "bundled" release
# tarball (which already ships vendor/, so NO composer run on the phone) into
# /opt/wallabag inside the Debian userland and serve it with php-fpm on a
# DEDICATED loopback pool, fronted by Caddy's `php_fastcgi` (the same shape as
# FreshRSS). The Symfony front controller is web/app.php.
#
# What it does (idempotent — review before running):
#   1. installs php-fpm + the PHP extensions Wallabag needs into the userland
#      (FreshRSS's set PLUS php-bcmath + php-tidy),
#   2. downloads + sha256-verifies (fail-closed) the pinned bundled tarball and
#      extracts the CODE to /opt/wallabag WITHOUT clobbering data/ (so an upgrade
#      keeps the SQLite DB),
#   3. keeps the SQLite DB + Symfony sessions on ext4 ($HOME/.pocket/wallabag,
#      bind-mounted to /opt/wallabag/data) — NEVER on the exFAT SD card,
#   4. patches app/config/parameters.yml for SQLite + the public domain + a
#      persisted random app secret + open-registration OFF,
#   5. on a FRESH db runs `wallabag:install` then seeds the admin from
#      ${ADMIN_USER}/${ADMIN_PASSWORD} (password fed OFF-ARGV via stdin); on an
#      EXISTING db it BACKS UP the SQLite file, runs doctrine migrations, and
#      clears+warms the Symfony prod cache (the Symfony upgrade discipline),
#   6. writes a self-contained Caddy vhost + validates the full Caddyfile
#      fail-closed (it does NOT restart Caddy),
#   7. supervises php-fpm via the shared lib.
#
# AUTH MODEL (default): Wallabag keeps its OWN native login; open self-
# registration is OFF (an admin creates accounts). The browser UI is a classic
# server-rendered Symfony app, so it tolerates the interactive Cloudflare Access
# edge gate AND the optional Matrix-SSO gateway (a COMMENTED block in the vhost).
# BUT the Wallabag REST API + the official mobile app / browser extension use
# OAuth2 BEARER tokens and CANNOT follow a 302-to-login — to use those, add a
# Cloudflare Access SERVICE-TOKEN exemption for read.${DOMAIN} (operator-side, in
# the Cloudflare dashboard; this script wires nothing for it). See docs/READLATER.md.
#
# STORAGE (load-bearing): the SQLite DB is a real database with locks + WAL, so it
# MUST live on ext4. We keep data/ on the host at $HOME/.pocket/wallabag (ext4,
# survives a rootfs rebuild) and bind-mount it in; putting it on the exFAT SD
# (${DATA_DIR}) would corrupt it (no rename-over-existing, no fsync, no locks).
#
# UPLOAD CAP: the Cloudflare Tunnel caps a single request body at ~100MB — a huge
# Pocket/OPML import through the public hostname can hit it; import big files on
# loopback/LAN. See docs/READLATER.md.
#
# Generalized from the FreshRSS app pattern; review before running.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env
require_var DOMAIN         "your public domain, e.g. example.com"
require_var DATA_DIR       "folder on your large volume / SD card"
require_var ADMIN_PASSWORD "the initial Wallabag admin password (set in .env)"
require_cmd proot-distro
require_cmd openssl                       # for the random Symfony app secret

# NOTE: enabling/disabling is handled by install.sh (it only runs this script when
# ENABLE_WALLABAG=true), so this script does not re-check the flag.

in_debian() { proot-distro login debian -- bash -lc "$1"; }

# ── Pinned release ───────────────────────────────────────────────────────────
# Pin an EXACT version + sha256 (env-overridable, with config/versions.env as the
# central manifest). Upstream publishes ONLY an MD5 (on the release blog, not on
# GitHub), so the sha256 below was COMPUTED by hashing the official GitHub release
# asset (wallabag-${WALLABAG_VERSION}.tar.gz) and is the fail-closed integrity
# anchor — MD5 is collision-broken and is at best a courtesy cross-check. To
# upgrade: download the new asset, `sha256sum` it yourself, bump both together,
# then re-run (a code-only swap; data/ is preserved). The bundled tarball already
# contains vendor/, so there is NO composer step on the phone.
WALLABAG_VERSION="${WALLABAG_VERSION:-2.6.14}"
WALLABAG_SHA256="${WALLABAG_SHA256:-0049345aec597dace8e2be2c85c2b8e7744217fe15fd5303bcab3811719eff0d}"
WALLABAG_TARBALL="wallabag-${WALLABAG_VERSION}.tar.gz"
WALLABAG_URL="${WALLABAG_URL:-https://github.com/wallabag/wallabag/releases/download/${WALLABAG_VERSION}/${WALLABAG_TARBALL}}"

# ── Service coordinates ──────────────────────────────────────────────────────
WB_DIR="/opt/wallabag"                          # app root INSIDE the userland
WB_WEBROOT="${WB_DIR}/web"                       # Symfony public webroot (app.php front controller)
WB_FPM_PORT="${WALLABAG_FPM_PORT:-9119}"         # dedicated php-fpm pool; Caddy fronts the edge
WB_HOST="read.${DOMAIN}"                         # public hostname
WB_ADMIN_USER="${ADMIN_USER:-admin}"
WB_ADMIN_EMAIL="${ADMIN_EMAIL:-${WB_ADMIN_USER}@${DOMAIN}}"
BASE_URL="https://${WB_HOST}"

# DB + sessions on ext4 (NOT exFAT). The backing dir is on the HOST under
# $HOME/.pocket so it survives a rootfs rebuild and lives on a real filesystem
# (locks/perms/fsync). It is bind-mounted into the userland at /opt/wallabag/data
# both at install time and at supervise time. ── load-bearing for data integrity ──
DB_BACKING="${HOME}/.pocket/wallabag"            # on ext4 (host)
DB_MOUNT="${WB_DIR}/data"                         # in userland — Wallabag's data dir
SQLITE_REL="data/db/wallabag.sqlite"             # relative to the project dir
SQLITE_HOST="${DB_BACKING}/db/wallabag.sqlite"   # same file as seen on the host
SECRET_FILE="${DB_BACKING}/.pocket-secret"       # 0600 on ext4 — stable Symfony app secret
VERSION_STAMP="${WB_DIR}/.pocket-installed-version"

CACHE_DIR="${DATA_DIR}/binaries"
WALLABAG_LOCAL="${CACHE_DIR}/${WALLABAG_TARBALL}"
WB_FPM_CONF="${WB_DIR}/php-fpm.conf"

mkdir -p "${CACHE_DIR}"

# ── DB dir on ext4 — refuse to ever place it under DATA_DIR (exFAT) ───────────
case "${DB_BACKING}" in
  "${DATA_DIR}"|"${DATA_DIR}/"*)
    die "refusing to put the Wallabag SQLite DB under DATA_DIR (${DATA_DIR}) — it is exFAT and would corrupt the db; it must stay on ext4 at \$HOME/.pocket/wallabag" ;;
esac
mkdir -p "${DB_BACKING}/db" || die "cannot create the Wallabag data dir ${DB_BACKING} on ext4"
chmod 700 "${DB_BACKING}" 2>/dev/null || true

# ── Preflight: the userland must exist ───────────────────────────────────────
in_debian 'true' >/dev/null 2>&1 || die "proot-distro debian not reachable — install the userland first (run scripts/install.sh)"

# ── 1. php-fpm + the PHP extensions Wallabag needs (idempotent) ──────────────
# Wallabag requires: tokenizer/session/ctype (core), curl, mbstring, xml/dom,
# intl, gd, bcmath, tidy, iconv (core), gettext (core), pdo-sqlite. Beyond the
# FreshRSS set we add php-bcmath + php-tidy. Unversioned package names let apt
# pick whatever PHP the userland ships (Wallabag needs PHP >= 7.4; bookworm = 8.2).
run_once wallabag-apt -- in_debian '
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y --no-install-recommends \
    php-fpm php-cli php-curl php-mbstring php-xml php-intl php-gd php-bcmath php-tidy php-sqlite3 php-gmp \
    curl ca-certificates
' || die "could not install php-fpm + Wallabag PHP extensions inside the userland"

# Resolve the php-fpm binary the userland actually installed.
WB_FPM_BIN="$(in_debian 'command -v php-fpm8.4 || command -v php-fpm8.3 || command -v php-fpm8.2 || command -v php-fpm8.1 || ls /usr/sbin/php-fpm* 2>/dev/null | head -1' 2>/dev/null | tr -d '\r')"
[ -n "${WB_FPM_BIN}" ] || die "no php-fpm binary found in the userland after apt install"
ok "php-fpm binary: ${WB_FPM_BIN}"

# ── 2. Fetch the pinned bundled tarball (sha256 fail-closed) ─────────────────
fetch_verified "${WALLABAG_URL}" "${WALLABAG_LOCAL}" "${WALLABAG_SHA256}"
ok "Wallabag ${WALLABAG_VERSION} tarball ready at ${WALLABAG_LOCAL} ($(wc -c < "${WALLABAG_LOCAL}") bytes)"

# ── 3. Extract the CODE into the userland (preserve data/ on upgrade) ────────
# The tarball top dir is wallabag-<ver>/ and already carries vendor/. We copy its
# CODE over ${WB_DIR}, leaving an existing data/ in place so an upgrade never
# clobbers the SQLite DB. Idempotent: skip if the version stamp already matches.
if in_debian "[ -f '${VERSION_STAMP}' ] && grep -qx '${WALLABAG_VERSION}' '${VERSION_STAMP}' 2>/dev/null"; then
  ok "Wallabag ${WALLABAG_VERSION} already extracted at ${WB_DIR}"
  fresh_extract=0
else
  say "extracting Wallabag ${WALLABAG_VERSION} into ${WB_DIR} (vendor/ pre-bundled; preserving any existing data/)"
  proot-distro login debian -- bash -lc "
    set -e
    mkdir -p '${WB_DIR}' /opt/wallabag-stage
    cd /opt/wallabag-stage
    tar -xzf -
    SRC=\$(find /opt/wallabag-stage -maxdepth 1 -type d -name 'wallabag-*' | head -1)
    [ -n \"\$SRC\" ] || { echo 'extract: no wallabag-* dir found'; exit 1; }
    # Copy app CODE; do NOT touch ${WB_DIR}/data (preserve the SQLite DB on upgrade).
    rsync -a --delete --exclude '/data' \"\$SRC\"/ '${WB_DIR}/' 2>/dev/null || cp -a \"\$SRC\"/. '${WB_DIR}/'
    rm -rf /opt/wallabag-stage
    printf '%s\n' '${WALLABAG_VERSION}' > '${VERSION_STAMP}'
  " < "${WALLABAG_LOCAL}" 2>&1 | grep -v 'proot warning' \
    || die "Wallabag extract failed"
  ok "Wallabag ${WALLABAG_VERSION} code extracted to ${WB_DIR}"
  fresh_extract=1
fi

in_debian "[ -f '${WB_WEBROOT}/app.php' ] && [ -x '${WB_DIR}/bin/console' ]" \
  || die "Wallabag tree incomplete at ${WB_DIR} (need web/app.php + bin/console)"

# ── 4. Data dir on ext4 (bind), persisted app secret ─────────────────────────
in_debian "mkdir -p '${DB_MOUNT}'" || die "failed to create ${DB_MOUNT} mountpoint in the userland"

# Persist a random Symfony app `secret` on ext4 (0600). Reused on re-run so it is
# stable across upgrades (rotating it invalidates CSRF tokens/sessions).
if [ -f "${SECRET_FILE}" ]; then
  # shellcheck disable=SC1090
  WB_SECRET="$(cat "${SECRET_FILE}")"
else
  WB_SECRET="$(openssl rand -hex 32)"
  ( umask 077; printf '%s' "${WB_SECRET}" > "${SECRET_FILE}" )
  chmod 600 "${SECRET_FILE}" 2>/dev/null || true
fi
[ -n "${WB_SECRET}" ] || die "Wallabag app secret is empty (check ${SECRET_FILE})"

# Does the SQLite DB already exist on the host ext4 path? (Decides fresh-install
# vs upgrade. Probe the HOST path — the in-userland path is only visible under the
# bind mount.)
db_existed=0
[ -f "${SQLITE_HOST}" ] && db_existed=1

# ── 5. Patch parameters.yml: SQLite + domain + secret + registration OFF ─────
# Use the bundled Symfony Yaml component so every required key stays intact (only
# the values we name change). domain + secret arrive via the ENVIRONMENT (off the
# command line). Idempotent — safe to re-apply on every run.
say "patching ${WB_DIR}/app/config/parameters.yml (SQLite, domain, secret, registration off)"
proot-distro login debian \
  --bind "${DB_BACKING}:${DB_MOUNT}" \
  -- env WB_DOMAIN="${BASE_URL}" WB_SECRET="${WB_SECRET}" \
     bash -lc "cd '${WB_DIR}' && php -r '
       require \"vendor/autoload.php\";
       \$f = \"app/config/parameters.yml\";
       \$d = \\Symfony\\Component\\Yaml\\Yaml::parseFile(\$f);
       if (!isset(\$d[\"parameters\"])) { fwrite(STDERR, \"no parameters key\n\"); exit(1); }
       \$d[\"parameters\"][\"database_driver\"]    = \"pdo_sqlite\";
       \$d[\"parameters\"][\"database_path\"]      = \"%kernel.project_dir%/${SQLITE_REL}\";
       \$d[\"parameters\"][\"domain_name\"]        = getenv(\"WB_DOMAIN\");
       \$d[\"parameters\"][\"fosuser_registration\"] = false;
       \$d[\"parameters\"][\"secret\"]             = getenv(\"WB_SECRET\");
       file_put_contents(\$f, \\Symfony\\Component\\Yaml\\Yaml::dump(\$d, 4));
       echo \"parameters.yml patched\n\";
     '" 2>&1 | grep -v 'proot warning' || die "parameters.yml patch failed"

# ── 6. Install (fresh) or migrate (upgrade) ──────────────────────────────────
if [ "${db_existed}" -eq 0 ]; then
  say "fresh DB — running wallabag:install (SQLite) then seeding the admin"
  proot-distro login debian \
    --bind "${DB_BACKING}:${DB_MOUNT}" \
    -- bash -lc "
      set -e
      cd '${WB_DIR}'
      mkdir -p data/db
      # Non-interactive install: builds the schema + a default 'wallabag' admin.
      php bin/console wallabag:install --no-interaction --env=prod
    " 2>&1 | grep -v 'proot warning' || die "wallabag:install failed (see output above)"

  # Seed the real admin OFF-ARGV: the password is fed on STDIN (FOSUserBundle's
  # create/change-password prompt reads it from the input stream when the password
  # argument is omitted), so ${ADMIN_PASSWORD} never appears on any command line.
  # If ADMIN_USER == 'wallabag' we re-password the default account; otherwise we
  # create a new super-admin and DEACTIVATE the default 'wallabag' account so its
  # well-known default password ('wallabag') can never log in.
  say "seeding the Wallabag admin '${WB_ADMIN_USER}' (password via stdin, off-argv)"
  if [ "${WB_ADMIN_USER}" = "wallabag" ]; then
    printf '%s\n' "${ADMIN_PASSWORD}" | proot-distro login debian \
      --bind "${DB_BACKING}:${DB_MOUNT}" \
      -- bash -lc "cd '${WB_DIR}' && php bin/console fos:user:change-password wallabag --env=prod" \
      2>&1 | grep -v 'proot warning' || die "setting the wallabag admin password failed"
  else
    printf '%s\n' "${ADMIN_PASSWORD}" | proot-distro login debian \
      --bind "${DB_BACKING}:${DB_MOUNT}" \
      -- bash -lc "cd '${WB_DIR}' && php bin/console fos:user:create '${WB_ADMIN_USER}' '${WB_ADMIN_EMAIL}' --super-admin --env=prod" \
      2>&1 | grep -v 'proot warning' || die "creating the Wallabag super-admin failed"
    # Kill the default account's well-known credential.
    proot-distro login debian \
      --bind "${DB_BACKING}:${DB_MOUNT}" \
      -- bash -lc "cd '${WB_DIR}' && php bin/console fos:user:deactivate wallabag --env=prod" \
      2>&1 | grep -v 'proot warning' || warn "could not deactivate the default 'wallabag' account — do it manually (fos:user:deactivate wallabag)"
  fi
  ok "Wallabag installed + admin '${WB_ADMIN_USER}' seeded (password from .env ADMIN_PASSWORD — change after first login)"
else
  # UPGRADE PATH (existing DB): SQLite migrations are a project-acknowledged
  # fragile spot and are NOT cleanly reversible — back the DB up FIRST, then run
  # the doctrine migrations. Fail closed: a failed migration aborts the install.
  say "existing DB — backing up the SQLite file, then running doctrine migrations"
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  cp -a "${SQLITE_HOST}" "${DB_BACKING}/db/wallabag.sqlite.bak-${ts}" 2>/dev/null \
    && ok "SQLite backed up → ${DB_BACKING}/db/wallabag.sqlite.bak-${ts}" \
    || warn "could not back up the SQLite DB before migrating — proceeding cautiously"
  proot-distro login debian \
    --bind "${DB_BACKING}:${DB_MOUNT}" \
    -- bash -lc "cd '${WB_DIR}' && php bin/console doctrine:migrations:migrate --no-interaction --env=prod" \
    2>&1 | grep -v 'proot warning' || die "doctrine migration failed — restore ${DB_BACKING}/db/wallabag.sqlite.bak-${ts} and investigate before retrying"
  ok "Wallabag DB migrated"
fi

# ── 7. Clear + warm the Symfony prod cache (mandatory after any code swap) ───
# A stale prod cache after swapping the code is the classic Wallabag 500/white
# screen. Always clear+warm in prod so a re-run / upgrade is clean.
say "clearing + warming the Symfony prod cache"
proot-distro login debian \
  --bind "${DB_BACKING}:${DB_MOUNT}" \
  -- bash -lc "cd '${WB_DIR}' && php bin/console cache:clear --env=prod --no-debug" \
  2>&1 | grep -v 'proot warning' || die "cache:clear failed (Wallabag would 500 with a stale prod cache)"
# Tighten DB perms (defence in depth).
chmod 600 "${SQLITE_HOST}" 2>/dev/null || true

# ── 8. Dedicated php-fpm pool (loopback :${WB_FPM_PORT}) ─────────────────────
# Loopback-only by design — deliberately NOT following CADDY_BIND, so an operator
# setting CADDY_BIND=0.0.0.0 to expose Caddy can never LAN-expose this no-edge-auth
# FastCGI backend. pm.max_children kept small (Symfony boots the whole kernel per
# request, ~80-150MB each); memory_limit generous for export/import.
say "writing the dedicated php-fpm pool → ${WB_FPM_CONF} (loopback :${WB_FPM_PORT})"
proot-distro login debian -- bash -lc "umask 077; cat > '${WB_FPM_CONF}'" <<POOL
[global]
pid = ${DB_MOUNT}/php-fpm.pid
error_log = ${DB_MOUNT}/php-fpm.log
daemonize = no

[wallabag]
user = root
group = root
; loopback-only (Caddy is the only front door); do NOT follow CADDY_BIND.
listen = 127.0.0.1:${WB_FPM_PORT}
pm = ondemand
pm.max_children = 3
pm.process_idle_timeout = 30s
pm.max_requests = 300
catch_workers_output = yes
php_admin_value[upload_max_filesize] = 64M
php_admin_value[post_max_size] = 66M
php_admin_value[memory_limit] = 384M
php_admin_value[max_execution_time] = 300
POOL
ok "wrote ${WB_FPM_CONF}"

# In-userland launcher (avoids nested-quoting through supervise→proot→bash).
proot-distro login debian -- bash -lc "umask 077; cat > '${WB_DIR}/run-fpm.sh'" <<LAUNCH
#!/bin/bash
# Runs INSIDE the Debian userland; started + kept alive by apps/wallabag.sh.
# Serves Wallabag on 127.0.0.1:${WB_FPM_PORT} (loopback-only); Caddy fronts TLS.
exec ${WB_FPM_BIN} -R -F -y '${WB_FPM_CONF}'
LAUNCH
in_debian "chmod +x '${WB_DIR}/run-fpm.sh'" || die "failed to make ${WB_DIR}/run-fpm.sh executable"

# ── 9. Caddy vhost (self-contained; imported by the core Caddyfile) ──────────
# Symfony front controller is web/app.php (not index.php), so php_fastcgi gets an
# explicit try_files that rewrites non-file requests to /app.php. Listener style
# matches the other vhosts exactly (explicit http://<host>:${CADDY_PORT} + bind).
say "writing the Caddy vhost → /etc/caddy/apps/wallabag.caddy"
in_debian "mkdir -p /etc/caddy/apps"
if ! proot-distro login debian -- bash -lc 'cat > /etc/caddy/apps/wallabag.caddy' <<EOF
# read.${DOMAIN} — Wallabag (read-later / article saver).
# Written by scripts/apps/wallabag.sh. Loopback-only; the Cloudflare Tunnel
# forwards public traffic here and (by default) Cloudflare Access gates the
# hostname at the edge. Wallabag self-authenticates with its OWN login.
# NOTE: the Wallabag REST API + mobile app/extension use OAuth2 bearer tokens and
# cannot follow a 302-to-login — for those add a CF Access service-token exemption
# for read.${DOMAIN} (operator-side). See docs/READLATER.md + docs/APP_AUTH.md.
http://read.${DOMAIN}:${CADDY_PORT} {
	bind ${CADDY_BIND}

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options nosniff
		X-Frame-Options SAMEORIGIN
		Referrer-Policy strict-origin-when-cross-origin
		-Server
	}

	root * ${WB_WEBROOT}

	# OPTIONAL Matrix-SSO gateway add-on (advanced; see docs/APP_AUTH.md). Disabled
	# by default — the default front door is Wallabag's native login + Cloudflare
	# Access at the edge. If enabled, the three parts MUST precede php_fastcgi: the
	# /authgw/* handler keeps the login form reachable, the request_header strips any
	# client-forged Remote-User before the gate, and forward_auth gates the rest.
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

	# Symfony single front controller: rewrite anything that is not a real file to
	# web/app.php (Wallabag has no index.php), then hand .php to the php-fpm pool.
	php_fastcgi 127.0.0.1:${WB_FPM_PORT} {
		try_files {path} /app.php?{query}
	}
	file_server
}
EOF
then
  die "failed to write /etc/caddy/apps/wallabag.caddy into the userland"
fi

say "validating the Caddyfile inside the userland"
in_debian 'caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile' \
  || die "caddy validate FAILED — refusing to leave a broken vhost in /etc/caddy/apps/wallabag.caddy"
ok "Wallabag vhost written + Caddyfile validates"

# ── 10. Supervise php-fpm on loopback ────────────────────────────────────────
say "supervising Wallabag php-fpm (bind 127.0.0.1:${WB_FPM_PORT}; data on ${DB_BACKING})"
supervise wallabag -- \
  proot-distro login debian \
  --bind "${DB_BACKING}:${DB_MOUNT}" \
  -- bash "${WB_DIR}/run-fpm.sh"

# ── 11. Best-effort health check ──────────────────────────────────────────────
say "waiting for Wallabag to answer on 127.0.0.1:${WB_FPM_PORT} (via a quick fcgi check is awkward; we poll the pool indirectly)"
healthy=0
for _ in $(seq 1 30); do
  # php-fpm speaks FastCGI, not HTTP, so a plain curl won't 200; instead confirm
  # the pool is listening on loopback from inside the userland.
  if in_debian "(command -v ss >/dev/null && ss -ltn 2>/dev/null | grep -q ':${WB_FPM_PORT} ') || (command -v nc >/dev/null && nc -z 127.0.0.1 ${WB_FPM_PORT} 2>/dev/null)"; then
    healthy=1; break
  fi
  sleep 1
done
if [ "${healthy}" -eq 1 ]; then
  ok "Wallabag php-fpm listening on 127.0.0.1:${WB_FPM_PORT}"
else
  warn "Wallabag php-fpm not yet listening on :${WB_FPM_PORT} — check ${POCKET_LOG_DIR}/wallabag.log (the supervisor keeps retrying)"
fi

# ── 12. Closing notes ─────────────────────────────────────────────────────────
cat >&2 <<EOF

$(ok "Wallabag installed + supervised (php-fpm 127.0.0.1:${WB_FPM_PORT}; SQLite on ${DB_BACKING})" 2>&1)

  Initial admin: '${WB_ADMIN_USER}' (password from .env ADMIN_PASSWORD) —
  CHANGE IT after first login (it is only seeded on a fresh database).

  Manual steps to finish (in the Cloudflare dashboard — NOT done by this script):
    1. Public hostname: add a Public Hostname in your Cloudflare Tunnel:
         ${WB_HOST}  ->  http://localhost:${CADDY_PORT}   (plain HTTP; the tunnel
       terminates public TLS).
    2. Cloudflare Access: add an Access policy protecting ${WB_HOST} (Wallabag's
       own login is the inner gate).

  Mobile app / browser extension / REST API: these use OAuth2 bearer tokens and
  CANNOT complete the Cloudflare Access 302 login. To use them, add a CF Access
  SERVICE-TOKEN exemption for ${WB_HOST} in the Cloudflare dashboard (operator-side;
  this script wires nothing for it). See docs/READLATER.md.

  Import cap: the Cloudflare Tunnel caps a single request body at ~100MB, so a huge
  Pocket/OPML import through the public hostname can fail — import big files on
  loopback/LAN. Article fetch is synchronous on save; some sites won't parse (a
  normal condition, not an install bug).

  If the stack is ALREADY running, reload Caddy so the new vhost goes live:
         bash ${POCKET_ROOT}/scripts/start-stack.sh --restart
  More detail: docs/READLATER.md + docs/APP_AUTH.md.
EOF

ok "apps/wallabag.sh done (read.${DOMAIN} once the Cloudflare hostname + Access policy are added)"

# Generalized from a working deployment; review before running.
