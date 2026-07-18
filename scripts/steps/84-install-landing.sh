#!/usr/bin/env bash
#
# steps/84-install-landing.sh — install the OPTIONAL customizable landing portal:
# a clean static service directory served by the core Caddy at your apex domain
# (http://${DOMAIN}): a clean, attractive index of the apps you have enabled.
#
# This is a core step that SELF-GATES on ENABLE_LANDING (install.sh runs it
# unconditionally; it no-ops when disabled). ENABLE_LANDING defaults to false.
#
# There is NO separate long-running process to supervise: the already-running
# core Caddy serves the static files directly. The page CONTENT (the app-card
# grid + the "your sites" grid) is rendered by scripts/landing/regen-landing.sh
# — the SAME render code path the Sites deploy/delete hot path calls at
# runtime (SPEC-LANDING-SYNC.md AD-6) — so this script is now a thin wrapper
# around that render plus the parts that only make sense at install time.
#
# What it does (idempotent — safe to re-run):
#   1. delegates the landing-page render to scripts/landing/regen-landing.sh,
#      fail-closed (SPEC-LANDING-SYNC.md §8 AD-7 — install-time failures MUST
#      fail the install; the Sites hot path is the one that goes best-effort),
#   2. copies the favicon into a dir INSIDE the userland (${LANDING_ROOT},
#      outside any app webroot) that Caddy can serve,
#   3. renders scripts/landing/landing.caddy.tmpl and drops it into
#      /etc/caddy/apps/landing.caddy (apex http://${DOMAIN}:${CADDY_PORT}),
#   4. validates the FULL Caddyfile fail-closed (it does NOT restart Caddy),
#   5. prints the restart hint + the manual Cloudflare apex-hostname step.
#
# Runtime: this step runs TERMUX-NATIVE but uses `proot-distro login debian` to
# write the favicon + vhost INTO the userland, because the core Caddy runs
# inside the userland and serves files from paths visible there.
#
# Generalized from a working deployment; review before running.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env

# ── Self-gate: only run when enabled (default off) ───────────────────────────
if [ "${ENABLE_LANDING:-false}" != "true" ]; then
  ok "landing portal disabled (ENABLE_LANDING != true) — skipping"
  exit 0
fi

require_var DOMAIN "your apex domain, e.g. example.com"
require_cmd proot-distro

in_debian() { proot-distro login debian -- bash -lc "$1"; }

# ── Paths + brand ─────────────────────────────────────────────────────────────
LANDING_DIR="${POCKET_ROOT}/scripts/landing"     # the templates ship here
PAGE_TMPL="${LANDING_DIR}/index.html.tmpl"
VHOST_TMPL="${LANDING_DIR}/landing.caddy.tmpl"
FAVICON_SRC="${LANDING_DIR}/favicon.svg"
LANDING_ROOT="/opt/landing"                       # serve dir INSIDE the userland (outside any app webroot)
BRAND="${LANDING_BRAND:-${DOMAIN}}"               # portal brand; defaults to the domain

[ -f "${PAGE_TMPL}" ]  || die "landing page template missing: ${PAGE_TMPL} — the landing module was not shipped"
[ -f "${VHOST_TMPL}" ] || die "landing vhost template missing: ${VHOST_TMPL}"

# ── Preflight: the userland must exist (Caddy runs inside it) ─────────────────
in_debian 'true' >/dev/null 2>&1 || die "proot-distro debian not reachable — install the userland first (run scripts/install.sh)"

# ── 1. Render the landing page via regen-landing.sh (SPEC-LANDING-SYNC §8) ───
# Delegates card-building + the "your sites" grid + the actual write into
# ${LANDING_ROOT}/index.html to the shared render script (AD-6: one render
# code path, used by both this installer and the Sites deploy/delete hot
# path). Deliberately NO `|| true` here (AD-7): a broken landing render fails
# the install, matching this script's own fail-closed `caddy validate`
# convention below. regen-landing.sh re-checks require_var DOMAIN itself too
# (it is also called standalone from the Sites hot path, where nothing else
# has already validated the environment).
say "rendering the landing page via regen-landing.sh"
bash "${POCKET_ROOT}/scripts/landing/regen-landing.sh" \
  || die "landing page render failed — see the output above"
ok "landing page installed (${LANDING_ROOT}/index.html)"

# ── 2. Copy the favicon into the userland serve dir (install-only; unchanged) ─
if [ -f "${FAVICON_SRC}" ]; then
  proot-distro login debian -- bash -lc "umask 022; cat > '${LANDING_ROOT}/favicon.svg'" < "${FAVICON_SRC}" \
    && in_debian "chmod 644 '${LANDING_ROOT}/favicon.svg'" || warn "could not install favicon.svg — the portal will 404 /favicon.svg (cosmetic)"
else
  warn "favicon.svg missing at ${FAVICON_SRC} — the portal will 404 /favicon.svg (cosmetic)"
fi

# ── 3. Render + drop the apex Caddy vhost ─────────────────────────────────────
# Substitute ALL template tokens with sed (mirrors scripts/render-config.sh): the
# ${DOMAIN}/${CADDY_PORT}/${CADDY_BIND} site-address/bind vars AND __LANDING_ROOT__
# /__AUTHGW_PORT__. We must do this with sed, NOT rely on the heredoc: heredoc
# expansion is non-recursive, so any ${VAR} sitting INSIDE the value of
# ${VHOST_RENDERED} would survive verbatim and break `caddy validate`. The core
# Caddyfile imports /etc/caddy/apps/*.caddy, so dropping this file in is all it
# takes — no hand-edit of the core file.
say "writing the apex Caddy vhost -> /etc/caddy/apps/landing.caddy"
VHOST_RENDERED="$(sed \
  -e "s|\${DOMAIN}|${DOMAIN}|g" \
  -e "s|\${CADDY_PORT}|${CADDY_PORT}|g" \
  -e "s|\${CADDY_BIND}|${CADDY_BIND}|g" \
  -e "s|__AUTHGW_PORT__|${AUTHGW_PORT:-9095}|g" \
  -e "s|__LANDING_ROOT__|${LANDING_ROOT}|g" \
  "${VHOST_TMPL}")"
proot-distro login debian -- bash -lc 'mkdir -p /etc/caddy/apps && cat > /etc/caddy/apps/landing.caddy' <<EOF || die "failed to write /etc/caddy/apps/landing.caddy"
${VHOST_RENDERED}
EOF
ok "wrote /etc/caddy/apps/landing.caddy (apex http://${DOMAIN}:${CADDY_PORT})"

# ── 4. Validate the FULL Caddyfile (fail closed; do NOT restart) ──────────────
# We do NOT restart Caddy here — print the restart hint instead so an already
# running stack picks up the new apex vhost on the operator's schedule.
say "validating the Caddyfile inside the userland"
in_debian 'caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile' \
  || die "caddy validate FAILED — refusing to leave a broken vhost in place (fix /etc/caddy/apps/landing.caddy)"
ok "Caddyfile still valid with the landing vhost added"

# ── Closing notes ─────────────────────────────────────────────────────────────
echo
ok "Landing portal installed (apex ${DOMAIN}; served by Caddy from ${LANDING_ROOT}; no separate process)"
say "Local check (the apex is matched by Host header on the shared listener):"
say "  curl -s -H 'Host: ${DOMAIN}' http://127.0.0.1:${CADDY_PORT}/ | grep -o '${BRAND}' | head -n1"
echo
say "Manual Cloudflare step (in the Cloudflare dashboard — NOT done by this script):"
say "  In the Tunnel config, add a Public Hostname for the APEX:"
say "       ${DOMAIN}  ->  http://localhost:${CADDY_PORT}  (apex CNAME-flattened; plain HTTP — the tunnel does TLS)"
say "  If you already serve mail/MX on the apex, Cloudflare handles both records."
say "  If the core stack is already running, pick up the new vhost with:"
say "       bash ${POCKET_ROOT}/scripts/start-stack.sh --restart"
say "  (brief ingress outage while cloudflared cycles)."

# Generalized from a working deployment; review before running.
