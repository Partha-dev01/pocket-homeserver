#!/usr/bin/env bash
#
# apps/sites.sh — install Pocket Pages: Netlify-like static-site hosting ON the
# phone. Drag-and-drop (admin panel, M2) or CLI/MCP deploys go through ONE
# pipeline (scripts/sites/site-deploy.sh) into per-site immutable release trees,
# published by an atomic symlink swap and served by the core Caddy at
# <site>.${DOMAIN}. Spec: docs/specs/SPEC-SITES-PIPELINE.md.
#
# What it does (idempotent — safe to re-run):
#   1. creates the sites root INSIDE the userland (/var/www/sites + .staging)
#      and seeds an empty registry (.registry.json) if absent,
#   2. computes the host-label index for ${DOMAIN} and renders
#      scripts/sites/sites.caddy.tmpl -> /etc/caddy/apps/sites.caddy — ONE
#      wildcard vhost (*.${DOMAIN}) whose file_server root is derived from the
#      request's host label; per-site deploys NEVER touch Caddy again (AD-1),
#   3. validates the FULL Caddyfile fail-closed (does NOT restart Caddy),
#   4. prints the manual Cloudflare step: either a ONE-TIME wildcard Public
#      Hostname (zero-dashboard-step future sites) or per-site hostnames.
#
# There is NO long-running process to supervise (landing-portal precedent): the
# already-running core Caddy serves every deployed site. Build toolchains
# (Hugo / Node) are NOT installed here — they install lazily on the first
# deploy that requests that build tier (SPEC AD-3), keeping this module light
# for upload-only users.
#
# Generalized from a working deployment; review before running.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env
require_var DOMAIN "your apex domain (DNS on Cloudflare)"
require_cmd proot-distro

in_debian() { proot-distro login debian -- bash -lc "$1"; }

SITES_DIR="${POCKET_ROOT}/scripts/sites"          # pipeline + template ship here
VHOST_TMPL="${SITES_DIR}/sites.caddy.tmpl"
SERVE_ROOT="/var/www/sites"                        # in-userland; Caddy roots here

[ -f "${VHOST_TMPL}" ] || die "sites vhost template missing: ${VHOST_TMPL} — the sites module was not shipped"
[ -f "${SITES_DIR}/site-deploy.sh" ] || die "pipeline missing: ${SITES_DIR}/site-deploy.sh"

# ── Preflight: the userland must exist (Caddy runs inside it) ─────────────────
in_debian 'true' >/dev/null 2>&1 || die "proot-distro debian not reachable — install the userland first (run scripts/install.sh)"

# ── 1. Sites root + staging + registry ────────────────────────────────────────
# The root lives INSIDE the userland rootfs: ext4 (symlinks/hardlinks/atomic
# rename all work — the deploy pipeline depends on that), Caddy-visible, and
# automatically inside ops/backup-all.sh's rootfs snapshot (SPEC AD-2). The
# runtime pipeline writes via the host-side rootfs path for speed; install-time
# setup goes through proot like every other app script.
say "creating the sites root (${SERVE_ROOT} + .staging) inside the userland"
in_debian "umask 022; mkdir -p '${SERVE_ROOT}/.staging' && chmod 755 '${SERVE_ROOT}' && chmod 700 '${SERVE_ROOT}/.staging'" \
  || die "failed to create ${SERVE_ROOT} in the userland"
# Seed the registry only if absent (idempotent — never clobber deployed state).
in_debian "[ -f '${SERVE_ROOT}/.registry.json' ] || printf '{\"version\": 1, \"sites\": {}}\n' > '${SERVE_ROOT}/.registry.json'" \
  || die "failed to seed ${SERVE_ROOT}/.registry.json"
ok "sites root ready (${SERVE_ROOT}; registry present)"

# ── 2. Render + drop the ONE wildcard vhost ───────────────────────────────────
# {labels.N} indexes host labels from the RIGHT (0-based), so the label index of
# the SITE name equals the number of labels in ${DOMAIN} itself:
#   example.com   -> 2 labels -> site label = {labels.2}
#   example.co.uk -> 3 labels -> site label = {labels.3}
LABEL_INDEX="$(awk -F. '{print NF}' <<<"${DOMAIN}")"
case "${LABEL_INDEX}" in
  ''|*[!0-9]*) die "could not compute the host-label index from DOMAIN='${DOMAIN}'" ;;
esac
[ "${LABEL_INDEX}" -ge 1 ] || die "DOMAIN='${DOMAIN}' does not look like a domain"

# SITES_SPA_MODE (SPEC-SITES-PANEL.md §15/AD-9): a single GLOBAL, install/
# toggle-time choice — resolved HERE, never per-deploy, because it edits the
# ONE wildcard vhost, not a per-site config. `true` swaps the bare
# `file_server` line in sites.caddy.tmpl for `try_files {path} {path}/
# /index.html` + `file_server` so a client-side router keeps working on a
# hard refresh/deep link.
# ⚠ SIBLING directives, NEVER a `route { … }` wrapper: Caddy's directive sort
# order runs `route` BEFORE `respond`, so a route-wrapped file_server would
# serve dotfiles before the vhost's `respond @dot 403` guard ever runs
# (probed on caddy v2.11.4: route-wrapped served an existing /assets/.env).
# As siblings, try_files sorts before respond, so an EXISTING dotfile keeps
# its original path and still 403s; `{path}/` keeps subdirectory index pages
# working (without it, /docs rewrites to the root /index.html).
# Built as a variable (not sed, which struggles with multi-line replacements)
# and substituted below via the same awk marker-line technique
# regen-landing.sh already uses for POCKET_CARDS/POCKET_SITES_SECTION.
if [ "${SITES_SPA_MODE:-false}" = "true" ]; then
  SPA_BLOCK=$'\ttry_files {path} {path}/ /index.html\n\tfile_server'
else
  SPA_BLOCK=$'\tfile_server'
fi

say "writing the wildcard vhost -> /etc/caddy/apps/sites.caddy (*.${DOMAIN}; site label = {labels.${LABEL_INDEX}}; SPA mode: ${SITES_SPA_MODE:-false})"
VHOST_RENDERED="$(sed \
  -e "s|\${DOMAIN}|${DOMAIN}|g" \
  -e "s|\${CADDY_PORT}|${CADDY_PORT}|g" \
  -e "s|\${CADDY_BIND}|${CADDY_BIND}|g" \
  -e "s|__L__|${LABEL_INDEX}|g" \
  "${VHOST_TMPL}" \
  | SPA_VAL="${SPA_BLOCK}" awk '
      {
        line = $0
        if (line ~ /^[ \t]*__SPA_TRY_FILES__[ \t]*$/) { printf "%s\n", ENVIRON["SPA_VAL"]; next }
        print line
      }'
)"
proot-distro login debian -- bash -lc 'mkdir -p /etc/caddy/apps && cat > /etc/caddy/apps/sites.caddy' <<EOF || die "failed to write /etc/caddy/apps/sites.caddy"
${VHOST_RENDERED}
EOF
ok "wrote /etc/caddy/apps/sites.caddy"

# ── 3. Validate the FULL Caddyfile (fail closed; do NOT restart) ──────────────
say "validating the Caddyfile inside the userland"
in_debian 'caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile' \
  || die "caddy validate FAILED — refusing to leave a broken vhost in place (fix /etc/caddy/apps/sites.caddy)"
ok "Caddyfile still valid with the sites wildcard vhost added"

# ── Closing notes ─────────────────────────────────────────────────────────────
echo
ok "Pocket Pages installed — deploy with: scripts/sites/site-deploy.sh <name> <artifact.zip>"
say "Each deployed site serves at https://<name>.${DOMAIN} (first-level subdomain:"
say "  covered by Cloudflare's FREE Universal SSL — this is why site hosts are never nested)."
echo
say "Manual Cloudflare step (Zero Trust dashboard — NOT done by this script). EITHER:"
say "  a) ONE-TIME wildcard (recommended — future sites need no dashboard work):"
say "       Public Hostname:  *.${DOMAIN}  ->  http://localhost:${CADDY_PORT}"
say "       (explicit hostnames like chat.${DOMAIN} keep outranking the wildcard), OR"
say "  b) per-site:  <name>.${DOMAIN}  ->  http://localhost:${CADDY_PORT}  for each site."
say "If the core stack is already running, pick up the new vhost with:"
say "     bash ${POCKET_ROOT}/scripts/start-stack.sh --restart"
say "(brief ingress outage while cloudflared cycles). After that, deploys never touch Caddy."

# Generalized from a working deployment; review before running.
