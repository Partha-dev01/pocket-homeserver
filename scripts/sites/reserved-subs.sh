# sites/reserved-subs.sh — the reserved-subdomain union for the sites module.
#
# Implements SPEC-SITES-PIPELINE.md §7. ONLY defines RESERVED_SUBS; every other
# concern (regex, the BYO-route-file check) lives in lib-sites.sh's
# validate_site_name(). This file is SOURCED, not executed, so it has no
# shebang — same convention as scripts/lib/common.sh (see its header) — but is
# still shellcheck-clean bash, hence the directive below.
# shellcheck shell=bash

# Guard against double-sourcing (this file is sourced by lib-sites.sh, which is
# itself sourced by all five sites/*.sh entry points — a re-source must be a
# harmless no-op, exactly like common.sh's own guard).
[ -n "${_POCKET_RESERVED_SUBS_LOADED:-}" ] && return 0
_POCKET_RESERVED_SUBS_LOADED=1

# RESERVED_SUBS = CORE_SUBS (scripts/apps/proxy-routes.sh:86 — the built-in/
# optional-app hostnames: chat admin files music books audiobooks read dav wiki
# vault links share rss notes tasks search tools status stickers webmail ai mcp
# git dns) UNION the sites-module-specific additions from SPEC-SITES-PIPELINE §7:
#   - infra/mail-adjacent labels a static site must never be allowed to squat
#     (www mail mta smtp imap pop autoconfig autodiscover — these are the kind
#     of hostname a mail client or ACME/well-known convention assumes exists),
#   - matrix (the homeserver's own well-known convention lives at the apex, but
#     the label itself should stay reserved against confusion),
#   - this module's own reserved namespace (sites api cdn ns1 ns2 preview — the
#     last four are forward-looking: a future CDN/nameserver/preview-deploy
#     feature must not be squattable by an operator site today).
#
# NOTE: CORE_SUBS is copied here by hand rather than sourced from
# proxy-routes.sh (proxy-routes.sh predates this module and doesn't factor its
# list out yet). SPEC-SITES-PIPELINE §7 calls for the reverse follow-up — have
# proxy-routes.sh source RESERVED_SUBS from THIS file instead of keeping its own
# copy — as a small, separate diff. Until that lands, keep the two lists in sync
# by hand if either changes.
# export: this is a leaf lib meant to be sourced standalone (proxy-routes.sh's
# planned follow-up, §7) as well as via lib-sites.sh — export marks it
# "used externally" for anyone shellchecking this file in isolation, and costs
# nothing (sourcing already shares the variable with every caller regardless).
export RESERVED_SUBS="chat admin files music books audiobooks read dav wiki vault links share rss notes tasks search tools status stickers webmail ai mcp git dns www mail mta smtp imap pop autoconfig autodiscover matrix sites api cdn ns1 ns2 preview"
