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
# core Caddy serves the static files directly. The page is rendered from
# scripts/landing/index.html.tmpl with the service cards GENERATED from the
# ENABLE_<APP> flags (e.g. ENABLE_LINKDING=true emits a card linking to
# https://links.${DOMAIN}); nothing is hardcoded to a particular deployment.
#
# What it does (idempotent — safe to re-run):
#   1. renders scripts/landing/index.html.tmpl -> a brand + a card per enabled app,
#   2. writes the rendered page + favicon into a dir INSIDE the userland
#      (${LANDING_ROOT}, outside any app webroot) that Caddy can serve,
#   3. renders scripts/landing/landing.caddy.tmpl and drops it into
#      /etc/caddy/apps/landing.caddy (apex http://${DOMAIN}:${CADDY_PORT}),
#   4. validates the FULL Caddyfile fail-closed (it does NOT restart Caddy),
#   5. prints the restart hint + the manual Cloudflare apex-hostname step.
#
# Runtime: this step runs TERMUX-NATIVE but uses `proot-distro login debian` to
# write the page + vhost INTO the userland, because the core Caddy runs inside
# the userland and serves files from paths visible there.
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

# ── 1. Build the service cards from the ENABLE_<APP> flags ────────────────────
# Each enabled optional app contributes ONE card linking to its public subdomain
# of ${DOMAIN}. The Matrix chat (Element) is CORE — always present — so it leads.
# Columns: ENABLE-flag | accent class (m/w/l/p, cycled) | subdomain | emoji |
# title | blurb. Nothing here is operator-specific: hostnames are derived from
# ${DOMAIN} and the apps you turned on.
#
# Accent classes cycle m -> w -> l -> p across cards purely for visual variety.
ACCENTS=(m w l p)
acc_i=0
next_accent() { local a="${ACCENTS[$((acc_i % ${#ACCENTS[@]}))]}"; acc_i=$((acc_i + 1)); printf '%s' "$a"; }

cards=""
emit_card() {  # emit_card <subdomain> <emoji> <title> <blurb>
  local sub="$1" emoji="$2" title="$3" blurb="$4" acc href
  acc="$(next_accent)"
  if [ -n "$sub" ]; then href="https://${sub}.${DOMAIN}"; else href="https://${DOMAIN}"; fi
  cards+="      <a class=\"card ${acc}\" href=\"${href}\" target=\"_blank\" rel=\"noopener\">
        <span class=\"ic\">${emoji}</span>
        <span class=\"ct\"><h3>${title}</h3><p>${blurb}</p></span>
        <span class=\"arr\">&#8250;</span>
      </a>
"
}

# Core: Matrix chat via Element (always installed — chat.${DOMAIN}).
emit_card "chat" "&#128172;" "Chat" "End-to-end encrypted group chat (Element)."

# Optional apps — each emitted only when its ENABLE_<APP> flag is true. The
# subdomain mapping mirrors .env.example (links/share/rss/notes/tasks/search/
# tools/status) and each app's own Caddy vhost.
[ "${ENABLE_LINKDING:-false}" = "true" ] && emit_card "links"  "&#128278;" "Bookmarks"   "Save, tag and organise your links."
[ "${ENABLE_PINGVIN:-false}"  = "true" ] && emit_card "share"  "&#128228;" "File Share"  "Send files securely, with expiry you control."
[ "${ENABLE_FRESHRSS:-false}" = "true" ] && emit_card "rss"    "&#128240;" "Feeds"       "All your RSS feeds in one place — no noise."
[ "${ENABLE_MEMOS:-false}"    = "true" ] && emit_card "notes"  "&#128221;" "Notes"       "Quick notes and thoughts, Markdown-native."
[ "${ENABLE_VIKUNJA:-false}"  = "true" ] && emit_card "tasks"  "&#9989;"   "Tasks"       "Tasks, lists and kanban boards."
[ "${ENABLE_SEARXNG:-false}"  = "true" ] && emit_card "search" "&#128269;" "Search"      "Private metasearch — no tracking, no ads."
[ "${ENABLE_ITTOOLS:-false}"  = "true" ] && emit_card "tools"  "&#128295;" "Dev Tools"   "Handy developer and encoding utilities."
[ "${ENABLE_GATUS:-false}"    = "true" ] && emit_card "status" "&#128202;" "Status"      "Live uptime monitoring for every service."

# If no optional apps are enabled, the grid still has the Chat card; keep an
# empty-state panel as a fallback only if even that were ever removed.
if [ -z "${cards}" ]; then
  cards="      <div class=\"empty\">No apps are enabled yet. Turn some on in <code>.env</code> (ENABLE_*) and re-run the installer with <code>--force</code> to populate this portal.</div>"
fi

# ── 2. Render the page (brand + generated cards) ──────────────────────────────
# Substitute __BRAND__ everywhere and replace the __CARDS__ placeholder comment
# with the generated card markup. We build the page in a host tmp string, then
# write it into the userland via proot. (BRAND/cards are values you set, not
# external input, but BRAND is shown verbatim — keep it plain in .env.)
say "rendering landing page (brand='${BRAND}'; $((acc_i)) card(s))"

# HTML-escape the brand before substituting it into the page. BRAND is operator
# config (not untrusted input), but it is rendered verbatim into the title/header/
# footer, so escaping &<>" is cheap defense-in-depth against a stray metacharacter.
BRAND_HTML="$(printf '%s' "${BRAND}" \
  | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g')"

# Render with awk so the multi-line ${cards} block is inserted literally (sed
# struggles with multi-line replacements + special chars). awk reads the card
# block from an env var to avoid any quoting/escaping pitfalls. The card block
# replaces ONLY the standalone POCKET_CARDS marker line (a line that is just that
# token + whitespace), NOT prose mentions of it elsewhere in the template.
RENDERED_PAGE="$(
  CARDS_BLOCK="${cards}" BRAND_VAL="${BRAND_HTML}" awk '
    {
      line = $0
      gsub(/__BRAND__/, ENVIRON["BRAND_VAL"], line)
      if (line ~ /^[ \t]*POCKET_CARDS[ \t]*$/) {
        printf "%s", ENVIRON["CARDS_BLOCK"]
        next
      }
      print line
    }
  ' "${PAGE_TMPL}"
)"
[ -n "${RENDERED_PAGE}" ] || die "rendered landing page came out empty — check ${PAGE_TMPL}"

# Write the page + favicon INTO the userland serve dir. proot reads our heredoc
# on stdin so no page content rides on argv.
say "installing the landing page -> ${LANDING_ROOT} (inside the userland)"
in_debian "mkdir -p '${LANDING_ROOT}'" || die "failed to create ${LANDING_ROOT} in the userland"
proot-distro login debian -- bash -lc "umask 022; cat > '${LANDING_ROOT}/index.html'" <<EOF || die "failed to write ${LANDING_ROOT}/index.html"
${RENDERED_PAGE}
EOF
in_debian "chmod 644 '${LANDING_ROOT}/index.html'" || true

if [ -f "${FAVICON_SRC}" ]; then
  proot-distro login debian -- bash -lc "umask 022; cat > '${LANDING_ROOT}/favicon.svg'" < "${FAVICON_SRC}" \
    && in_debian "chmod 644 '${LANDING_ROOT}/favicon.svg'" || warn "could not install favicon.svg — the portal will 404 /favicon.svg (cosmetic)"
else
  warn "favicon.svg missing at ${FAVICON_SRC} — the portal will 404 /favicon.svg (cosmetic)"
fi
ok "landing page installed (${LANDING_ROOT}/index.html)"

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
