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

# Forms (SPEC-DIFFERENTIATORS §8, AD-7 as amended by C-2/C-3): rendered ONLY
# when enabled — an empty value makes the awk below drop the marker line
# entirely. The gate token (C-2) is minted ONCE, 0600, under POCKET_STATE_DIR;
# the panel READS the same file, and baking the value into this vhost's
# header_up makes the sites vhost the PROVABLE sole site-attributor (any other
# path to the panel either strips the headers or doesn't know the token).
FORMS_BLOCK=""
if [ "${ENABLE_SITES_FORMS:-false}" = "true" ]; then
  [ "${ENABLE_SITES:-false}" = "true" ] \
    || die "ENABLE_SITES_FORMS=true requires ENABLE_SITES=true (it is a Pocket Pages sub-feature, not a standalone app)"
  require_cmd openssl
  FORMS_GATE_FILE="${POCKET_STATE_DIR}/sites-forms.gate"
  if [ ! -s "${FORMS_GATE_FILE}" ]; then
    say "minting the forms gate token -> ${FORMS_GATE_FILE} (0600, read back by the admin panel)"
    ( umask 077; openssl rand -hex 32 > "${FORMS_GATE_FILE}.tmp" ) \
      || die "could not mint the forms gate token"
    mv -f "${FORMS_GATE_FILE}.tmp" "${FORMS_GATE_FILE}"
    chmod 600 "${FORMS_GATE_FILE}"
  fi
  FORMS_GATE_TOKEN="$(cat "${FORMS_GATE_FILE}")"
  [ -n "${FORMS_GATE_TOKEN}" ] || die "empty forms gate token at ${FORMS_GATE_FILE}"
  # SET-only, deliberately NO `header_up -X-...` deletes: a header_up SET
  # already REPLACES any client-supplied value wholesale (proven live: a
  # forged X-Pocket-Site/-Forms-Gate arrives upstream as OUR values, exactly
  # one each). Caddy does NOT apply header ops in written order within one
  # reverse_proxy block — a delete listed alongside a set for the same header
  # runs AFTER it and wipes Caddy's own value, killing the feature. Delete-only
  # strips (the admin vhost's belt in steps/70) are unaffected.
  FORMS_BLOCK=$'\t@forms path /__pocket-forms__/*\n\treverse_proxy @forms 127.0.0.1:'"${ADMINWEB_PORT:-9000}"$' {\n\t\theader_up X-Pocket-Site {labels.'"${LABEL_INDEX}"$'}\n\t\theader_up X-Pocket-Forms-Gate '"${FORMS_GATE_TOKEN}"$'\n\t}'
fi

# Analytics-lite (SPEC-DIFFERENTIATORS §9, AD-5/AD-10): the per-vhost JSON
# access log the M1 template comment always anticipated — same roll_size/
# roll_keep/format values as the three existing precedents (core chat vhost,
# landing, MCP). ONE shared log for every deployed site (this is ONE wildcard
# vhost); the parser attributes per-site by request.host at read time.
ANALYTICS_LOG=""
if [ "${ENABLE_SITES_ANALYTICS:-false}" = "true" ]; then
  [ "${ENABLE_SITES:-false}" = "true" ] \
    || die "ENABLE_SITES_ANALYTICS=true requires ENABLE_SITES=true (it is a Pocket Pages sub-feature, not a standalone app)"
  ANALYTICS_LOG=$'\tlog {\n\t\toutput file /var/log/pocket/sites-access.log {\n\t\t\troll_size 10MiB\n\t\t\troll_keep 5\n\t\t}\n\t\tformat json\n\t}'
fi

say "writing the wildcard vhost -> /etc/caddy/apps/sites.caddy (*.${DOMAIN}; site label = {labels.${LABEL_INDEX}}; SPA mode: ${SITES_SPA_MODE:-false})"
VHOST_RENDERED="$(sed \
  -e "s|\${DOMAIN}|${DOMAIN}|g" \
  -e "s|\${CADDY_PORT}|${CADDY_PORT}|g" \
  -e "s|\${CADDY_BIND}|${CADDY_BIND}|g" \
  -e "s|__L__|${LABEL_INDEX}|g" \
  "${VHOST_TMPL}" \
  | SPA_VAL="${SPA_BLOCK}" FORMS_VAL="${FORMS_BLOCK}" AN_VAL="${ANALYTICS_LOG}" awk '
      {
        line = $0
        if (line ~ /^[ \t]*__SPA_TRY_FILES__[ \t]*$/) { printf "%s\n", ENVIRON["SPA_VAL"]; next }
        if (line ~ /^[ \t]*__FORMS_BLOCK__[ \t]*$/)   { if (ENVIRON["FORMS_VAL"] != "") printf "%s\n", ENVIRON["FORMS_VAL"]; next }
        if (line ~ /^[ \t]*__ANALYTICS_LOG__[ \t]*$/) { if (ENVIRON["AN_VAL"] != "") printf "%s\n", ENVIRON["AN_VAL"]; next }
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

# ── 4. Share-sheet deploy hook (CORRECTION C-1; ENABLE_SITES_SHARE_DEPLOY) ───
# Installs ~/bin/termux-file-editor -- Termux's OWN global "edit a file" hook
# (scripts/sites/pocket-share-hook.sh's header explains what it does for a
# shared .zip vs every other file, and why site-deploy.sh's tty-only staging
# exemption applies to it). A Termux-HOST file, NOT inside the userland --
# plain file I/O, no proot-distro round trip, same "host for placement" split
# every other Termux-native install step in this repo uses (e.g. step
# 70-install-admin.sh's ~/pocket-admin).
if [ "${ENABLE_SITES_SHARE_DEPLOY:-false}" = "true" ]; then
  [ "${ENABLE_SITES:-false}" = "true" ] \
    || die "ENABLE_SITES_SHARE_DEPLOY=true requires ENABLE_SITES=true (it is a Pocket Pages sub-feature, not a standalone app)"
  HOOK_SRC="${SITES_DIR}/pocket-share-hook.sh"
  HOOK_DEST="${HOME}/bin/termux-file-editor"
  HOOK_MARKER="# pocket-homeserver share-deploy hook (ENABLE_SITES_SHARE_DEPLOY)"
  [ -f "${HOOK_SRC}" ] || die "share-deploy hook source missing: ${HOOK_SRC}"
  mkdir -p "${HOME}/bin"
  if [ ! -e "${HOOK_DEST}" ]; then
    say "installing the share-deploy hook -> ${HOOK_DEST} (no existing hook found)"
    sed "s|__POCKET_ROOT__|${POCKET_ROOT}|" "${HOOK_SRC}" > "${HOOK_DEST}" \
      || die "failed to write ${HOOK_DEST}"
    chmod +x "${HOOK_DEST}"
    ok "share-deploy hook installed at ${HOOK_DEST}"
  elif grep -qF -- "${HOOK_MARKER}" "${HOOK_DEST}" 2>/dev/null; then
    say "updating our own share-deploy hook at ${HOOK_DEST} (marker matched)"
    sed "s|__POCKET_ROOT__|${POCKET_ROOT}|" "${HOOK_SRC}" > "${HOOK_DEST}" \
      || die "failed to write ${HOOK_DEST}"
    chmod +x "${HOOK_DEST}"
    ok "share-deploy hook updated at ${HOOK_DEST}"
  else
    warn "${HOOK_DEST} already exists and is NOT a pocket-homeserver hook -- leaving it untouched"
    warn "  Termux only allows ONE global file-editor hook. To switch to share-sheet deploy,"
    warn "  back up your existing ~/bin/termux-file-editor by hand, then re-run this script."
  fi
  echo
  say "Share flow: Share a .zip from any app -> pick \"Termux\" from the share sheet -> confirm"
  say "  the filename Android/Termux asks for -> type a site name when prompted -> the deploy"
  say "  runs in the Termux session Android just opened."
  say "  NOTE: the share-sheet entry is labeled \"Termux\" (the receiving app), not"
  say "  \"pocket-homeserver\" -- only a companion Android app could change that (not shipped here)."
  say "  Termux:API (F-Droid) is OPTIONAL but nicer: without it, the hook falls back to a plain"
  say "  text prompt instead of a termux-dialog popup, and skips toast/notification feedback."
  say "  Android's storage / \"All files access\" permission (granted to Termux) is what lets the"
  say "  OS save the shared file into ~/downloads before this hook ever runs."
fi

# ── 5. Termux:Widget one-tap deploy (ENABLE_SITES_WIDGET_DEPLOY) ─────────────
if [ "${ENABLE_SITES_WIDGET_DEPLOY:-false}" = "true" ]; then
  [ "${ENABLE_SITES:-false}" = "true" ] \
    || die "ENABLE_SITES_WIDGET_DEPLOY=true requires ENABLE_SITES=true (it is a Pocket Pages sub-feature, not a standalone app)"
  WIDGET_SRC="${SITES_DIR}/pocket-deploy-widget.sh"
  WIDGET_DEST="${HOME}/.shortcuts/pocket-deploy.sh"
  [ -f "${WIDGET_SRC}" ] || die "widget-deploy source missing: ${WIDGET_SRC}"
  say "installing the Termux:Widget deploy shortcut -> ${WIDGET_DEST}"
  mkdir -p "${HOME}/.shortcuts"
  # A real FILE (not a symlink) -- Termux:Widget's own docs recommend this so
  # it can stat the shortcut reliably.
  sed "s|__POCKET_ROOT__|${POCKET_ROOT}|" "${WIDGET_SRC}" > "${WIDGET_DEST}" \
    || die "failed to write ${WIDGET_DEST}"
  chmod +x "${WIDGET_DEST}"
  ok "widget-deploy shortcut installed at ${WIDGET_DEST}"
  echo
  say "One-tap deploy: install Termux:Widget from F-Droid (same channel as Termux:Boot,"
  say "  scripts/steps/75-install-boot.sh), then long-press your home screen -> Widgets ->"
  say "  Termux:Widget -> add the \"pocket-deploy\" shortcut."
  say "  Tapping it opens the system file picker (Storage Access Framework) -- pick a .zip"
  say "  from anywhere on the device, type a site name, and it deploys."
  say "  NOTE: this is NOT the Android Share Sheet -- save/share a file into place FIRST,"
  say "  then tap the widget (a two-step flow), see docs/SITES.md."
  say "  REQUIRES the Termux:API app + termux-api package (F-Droid) -- the file picker IS"
  say "  termux-storage-get; the shortcut exits with an error if Termux:API is missing."
  say "  Also requires Android's storage / \"All files access\" permission (granted to Termux)"
  say "  for termux-storage-get to read from other apps' storage providers."
fi

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
