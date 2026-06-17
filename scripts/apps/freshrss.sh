#!/usr/bin/env bash
#
# apps/freshrss.sh — install + supervise FreshRSS (self-hosted RSS/Atom reader)
# as an OPTIONAL app behind the loopback Caddy edge.
#
# FreshRSS is a PHP application (no single arm64 binary). We install the pinned
# upstream source tarball into /opt/freshrss inside the Debian userland and serve
# it with php-fpm on a DEDICATED pool (loopback ${CADDY_BIND}:${FRESHRSS_FPM_PORT}).
# Caddy fronts it with the `php_fastcgi` directive (NOT reverse_proxy, the way the
# Go/Python apps are fronted) pointing at that php-fpm listener, with `root *` at
# FreshRSS's public webroot. The public hostname is rss.${DOMAIN}.
#
# What it does (idempotent — safe to re-run):
#   1. installs php-fpm + the PHP extensions FreshRSS needs into the userland,
#   2. downloads + sha256-verifies the pinned FreshRSS source tarball
#      (v${FRESHRSS_VERSION}) and extracts it to /opt/freshrss WITHOUT clobbering an
#      existing data/ dir (so an upgrade keeps the SQLite DB + feeds),
#   3. writes a dedicated php-fpm pool config (loopback :${FRESHRSS_FPM_PORT}),
#   4. runs the FreshRSS headless installer (cli/prepare.php + cli/do-install.php)
#      for SQLite + native `form` login, then creates the initial admin from
#      ${ADMIN_USER}/${ADMIN_PASSWORD} (idempotent — a no-op if it already exists);
#      sets base_url to https://rss.${DOMAIN} and disables open registration,
#   5. writes a self-contained Caddy vhost to /etc/caddy/apps/freshrss.caddy
#      (the php_fastcgi shape) and validates the full Caddyfile fail-closed (it
#      does NOT restart Caddy),
#   6. supervises php-fpm (the web service) AND a feed-refresh loop via the shared
#      lib (respawn + identity-checked pidfile).
#
# AUTH MODEL (default): FreshRSS keeps its OWN native login (auth_type=form). Open
# self-registration is OFF, so accounts are created only by an admin — we create
# one initial admin from ${ADMIN_USER}/${ADMIN_PASSWORD}. The public hostname is
# additionally gated at the Cloudflare edge with Cloudflare Access (a policy you
# add in the Cloudflare dashboard — NOT configured by this script). An optional
# Matrix-SSO gateway add-on (single sign-on across apps) is documented in
# docs/APP_AUTH.md; its hooks are present here only as a COMMENTED-OUT block in
# the Caddy vhost.
#
# Data (the SQLite DB, user config, feed cache, favicons) lives on the large
# volume under ${DATA_DIR}/freshrss so the userland rootfs stays lean. The
# userland can't see that path directly, so it is bind-mounted into the userland
# at /opt/freshrss/data — both at init time and at supervise time.
#
# Generalized from a working deployment; review before running.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env
require_var DOMAIN         "your public domain, e.g. example.com"
require_var DATA_DIR       "folder on your large volume / SD card"
require_var ADMIN_PASSWORD "the initial FreshRSS admin password (set in .env)"
require_cmd proot-distro

# NOTE: enabling/disabling is handled by install.sh (it only runs this script when
# ENABLE_FRESHRSS=true), so this script does not re-check the flag.

in_debian() { proot-distro login debian -- bash -lc "$1"; }

# ── Pinned release ───────────────────────────────────────────────────────────
# Pin an EXACT upstream tag (env-overridable) rather than a floating branch, so an
# upgrade is a deliberate bump. Version + sha256 copied VERBATIM from the reference
# deployment. NOTE: this is a GitHub *auto-generated* source archive
# (archive/refs/tags/…); GitHub does not contractually guarantee these are
# byte-stable forever (it changed their git-archive compression once, in early
# 2023). They have been stable since, but if a future rebuild fails this check on a
# download you have confirmed is genuine, regenerate the hash and bump it alongside
# FRESHRSS_VERSION:  curl -fsSL "$FRESHRSS_URL" | sha256sum
FRESHRSS_VERSION="${FRESHRSS_VERSION:-1.29.1}"
FRESHRSS_URL="${FRESHRSS_URL:-https://github.com/FreshRSS/FreshRSS/archive/refs/tags/${FRESHRSS_VERSION}.tar.gz}"
FRESHRSS_SHA256="${FRESHRSS_SHA256:-b956aa4cd1f4d65eaad626a2648fecfdcbb7cdebf9253f3f4064965aefcd28cc}"

# ── Service-local config ─────────────────────────────────────────────────────
FR_DIR="/opt/freshrss"                       # app root INSIDE the userland (webroot = $FR_DIR/p)
FR_WEBROOT="${FR_DIR}/p"                      # FreshRSS public webroot (index.php front controller)
FR_FPM_PORT="${FRESHRSS_FPM_PORT:-9112}"      # dedicated php-fpm pool; Caddy fronts the TLS edge
FR_HOST="rss.${DOMAIN}"                       # public hostname
FR_DATA_HOST="${DATA_DIR}/freshrss"           # SQLite DB + config + feed cache (large volume)
FR_DATA_USERLAND="${FR_DIR}/data"             # bind target inside the userland (FreshRSS's data dir)
FR_FPM_CONF="${FR_DIR}/php-fpm.conf"          # dedicated pool config (in the userland)
FR_REFRESH_INTERVAL="${FRESHRSS_REFRESH_INTERVAL:-900}"  # seconds between feed pulls (~15 min)
BASE_URL="https://${FR_HOST}"

mkdir -p "${FR_DATA_HOST}"

# ── Preflight: the userland must exist ───────────────────────────────────────
in_debian 'true' >/dev/null 2>&1 || die "proot-distro debian not reachable — install the userland first (run scripts/install.sh)"

# ── 1. php-fpm + the PHP extensions FreshRSS needs (idempotent) ──────────────
# FreshRSS needs: curl, mbstring, xml, intl, zip, sqlite3, gmp (crypto helper),
# gd (favicons). We install Debian's default php-fpm + the matching extension
# packages from the userland's repos — generalized from the reference (which
# pinned php8.4-* explicitly). Using the unversioned package names lets apt pick
# whatever PHP the userland's Debian release ships, so this stays portable across
# Debian versions. UNCERTAINTY: a very old userland could ship a PHP too old for
# FreshRSS ${FRESHRSS_VERSION} (it needs PHP >= 8.1); the validate step below
# fails closed if php-fpm is missing, but does not assert a minimum PHP version.
run_once freshrss-apt -- in_debian '
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y --no-install-recommends \
    php-fpm php-cli php-curl php-mbstring php-xml php-intl php-zip php-sqlite3 php-gmp php-gd \
    curl ca-certificates
' || die "could not install php-fpm + FreshRSS PHP extensions inside the userland"

# Resolve the php-fpm binary the userland actually installed (the package name is
# unversioned, but the binary on PATH is php-fpmX.Y). Fail closed if absent.
FR_FPM_BIN="$(in_debian 'command -v php-fpm8.4 || command -v php-fpm8.3 || command -v php-fpm8.2 || command -v php-fpm8.1 || ls /usr/sbin/php-fpm* 2>/dev/null | head -1' 2>/dev/null | tr -d '\r')"
[ -n "${FR_FPM_BIN}" ] || die "no php-fpm binary found in the userland after apt install — check 'proot-distro login debian -- ls /usr/sbin/php-fpm*'"
ok "php-fpm binary: ${FR_FPM_BIN}"

# ── 2. Fetch the pinned source + extract (preserving data/ on upgrade) ───────
# Idempotent: skip if the app root already carries the pinned version. We extract
# the versioned top dir (FreshRSS-<ver>) and copy its CODE over $FR_DIR, leaving an
# existing data/ in place so an upgrade never clobbers the SQLite DB or feed cache.
if in_debian "[ -f '${FR_DIR}/constants.php' ] && grep -q \"FRESHRSS_VERSION', '${FRESHRSS_VERSION}\" '${FR_DIR}/constants.php' 2>/dev/null"; then
  ok "FreshRSS ${FRESHRSS_VERSION} already extracted at ${FR_DIR}"
else
  say "downloading + sha256-verifying + extracting FreshRSS ${FRESHRSS_VERSION}"
  # The sha256 is verified fail-closed INSIDE the userland (sha256sum -c), so a
  # corrupt/tampered tarball aborts the install rather than running unknown code.
  in_debian "
    set -e
    mkdir -p '${FR_DIR}' /opt/freshrss-stage
    cd /opt/freshrss-stage
    curl -fsSL --retry 3 -o fr.tar.gz '${FRESHRSS_URL}'
    echo '${FRESHRSS_SHA256}  fr.tar.gz' | sha256sum -c -
    tar -xzf fr.tar.gz
    rm -f fr.tar.gz
    SRC=\$(find /opt/freshrss-stage -maxdepth 1 -type d -name 'FreshRSS-*' | head -1)
    [ -n \"\$SRC\" ] || { echo 'extract: no FreshRSS-* dir found'; exit 1; }
    # Copy app CODE (NOT data/ — preserve the SQLite DB + feeds on upgrade).
    cp -a \"\$SRC\"/. '${FR_DIR}/'
    rm -rf /opt/freshrss-stage
  " 2>&1 | grep -v 'proot warning' \
    || die "FreshRSS download/verify/extract failed (bad URL, or sha256 mismatch vs ${FRESHRSS_SHA256} — see the FRESHRSS_SHA256 note if GitHub re-archived the tag)"
  ok "FreshRSS ${FRESHRSS_VERSION} extracted to ${FR_DIR}"
fi

# Fail closed: the app tree must be present.
in_debian "[ -f '${FR_DIR}/constants.php' ] && [ -f '${FR_WEBROOT}/index.php' ]" \
  || die "FreshRSS tree incomplete at ${FR_DIR} (need constants.php + p/index.php)"

# ── 3. Create the data dir (DB + config + feed cache on the large volume) ─────
# FreshRSS's data dir is fixed at <app>/data. The userland sees the large volume
# there via a bind mount (proot-distro login --bind). We create both the
# in-userland mountpoint AND the backing dir on the volume.
in_debian "mkdir -p '${FR_DATA_USERLAND}'" || die "failed to create ${FR_DATA_USERLAND} in the userland"
mkdir -p "${FR_DATA_HOST}"
ok "FreshRSS data backing dir ready: ${FR_DATA_HOST} (bind-mounted at ${FR_DATA_USERLAND})"

# ── 4. Dedicated php-fpm pool (loopback :${FR_FPM_PORT}) ──────────────────────
# A self-contained pool so FreshRSS never shares workers with anything else. proot
# is single-user root, so the pool runs as root (the rest of the stack does too).
# pid/log land under the data dir so they persist with the app. The generous
# limits cover slow feed/favicon fetches over a phone uplink.
say "writing the dedicated php-fpm pool → ${FR_FPM_CONF} (loopback :${FR_FPM_PORT})"
proot-distro login debian -- bash -lc "umask 077; cat > '${FR_FPM_CONF}'" <<POOL
[global]
pid = ${FR_DATA_USERLAND}/php-fpm.pid
error_log = ${FR_DATA_USERLAND}/php-fpm.log
daemonize = no

[freshrss]
user = root
group = root
listen = ${CADDY_BIND}:${FR_FPM_PORT}
pm = ondemand
pm.max_children = 4
pm.process_idle_timeout = 30s
pm.max_requests = 500
catch_workers_output = yes
; FreshRSS feed refresh + favicon fetch can be slow on a phone link.
php_admin_value[upload_max_filesize] = 32M
php_admin_value[post_max_size] = 34M
php_admin_value[memory_limit] = 256M
php_admin_value[max_execution_time] = 300
POOL
ok "wrote ${FR_FPM_CONF}"

# ── 5. Headless install (SQLite + native form login) + initial admin ─────────
# Run inside the userland with the data dir bind-mounted so the SQLite DB lands on
# the large volume. cli/prepare.php creates the data dirs; cli/do-install.php
# writes data/config.php (idempotent: skip if it already exists). We install with
# auth_type=form (FreshRSS's OWN login) — the gateway/OIDC wiring from the private
# reference is dropped for the public default. base-url is the public origin
# (FreshRSS builds links/redirects from it).
say "running the FreshRSS headless install (prepare + do-install, SQLite, form login) inside the userland"
proot-distro login debian \
  --bind "${FR_DATA_HOST}:${FR_DATA_USERLAND}" \
  -- bash -lc "
    set -e
    cd '${FR_DIR}' || exit 1
    php cli/prepare.php
    if [ ! -f '${FR_DATA_USERLAND}/config.php' ]; then
      php cli/do-install.php \
        --default-user '${ADMIN_USER:-admin}' \
        --auth-type form \
        --environment production \
        --base-url '${BASE_URL}' \
        --language en \
        --title 'FreshRSS' \
        --db-type sqlite
    fi
  " 2>&1 | grep -v 'proot warning' || die "FreshRSS do-install failed (see output above)"
ok "FreshRSS installed (SQLite under ${FR_DATA_HOST})"

# Create the initial admin from .env (idempotent). cli/create-user.php errors if
# the user already exists, so guard it by listing users first — a re-run is then a
# clean no-op. The default-user from do-install above is the admin's username; this
# step sets its FORM password (do-install does not take a password for form auth).
say "ensuring the initial admin user '${ADMIN_USER:-admin}' exists (idempotent)"
proot-distro login debian \
  --bind "${FR_DATA_HOST}:${FR_DATA_USERLAND}" \
  -- bash -lc "
    set -e
    cd '${FR_DIR}' || exit 1
    if php cli/list-users.php 2>/dev/null | tr ',' '\n' | grep -qx '${ADMIN_USER:-admin}'; then
      echo 'admin user already exists — skipping create-user'
    else
      php cli/create-user.php --user '${ADMIN_USER:-admin}' --password '${ADMIN_PASSWORD}' --language en
    fi
  " 2>&1 | grep -v 'proot warning' || die "FreshRSS admin user creation failed (see output above)"
ok "initial admin user '${ADMIN_USER:-admin}' present (password from .env ADMIN_PASSWORD)"

# ── 6. Harden config.php: native form login + disable open registration ──────
# auth_type=form keeps FreshRSS's own login as the inner gate. Open self-
# registration is disabled and anonymous access is off, so an admin is the only
# way new accounts are created. base_url is re-asserted (FreshRSS builds absolute
# links/redirects from it). Idempotent: a pure PHP rewrite of the returned array.
say "patching ${FR_DATA_USERLAND}/config.php (auth_type=form + base_url + disable open registration / anonymous)"
proot-distro login debian \
  --bind "${FR_DATA_HOST}:${FR_DATA_USERLAND}" \
  -- bash -lc "php -r '
    \$p = \"${FR_DATA_USERLAND}/config.php\";
    if (!file_exists(\$p)) { fwrite(STDERR, \"config.php missing\n\"); exit(1); }
    \$c = require \$p;
    \$c[\"auth_type\"]            = \"form\";
    \$c[\"base_url\"]             = \"${BASE_URL}\";
    \$c[\"allow_anonymous\"]      = false;
    \$c[\"allow_anonymous_refresh\"] = false;
    \$c[\"unsafe_autologin_enabled\"] = false;
    file_put_contents(\$p, \"<?php\n return \" . var_export(\$c, true) . \";\n\");
    echo \"config.php patched\n\";
  '" 2>&1 | grep -v 'proot warning' || die "config.php patch failed"

# Permissions: FreshRSS ships cli/access-permissions.sh; the php-fpm user (root in
# this single-user proot) must be able to write the data dir. Harden config.php.
proot-distro login debian \
  --bind "${FR_DATA_HOST}:${FR_DATA_USERLAND}" \
  -- bash -lc "cd '${FR_DIR}' && [ -x cli/access-permissions.sh ] && bash cli/access-permissions.sh >/dev/null 2>&1; chmod -R u+rwX '${FR_DATA_USERLAND}'; chmod 600 '${FR_DATA_USERLAND}/config.php' 2>/dev/null || true; true" \
  >/dev/null 2>&1 || true

# ── 7. Write the in-userland php-fpm + feed-refresh launchers ────────────────
# Kept as files inside the userland to avoid nested-quoting through
# supervise→bash -c→proot-distro→bash -c. php-fpm runs in the FOREGROUND
# (-F) under the supervisor; -R lets the pool run as root (proot is single-user
# root). The refresh launcher is a sleep loop that runs FreshRSS's all-users
# actualize script (app/actualize_script.php) every ${FR_REFRESH_INTERVAL}s — the
# productized equivalent of the Docker image's CRON_MIN. (The private reference
# left feed refresh as a manual/operator cron; we supervise it here so RSS feeds
# actually update without operator action.)
say "writing ${FR_DIR}/run-fpm.sh + ${FR_DIR}/run-refresh.sh launchers"
proot-distro login debian -- bash -lc "umask 077; cat > '${FR_DIR}/run-fpm.sh'" <<LAUNCH
#!/bin/bash
# Runs INSIDE the Debian userland; started + kept alive by apps/freshrss.sh.
# Serves FreshRSS on ${CADDY_BIND}:${FR_FPM_PORT}; Caddy fronts the public TLS edge.
exec ${FR_FPM_BIN} -R -F -y '${FR_FPM_CONF}'
LAUNCH
in_debian "chmod +x '${FR_DIR}/run-fpm.sh'" || die "failed to make ${FR_DIR}/run-fpm.sh executable"

proot-distro login debian -- bash -lc "umask 077; cat > '${FR_DIR}/run-refresh.sh'" <<LAUNCH
#!/bin/bash
# Runs INSIDE the Debian userland; feed-refresh loop (the all-users actualize
# script). No network port. Sleeps ${FR_REFRESH_INTERVAL}s between pulls.
cd '${FR_DIR}' || exit 1
while true; do
  php app/actualize_script.php >/dev/null 2>&1 || true
  sleep ${FR_REFRESH_INTERVAL}
done
LAUNCH
in_debian "chmod +x '${FR_DIR}/run-refresh.sh'" || die "failed to make ${FR_DIR}/run-refresh.sh executable"
ok "wrote the php-fpm + feed-refresh launchers"

# ── 8. Caddy vhost (self-contained site block, imported by the core Caddyfile) ─
# Matches the core Caddyfile listener style EXACTLY: explicit
# http://<host>:${CADDY_PORT} + bind ${CADDY_BIND} (plain HTTP on the shared high
# loopback port; the Cloudflare Tunnel terminates public TLS). The core Caddyfile
# imports /etc/caddy/apps/*.caddy, so dropping this file in is all it takes.
#
# Unlike the reverse_proxy apps, FreshRSS is a classic PHP app: we set `root *` to
# its public webroot (${FR_WEBROOT} = /opt/freshrss/p, the index.php front
# controller) and hand non-static requests to php-fpm via `php_fastcgi`, with
# `file_server` serving the static assets under that webroot. (i/ and api/ resolve
# from inside p/, so rooting at p/ is correct.)
say "writing the Caddy vhost → /etc/caddy/apps/freshrss.caddy"
proot-distro login debian -- bash -lc 'mkdir -p /etc/caddy/apps && cat > /etc/caddy/apps/freshrss.caddy' <<EOF
# FreshRSS (RSS reader) — optional app vhost for pocket-homeserver.
# Public hostname rss.${DOMAIN}; bound to loopback (the Cloudflare Tunnel forwards
# public traffic here). FreshRSS self-authenticates with its OWN login; by default
# this hostname is ALSO gated at the Cloudflare edge with Cloudflare Access
# (configured in the Cloudflare dashboard).
http://${FR_HOST}:${CADDY_PORT} {
	bind ${CADDY_BIND}

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options nosniff
		X-Frame-Options DENY
		Referrer-Policy strict-origin-when-cross-origin
		Cross-Origin-Opener-Policy same-origin
		-Server
	}

	# FreshRSS is a PHP app: serve its public webroot (the p/ front controller)
	# and hand dynamic requests to the dedicated php-fpm pool. file_server serves
	# the CSS/JS/image assets that live under the same webroot.
	root * ${FR_WEBROOT}

	# OPTIONAL Matrix-SSO gateway add-on (single sign-on across apps). Disabled by
	# default — the default front door is FreshRSS's native login + Cloudflare
	# Access at the edge. To enable, run the optional Matrix-auth gateway and
	# uncomment this block (see docs/APP_AUTH.md); it must precede php_fastcgi so
	# unauthenticated requests are redirected to login first. (With this enabled
	# you would also switch FreshRSS to auth_type=http_auth + trusted_sources
	# loopback and pass Remote-User into the FastCGI env — see docs/APP_AUTH.md.)
	# forward_auth 127.0.0.1:9095 {
	# 	uri /authgw/verify
	# 	copy_headers Remote-User
	# }

	php_fastcgi ${CADDY_BIND}:${FR_FPM_PORT}
	file_server
}
EOF
ok "wrote /etc/caddy/apps/freshrss.caddy"

# Validate the FULL Caddyfile inside the userland (fail closed). We do NOT restart
# Caddy here — print the restart hint instead so an already-running stack picks up
# the new vhost on the operator's schedule.
say "validating the Caddyfile inside the userland"
in_debian 'caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile' \
  || die "caddy validate FAILED — refusing to leave a broken vhost in place (fix /etc/caddy/apps/freshrss.caddy)"
ok "Caddyfile still valid with the freshrss vhost added"

# ── 9. Supervise php-fpm (web) + the feed-refresh loop ───────────────────────
# The shared supervisor (respawn loop + identity-checked pidfile) runs each
# launcher inside the userland with the large-volume data dir bind-mounted in so
# the SQLite DB + feed cache land on ${DATA_DIR}.
supervise freshrss -- \
  proot-distro login debian \
  --bind "${FR_DATA_HOST}:${FR_DATA_USERLAND}" \
  -- bash "${FR_DIR}/run-fpm.sh"

supervise freshrss-refresh -- \
  proot-distro login debian \
  --bind "${FR_DATA_HOST}:${FR_DATA_USERLAND}" \
  -- bash "${FR_DIR}/run-refresh.sh"

# ── Closing notes ─────────────────────────────────────────────────────────────
echo
ok "FreshRSS installed + supervised (php-fpm ${CADDY_BIND}:${FR_FPM_PORT}; data on ${FR_DATA_HOST})"
say "Feeds auto-refresh every ${FR_REFRESH_INTERVAL}s via the supervised freshrss-refresh loop."
say "Initial admin: '${ADMIN_USER:-admin}' (password from .env ADMIN_PASSWORD) — change it after first login."
echo
say "Manual Cloudflare steps (in the Cloudflare dashboard — NOT done by this script):"
say "  1. In the Tunnel config, add a Public Hostname:"
say "       ${FR_HOST}  ->  http://localhost:${CADDY_PORT}  (the local Caddy edge, plain HTTP)"
say "  2. Add a Cloudflare Access policy (Zero Trust) protecting ${FR_HOST} so only"
say "     your chosen identities can reach it (FreshRSS's own login is the inner gate)."
say "  If the core stack is already running, pick up the new vhost with:"
say "       bash ${POCKET_ROOT}/scripts/start-stack.sh --restart"
say "  (brief ingress outage while cloudflared cycles)."

# Generalized from a working deployment; review before running.
