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
say "Registration is closed by default. To create your first (admin) account, run"
say "scripts/ops/rotate-registration-token.sh AFTER the stack is up — it mints a"
say "token + opens token-gated signup, then register at chat.\$DOMAIN. See docs/SETUP.md step 8."

# ── Optional single sign-on ──────────────────────────────────────────────────
printf '\n'; say "── Optional single sign-on (advanced) ─────────────"
say "The Matrix-SSO gateway lets users sign into the apps with their Matrix login."
ask_yn ENABLE_AUTH_GATEWAY "Enable the Matrix-SSO auth gateway?" n
AUTHGW_ADMINS=""
if [ "$ENABLE_AUTH_GATEWAY" = "true" ]; then
  ask AUTHGW_ADMINS "Admin usernames for SSO (comma-separated localparts; blank = none)"
fi

# ── Optional Matrix bootstrap ────────────────────────────────────────────────
printf '\n'; say "── Matrix bootstrap (optional) ────────────────────"
say "Seed an admin account + a hub Space/rooms + an announcements room after the stack is up."
say "Idempotent. It needs registration opened first (rotate-registration-token.sh) — see docs/BOOTSTRAP.md."
ask_yn ENABLE_BOOTSTRAP "Seed a Matrix admin + default Space/rooms?" n
ADMIN_MATRIX_USER="admin"; BOOTSTRAP_AVATARS="false"
if [ "$ENABLE_BOOTSTRAP" = "true" ]; then
  ask ADMIN_MATRIX_USER "Matrix admin username (localpart)" "admin"
  ask_yn BOOTSTRAP_AVATARS "Also generate + upload avatars (needs Pillow)?" n
fi

# ── Matrix user management in the admin panel (optional) ──────────────────────
printf '\n'; say "── Matrix user management (admin panel) ───────────"
say "Adds a Users page to the admin panel — list / create / reset-password /"
say "suspend / deactivate + mint invite tokens — driven through the homeserver's"
say "admin command room. Needs an admin account (the bootstrap admin). See docs/USERS.md."
ask_yn ENABLE_USER_ADMIN "Enable Matrix user management in the panel?" n

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
if [ "$EN_SEARXNG" = "true" ] || [ "$EN_ITTOOLS" = "true" ] || [ "$EN_GATUS" = "true" ]; then
  warn "SearXNG, IT-Tools and Gatus have NO built-in login — Cloudflare Access (or"
  warn "another auth layer) is the ONLY thing protecting them. Without it you publish"
  warn "an open metasearch proxy / open tools site / open status page. See docs/APP_AUTH.md."
fi

# ── Privacy & media filters ───────────────────────────────────────────────────
printf '\n'; say "── Privacy & media filters (optional) ─────────────"
say "Two small loopback proxies in front of Matrix (both off by default)."
ask_yn ENABLE_USER_FILTER  "Hide chosen accounts from member search (user-filter)?"                n
ask_yn ENABLE_MEDIA_FILTER "Fix untyped media so mobile clients show thumbnails (media-filter)?"   n

# ── Optional cloud-LLM chat bots ──────────────────────────────────────────────
printf '\n'; say "── Cloud-LLM Matrix chat bots (optional) ──────────"
say "Matrix bots that answer @-mentions via an OpenAI-compatible API (e.g. Groq's free tier)."
say "Configure each bot later in a 0600 file under \${DATA_DIR}/secrets/ — see docs/CHATBOTS.md."
ask_yn ENABLE_CLOUD_BOTS "Enable cloud-LLM Matrix chat bots?" n

# ── Optional on-phone LLM bot (exobot — advanced / BYO) ───────────────────────
printf '\n'; say "── On-phone LLM bot (exobot) — advanced / BYO ─────"
say "Runs an LLM ON the phone (no cloud, no API key). You supply your OWN llama.cpp"
say "build + a GGUF model. The bot's Matrix token goes in a 0600 secrets file (NOT"
say ".env), off-argv — see docs/CHATBOTS.md."
ask_yn ENABLE_EXOBOT "Enable the on-phone LLM bot (advanced)?" n
EXOBOT_LOCALPART="exobot"; LLAMA_SERVER_BIN=""; MODEL_PATH=""
EXOBOT_ALLOWED_ROOMS=""; EXOBOT_UI="false"; EXOBOT_UI_HOST_PUBLIC="ai.$DOMAIN"
if [ "$ENABLE_EXOBOT" = "true" ]; then
  ask EXOBOT_LOCALPART     "Bot account localpart"                                  "exobot"
  ask LLAMA_SERVER_BIN     "Path to your llama-server binary (inside the userland)"
  ask MODEL_PATH           "Path to your GGUF model (inside the userland)"
  ask EXOBOT_ALLOWED_ROOMS "Allowed Matrix room IDs (comma-separated; blank = none)"
  ask_yn EXOBOT_UI         "Also enable the optional Gradio web UI?" n
  [ "$EXOBOT_UI" = "true" ] && ask EXOBOT_UI_HOST_PUBLIC "Public hostname for the UI" "ai.$DOMAIN"
fi

# ── Optional sticker picker ───────────────────────────────────────────────────
printf '\n'; say "── Sticker picker (optional) ──────────────────────"
say "Maunium stickerpicker widget + backend + DM-import bot, on stickers.$DOMAIN."
say "Needs a Matrix service-account token (created AFTER the stack is up) — you fill"
say "STICKER_SERVICE_TOKEN (+ optional GIPHY_API_KEY / bot tokens) into .env then. See docs/STICKERS.md."
ask_yn ENABLE_STICKERS "Enable the sticker picker?" n

# ── Optional operator admin bot ───────────────────────────────────────────────
printf '\n'; say "── Operator admin bot (optional) ──────────────────"
say "A Matrix bot that lets ONLY you drive the stack from a private admin-ops room"
say "(!status, !users, !invite-token, !restart-stack…). Its token + room go in a 0600"
say "secrets file (created AFTER the stack is up) — not .env. See docs/ADMINBOT.md."
ask_yn ENABLE_ADMINBOT "Enable the operator admin bot?" n

# ── Optional landing portal ───────────────────────────────────────────────────
printf '\n'; say "── Landing portal (optional) ──────────────────────"
say "A clean service directory at your apex domain (http://$DOMAIN); cards are built"
say "from the apps you enabled. No bait/decoys. Needs an apex CF Tunnel hostname."
ask_yn ENABLE_LANDING "Install the landing portal?" n
LANDING_BRAND="$DOMAIN"
[ "$ENABLE_LANDING" = "true" ] && ask LANDING_BRAND "Portal brand (shown on the page)" "$DOMAIN"

# ── Optional email + webmail (advanced) ───────────────────────────────────────
printf '\n'; say "── Email + webmail (optional, advanced) ───────────"
say "A self-hosted mailbox (Maddy) + SnappyMail webmail at webmail.$DOMAIN. You must"
say "provision Cloudflare Email Routing + an R2 bucket + Resend on YOUR accounts and"
say "drop their secrets into 0600 files under \$DATA_DIR/secrets AFTER setup (the"
say "install step + docs/EMAIL.md walk you through it). Matrix-SSO webmail also needs"
say "the auth gateway. Leave off unless you want to run mail."
ask_yn ENABLE_EMAIL "Enable the email subsystem (mail server + webmail)?" n
MAIL_DOMAIN="mail.$DOMAIN"; ENABLE_WEBMAIL_ADMIN=false
if [ "$ENABLE_EMAIL" = "true" ]; then
  ask MAIL_DOMAIN "Mail domain (Cloudflare Email Routing target)" "mail.$DOMAIN"
  ask_yn ENABLE_WEBMAIL_ADMIN "Enable SnappyMail's native admin panel (behind CF Access)?" n
fi

# ── Optional MCP server (advanced) ────────────────────────────────────────────
printf '\n'; say "── MCP server (optional, advanced) ────────────────"
say "An optional Model Context Protocol server so an MCP client (Claude Desktop /"
say "Claude Code / the claude.ai connector) can observe + operate the stack through"
say "an audited tool set. 'stdio' runs over your SSH session (nothing published);"
say "'http'/'both' also serve a remote transport behind Cloudflare Access. The"
say "bearer credential is generated at install, not here. See docs/MCP.md."
ask_yn ENABLE_MCP "Enable the MCP server?" n
MCP_TRANSPORT="stdio"; MCP_ALLOW_OPERATE="false"; MCP_ALLOW_DANGER="false"
if [ "$ENABLE_MCP" = "true" ]; then
  while :; do
    ask MCP_TRANSPORT "Transport (stdio | http | both)" "stdio"
    case "$MCP_TRANSPORT" in stdio|http|both) break;; *) warn "choose stdio, http, or both";; esac
  done
  ask_yn MCP_ALLOW_OPERATE "Allow the operate tier (restart/backup/rotate-reg-token)?" n
  ask_yn MCP_ALLOW_DANGER  "Allow the danger tier (panic; still needs a per-call confirm)?" n
fi

# ── Optional honeypot watcher ─────────────────────────────────────────────────
printf '\n'; say "── Honeypot watcher (optional) ────────────────────"
say "A native watcher that tails the Caddy access log and flags scanner probes into"
say "a ledger the admin panel's Security console reads. No inbound listener, no Caddy"
say "change; alert-only by default. See docs/HONEYPOT.md."
ask_yn ENABLE_HONEYPOT "Enable the honeypot watcher?" n
HONEYPOT_DECOY_HOSTS=""
if [ "$ENABLE_HONEYPOT" = "true" ]; then
  ask HONEYPOT_DECOY_HOSTS "Decoy subdomains (comma-separated, e.g. nas.$DOMAIN,vpn.$DOMAIN; blank = none)"
fi

# ── Optional scheduled-backup daemon ──────────────────────────────────────────
printf '\n'; say "── Scheduled backups (optional daemon) ────────────"
say "A small supervised loop that wakes once a day and snapshots automatically: the"
say "Matrix DB weekly (Sun, UTC) + the full userland on the 1st of the month (UTC),"
say "then applies retention. On-demand backups still work regardless. See docs/BACKUPS.md."
ask_yn ENABLE_BACKUP_DAEMON "Enable the scheduled-backup daemon?" n
BACKUP_DAEMON_HOUR="4"; BACKUP_DAEMON_HC_URL=""
if [ "$ENABLE_BACKUP_DAEMON" = "true" ]; then
  ask BACKUP_DAEMON_HOUR   "Hour of day to run (UTC, 0-23)" "4"
  ask BACKUP_DAEMON_HC_URL "Optional heartbeat URL (e.g. a healthchecks.io ping URL; blank = none)"
fi

# ── Off-device encrypted backup (optional) ────────────────────────────────────
printf '\n'; say "── Off-device encrypted backup (optional) ─────────"
say "Push age-ENCRYPTED backups to an S3-compatible bucket (R2 / B2 / S3 / Wasabi /"
say "MinIO) so a lost or dead phone is not a lost backup. Requires an age recipient"
say "(backups are encrypted before they leave the device)."
ask_yn ENABLE_OFFSITE_BACKUP "Enable off-device encrypted backup?" n
AGE_RECIPIENT=""
if [ "$ENABLE_OFFSITE_BACKUP" = "true" ]; then
  say "Generate a keypair with 'age-keygen' and keep the PRIVATE key OFF the phone."
  while :; do
    ask AGE_RECIPIENT "age recipient (PUBLIC key, starts with age1…)"
    case "$AGE_RECIPIENT" in
      age1*) break ;;
      "")    warn "offsite needs an age recipient so backups can be encrypted" ;;
      *)     warn "an age recipient starts with 'age1'" ;;
    esac
  done
  say "After setup, create ${DATA_DIR}/secrets/offsite.env (0600) with your S3"
  say "endpoint / bucket / region / keys. See docs/BACKUPS.md."
fi

# ── Observability + crash-loop alerts (optional) ──────────────────────────────
printf '\n'; say "── Observability + alerts (optional) ──────────────"
say "A tiny sampler records CPU/RAM/disk/temp once a minute so the admin panel can"
say "draw sparklines + a 24h health strip at /metrics. Cheap; recommended."
ask_yn ENABLE_METRICS "Enable the metrics sampler?" y

say ""
say "If a service crash-loops, fire ONE alert. Pick a channel:"
say "  1) none   2) ntfy.sh push   3) healthchecks.io ping   4) Matrix message"
POCKET_ALERT_CMD=""; _alert_kind=""; _want_matrix_alert=false
ask _alert_kind "Alert channel [1-4]" "1"
case "$_alert_kind" in
  2) ask _ntfy "ntfy topic URL (e.g. https://ntfy.sh/your-topic)"
     # Single-quote the part with $POCKET_ALERT_* so those stay LITERAL in .env and
     # expand at alert time; concatenate the (setup-time) topic URL after it.
     [ -n "$_ntfy" ] && POCKET_ALERT_CMD='curl -fsS -m10 -H "Title: pocket-homeserver DEGRADED" -d "service $POCKET_ALERT_SERVICE crash-looping (rc=$POCKET_ALERT_RC, fails=$POCKET_ALERT_FAILS)" '"$_ntfy" ;;
  3) ask _hc "healthchecks.io ping URL (e.g. https://hc-ping.com/<uuid>)"
     [ -n "$_hc" ] && POCKET_ALERT_CMD="curl -fsS -m10 \"${_hc%/}/fail\"" ;;
  4) POCKET_ALERT_CMD="bash \"$POCKET_ROOT/scripts/ops/alert-matrix.sh\""
     _want_matrix_alert=true ;;
  *) POCKET_ALERT_CMD="" ;;
esac

# ── Write .env ───────────────────────────────────────────────────────────────
# Quote free-form / secret values so the file sources cleanly; leave derived
# values (${DOMAIN}, ${DATA_DIR}, $HOME) as references, exactly like the template.
Q_DOMAIN=$(envq "$DOMAIN");        Q_TZ=$(envq "$TZ");            Q_DATA=$(envq "$DATA_DIR")
Q_TUN=$(envq "$CF_TUNNEL_TOKEN");  Q_AUSER=$(envq "$ADMIN_USER"); Q_APASS=$(envq "$ADMIN_PASSWORD")
Q_GWADM=$(envq "$AUTHGW_ADMINS")
Q_XLOCAL=$(envq "$EXOBOT_LOCALPART"); Q_XBIN=$(envq "$LLAMA_SERVER_BIN"); Q_XMODEL=$(envq "$MODEL_PATH")
Q_XROOMS=$(envq "$EXOBOT_ALLOWED_ROOMS"); Q_XUIHOST=$(envq "$EXOBOT_UI_HOST_PUBLIC")
Q_LANDBRAND=$(envq "$LANDING_BRAND")
Q_MAILDOMAIN=$(envq "$MAIL_DOMAIN")
Q_MCPTRANS=$(envq "$MCP_TRANSPORT")
Q_HPDECOY=$(envq "$HONEYPOT_DECOY_HOSTS"); Q_BDHOUR=$(envq "$BACKUP_DAEMON_HOUR"); Q_BDHC=$(envq "$BACKUP_DAEMON_HC_URL")
Q_ALERTCMD=$(envq "$POCKET_ALERT_CMD"); Q_AGE_RCPT=$(envq "$AGE_RECIPIENT")

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

# ─── Optional Matrix admin bot ──────────────────────────────────────────────
# The base install ships no bot; leave false unless you have added one. Only the
# rotate-adminbot-token.sh / rotate-all.sh ops scripts read this.
ENABLE_ADMINBOT=${ENABLE_ADMINBOT}

# ─── Matrix bootstrap (optional, idempotent; off by default) ────────────────
# Runs AFTER the stack is up; needs registration opened first. See docs/BOOTSTRAP.md.
ENABLE_BOOTSTRAP=${ENABLE_BOOTSTRAP}
ADMIN_MATRIX_USER=${ADMIN_MATRIX_USER}
BOOTSTRAP_AVATARS=${BOOTSTRAP_AVATARS}
# Matrix user management in the admin panel (drives the admin command room).
ENABLE_USER_ADMIN=${ENABLE_USER_ADMIN}
INVITE_TOKEN_DAYS=7
MATRIX_SPACE_ALIAS=hub
MATRIX_SPACE_NAME="Community Hub"
MATRIX_SPACE_TOPIC="The landing space for community chat."
MATRIX_PRIVATE_ROOM_ALIAS=private
MATRIX_ANNOUNCE_ALIAS=announcements

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

# ─── Cloud-LLM Matrix chat bots (optional) ──────────────────────────────────
# Per-bot secrets live in 0600 files under \${DATA_DIR}/secrets, never here.
ENABLE_CLOUD_BOTS=${ENABLE_CLOUD_BOTS}

# ─── Sticker picker (optional) ──────────────────────────────────────────────
# Fill STICKER_SERVICE_TOKEN (+ optional GIPHY_API_KEY / bot tokens) AFTER the
# stack is up and you have created the accounts. See docs/STICKERS.md.
ENABLE_STICKERS=${ENABLE_STICKERS}
STICKERPICKER_REPO=https://github.com/maunium/stickerpicker.git
STICKERPICKER_REF=master
STICKER_BACKEND_PORT=8451
STICKER_IDENTITY_MODE=log
STICKER_SERVICE_TOKEN=
GIPHY_API_KEY=
STICKER_BOT_TOKEN=
STICKER_BOT_MXID=
STICKER_ADMIN_TOKEN=
STICKER_ADMIN_MXID=

# ─── On-phone LLM bot (exobot) — advanced / BYO ─────────────────────────────
# The bot's Matrix token goes in \${DATA_DIR}/secrets/exobot.env (0600), not here.
ENABLE_EXOBOT=${ENABLE_EXOBOT}
EXOBOT_LOCALPART=${Q_XLOCAL}
LLAMA_SERVER_BIN=${Q_XBIN}
MODEL_PATH=${Q_XMODEL}
EXOBOT_PROOT_DISTRO=debian
LLAMA_SERVER_PORT=8081
LLAMA_KEEP_WARM=true
EXOBOT_IDLE_TIMEOUT_S=600
EXOBOT_ALLOWED_ROOMS=${Q_XROOMS}
INTERJECT_ENABLED=false
SEED_ENABLED=false
REVIVE_ENABLED=false
CROSSBOT_ENABLED=false
EXOBOT_UI=${EXOBOT_UI}
EXOBOT_UI_PORT=9114
EXOBOT_WAKER_PORT=9116
EXOBOT_UI_TITLE="Self-hosted AI"
EXOBOT_UI_HOST_PUBLIC=${Q_XUIHOST}

# ─── Landing portal (optional) ──────────────────────────────────────────────
# A service directory at your apex domain; cards built from the ENABLE_* flags.
# LANDING_BRAND is HTML-escaped at render — keep it plain text. See docs/LANDING.md.
ENABLE_LANDING=${ENABLE_LANDING}
LANDING_BRAND=${Q_LANDBRAND}

# ─── Email + webmail (optional, advanced) ───────────────────────────────────
# Secrets (R2 + Resend) are NOT here — create 0600 files under \${DATA_DIR}/secrets
# after setup; the installer generates the inject + mailbox passwords. Matrix-SSO
# webmail also needs ENABLE_AUTH_GATEWAY=true. See docs/EMAIL.md + docs/WEBMAIL.md.
ENABLE_EMAIL=${ENABLE_EMAIL}
MAIL_DOMAIN=${Q_MAILDOMAIN}
MAIL_HOSTNAME=mx.\${MAIL_DOMAIN}
MAIL_IMAP_PORT=9143
MAIL_INJECT_PORT=9125
MAIL_SUBMISSION_PORT=9587
MAIL_POLL=180
MAIL_ADMIN_LOCALPART=admin
SNAPPYMAIL_FPM_PORT=9092
ENABLE_WEBMAIL_ADMIN=${ENABLE_WEBMAIL_ADMIN}
# Pinned Maddy release — set MADDY_SHA256 to the real checksum before enabling email
# (the step fails closed until you do). MADDY_ARCH is arm64 on a phone, amd64 on PC.
# MADDY_VERSION=0.9.5
# MADDY_ARCH=arm64
# MADDY_SHA256=

# ─── MCP server (optional, advanced) ────────────────────────────────────────
# An audited Model Context Protocol adapter for MCP clients. 'stdio' runs over
# SSH (nothing published); 'http'/'both' add a remote transport behind CF Access.
# The bearer credential is GENERATED at install into the 0600 file below (it is a
# path, not a secret). Read tools are on when enabled; mutating tiers default off.
# See docs/MCP.md + docs/MCP_SERVER_SPEC.md.
ENABLE_MCP=${ENABLE_MCP}
MCP_TRANSPORT=${Q_MCPTRANS}
MCP_HTTP_HOST=mcp
MCP_HTTP_PORT=9120
MCP_ALLOW_OPERATE=${MCP_ALLOW_OPERATE}
MCP_ALLOW_DANGER=${MCP_ALLOW_DANGER}
MCP_BEARER_TOKEN_FILE=\${DATA_DIR}/secrets/mcp-bearer.cred
MCP_LOG_REDACT=true
MCP_ALLOWED_LOGS=caddy.log,caddy-access.log,cloudflared.log,matrix.log,adminweb.log,auth-gw.log,honeypot.log,backup-daemon.log
MCP_RATE_LIMIT=60/min

# ─── Honeypot (optional, alert-only by default) ─────────────────────────────
# Tails the Caddy access log and flags scanner probes into a ledger the admin
# panel's Security console reads. No inbound listener / no Caddy change. Matrix
# alerts, CF blocking and geo enrichment are opt-in via 0600 files / datasets,
# never .env. See docs/HONEYPOT.md.
ENABLE_HONEYPOT=${ENABLE_HONEYPOT}
HONEYPOT_DECOY_HOSTS=${Q_HPDECOY}

# ─── Backups ────────────────────────────────────────────────────────────────
BACKUP_DIR=\${DATA_DIR}/backups
BACKUP_KEEP_DB=3
BACKUP_KEEP_ROOTFS=4
# age recipient (PUBLIC key) — when set, backups are encrypted; required for offsite.
BACKUP_AGE_RECIPIENT=${Q_AGE_RCPT}
# age PRIVATE-key file path, needed only to RESTORE an encrypted backup (kept OFF
# the backup volume). It is a path, not a secret value. Empty by default.
BACKUP_AGE_IDENTITY=

# ─── Off-device encrypted backup (optional) ─────────────────────────────────
# Push the age-encrypted archives to an S3-compatible bucket. Needs a 0600
# \${DATA_DIR}/secrets/offsite.env (S3 endpoint/bucket/region/keys). Refuses to run
# unless BACKUP_AGE_RECIPIENT is set. See docs/BACKUPS.md.
ENABLE_OFFSITE_BACKUP=${ENABLE_OFFSITE_BACKUP}

# ─── Scheduled backups (optional daemon) ────────────────────────────────────
# When true, start-stack.sh supervises a loop that wakes once a day and snapshots
# automatically (DB weekly Sun / DB+rootfs on the 1st, UTC), then applies retention.
ENABLE_BACKUP_DAEMON=${ENABLE_BACKUP_DAEMON}
# Hour of day (UTC, 0-23) the daemon wakes to run any due snapshot.
BACKUP_DAEMON_HOUR=${Q_BDHOUR}
# Optional heartbeat URL (e.g. a healthchecks.io ping URL); empty = no heartbeat.
BACKUP_DAEMON_HC_URL=${Q_BDHC}

# ─── Observability / metrics sampler (optional) ─────────────────────────────
# Records CPU/mem/disk/temp once a minute into a tiny capped ring on ext4; the
# admin panel charts it at /metrics. See docs/OBSERVABILITY.md.
ENABLE_METRICS=${ENABLE_METRICS}
POCKET_METRICS_POLL_S=60
POCKET_METRICS_RING=5760
POCKET_METRICS_BATTERY=true

# ─── Service supervision / crash-loop alert (optional) ──────────────────────
# Run once via 'sh -c' when ANY service enters DEGRADED, with \$POCKET_ALERT_SERVICE
# / \$POCKET_ALERT_RC / \$POCKET_ALERT_FAILS in the environment. Empty = no alert.
POCKET_ALERT_CMD=${Q_ALERTCMD}
EOF
mv -f "$tmp" "$ENV_OUT"
chmod 600 "$ENV_OUT"
ok "wrote $ENV_OUT (0600)"

if [ "${_want_matrix_alert:-false}" = "true" ]; then
  printf '\n'; warn "Matrix crash-loop alerts need a 0600 secrets file (token NOT in .env):"
  say "  mkdir -p \"\$DATA_DIR/secrets\""
  say "  printf 'ALERT_MATRIX_HS=http://127.0.0.1:8448\\nALERT_MATRIX_TOKEN=<bot token>\\nALERT_MATRIX_ROOM=!roomid:$DOMAIN\\n' > \"\$DATA_DIR/secrets/alert-matrix.env\""
  say "  chmod 600 \"\$DATA_DIR/secrets/alert-matrix.env\""
  say "Create the bot account + room AFTER the stack is up. See docs/OBSERVABILITY.md."
fi

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
  printf '  bootstrap     : %s%s\n'  "$ENABLE_BOOTSTRAP" "$([ "$ENABLE_BOOTSTRAP" = "true" ] && echo " (admin=$ADMIN_MATRIX_USER)")"
  printf '  user mgmt     : %s\n'    "$ENABLE_USER_ADMIN"
  printf '  filters       : user=%s media=%s\n' "$ENABLE_USER_FILTER" "$ENABLE_MEDIA_FILTER"
  printf '  cloud bots    : %s\n'    "$ENABLE_CLOUD_BOTS"
  printf '  on-phone bot  : %s%s\n'  "$ENABLE_EXOBOT" "$([ "$ENABLE_EXOBOT" = "true" ] && echo " (ui=$EXOBOT_UI)")"
  printf '  stickers      : %s\n'    "$ENABLE_STICKERS"
  printf '  admin bot     : %s\n'    "$ENABLE_ADMINBOT"
  printf '  landing       : %s\n'    "$ENABLE_LANDING"
  printf '  email+webmail : %s%s\n'  "$ENABLE_EMAIL" "$([ "$ENABLE_EMAIL" = "true" ] && echo " (domain=$MAIL_DOMAIN, admin=$ENABLE_WEBMAIL_ADMIN)")"
  printf '  mcp server    : %s%s\n'  "$ENABLE_MCP" "$([ "$ENABLE_MCP" = "true" ] && echo " (transport=$MCP_TRANSPORT, operate=$MCP_ALLOW_OPERATE, danger=$MCP_ALLOW_DANGER)")"
  printf '  honeypot      : %s\n'    "$ENABLE_HONEYPOT"
  printf '  backup daemon : %s%s\n'  "$ENABLE_BACKUP_DAEMON" "$([ "$ENABLE_BACKUP_DAEMON" = "true" ] && echo " (hour=$BACKUP_DAEMON_HOUR)")"
  printf '  metrics       : %s\n'    "$ENABLE_METRICS"
  printf '  crash alert   : %s\n'    "$([ -n "$POCKET_ALERT_CMD" ] && echo "on" || echo "none")"
  printf '  offsite backup: %s\n'    "$ENABLE_OFFSITE_BACKUP"
  printf '  apps enabled  :%s\n'     "${apps:- (none)}"
} >&2

printf '\n'; say "next: review .env if you wish, then run the installer:"
say "    ./scripts/install.sh"
say "to create your first (admin) account, AFTER the stack is up run"
say "    bash scripts/ops/rotate-registration-token.sh"
say "(it mints a token + opens token-gated signup), then register at chat.$DOMAIN."
say "See docs/SETUP.md step 8 / docs/ADMIN.md."

printf '\n'
ask_yn _runnow "Run ./scripts/install.sh now?" n
if [ "$_runnow" = "true" ]; then
  exec bash "$POCKET_ROOT/scripts/install.sh"
fi
ok "setup complete."
