#!/usr/bin/env bash
#
# scripts/landing/regen-landing.sh — render-only, callable at RUNTIME (the Sites
# deploy/delete hot path) as well as from steps/84-install-landing.sh at install
# time. See docs/specs/SPEC-LANDING-SYNC.md.
#
# EXEC-BIT EXCEPTION: every other script in this repo is invoked via
# `bash path/to/script.sh` and deliberately ships WITHOUT the executable bit.
# This file is the one exception: site-deploy.sh's and site-delete.sh's
# landing-regen hook gates on `[ -x "${REGEN}" ]` and execs it directly
# (`"${REGEN}" || warn ...`) — without the exec bit set (chmod +x / git mode
# 100755) the hook silently no-ops forever ("landing-regen hook not present
# yet"), so this file MUST be committed executable. See SPEC-LANDING-SYNC §9.
#
# Renders scripts/landing/index.html.tmpl -> ${LANDING_ROOT}/index.html:
#   - one card per ENABLE_<APP>=true flag (unchanged from 84-install-landing.sh)
#   - a "your sites" card grid read from the Pocket Pages registry, when
#     ENABLE_SITES=true and the registry has at least one entry
#
# Contract (SPEC-LANDING-SYNC §7):
#   - silent no-op (exit 0) when ENABLE_LANDING != true
#   - NEVER touches Caddy (no vhost render, no `caddy validate`) — AD-3:
#     SPEC-SITES-PIPELINE AD-1 requires per-deploy operations to be pure
#     filesystem ops, and this script runs on that hot path
#   - idempotent — overwrites LANDING_ROOT/index.html in full every run
#   - --print: write the rendered HTML to stdout instead of the userland, and
#     skip proot-distro entirely — the laptop-testable seam (AD-5)
#   - exits nonzero on a REAL error (template missing, render came out empty);
#     it does NOT soften its own exit code — callers decide fail-closed
#     (84-install-landing.sh) vs best-effort (site-deploy.sh/site-delete.sh,
#     AD-7)

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
load_env

PRINT_ONLY=0
[ "${1:-}" = "--print" ] && PRINT_ONLY=1

[ "${ENABLE_LANDING:-false}" = "true" ] || { ok "landing disabled (ENABLE_LANDING != true) — regen no-op"; exit 0; }
require_var DOMAIN "your apex domain"

LANDING_DIR="${POCKET_ROOT}/scripts/landing"
PAGE_TMPL="${LANDING_DIR}/index.html.tmpl"
LANDING_ROOT="/opt/landing"
BRAND="${LANDING_BRAND:-${DOMAIN}}"
# Same PD_BASE pattern as ops/backup-all.sh:33 and sites/lib-sites.sh — plain
# host-side file I/O to READ the registry (only the final WRITE needs proot,
# because Caddy — and thus LANDING_ROOT — lives inside the userland). Laptop-
# test override: POCKET_SITES_ROOT, the SAME seam lib-sites.sh already
# documents — do NOT invent a second registry-specific override; the M1 and M2
# test suites must share one fixture convention.
PD_BASE="${PREFIX:-/data/data/com.termux/files/usr}/var/lib/proot-distro/installed-rootfs"
SITES_ROOT="${POCKET_SITES_ROOT:-${PD_BASE}/debian/var/www/sites}"
SITES_REGISTRY="${SITES_ROOT}/.registry.json"

[ -f "${PAGE_TMPL}" ] || die "landing page template missing: ${PAGE_TMPL}"

# ── 1. App cards — MOVED VERBATIM from 84-install-landing.sh (unchanged logic) ──
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

# ── 2. NEW: sites cards, from the registry ──────────────────────────────────
site_cards=""
if [ "${ENABLE_SITES:-false}" = "true" ] && [ -f "${SITES_REGISTRY}" ]; then
  # Names only, one per line: SUB_RE already guarantees no whitespace/metacharacters
  # (AD-4), so plain newline-splitting in bash is safe here.
  while IFS= read -r sname; do
    [ -n "$sname" ] || continue
    site_cards+="      <a class=\"card site\" href=\"https://${sname}.${DOMAIN}\" target=\"_blank\" rel=\"noopener\">
        <span class=\"ic\">&#127760;</span>
        <span class=\"ct\"><h3>${sname} <span class=dot></span></h3><p>${sname}.${DOMAIN}</p></span>
        <span class=\"arr\">&#8250;</span>
      </a>
"
  done < <(python3 -c '
import json, re, sys
try:
    with open(sys.argv[1]) as f:
        reg = json.load(f)
except Exception:
    sys.exit(0)          # missing/corrupt registry -> zero site cards, not an error
for name in sorted(reg.get("sites", {})):
    # Belt over AD-4: emit ONLY SUB_RE-shaped names (same pattern as
    # lib-sites.sh validate_site_name). Deploy-time validation covers the
    # normal path, but this page is PUBLIC and a Node build tier runs
    # arbitrary package code inside the userland — a tampered registry key
    # must not become injected markup here.
    if re.fullmatch(r"[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?", name):
        print(name)
' "${SITES_REGISTRY}" 2>/dev/null || true)
fi
sites_section=""
if [ -n "${site_cards}" ]; then
  sites_section="    <h2 class=subhead>your sites</h2>
    <div class=\"grid\">
${site_cards}    </div>
"
fi

# ── 3. Render (awk substitution — same mechanism as today, one more marker) ──
BRAND_HTML="$(printf '%s' "${BRAND}" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g')"
# gsub()'s replacement string treats `&` as "the matched text" and `\` as its
# escape — and BRAND_HTML contains a literal `&` whenever the HTML-escape above
# fired at all (&amp; &lt; ...). Escape both for gsub, or a brand like
# "A & B" renders as "A __BRAND__amp; B".
BRAND_GSUB="${BRAND_HTML//\\/\\\\}"
BRAND_GSUB="${BRAND_GSUB//&/\\&}"
RENDERED_PAGE="$(
  CARDS_BLOCK="${cards}" SITES_BLOCK="${sites_section}" BRAND_VAL="${BRAND_GSUB}" awk '
    {
      line = $0
      gsub(/__BRAND__/, ENVIRON["BRAND_VAL"], line)
      if (line ~ /^[ \t]*POCKET_CARDS[ \t]*$/)         { printf "%s", ENVIRON["CARDS_BLOCK"]; next }
      if (line ~ /^[ \t]*POCKET_SITES_SECTION[ \t]*$/) { printf "%s", ENVIRON["SITES_BLOCK"]; next }
      print line
    }' "${PAGE_TMPL}"
)"
[ -n "${RENDERED_PAGE}" ] || die "rendered landing page came out empty — check ${PAGE_TMPL}"

if [ "${PRINT_ONLY}" -eq 1 ]; then
  printf '%s' "${RENDERED_PAGE}"
  exit 0
fi

# ── 4. Write into the userland (the ONLY proot-dependent step) ─────────────
require_cmd proot-distro
proot-distro login debian -- bash -lc "mkdir -p '${LANDING_ROOT}'" \
  || die "failed to create ${LANDING_ROOT} in the userland"
proot-distro login debian -- bash -lc "umask 022; cat > '${LANDING_ROOT}/index.html'" <<EOF || die "failed to write ${LANDING_ROOT}/index.html"
${RENDERED_PAGE}
EOF
ok "landing page regenerated (${LANDING_ROOT}/index.html; $((acc_i)) app card(s))"
