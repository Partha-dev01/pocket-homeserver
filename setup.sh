#!/usr/bin/env bash
#
# setup.sh — interactive first-run wizard for pocket-homeserver.
#
# Asks a short series of questions and writes a complete, ready-to-use .env.
# It never prints your secrets back to the screen, refuses to silently clobber
# an existing .env (it backs it up first), and writes .env with 0600 perms.
#
# When it finishes:   ./scripts/install.sh
#
# Re-runnable any time. Prefer doing it by hand? Copy .env.example to .env and
# edit it instead (see docs/SETUP.md) — this wizard is just the friendly path.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/scripts/lib/common.sh"          # say/ok/warn/die + $POCKET_ROOT

ENV_OUT="$POCKET_ROOT/.env"
EXAMPLE="$POCKET_ROOT/.env.example"
[ -f "$EXAMPLE" ] || die "can't find .env.example — run setup.sh from the repo root"

[ -t 0 ] || warn "stdin is not a terminal — reading scripted answers; input won't be hidden"

# ── tiny prompt helpers ──────────────────────────────────────────────────────
# ask VAR "Prompt" [default] — read a line; empty input takes the default.
ask() {
  local __v="$1" prompt="$2" def="${3:-}" ans=""
  if [ -n "$def" ]; then
    read -r -p "$prompt [$def]: " ans || ans=""
    ans="${ans:-$def}"
  else
    read -r -p "$prompt: " ans || ans=""
  fi
  printf -v "$__v" '%s' "$ans"
}
# ask_secret VAR "Prompt" — no echo; entered twice and must match.
ask_secret() {
  local __v="$1" prompt="$2" a="" b=""
  while true; do
    read -rs -p "$prompt: " a || a=""; printf '\n' >&2
    read -rs -p "  confirm: " b || b=""; printf '\n' >&2
    if [ "$a" != "$b" ]; then warn "entries didn't match — try again"; continue; fi
    printf -v "$__v" '%s' "$a"; return 0
  done
}
# ask_yn VAR "Prompt" default(y|n) — sets VAR to the string "true" or "false".
ask_yn() {
  local __v="$1" prompt="$2" def="${3:-n}" ans="" hint
  case "$def" in [yY]*) hint="[Y/n]";; *) hint="[y/N]";; esac
  read -r -p "$prompt $hint: " ans || ans=""
  ans="${ans:-$def}"
  case "$ans" in [yY]*|true) printf -v "$__v" 'true';; *) printf -v "$__v" 'false';; esac
}
# envq VALUE — single-quote a value so .env can be sourced verbatim, even if it
# contains spaces, $, ", backticks or single quotes.
envq() { local s=${1//\'/\'\\\'\'}; printf "'%s'" "$s"; }
# gen_token — a random hex token (openssl, else python3, else /dev/urandom).
gen_token() {
  if command -v openssl >/dev/null 2>&1; then openssl rand -hex 16
  elif command -v python3 >/dev/null 2>&1; then python3 -c 'import secrets;print(secrets.token_hex(16))'
  else head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'; fi
}

printf '\n'
say "pocket-homeserver setup — this writes your .env (Ctrl-C to abort)"

# Never clobber an existing .env without asking; back it up first.
if [ -f "$ENV_OUT" ]; then
  warn "a .env already exists at $ENV_OUT"
  ask_yn _ow "overwrite it (your current one is backed up first)?" n
  [ "$_ow" = "true" ] || { say "left your existing .env untouched — nothing changed"; exit 0; }
  bak="$ENV_OUT.bak-$(date -u +%Y%m%dT%H%M%SZ)"
  cp -p "$ENV_OUT" "$bak"; ok "backed up existing .env -> $bak"
fi

# ── Core ─────────────────────────────────────────────────────────────────────
printf '\n'; say "── Core ───────────────────────────────────────────"
while :; do
  ask DOMAIN "Your apex domain, DNS managed by Cloudflare (e.g. my.org)"
  case "$DOMAIN" in
    ""|example.com) warn "enter your real domain (not the placeholder)";;
    *\ *)           warn "a domain has no spaces";;
    *.*)            break;;
    *)              warn "that doesn't look like a domain (it needs a dot)";;
  esac
done
ask TZ "Timezone (IANA name)" "Etc/UTC"

while :; do
  ask DATA_DIR "Absolute path to your large data store, e.g. /storage/XXXX-XXXX/pocket-homeserver"
  case "$DATA_DIR" in
    *XXXX-XXXX*) warn "replace XXXX-XXXX with your card's real volume id";;
    /*)          break;;
    *)           warn "use an absolute path (it must start with /)";;
  esac
done

# ── Cloudflare Tunnel ────────────────────────────────────────────────────────
printf '\n'; say "── Cloudflare Tunnel ──────────────────────────────"
say "In the Zero Trust dashboard, create a tunnel and copy its token (a long eyJ… string)."
while :; do
  ask_secret CF_TUNNEL_TOKEN "Cloudflare Tunnel token (hidden)"
  [ -n "$CF_TUNNEL_TOKEN" ] && break
  warn "the tunnel token can't be empty"
done
case "$CF_TUNNEL_TOKEN" in
  eyJ*) ;;
  *) warn "that didn't start with 'eyJ' — double-check you pasted the tunnel token, not something else";;
esac

# ── Admin panel login ────────────────────────────────────────────────────────
# ADMIN_PASSWORD is also the initial superuser password for the apps, so it is
# required regardless of whether the panel itself is enabled.
printf '\n'; say "── Admin login ────────────────────────────────────"
ask ADMIN_USER "Admin username" "admin"
while :; do
  ask_secret ADMIN_PASSWORD "Admin password (min 12 chars, hidden)"
  [ "${#ADMIN_PASSWORD}" -ge 12 ] && break
  warn "please use at least 12 characters"
done
ask_yn ENABLE_ADMIN "Enable the web admin panel?" y

# ── Reboot survival ──────────────────────────────────────────────────────────
printf '\n'; say "── Reboot survival ────────────────────────────────"
say "Auto-start the stack on boot + a watchdog that revives killed services."
say "(Needs the Termux:Boot and Termux:API addon apps; setup is fail-soft if absent.)"
ask_yn ENABLE_BOOT "Install reboot survival + the self-heal watchdog?" y

# ── Matrix homeserver ────────────────────────────────────────────────────────
printf '\n'; say "── Matrix homeserver ──────────────────────────────"
ask_yn _gentok "Generate a registration token now (lets you create your first user)?" y
if [ "$_gentok" = "true" ]; then
  MATRIX_REGISTRATION_TOKEN="$(gen_token)"
  MATRIX_ALLOW_REGISTRATION=true
  ok "registration token generated and stored in .env (token-gated registration ON)"
else
  MATRIX_REGISTRATION_TOKEN=""
  MATRIX_ALLOW_REGISTRATION=false
fi

# ── Optional single sign-on ──────────────────────────────────────────────────
printf '\n'; say "── Optional single sign-on (advanced) ─────────────"
say "The Matrix-SSO gateway lets users sign into the apps with their Matrix login."
ask_yn ENABLE_AUTH_GATEWAY "Enable the Matrix-SSO auth gateway?" n
AUTHGW_ADMINS=""
if [ "$ENABLE_AUTH_GATEWAY" = "true" ]; then
  ask AUTHGW_ADMINS "Admin usernames for SSO (comma-separated localparts; blank = none)"
fi

# ── Optional apps ────────────────────────────────────────────────────────────
printf '\n'; say "── Optional apps (each on its own subdomain) ──────"
say "  (Element — the Matrix web client — is part of the core stack on chat.$DOMAIN; always installed.)"
ask_yn EN_LINKDING "Bookmarks (links.$DOMAIN)?"                n
ask_yn EN_PINGVIN  "File sharing (share.$DOMAIN)?"             n
ask_yn EN_FRESHRSS "RSS reader (rss.$DOMAIN)?"                 n
ask_yn EN_MEMOS    "Notes (notes.$DOMAIN)?"                    n
ask_yn EN_VIKUNJA  "Tasks (tasks.$DOMAIN)?"                    n
ask_yn EN_SEARXNG  "Metasearch (search.$DOMAIN)?"             n
ask_yn EN_ITTOOLS  "Developer tools (tools.$DOMAIN)?"          n
ask_yn EN_GATUS    "Status page (status.$DOMAIN)?"            n

# ── Privacy & media filters ───────────────────────────────────────────────────
printf '\n'; say "── Privacy & media filters (optional) ─────────────"
say "Two small loopback proxies in front of Matrix (both off by default)."
ask_yn ENABLE_USER_FILTER  "Hide chosen accounts from member search (user-filter)?"                n
ask_yn ENABLE_MEDIA_FILTER "Fix untyped media so mobile clients show thumbnails (media-filter)?"   n

# ── Write .env ───────────────────────────────────────────────────────────────
# Quote free-form / secret values so the file sources cleanly; leave derived
# values (${DOMAIN}, ${DATA_DIR}, $HOME) as references, exactly like the template.
Q_DOMAIN=$(envq "$DOMAIN");        Q_TZ=$(envq "$TZ");            Q_DATA=$(envq "$DATA_DIR")
Q_TUN=$(envq "$CF_TUNNEL_TOKEN");  Q_AUSER=$(envq "$ADMIN_USER"); Q_APASS=$(envq "$ADMIN_PASSWORD")
Q_REGTOK=$(envq "$MATRIX_REGISTRATION_TOKEN"); Q_GWADM=$(envq "$AUTHGW_ADMINS")

umask 077
tmp="$ENV_OUT.tmp.$$"
cat > "$tmp" <<EOF
# pocket-homeserver — configuration  (generated by ./setup.sh)
#
# Holds real values, including secrets. It is gitignored and must NEVER be
# committed. Re-run ./setup.sh to regenerate, or edit by hand. The scripts
# source this file with bash, so \${DOMAIN}-style references expand as expected.

# ─── Core ─────────────────────────────────────────────────────────────────
DOMAIN=${Q_DOMAIN}
TZ=${Q_TZ}
MATRIX_SERVER_NAME=\${DOMAIN}

# ─── Storage ────────────────────────────────────────────────────────────────
DATA_DIR=${Q_DATA}
ROOTFS_DIR=\$HOME/debian

# ─── Cloudflare Tunnel (ingress) — KEEP SECRET, never commit this file ───────
CF_TUNNEL_TOKEN=${Q_TUN}
CADDY_BIND=127.0.0.1
CADDY_PORT=8443

# ─── Matrix homeserver ──────────────────────────────────────────────────────
MATRIX_ALLOW_FEDERATION=false
MATRIX_ALLOW_REGISTRATION=${MATRIX_ALLOW_REGISTRATION}
MATRIX_REGISTRATION_TOKEN=${Q_REGTOK}

# ─── Web admin panel ────────────────────────────────────────────────────────
ENABLE_ADMIN=${ENABLE_ADMIN}
ADMIN_HOST=admin.\${DOMAIN}
ADMIN_USER=${Q_AUSER}
ADMIN_PASSWORD=${Q_APASS}
ADMINWEB_PORT=9000
ADMIN_BRAND=\${DOMAIN}
ADMIN_IDLE_MINUTES=30
CF_ACCESS_MODE=log
CF_ACCESS_TEAM_DOMAIN=
CF_ACCESS_AUD=

# ─── Reboot survival ────────────────────────────────────────────────────────
ENABLE_BOOT=${ENABLE_BOOT}

# ─── Optional Matrix-SSO auth gateway (advanced) ────────────────────────────
ENABLE_AUTH_GATEWAY=${ENABLE_AUTH_GATEWAY}
AUTHGW_PORT=9095
AUTHGW_ADMINS=${Q_GWADM}
AUTHGW_COOKIE_DOMAIN=\${DOMAIN}
AUTHGW_TTL=2592000
AUTHGW_BRAND=\${DOMAIN}

# ─── Optional apps ──────────────────────────────────────────────────────────
ENABLE_LINKDING=${EN_LINKDING}
ENABLE_PINGVIN=${EN_PINGVIN}
ENABLE_FRESHRSS=${EN_FRESHRSS}
ENABLE_MEMOS=${EN_MEMOS}
ENABLE_VIKUNJA=${EN_VIKUNJA}
ENABLE_SEARXNG=${EN_SEARXNG}
ENABLE_ITTOOLS=${EN_ITTOOLS}
ENABLE_GATUS=${EN_GATUS}

# ─── Privacy & media filters (optional) ─────────────────────────────────────
ENABLE_USER_FILTER=${ENABLE_USER_FILTER}
USER_FILTER_PORT=8449
ENABLE_MEDIA_FILTER=${ENABLE_MEDIA_FILTER}
MEDIA_FILTER_PORT=8450
MATRIX_LOOPBACK=http://127.0.0.1:8448

# ─── Backups ────────────────────────────────────────────────────────────────
BACKUP_DIR=\${DATA_DIR}/backups
BACKUP_KEEP_DB=3
BACKUP_KEEP_ROOTFS=4
BACKUP_AGE_RECIPIENT=
EOF
mv -f "$tmp" "$ENV_OUT"
chmod 600 "$ENV_OUT"
ok "wrote $ENV_OUT (0600)"

# ── Summary (no secrets) + hand-off ──────────────────────────────────────────
apps=""
for kv in linkding:$EN_LINKDING pingvin:$EN_PINGVIN \
          freshrss:$EN_FRESHRSS memos:$EN_MEMOS vikunja:$EN_VIKUNJA \
          searxng:$EN_SEARXNG ittools:$EN_ITTOOLS gatus:$EN_GATUS; do
  [ "${kv#*:}" = "true" ] && apps="$apps ${kv%%:*}"
done
printf '\n'; ok "configuration summary (no secrets shown):"
{
  printf '  domain        : %s\n'    "$DOMAIN"
  printf '  timezone      : %s\n'    "$TZ"
  printf '  data dir      : %s\n'    "$DATA_DIR"
  printf '  admin panel   : %s (user: %s)\n' "$ENABLE_ADMIN" "$ADMIN_USER"
  printf '  reboot survive: %s\n'    "$ENABLE_BOOT"
  printf '  sso gateway   : %s\n'    "$ENABLE_AUTH_GATEWAY"
  printf '  filters       : user=%s media=%s\n' "$ENABLE_USER_FILTER" "$ENABLE_MEDIA_FILTER"
  printf '  registration  : %s\n'    "$([ -n "$MATRIX_REGISTRATION_TOKEN" ] && echo 'generated (in .env)' || echo 'none')"
  printf '  apps enabled  :%s\n'     "${apps:- (none)}"
} >&2

printf '\n'; say "next: review .env if you wish, then run the installer:"
say "    ./scripts/install.sh"
[ -n "$MATRIX_REGISTRATION_TOKEN" ] && \
  say "your Matrix registration token is in .env — use it to create your first user."

printf '\n'
ask_yn _runnow "Run ./scripts/install.sh now?" n
if [ "$_runnow" = "true" ]; then
  exec bash "$POCKET_ROOT/scripts/install.sh"
fi
ok "setup complete."
