#!/usr/bin/env bash
#
# apps/searxng.sh — install + supervise SearXNG (private metasearch engine) as an
# OPTIONAL app behind the loopback Caddy edge.
#
# SearXNG is a Python (Flask) metasearch front-end. It ships no release binary —
# upstream distributes a Docker image and the source, and the documented install
# is a git clone + an editable pip install into a virtualenv — so we build it
# from source INTO a venv inside the Debian userland and serve its WSGI app
# (searx.webapp:application) under uWSGI on ${CADDY_BIND}:${SEARXNG_PORT}. The
# core Caddy fronts it; the public hostname is search.${DOMAIN}.
#
# What it does (idempotent — safe to re-run):
#   1. installs the build/runtime apt deps inside the userland (a C toolchain is
#      needed to compile the msgspec / lxml / pybind11 wheels) plus uWSGI and its
#      python3 plugin,
#   2. clones SearXNG (rolling — see the pin note) into /opt/searxng and installs
#      it editable into a venv at /opt/searxng-venv,
#   3. generates + persists a per-deployment server.secret_key under
#      ${DATA_DIR}/secrets/searxng.env (chmod 600; reused on re-run) and injects
#      it at runtime via the uWSGI env (so it never lands in settings.yml at rest),
#   4. writes a hardened settings.yml + a uwsgi.ini into the userland,
#   5. writes a self-contained Caddy vhost to /etc/caddy/apps/searxng.caddy and
#      validates the full Caddyfile fail-closed (it does NOT restart Caddy),
#   6. supervises the uWSGI service via the shared lib (respawn + identity pid).
#
# AUTH MODEL (critical): SearXNG has NO authentication of its own. Left open it is
# an unauthenticated metasearch PROXY anyone on the internet can drive. So the
# DEFAULT front door is to gate search.${DOMAIN} at the Cloudflare edge with a
# Cloudflare Access policy (a policy you add in the Cloudflare dashboard — NOT
# configured by this script). UNLIKE the apps that carry their own login, here
# the edge gate is REQUIRED, not just defence-in-depth. An optional Matrix-SSO
# gateway add-on (single sign-on across apps) is documented in docs/APP_AUTH.md;
# its hooks are present here only as a COMMENTED-OUT block in the Caddy vhost.
#
# State: SearXNG is essentially stateless (just settings + the secret). The
# secret lives on the large volume under ${DATA_DIR}/secrets and is injected at
# runtime; settings.yml + uwsgi.ini live in the userland and are rewritten from
# this script (source of truth) so a userland wipe is recoverable by re-running.
#
# Generalized from a working deployment; review before running.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env
require_var DOMAIN   "your public domain, e.g. example.com"
require_var DATA_DIR "folder on your large volume / SD card"
require_cmd proot-distro
require_cmd openssl

# NOTE: enabling/disabling is handled by install.sh (it only runs this script when
# ENABLE_SEARXNG=true), so this script does not re-check the flag.

in_debian() { proot-distro login debian -- bash -lc "$1"; }

# ── Pinned source ──────────────────────────────────────────────────────────────
# SearXNG is a ROLLING release: upstream publishes NO version tags at all (the
# reference deployment confirmed `git ls-remote` returns zero refs/tags), so
# `master` IS the canonical install ref — this matches SearXNG's own install
# docs. We shallow-clone master; on upgrade just re-run (re-pulls master). For a
# hard pin, set SEARXNG_REF to a commit SHA (the full-clone fallback below handles
# a non-branch ref). The reference deployment's master HEAD at clone time was
# commit e964708c (INFORMATIONAL only — not enforced). Because there is no release
# tarball and no published sha256 for a source checkout, there is no
# fetch_verified pin here; integrity is the git ref fetched over HTTPS from the
# canonical repo. (Do NOT invent a version or a sha256.)
SEARXNG_REF="${SEARXNG_REF:-master}"
SEARXNG_REPO="${SEARXNG_REPO:-https://github.com/searxng/searxng.git}"

# ── Service-local config ─────────────────────────────────────────────────────
SX_DIR="/opt/searxng"                  # git working tree INSIDE the userland
SX_VENV="/opt/searxng-venv"            # virtualenv (out of the tree) in the userland
SX_PORT="${SEARXNG_PORT:-9113}"        # loopback bind; Caddy fronts the TLS edge
SX_HOST="search.${DOMAIN}"             # public hostname
SX_ETC="/etc/searxng"                  # settings.yml + uwsgi.ini live here (in userland)
SETTINGS="${SX_ETC}/settings.yml"
UWSGI_INI="${SX_ETC}/uwsgi.ini"
SECRETS_FILE="${DATA_DIR}/secrets/searxng.env"

# Instance name shown in the UI — derived from the domain (no operator-specific
# branding); override with SEARXNG_INSTANCE_NAME if you want something custom.
SX_INSTANCE_NAME="${SEARXNG_INSTANCE_NAME:-${DOMAIN} Search}"

mkdir -p "${DATA_DIR}/secrets"

# ── Preflight: the userland must exist ───────────────────────────────────────
in_debian 'true' >/dev/null 2>&1 || die "proot-distro debian not reachable — install the userland first (run scripts/install.sh)"

# ── 1. Build/runtime deps inside the userland ────────────────────────────────
# SearXNG needs python3 + venv + a C toolchain because msgspec / lxml / pybind11
# build native wheels, and uWSGI with the python3 plugin to serve the WSGI app.
# git clones the source; libxml2/libxslt are for lxml; babel for translations.
# --no-install-recommends keeps the userland lean. Idempotent: run_once marks it
# done; the explicit check below also fast-paths a re-run.
if in_debian "command -v uwsgi >/dev/null 2>&1 && [ -x ${SX_VENV}/bin/python ]"; then
  ok "skip: searxng build/runtime deps + venv already present"
else
  run_once searxng-apt -- in_debian \
    "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       git build-essential python3-dev python3-venv python3-pip python3-babel \
       uwsgi uwsgi-plugin-python3 \
       libxml2-dev libxslt1-dev zlib1g-dev libffi-dev libssl-dev shared-mime-info \
       ca-certificates" \
    || die "could not install SearXNG build/runtime deps inside the userland"
  in_debian "command -v uwsgi >/dev/null 2>&1" \
    || die "uwsgi still missing after apt — check 'dpkg --audit' inside the userland"
fi

# ── 2. Clone the source + build the venv (editable install) ──────────────────
# Idempotent: clone only if absent (shallow on a branch ref, with a full-clone +
# checkout fallback for a commit-SHA pin), then create the venv + pip-install the
# project editable if `import searx` does not yet succeed. --use-pep517
# --no-build-isolation is intentional (per SearXNG's build template) so the
# system toolchain + the pre-installed build deps are used for the native wheels.
say "building SearXNG into ${SX_DIR} (git clone + venv + editable install; first run is slow)"
in_debian "
  set -e
  if [ -f '${SX_DIR}/searx/webapp.py' ]; then
    echo 'searxng source already present at ${SX_DIR}'
  else
    git clone --depth 1 --branch '${SEARXNG_REF}' '${SEARXNG_REPO}' '${SX_DIR}' \
      || { rm -rf '${SX_DIR}'; git clone '${SEARXNG_REPO}' '${SX_DIR}' && git -C '${SX_DIR}' checkout '${SEARXNG_REF}'; }
  fi
  if [ -x '${SX_VENV}/bin/python' ] && '${SX_VENV}/bin/python' -c 'import searx' 2>/dev/null; then
    echo 'searxng venv already provisioned (searx importable)'
  else
    [ -x '${SX_VENV}/bin/python' ] || python3 -m venv '${SX_VENV}'
    # Build prerequisites per the official build template, then editable install.
    '${SX_VENV}/bin/pip' install -U pip setuptools wheel pyyaml msgspec typing-extensions pybind11 >/dev/null
    cd '${SX_DIR}' && '${SX_VENV}/bin/pip' install --use-pep517 --no-build-isolation -e .
    '${SX_VENV}/bin/python' -c 'import searx'
  fi
" 2>&1 | grep -v 'proot warning' || die "SearXNG build failed inside the userland (see output above)"

# Fail closed: the source tree + the venv interpreter must exist and import searx.
in_debian "[ -f '${SX_DIR}/searx/webapp.py' ] && [ -x '${SX_VENV}/bin/python' ] && '${SX_VENV}/bin/python' -c 'import searx'" \
  || die "SearXNG build incomplete (need ${SX_DIR}/searx/webapp.py + an importable searx in ${SX_VENV})"
ok "SearXNG built at ${SX_DIR} (venv ${SX_VENV})"

# ── 3. Generate + persist the per-deployment server.secret_key ────────────────
# SearXNG REQUIRES server.secret_key. It is a PER-DEPLOYMENT secret (not a shared
# operator credential): generate once with `openssl rand -hex 32` (64 hex chars),
# persist under ${DATA_DIR}/secrets (600), reuse on every re-run. NEVER hardcode
# it; NEVER copy any value from a reference deployment. We inject it at runtime
# via the uWSGI env (env = SEARXNG_SECRET_KEY=…) so the secret never lives in
# settings.yml on the volume/userland at rest; settings.yml carries a placeholder
# and the env value wins.
if [ -f "${SECRETS_FILE}" ]; then
  # shellcheck disable=SC1090
  . "${SECRETS_FILE}"
  say "reusing SearXNG secret_key from ${SECRETS_FILE}"
else
  SEARXNG_SECRET_KEY="$(openssl rand -hex 32)"   # 64 hex chars
  umask 077
  cat > "${SECRETS_FILE}" <<EOF
# Per-deployment SearXNG server.secret_key — generated by apps/searxng.sh.
# Keep private. Deleting this file rotates the key (invalidates any signed state).
SEARXNG_SECRET_KEY=${SEARXNG_SECRET_KEY}
EOF
  chmod 600 "${SECRETS_FILE}"
  ok "generated SearXNG secret_key → ${SECRETS_FILE} (chmod 600)"
fi
[ -n "${SEARXNG_SECRET_KEY:-}" ] || die "SearXNG secret_key is empty — check ${SECRETS_FILE}"

# ── 4a. Hardened settings.yml (written into the userland; source of truth) ────
# Re-applied on every run so a userland wipe is recoverable. use_default_settings
# keeps the full upstream engine catalogue (≈80 engines) for diverse results;
# we override only what matters. Hardening rationale inline. The secret_key here
# is a PLACEHOLDER — the uWSGI env value (step 4b) overrides it at runtime.
say "writing hardened settings.yml → ${SETTINGS}"
in_debian "mkdir -p ${SX_ETC}"
proot-distro login debian -- bash -lc "cat > ${SETTINGS}" <<YAML
# Managed by apps/searxng.sh — hardened single-tenant instance. RE-APPLY ON
# UPGRADE. secret_key is injected at runtime via the env var SEARXNG_SECRET_KEY
# (uwsgi.ini env=), so the value below is a placeholder that is never used.
#
# The FULL upstream engine catalogue stays active (use_default_settings: true);
# per-query wall-clock is bounded by outgoing.request_timeout, not by the engine
# count — SearXNG queries a category's engines in PARALLEL and renders when the
# slowest responds or times out, so a tight timeout lets slow / bot-blocked
# engines fall out while every quick engine still contributes.
use_default_settings: true

general:
  debug: false
  instance_name: "${SX_INSTANCE_NAME}"
  donation_url: false
  contact_url: false
  enable_metrics: false

server:
  # Overridden at runtime from \$SEARXNG_SECRET_KEY (env). Placeholder kept so the
  # file is valid even if read standalone; the env value always wins.
  secret_key: "set-via-env-SEARXNG_SECRET_KEY"
  bind_address: "127.0.0.1"
  port: ${SX_PORT}
  base_url: "https://${SX_HOST}/"
  # limiter:false because we run NO Valkey/Redis. The botdetection limiter
  # REQUIRES redis; enabling it without redis breaks every query. Abuse
  # rate-limiting is unnecessary anyway — the instance is single-tenant and the
  # whole host is gated at the Cloudflare edge.
  limiter: false
  public_instance: false
  # SSRF guard: image_proxy MUST stay false. With it ON, SearXNG fetches an image
  # URL SERVER-SIDE and proxies the bytes back — a visitor could point it at
  # http://127.0.0.1:<port>/… and turn the search box into a loopback
  # port-scanner / exfil for every on-box service. OFF = images render
  # client-side from the remote URL (we lose the privacy proxy but close the
  # loopback SSRF vector). Do not flip this to true.
  image_proxy: false
  method: "POST"
  http_protocol_version: "1.0"

search:
  safe_search: 0
  autocomplete: "duckduckgo"
  # formats: html ONLY — deliberately NO json/csv/rss, so the instance exposes no
  # scriptable/scrapable API surface (defence-in-depth behind the edge gate).
  formats:
    - html

ui:
  static_use_hash: true
  query_in_header: true
  infinite_scroll: false
  center_results: false
  results_on_new_tab: false

outgoing:
  request_timeout: 2.5          # default per-engine cap with the FULL catalogue
  max_request_timeout: 3.0      # hard ceiling so no single engine drags a query
  pool_connections: 100
  pool_maxsize: 40              # headroom for the wide parallel fan-out

# Botdetection / limiter back-end. We DO NOT run redis; with limiter:false this
# block is inert, but we set it false explicitly so an accidental limiter:true
# flip fails loudly instead of silently hammering a missing redis.
redis:
  url: false
YAML
in_debian "chmod 640 ${SETTINGS}" 2>/dev/null || true
ok "wrote ${SETTINGS} (chmod 640)"

# ── 4b. uwsgi.ini (workers=1, http-socket on loopback, settings + secret env) ─
# SearXNG's WSGI entrypoint is searx.webapp:application. We run an http-socket
# (NOT a uwsgi/unix socket) so Caddy can plain reverse_proxy to 127.0.0.1:${SX_PORT}.
# The system uwsgi binary loads the python3 plugin against our venv. workers=1
# keeps RSS modest on a phone (single-tenant instance). The secret_key is passed
# via env so it never lands in settings.yml at rest — hence this file is chmod 600.
say "writing uwsgi.ini → ${UWSGI_INI} (workers=1, http-socket 127.0.0.1:${SX_PORT})"
proot-distro login debian -- bash -lc "umask 077; cat > ${UWSGI_INI}" <<INI
# Managed by apps/searxng.sh — SearXNG uWSGI app (single worker). Carries the
# runtime secret_key in env= → chmod 600. RE-APPLY ON UPGRADE.
[uwsgi]
# Run in proot as root (single-tenant, like the rest of the stack). No uid/gid drop.
uid = root
gid = root

# Python plugin + venv (the system uwsgi binary loads the python3 plugin).
plugins = python3
virtualenv = ${SX_VENV}
pythonpath = ${SX_DIR}
chdir = ${SX_DIR}
module = searx.webapp

# Loopback HTTP socket for Caddy reverse_proxy. NOT a public bind.
http-socket = 127.0.0.1:${SX_PORT}
buffer-size = 8192

# Single worker (single-tenant instance; keeps RSS modest on a phone).
master = true
workers = 1
threads = 4
single-interpreter = true
enable-threads = true
lazy-apps = true

# Behaviour / lifecycle
die-on-term = true
need-app = true
auto-procname = true
procname-prefix-spaces = searxng
disable-logging = true
log-5xx = true
harakiri = 30

# Environment: settings path + the runtime secret_key (overrides settings.yml).
env = SEARXNG_SETTINGS_PATH=${SETTINGS}
env = SEARXNG_SECRET_KEY=${SEARXNG_SECRET_KEY}
env = LANG=C.UTF-8
INI
in_debian "chmod 600 ${UWSGI_INI}" 2>/dev/null || true   # carries the secret_key
ok "wrote ${UWSGI_INI} (chmod 600)"

# ── 5. Caddy vhost (self-contained site block, imported by the core Caddyfile) ─
# Matches the core Caddyfile listener style EXACTLY: explicit
# http://<host>:${CADDY_PORT} + bind ${CADDY_BIND} (plain HTTP on the shared high
# loopback port; the Cloudflare Tunnel terminates public TLS). The core Caddyfile
# imports /etc/caddy/apps/*.caddy, so dropping this file in is all it takes.
#
# AUTH: SearXNG has NO native login. The DEFAULT is a plain reverse_proxy + a
# REQUIRED Cloudflare Access policy at the edge (configured in the Cloudflare
# dashboard). The OPTIONAL Matrix-SSO gateway block is COMMENTED OUT (uncomment
# only if you run that add-on — see docs/APP_AUTH.md); its /authgw/* handler must
# precede the gated catch-all so the login page itself stays reachable.
say "writing the Caddy vhost → /etc/caddy/apps/searxng.caddy"
proot-distro login debian -- bash -lc 'mkdir -p /etc/caddy/apps && cat > /etc/caddy/apps/searxng.caddy' <<EOF
# ============================================================================
# SearXNG (private metasearch) — search.${DOMAIN}   (NO native auth)
# Public hostname search.${DOMAIN}; bound to loopback (the Cloudflare Tunnel
# forwards public traffic here). uWSGI app on 127.0.0.1:${SX_PORT}.
#
# AUTH (REQUIRED): SearXNG has NO login of its own — left open it is an
# unauthenticated metasearch PROXY anyone could drive. You MUST protect this host
# with a Cloudflare Access policy at the edge (Cloudflare Zero Trust dashboard).
# To gate it with the OPTIONAL Matrix-SSO gateway instead, uncomment the block
# below (the /authgw/* handler MUST precede the gated catch-all). See
# docs/APP_AUTH.md.
# Installed by scripts/apps/searxng.sh.
# ============================================================================
http://${SX_HOST}:${CADDY_PORT} {
	bind ${CADDY_BIND}

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options nosniff
		X-Frame-Options DENY
		Referrer-Policy strict-origin-when-cross-origin
		Cross-Origin-Opener-Policy same-origin
		-Server
	}

	# ── OPTIONAL: Matrix-SSO gateway add-on (default is Cloudflare Access) ──
	# Uncomment to require a Matrix-SSO session cookie for the whole site. The
	# /authgw/* handler MUST come first so the login page itself stays reachable;
	# the forward_auth then gates everything else (non-2xx → the gateway's 302 to
	# the login form). See docs/APP_AUTH.md.
	#
	# handle /authgw/* {
	# 	reverse_proxy 127.0.0.1:9095
	# }
	# handle {
	# 	forward_auth 127.0.0.1:9095 {
	# 		uri /authgw/verify
	# 		copy_headers Remote-User
	# 	}
	# 	reverse_proxy 127.0.0.1:${SX_PORT} {
	# 		header_up Host {http.request.host}
	# 		header_up X-Forwarded-Proto https
	# 	}
	# }

	# Default: plain proxy to uWSGI. The Cloudflare Access policy at the edge is
	# the front door. (Comment this out if you enable the gateway block above.)
	reverse_proxy 127.0.0.1:${SX_PORT} {
		header_up Host {http.request.host}
		header_up X-Forwarded-Proto https
	}
}
EOF
ok "wrote /etc/caddy/apps/searxng.caddy"

# Validate the FULL Caddyfile inside the userland (fail closed). We do NOT restart
# Caddy here — print the restart hint instead so an already-running stack picks up
# the new vhost on the operator's schedule.
say "validating the Caddyfile inside the userland"
in_debian 'caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile' \
  || die "caddy validate FAILED — refusing to leave a broken vhost in place (fix /etc/caddy/apps/searxng.caddy)"
ok "Caddyfile still valid with the searxng vhost added"

# ── 6. Supervise the uWSGI service ────────────────────────────────────────────
# The shared supervisor (respawn loop + identity-checked pidfile) runs uwsgi in
# the foreground inside the userland (master mode, no daemonize) so the loop owns
# it. The uwsgi.ini env injects the secret_key + settings path. The supervisor's
# argv carries the ini path, which the identity check matches on.
supervise searxng -- \
  proot-distro login debian -- /usr/bin/uwsgi --ini "${UWSGI_INI}"

# ── Closing notes ─────────────────────────────────────────────────────────────
echo
ok "SearXNG installed + supervised (uWSGI loopback 127.0.0.1:${SX_PORT})"
say "Liveness (direct, bypasses any gate): curl -sf http://127.0.0.1:${SX_PORT}/"
echo
warn "SearXNG has NO authentication of its own. Left unprotected, search.${DOMAIN} is an"
warn "OPEN metasearch proxy that anyone on the internet can drive. You MUST gate it —"
warn "either with a Cloudflare Access policy at the edge (the default, below) or with the"
warn "optional Matrix-SSO gateway block in the vhost (see docs/APP_AUTH.md). Do NOT expose"
warn "this host without one of those gates in place."
echo
say "Manual Cloudflare steps (in the Cloudflare dashboard — NOT done by this script):"
say "  1. In the Tunnel config, add a Public Hostname:"
say "       ${SX_HOST}  ->  http://localhost:${CADDY_PORT}  (the local Caddy edge, plain HTTP)"
say "  2. Add a Cloudflare Access policy (Zero Trust) protecting ${SX_HOST} so only your"
say "     chosen identities can reach it. This step is REQUIRED here — SearXNG has no"
say "     login of its own, so the edge gate IS the only front door (unless you enable the"
say "     optional Matrix-SSO gateway block in the vhost)."
say "  If the core stack is already running, pick up the new vhost with:"
say "       bash ${POCKET_ROOT}/scripts/start-stack.sh --restart"
say "  (brief ingress outage while cloudflared cycles)."

# Generalized from a working deployment; review before running.
