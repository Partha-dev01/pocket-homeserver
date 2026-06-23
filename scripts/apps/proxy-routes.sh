#!/usr/bin/env bash
#
# apps/proxy-routes.sh — generate operator-defined, LOOPBACK-ONLY Caddy vhosts from
# a PROXY_ROUTES list in .env (the "bring-your-own reverse-proxy" module).
#
# This is the ONE place where the operator can publish a service that pocket-
# homeserver does not ship a dedicated app for — e.g. their own little Go/Node/
# Python daemon already listening on 127.0.0.1:NNNN inside the userland. It writes
# nothing but Caddy site blocks; there is NO binary to download, NO data to store,
# and NO supervised process. Each route becomes `sub.${DOMAIN}` fronted by the core
# loopback Caddy edge on ${CADDY_BIND}:${CADDY_PORT}, exactly like every built-in app.
#
# INPUT (from .env): PROXY_ROUTES — a whitespace/newline-separated list of entries
#   sub=HOST:PORT
# e.g.
#   PROXY_ROUTES="grafana=127.0.0.1:3000 metrics=localhost:9091
#   uptime=127.0.0.1:3001"
# For EACH entry this script:
#   1. parses sub / host / port,
#   2. ┌── SECURITY-LOAD-BEARING ──────────────────────────────────────────────┐
#      │ REFUSES (die) any target whose host is not exactly 127.0.0.1 or ::1    │
#      │ ('localhost' is normalized to 127.0.0.1). The whole point of this      │
#      │ stack is that NOTHING listens off-loopback; letting an operator point  │
#      │ a public hostname at a LAN/Internet address would tunnel arbitrary     │
#      │ traffic out through their Cloudflare account. This is the load-bearing │
#      │ gate — it fails closed and writes nothing on a bad host.               │
#      └───────────────────────────────────────────────────────────────────────┘
#   3. validates `sub` against a strict DNS-label regex and `port` as an integer
#      1..65535 (a Caddyfile-injection guard — the values are interpolated into a
#      heredoc, so a hostile sub/port could otherwise inject directives),
#   4. COLLISION-CHECKS sub.${DOMAIN} against the built-in/core hostnames AND any
#      site address already present in /etc/caddy/apps/*.caddy, and dies on a clash
#      (we do NOT rely on `caddy validate` to catch a duplicate site address — its
#      behaviour on duplicate addresses is not a guarantee we want to lean on),
#   5. WARNS (does not fail) if PORT matches a known built-in loopback port, since
#      that almost certainly means the operator typo'd a port and is about to proxy
#      their public hostname straight at adminweb / the auth gateway / a media app.
# After ALL routes are written it runs `caddy validate` ONCE, fail-closed; if it
# fails, every byo-*.caddy this run created is REMOVED so we never leave a broken
# Caddyfile behind.
#
# STORAGE: none (no DB/index/WAL/cache/state) — only Caddy site files in the
# userland at /etc/caddy/apps/byo-<sub>.caddy. SECRETS: none.
#
# AUTH MODEL: each generated vhost is, by default, gated ONLY at the Cloudflare edge
# (Cloudflare Access — a policy you add in the dashboard, NOT wired here). Whatever
# you proxy keeps its own auth too. The standard 3-part Matrix-SSO forward_auth
# block is written COMMENTED OUT (copied from the built-in apps) for the operator to
# opt into per route. A backend that speaks a non-browser/token API (and so cannot
# follow a 302-to-login) must NOT be put behind forward_auth — see docs/PROXY_ROUTES.md.
#
# NOTE: enabling/disabling is handled by install.sh (it only runs this when
# ENABLE_PROXY_ROUTES=true), so this script does not re-check the flag.
#
# Idempotent — re-running rewrites this run's byo-*.caddy from the current
# PROXY_ROUTES. Generalized from the dufs/radicale vhost pattern; review first.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env
require_var DOMAIN "your public domain, e.g. example.com"
require_cmd proot-distro

in_debian() { proot-distro login debian -- bash -lc "$1"; }

# ── Preflight: the userland + the core Caddyfile must exist ──────────────────
in_debian 'true' >/dev/null 2>&1 || die "proot-distro debian not reachable — install the userland first (run scripts/install.sh)"
in_debian '[ -f /etc/caddy/Caddyfile ]' \
  || die "no /etc/caddy/Caddyfile in the userland — install + render the core edge first (run scripts/install.sh)"

# ── Read PROXY_ROUTES ─────────────────────────────────────────────────────────
# Empty is allowed and NOT an early exit: it means "no BYO routes", and we still want
# to sweep away any byo-*.caddy left from a previous run (so a removed route stops
# being published — this generator is authoritative). The route loop simply iterates
# nothing; the stale-sweep below does the cleanup.
PROXY_ROUTES="${PROXY_ROUTES:-}"
if [ -z "${PROXY_ROUTES// /}" ]; then
  warn "PROXY_ROUTES is empty — no routes to generate; will sweep any stale byo-*.caddy. Set it in .env (e.g. 'grafana=127.0.0.1:3000') to publish a loopback service. See docs/PROXY_ROUTES.md"
fi

# ── Built-in / core hostname reservations (collision guard) ──────────────────
# Subdomains owned by the core stack or a shipped optional app. A BYO route may
# never claim one of these — sub.${DOMAIN} must be unique. (dns/git are reserved
# for forward-looking core hostnames so a BYO route can't squat them later.)
CORE_SUBS="chat admin files music books audiobooks read dav wiki vault links share rss notes tasks search tools status stickers webmail ai mcp git dns"

# ── Known built-in loopback ports (warn-only) ────────────────────────────────
# A BYO route pointing at one of these almost certainly means a typo'd port that
# would proxy a public hostname straight at an internal service. We WARN, not die,
# because an operator legitimately running e.g. a second front-end on adminweb's
# data is their call — but it should be loud.
# format: "port:what"
KNOWN_PORTS="9000:adminweb 9095:auth-gw 9120:mcp 9123:navidrome 9124:kavita 9127:audiobookshelf 9128:forgejo 8448:matrix 8443:caddy"

# ── DNS-label regex (Caddyfile-injection guard for `sub`) ────────────────────
# A single label: starts/ends alphanumeric, may contain hyphens, 1..63 chars.
SUB_RE='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'

APPS_DIR=/etc/caddy/apps
in_debian "mkdir -p ${APPS_DIR}" || die "failed to create ${APPS_DIR} in the userland"

# Snapshot the site addresses ALREADY declared in /etc/caddy/apps/*.caddy (other
# apps' vhosts + any byo-*.caddy from a previous run we are not rewriting this run).
# We match the leading `http://<host>:` site-address line each app block opens with.
# This is read ONCE up front; routes we write this run are tracked separately below
# so two routes in the same PROXY_ROUTES can't silently collide either.
EXISTING_HOSTS="$(in_debian "grep -hoE '^http://[A-Za-z0-9.-]+:' ${APPS_DIR}/*.caddy 2>/dev/null | sed -E 's#^http://##; s#:\$##'" || true)"

# Files we create THIS run — for the fail-closed rollback if `caddy validate` fails.
written_files=()
# sub.${DOMAIN} hosts we have accepted this run (intra-run duplicate guard).
declare -A seen_hosts=()

host_is_loopback() {  # host_is_loopback HOST  → rc0 if loopback (after normalize)
  case "$1" in
    127.0.0.1|::1) return 0 ;;
    *) return 1 ;;
  esac
}

# ── Parse + validate + write each route ──────────────────────────────────────
n_routes=0
# Word-split PROXY_ROUTES on whitespace/newlines (the documented separator).
for entry in ${PROXY_ROUTES}; do
  [ -n "${entry}" ] || continue

  # entry must be exactly sub=HOST:PORT
  case "${entry}" in
    *=*) : ;;
    *) die "PROXY_ROUTES entry '${entry}' is malformed — expected 'sub=HOST:PORT' (e.g. grafana=127.0.0.1:3000)" ;;
  esac
  sub="${entry%%=*}"
  target="${entry#*=}"

  # split HOST:PORT on the LAST colon, so an IPv6 host like ::1 is handled.
  case "${target}" in
    *:*) : ;;
    *) die "PROXY_ROUTES entry '${entry}' has no PORT — expected 'sub=HOST:PORT' (e.g. ${sub}=127.0.0.1:3000)" ;;
  esac
  port="${target##*:}"
  host="${target%:*}"

  # Normalize the convenience alias 'localhost' → 127.0.0.1.
  [ "${host}" = "localhost" ] && host="127.0.0.1"

  # ── (2) SECURITY-LOAD-BEARING loopback gate (fail-closed) ──────────────────
  host_is_loopback "${host}" \
    || die "PROXY_ROUTES entry '${entry}': target host '${host}' is NOT loopback. Only 127.0.0.1 or ::1 (or 'localhost') are allowed — refusing to publish a public hostname pointing off-loopback (this would tunnel arbitrary traffic out through your Cloudflare account). See docs/PROXY_ROUTES.md"

  # ── (3a) strict DNS-label validation for `sub` (injection guard) ───────────
  # Lower-case first so 'Grafana' is accepted but normalized.
  sub="$(printf '%s' "${sub}" | tr '[:upper:]' '[:lower:]')"
  printf '%s' "${sub}" | grep -Eq "${SUB_RE}" \
    || die "PROXY_ROUTES entry '${entry}': subdomain '${sub}' is not a valid DNS label (must match ${SUB_RE} — lowercase letters/digits/hyphen, 1..63 chars, no leading/trailing hyphen)"

  # ── (3b) port must be an integer 1..65535 (injection guard) ────────────────
  case "${port}" in
    ''|*[!0-9]*) die "PROXY_ROUTES entry '${entry}': port '${port}' is not a number" ;;
  esac
  if [ "${port}" -lt 1 ] || [ "${port}" -gt 65535 ]; then
    die "PROXY_ROUTES entry '${entry}': port '${port}' is out of range (must be 1..65535)"
  fi

  fqdn="${sub}.${DOMAIN}"

  # ── (4) collision check — core hostnames, prior apps, and this run ─────────
  for c in ${CORE_SUBS}; do
    if [ "${sub}" = "${c}" ]; then
      die "PROXY_ROUTES entry '${entry}': '${sub}.${DOMAIN}' collides with the built-in/reserved hostname '${c}.${DOMAIN}' — pick a different subdomain"
    fi
  done
  if [ -n "${seen_hosts[${fqdn}]:-}" ]; then
    die "PROXY_ROUTES has two routes for '${fqdn}' — each subdomain may appear at most once"
  fi
  # Match against site addresses already on disk (other apps / a prior byo run we
  # are not rewriting this very iteration). We compare the bare fqdn.
  while IFS= read -r h; do
    [ -n "${h}" ] || continue
    if [ "${h}" = "${fqdn}" ]; then
      # A byo-<sub>.caddy we are about to (re)write this run is fine — that is
      # idempotent self-overwrite. Only an address owned by a DIFFERENT file is a clash.
      owner="$(in_debian "grep -lE '^http://${fqdn}:' ${APPS_DIR}/*.caddy 2>/dev/null | head -1 | xargs -r basename" || true)"
      if [ -n "${owner}" ] && [ "${owner}" != "byo-${sub}.caddy" ]; then
        die "PROXY_ROUTES entry '${entry}': '${fqdn}' is already served by ${APPS_DIR}/${owner} — refusing to create a duplicate site address"
      fi
    fi
  done <<EOF
${EXISTING_HOSTS}
EOF
  seen_hosts[${fqdn}]=1

  # ── (5) warn-only known-port collision ─────────────────────────────────────
  for kp in ${KNOWN_PORTS}; do
    if [ "${port}" = "${kp%%:*}" ]; then
      warn "PROXY_ROUTES entry '${entry}': port ${port} is a known built-in loopback port (${kp#*:}). If that was a typo you are about to publish ${fqdn} straight onto an internal service — double-check the port."
    fi
  done

  # ── write /etc/caddy/apps/byo-<sub>.caddy ──────────────────────────────────
  # Listener style MUST match the built-in vhosts: explicit `http://<host>:${CADDY_PORT}`
  # + `bind ${CADDY_BIND}` (plain HTTP on the shared high loopback port; the
  # Cloudflare Tunnel terminates public TLS). All interpolated values (DOMAIN,
  # CADDY_BIND, CADDY_PORT, fqdn, host, port) are already validated above.
  # The 3-part Matrix-SSO forward_auth block is copied COMMENTED from dufs.sh.
  caddy_file="${APPS_DIR}/byo-${sub}.caddy"
  say "writing BYO vhost → ${caddy_file}  (${fqdn} → ${host}:${port})"
  if ! proot-distro login debian -- bash -lc "mkdir -p ${APPS_DIR} && cat > ${caddy_file}" <<EOF
# ${fqdn} — operator-defined reverse proxy (BYO route from PROXY_ROUTES).
# Written by scripts/apps/proxy-routes.sh. Loopback-only; the Cloudflare Tunnel
# forwards public traffic here and (by default) Cloudflare Access gates the
# hostname at the edge. The proxied backend keeps its own auth. The target host is
# enforced to be loopback at generation time. See docs/PROXY_ROUTES.md.
http://${fqdn}:${CADDY_PORT} {
	bind ${CADDY_BIND}

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options nosniff
		X-Frame-Options SAMEORIGIN
		Referrer-Policy no-referrer
		-Server
	}

	# OPTIONAL Matrix-SSO gateway add-on (advanced; see docs/APP_AUTH.md).
	# Disabled by default — the default front door is Cloudflare Access at the
	# edge. If you enable it, the three parts MUST precede the reverse_proxy below:
	# the /authgw/* handler keeps the login form reachable (else the 302-to-login
	# loops), the request_header strips any client-forged Remote-User before the
	# gate, and forward_auth gates the rest. Do NOT enable it for a backend that
	# speaks a token/non-browser API (it cannot follow the 302-to-login).
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

	# Everything → the operator's loopback backend.
	reverse_proxy ${host}:${port}
}
EOF
  then
    die "failed to write ${caddy_file} into the userland"
  fi
  written_files+=("${caddy_file}")
  n_routes=$((n_routes + 1))
  ok "wrote ${caddy_file}"
done

# ── Sweep stale BYO vhosts (routes removed from PROXY_ROUTES) ─────────────────
# This generator is AUTHORITATIVE: a byo-<sub>.caddy whose subdomain is no longer in
# the current PROXY_ROUTES must stop being published. Remove any byo-*.caddy that we
# did NOT (re)write this run. We only ever touch our own byo-* namespace — never
# another app's vhost — so this cannot disturb a built-in app's site block.
keep=" "
for f in "${written_files[@]:-}"; do [ -n "${f}" ] && keep="${keep}$(basename "${f}") "; done
swept=0
while IFS= read -r sf; do
  [ -n "${sf}" ] || continue
  base="$(basename "${sf}")"
  case "${keep}" in
    *" ${base} "*) : ;;                       # kept — written this run
    *) say "removing stale BYO vhost (no longer in PROXY_ROUTES): ${base}"
       in_debian "rm -f ${APPS_DIR}/${base}" 2>/dev/null && swept=$((swept + 1)) || true ;;
  esac
done <<EOF
$(in_debian "ls -1 ${APPS_DIR}/byo-*.caddy 2>/dev/null" || true)
EOF
[ "${swept}" -gt 0 ] && ok "swept ${swept} stale BYO vhost(s) for removed route(s)"

if [ "${n_routes}" -eq 0 ] && [ "${swept}" -eq 0 ]; then
  warn "PROXY_ROUTES produced no usable routes and there was nothing stale to remove — nothing to do"
  exit 0
fi

# ── Validate the WHOLE Caddyfile ONCE, fail-closed (roll back on failure) ────
# If validation fails we REMOVE every byo-*.caddy we wrote this run so we never
# leave a broken edge config in place. We do NOT restart Caddy here (no app script
# does); start-stack.sh brings the edge up afterward (or --restart reloads it).
say "validating the Caddyfile inside the userland (after writing ${n_routes} BYO route(s))"
if ! in_debian 'caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile'; then
  warn "caddy validate FAILED — removing the ${n_routes} byo-*.caddy file(s) written this run to keep the Caddyfile valid"
  for f in "${written_files[@]}"; do
    in_debian "rm -f ${f}" 2>/dev/null || true
  done
  die "caddy validate FAILED for the generated BYO routes — rolled back; check PROXY_ROUTES in .env. See docs/PROXY_ROUTES.md"
fi
ok "BYO routes written + Caddyfile validates (${n_routes} route(s))"

# ── Closing notes (manual Cloudflare steps — NOT done by this script) ────────
cat >&2 <<EOF

$(ok "proxy-routes installed — ${n_routes} operator-defined vhost(s) generated" 2>&1)

  For EACH route's subdomain you must finish in the Cloudflare dashboard (NOT done
  by this script):
    1. Public hostname: add a Public Hostname in your Cloudflare Tunnel:
         sub.${DOMAIN}  ->  http://localhost:${CADDY_PORT}
       (plain HTTP — the tunnel terminates public TLS).
    2. Cloudflare Access: add an Access application/policy covering sub.${DOMAIN}
       so only people you allow can reach it. The proxied backend keeps its OWN
       auth too. A backend that speaks a non-browser/token API needs a service-
       token exemption instead of an interactive login. See docs/APP_AUTH.md.

  Each generated file is ${APPS_DIR}/byo-<sub>.caddy in the userland; remove a
  route by deleting its entry from PROXY_ROUTES and re-running — the generator
  rewrites the live routes and AUTOMATICALLY sweeps away the byo-*.caddy for any
  route you dropped (no hand-deletion needed), then re-validates fail-closed.

  If the stack is ALREADY running, reload Caddy so the new vhosts go live:
         bash ${POCKET_ROOT}/scripts/start-stack.sh --restart
    (a full install starts the stack afterward, so no reload is needed then).

  More detail: docs/PROXY_ROUTES.md.
EOF

ok "apps/proxy-routes.sh done"

# Generalized from the dufs/radicale vhost pattern; review before running.
