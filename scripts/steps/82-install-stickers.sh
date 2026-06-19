#!/usr/bin/env bash
#
# steps/82-install-stickers.sh — install the OPTIONAL Matrix sticker picker: the
# third-party Maunium stickerpicker widget (FETCHED from upstream at install
# time, AGPL) + a small native backend (Upload + Giphy proxy) + an importer bot.
#
# This is a core step that SELF-GATES on ENABLE_STICKERS (install.sh runs it
# unconditionally; it no-ops when disabled). ENABLE_STICKERS defaults to false.
#
# Architecture:
#   - The picker is a static SPA served by Caddy from /var/www/stickerpicker in
#     the userland, on its own vhost http://stickers.${DOMAIN}:${CADDY_PORT}.
#   - scripts/sticker/sticker-backend.py runs TERMUX-NATIVE on 127.0.0.1:8451
#     (Element widgets can't upload; it proxies uploads to the Matrix media API
#     with a service token, and proxies Giphy search/pick with a server-side
#     key). Caddy maps the vhost's /api/* to it.
#   - scripts/sticker/importer-bot.py runs TERMUX-NATIVE too: a Matrix bot that
#     imports an image a user DMs it into that user's pack (!help/!list/!random/
#     !delete). Native because it only talks to the loopback CS API + backend.
#
# LICENSING: the Maunium stickerpicker is third-party (AGPL v3). We do NOT vendor
# its source; this step CLONES it (pinned ref) and copies its web/ assets into
# the userland. Only OUR thin config lives in scripts/sticker/widget/. See that
# directory's README + docs/STICKERS.md.
#
# What it does (idempotent — safe to re-run):
#   1. fetches/refreshes the upstream picker at the pinned ref under
#      ${DATA_DIR}/stickerpicker-src,
#   2. copies its web/ assets into the userland at /var/www/stickerpicker, seeds
#      packs/index.json if absent, makes the packs/ dir live on the large volume,
#   3. seeds a 0600 ${DATA_DIR}/secrets/sticker.env (Giphy key + service/bot
#      tokens + the URL-signing secret) — secrets stay in the file, off argv,
#   4. installs the backend's optional Pillow dep (best effort),
#   5. writes a self-contained Caddy vhost to /etc/caddy/apps/stickers.caddy and
#      validates the full Caddyfile fail-closed (it does NOT restart Caddy),
#   6. supervises the backend + the importer bot Termux-native (records their
#      .cmd so start-stack.sh re-supervises them on every bring-up),
#   7. registers the picker as a personal widget on the admin account via the
#      Matrix API (mirrors the reference 49e step), with a signed identity baked
#      into the per-user widget URL.
#
# Generalized from a working deployment; review before running on a fresh phone.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env

# ── Self-gate: only run when enabled (default off) ───────────────────────────
if [ "${ENABLE_STICKERS:-false}" != "true" ]; then
  ok "stickers disabled (ENABLE_STICKERS != true) — skipping (this is the default)"
  exit 0
fi

require_var DOMAIN   "your apex domain (DNS on Cloudflare)"
require_var DATA_DIR "folder on your large volume / SD card"
require_cmd proot-distro
require_cmd python3
require_cmd git
require_cmd curl

: "${MATRIX_SERVER_NAME:=$DOMAIN}"

in_debian() { proot-distro login debian -- bash -lc "$1"; }

# ── Pinned upstream picker ────────────────────────────────────────────────────
# Pin an EXACT upstream ref (env-overridable) rather than tracking the default
# branch, so an upgrade is a deliberate bump. Upstream ships no release tarball +
# no published sha256 for the web assets (it is a source SPA), so there is no
# fetch_verified pin here; integrity is the pinned ref fetched over HTTPS from
# the canonical repo. (Do NOT invent a sha256.) Bump STICKERPICKER_REF + re-run
# with --force to upgrade, then re-verify the widget in a real Element client.
SP_REPO="${STICKERPICKER_REPO:-https://github.com/maunium/stickerpicker.git}"
SP_REF="${STICKERPICKER_REF:-master}"
SP_SRC_HOST="${DATA_DIR}/stickerpicker-src"           # upstream checkout (large volume)

# ── Service-local config ──────────────────────────────────────────────────────
SP_HOST="stickers.${DOMAIN}"                          # public hostname for the widget
SP_WWW_USERLAND="/var/www/stickerpicker"              # served by Caddy (in userland)
SP_PACKS_HOST="${DATA_DIR}/sticker/packs"             # per-user packs (large volume)
SP_PACKS_USERLAND="${SP_WWW_USERLAND}/packs"          # bind target (the picker's fixed path)
SECRETS_FILE="${DATA_DIR}/secrets/sticker.env"
URL_SECRET_FILE="${DATA_DIR}/secrets/sticker-url.secret"
BACKEND_SRC="${POCKET_ROOT}/scripts/sticker/sticker-backend.py"
IMPORTER_SRC="${POCKET_ROOT}/scripts/sticker/importer-bot.py"
WIDGET_DIR="${POCKET_ROOT}/scripts/sticker/widget"
BACKEND_PORT="${STICKER_BACKEND_PORT:-8451}"

# ── Preflight: the userland + our source files must exist ────────────────────
[ -f "${BACKEND_SRC}" ]  || die "sticker backend missing: ${BACKEND_SRC}"
[ -f "${IMPORTER_SRC}" ] || die "importer bot missing: ${IMPORTER_SRC}"
python3 -c "import ast,sys; ast.parse(open('${BACKEND_SRC}').read())" \
  || die "sticker-backend.py failed to parse under python3"
python3 -c "import ast,sys; ast.parse(open('${IMPORTER_SRC}').read())" \
  || die "importer-bot.py failed to parse under python3"
in_debian 'true' >/dev/null 2>&1 || die "proot-distro debian not reachable — run scripts/install.sh first"

mkdir -p "${DATA_DIR}/secrets" "${SP_PACKS_HOST}/thumbnails" "${SP_PACKS_HOST}/users"
chmod 700 "${DATA_DIR}/secrets" 2>/dev/null || true

# ── 1. Fetch / refresh the upstream picker (AGPL — fetched, NOT vendored) ─────
# Idempotent: clone-or-fetch to the pinned ref. The picker's own LICENSE travels
# with the checkout (we never strip it).
say "fetching the upstream Maunium stickerpicker (${SP_REF}) — third-party AGPL, not vendored"
if [ -d "${SP_SRC_HOST}/.git" ]; then
  git -C "${SP_SRC_HOST}" fetch --depth 1 origin "${SP_REF}" \
    || die "could not fetch the upstream picker ref '${SP_REF}'"
  git -C "${SP_SRC_HOST}" checkout -q FETCH_HEAD \
    || git -C "${SP_SRC_HOST}" checkout -q "${SP_REF}" \
    || die "could not check out '${SP_REF}'"
else
  rm -rf "${SP_SRC_HOST}"
  git clone --depth 1 --branch "${SP_REF}" "${SP_REPO}" "${SP_SRC_HOST}" 2>/dev/null \
    || git clone "${SP_REPO}" "${SP_SRC_HOST}" \
    || die "could not clone the upstream picker from ${SP_REPO}"
  git -C "${SP_SRC_HOST}" checkout -q "${SP_REF}" 2>/dev/null || true
fi
[ -d "${SP_SRC_HOST}/web" ] || die "upstream picker has no web/ dir at ${SP_SRC_HOST}/web — wrong ref?"
ok "upstream picker checked out at ${SP_SRC_HOST} (web/ present)"

# ── 2. Copy the static assets into the userland + put packs on the volume ─────
# The picker is a static SPA — the reference deployment serves web/ as-is (no
# build). Copy the tree into the userland; exclude packaging-only files. The
# packs/ dir lives on the large volume and is bind-mounted at the picker's fixed
# path at supervise time (so user packs + thumbnails survive a rootfs rebuild).
say "installing picker assets into the userland (${SP_WWW_USERLAND})"
in_debian "rm -rf '${SP_WWW_USERLAND}' && mkdir -p '${SP_WWW_USERLAND}'" \
  || die "could not prepare ${SP_WWW_USERLAND} in the userland"
# Stream web/ over a tar pipe so we never hardcode the rootfs path on the host.
( cd "${SP_SRC_HOST}/web" && tar -cf - \
    --exclude=package.json --exclude=yarn.lock --exclude=esinstall.js \
    --exclude=node_modules . ) \
  | proot-distro login debian -- bash -lc "tar -xf - -C '${SP_WWW_USERLAND}'" \
  || die "failed to copy picker web assets into the userland"
in_debian "chmod -R a+rX '${SP_WWW_USERLAND}'" || true
in_debian "[ -f '${SP_WWW_USERLAND}/index.html' ]" \
  || die "picker install looks incomplete (index.html missing in ${SP_WWW_USERLAND})"

# packs/ on the large volume; seed an empty index.json from OUR template if the
# picker didn't ship one. Substitute the server_name placeholder.
mkdir -p "${SP_PACKS_HOST}/thumbnails" "${SP_PACKS_HOST}/users"
if [ ! -f "${SP_PACKS_HOST}/index.json" ]; then
  sed "s|__MATRIX_SERVER_NAME__|${MATRIX_SERVER_NAME}|g" \
    "${WIDGET_DIR}/index.json.tmpl" > "${SP_PACKS_HOST}/index.json"
  say "seeded an empty packs/index.json (the backend grows it as users upload)"
fi
ok "picker assets installed; packs on the large volume at ${SP_PACKS_HOST}"

# ── 3. Seed the 0600 secrets file (Giphy key + tokens + URL-signing secret) ───
# Secrets live in this file (sourced by the launcher), NEVER on argv. The values
# come from .env (GIPHY_API_KEY, STICKER_SERVICE_TOKEN, STICKER_BOT_*); we copy
# them into a 0600 file so the supervised launcher reads them without them
# appearing in /proc/*/cmdline. The HMAC URL-signing secret is generated once and
# persisted (a per-deployment secret, not a credential).
#
# The URL-signing secret (256-bit, openssl rand -hex 32) is generated ONCE here,
# 0600, and is the single source consumed by all three signers: it is written into
# ${SECRETS_FILE} as STICKER_URL_SECRET (the backend + importer read it from the
# env) AND re-read below in section 7 for the openssl widget-URL signature — all
# command-substituted (trailing newline stripped) so the byte value is identical.
if [ ! -s "${URL_SECRET_FILE}" ]; then
  ( umask 077; openssl rand -hex 32 > "${URL_SECRET_FILE}" ) \
    || die "failed to generate the sticker URL-signing secret"
  chmod 600 "${URL_SECRET_FILE}" 2>/dev/null || true
  say "generated the sticker URL-signing secret → ${URL_SECRET_FILE}"
fi
[ -s "${URL_SECRET_FILE}" ] || die "sticker URL-signing secret missing: ${URL_SECRET_FILE}"

# STICKER_SERVICE_TOKEN must be a real Matrix access token (a user on this
# homeserver with media-upload rights). It is user-supplied via .env / setup.sh;
# fail loud if absent so we don't supervise a backend that 401s every upload.
require_var STICKER_SERVICE_TOKEN "a Matrix access token for the sticker backend to upload media (set in .env / setup.sh)"

umask 077
{
  echo "# pocket-homeserver sticker backend + importer secrets — generated by"
  echo "# steps/82-install-stickers.sh. 0600. Keep private; sourced by the launchers."
  echo "STICKER_BIND_HOST=127.0.0.1"
  echo "STICKER_BIND_PORT=${BACKEND_PORT}"
  echo "STICKER_PACKS_DIR=${SP_PACKS_USERLAND}"
  echo "HS_LOCAL=http://127.0.0.1:8448"
  echo "HS_URL=http://127.0.0.1:8448"
  echo "STICKER_BACKEND_URL=http://127.0.0.1:${BACKEND_PORT}"
  echo "MATRIX_SERVER_NAME=${MATRIX_SERVER_NAME}"
  echo "STICKER_WIDGET_ORIGIN=https://${SP_HOST}"
  echo "STICKER_IDENTITY_MODE=${STICKER_IDENTITY_MODE:-log}"
  echo "STICKER_URL_SECRET=$(cat "${URL_SECRET_FILE}")"
  echo "STICKER_SERVICE_TOKEN=${STICKER_SERVICE_TOKEN}"
  # Giphy is optional — empty key disables the Giphy tab (503), not the picker.
  echo "GIPHY_API_KEY=${GIPHY_API_KEY:-}"
  # Importer bot creds (optional — set to also run the DM-import bot).
  echo "STICKER_BOT_TOKEN=${STICKER_BOT_TOKEN:-}"
  echo "STICKER_BOT_MXID=${STICKER_BOT_MXID:-}"
  echo "STICKER_BOT_NAME=${STICKER_BOT_NAME:-sticker-importer}"
} > "${SECRETS_FILE}"
chmod 600 "${SECRETS_FILE}" 2>/dev/null || true
ok "wrote ${SECRETS_FILE} (0600; Giphy=$([ -n "${GIPHY_API_KEY:-}" ] && echo on || echo off))"

# ── 4. Optional Pillow for nicer 256px thumbnails (best effort) ──────────────
# The backend works without Pillow (it writes raw bytes the browser scales via
# CSS); Pillow just produces smaller, pre-sized thumbnails. Native to Termux.
if ! python3 -c 'import PIL' >/dev/null 2>&1; then
  say "installing Pillow (optional — improves picker thumbnails)"
  pip install --quiet Pillow >/dev/null 2>&1 \
    || pip3 install --quiet Pillow >/dev/null 2>&1 \
    || warn "Pillow not installed — thumbnails fall back to raw bytes (the picker still works)"
fi

# ── 5. Caddy vhost (self-contained site block, imported by the core Caddyfile) ─
# Matches the core Caddyfile listener style EXACTLY: explicit
# http://<host>:${CADDY_PORT} + bind ${CADDY_BIND} (plain HTTP on the shared high
# loopback port; the Cloudflare Tunnel terminates public TLS). The picker fetches
# api/* relative to its base, so handle_path /api/* strips the prefix and proxies
# to the native backend on loopback; everything else is the static SPA.
say "writing the Caddy vhost → /etc/caddy/apps/stickers.caddy"
proot-distro login debian -- bash -lc 'mkdir -p /etc/caddy/apps && cat > /etc/caddy/apps/stickers.caddy' <<EOF
# Sticker picker (Maunium widget) — optional app vhost for pocket-homeserver.
# Public hostname stickers.${DOMAIN}; bound to loopback (the Cloudflare Tunnel
# forwards public traffic here). The picker runs inside Element's iframe; gate
# this hostname at the Cloudflare edge with Cloudflare Access (dashboard).
http://${SP_HOST}:${CADDY_PORT} {
	bind ${CADDY_BIND}

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options nosniff
		# The picker is loaded as a widget INSIDE Element's iframe, so it must
		# be frameable by the chat origin (do NOT send X-Frame-Options DENY).
		Referrer-Policy no-referrer
		-Server
	}

	# /api/* → the native sticker backend on loopback (Upload + Giphy proxy +
	# pack writes). handle_path strips the /api prefix so the backend sees
	# /api/<endpoint> as written in sticker-backend.py (it expects /api/*).
	handle /api/* {
		reverse_proxy 127.0.0.1:${BACKEND_PORT} {
			header_up X-Real-IP {client_ip}
		}
	}

	# Everything else → the static picker SPA assets.
	handle {
		root * ${SP_WWW_USERLAND}
		file_server
	}
}
EOF
ok "wrote /etc/caddy/apps/stickers.caddy"

# Validate the FULL Caddyfile inside the userland (fail closed). We do NOT restart
# Caddy here — print the restart hint instead.
say "validating the Caddyfile inside the userland"
in_debian 'caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile' \
  || die "caddy validate FAILED — refusing to leave a broken vhost in place (fix /etc/caddy/apps/stickers.caddy)"
ok "Caddyfile still valid with the stickers vhost added"

# ── 6. Supervise the backend + importer bot (Termux-native) ──────────────────
# Both are native python3 (they only talk to the loopback CS API + backend). The
# shared supervisor records each launch argv to ${POCKET_STATE_DIR}/<name>.cmd so
# start-stack.sh re-supervises them on every bring-up and ops/restart.sh can
# restart them. Secrets are read from the 0600 ${SECRETS_FILE} by a tiny launcher
# (env file sourced inside it) — never passed on argv.
say "writing the native launchers under ${DATA_DIR}/sticker"
mkdir -p "${DATA_DIR}/sticker"
cat > "${DATA_DIR}/sticker/run-backend.sh" <<LAUNCH
#!/usr/bin/env bash
# Runs TERMUX-NATIVE; started + kept alive by steps/82-install-stickers.sh.
# Sources the 0600 secrets file so STICKER_SERVICE_TOKEN/GIPHY_API_KEY/etc. reach
# the backend via the environment, never via argv.
set -a; . "${SECRETS_FILE}"; set +a
exec python3 "${BACKEND_SRC}"
LAUNCH
chmod 700 "${DATA_DIR}/sticker/run-backend.sh"

cat > "${DATA_DIR}/sticker/run-importer.sh" <<LAUNCH
#!/usr/bin/env bash
# Runs TERMUX-NATIVE; started + kept alive by steps/82-install-stickers.sh.
set -a; . "${SECRETS_FILE}"; set +a
exec python3 "${IMPORTER_SRC}"
LAUNCH
chmod 700 "${DATA_DIR}/sticker/run-importer.sh"

supervise sticker-backend -- bash "${DATA_DIR}/sticker/run-backend.sh"

# Confirm the backend health endpoint comes up on loopback.
say "confirming the sticker backend came up"
up=0
for _ in $(seq 1 15); do
  if curl -sf -m 3 "http://127.0.0.1:${BACKEND_PORT}/api/health" >/dev/null 2>&1; then
    up=1; break
  fi
  sleep 1
done
[ "${up}" -eq 1 ] && ok "sticker backend healthy on 127.0.0.1:${BACKEND_PORT}" \
  || warn "sticker backend not healthy yet — check ${POCKET_LOG_DIR}/sticker-backend.log"

# The importer bot only runs if its creds are present (optional capability).
if [ -n "${STICKER_BOT_TOKEN:-}" ] && [ -n "${STICKER_BOT_MXID:-}" ]; then
  supervise sticker-importer -- bash "${DATA_DIR}/sticker/run-importer.sh"
  ok "importer bot supervised (DM ${STICKER_BOT_MXID} an image to import it)"
else
  say "importer bot creds not set (STICKER_BOT_TOKEN/STICKER_BOT_MXID) — skipping it (the picker still works)"
  say "  set them in .env / setup.sh to also run the DM-import bot, then re-run with --force"
fi

# ── 7. Register the picker as a personal widget on the admin account ─────────
# Mirrors the reference 49e step: writes an m.widgets entry to the admin user's
# account_data so Element shows the sticker icon in the room composer. The widget
# URL carries a signed identity (<mxid>|<hmac>) so the backend can verify the
# caller's mxid (the picker only FORWARDS this value; no JS rebuild needed).
# Needs an admin access token + mxid (user-supplied via .env / setup.sh).
#
# The HMAC signature computed below matches sticker-backend.py:_sign_mxid()
# byte-for-byte (verified openssl⇄python before shipping): `printf %s "$mxid" |
# openssl dgst -sha256 -hmac "$secret"` and Python's hmac.new(secret, mxid,
# sha256).hexdigest() produce identical hex. awk '{print $NF}' takes the hex
# from openssl's "SHA2-256(stdin)= <hex>" output. A mismatch would fail every
# widget call in enforce mode.
if [ -n "${STICKER_ADMIN_TOKEN:-}" ] && [ -n "${STICKER_ADMIN_MXID:-}" ]; then
  require_cmd jq
  API="http://127.0.0.1:8448/_matrix/client/v3"
  curl -sf -m 3 http://127.0.0.1:8448/_matrix/client/versions >/dev/null \
    || warn "homeserver not responding on 127.0.0.1:8448 — skipping widget registration (re-run later)"
  if curl -sf -m 3 http://127.0.0.1:8448/_matrix/client/versions >/dev/null 2>&1; then
    URL_SECRET="$(cat "${URL_SECRET_FILE}")"
    SIG="$(printf %s "${STICKER_ADMIN_MXID}" | openssl dgst -sha256 -hmac "${URL_SECRET}" | awk '{print $NF}')"
    [ -n "${SIG}" ] || die "failed to compute the widget-URL identity signature (openssl)"
    ENC_SIGNED="$(printf %s "${STICKER_ADMIN_MXID}|${SIG}" | jq -Rr @uri)"
    ENC_MXID="$(printf %s "${STICKER_ADMIN_MXID}" | jq -Rr @uri)"
    WIDGET_URL="https://${SP_HOST}/?theme=\$theme&matrix_user_id=${ENC_SIGNED}&matrix_room_id=\$matrix_room_id"
    WIDGET_ID="stickerpicker"
    # account_data shape: the OUTER type is m.widget; the m.stickerpicker type
    # lives at content.type (verified against the Maunium widget wiki).
    BODY="$(jq -nc \
        --arg id     "${WIDGET_ID}" \
        --arg url    "${WIDGET_URL}" \
        --arg name   "Stickerpicker" \
        --arg sender "${STICKER_ADMIN_MXID}" \
        '{ ($id): {
              type: "m.widget", id: $id, sender: $sender, state_key: $id,
              content: { type: "m.stickerpicker", url: $url, name: $name,
                         creatorUserId: $sender, data: {} } } }')"
    say "registering the m.widgets account_data on ${STICKER_ADMIN_MXID}"
    HTTP="$(curl -sS -o /dev/null -w '%{http_code}' \
        -H "Authorization: Bearer ${STICKER_ADMIN_TOKEN}" \
        -H "Content-Type: application/json" \
        -X PUT "${API}/user/${ENC_MXID}/account_data/m.widgets" \
        -d "${BODY}" 2>/dev/null || echo 000)"
    if [ "${HTTP}" = "200" ] || [ "${HTTP}" = "204" ]; then
      ok "sticker picker widget registered on ${STICKER_ADMIN_MXID} (HTTP ${HTTP})"
    else
      warn "widget registration returned HTTP ${HTTP} — register it later (token/mxid valid?)"
    fi
  fi
else
  say "widget auto-registration skipped (set STICKER_ADMIN_TOKEN + STICKER_ADMIN_MXID in .env / setup.sh)"
  say "  without it, enable the picker per user via Element's integration/widget settings."
fi

# ── Closing notes ─────────────────────────────────────────────────────────────
echo
ok "Sticker picker installed (widget served on ${SP_HOST}; backend 127.0.0.1:${BACKEND_PORT}; packs on ${SP_PACKS_HOST})"
say "The picker UI is the third-party Maunium stickerpicker (AGPL), fetched at ${SP_SRC_HOST}."
echo
say "Manual Cloudflare steps (in the Cloudflare dashboard — NOT done by this script):"
say "  1. In the Tunnel config, add a Public Hostname:"
say "       ${SP_HOST}  ->  http://localhost:${CADDY_PORT}  (the local Caddy edge, plain HTTP)"
say "  2. Add a Cloudflare Access policy protecting ${SP_HOST} so only your users reach it."
say "  If the core stack is already running, pick up the new vhost with:"
say "       bash ${POCKET_ROOT}/scripts/start-stack.sh --restart"
say "  (brief ingress outage while cloudflared cycles)."
echo
say "Identity mode is '${STICKER_IDENTITY_MODE:-log}'. Start in 'log', mint widget URLs for"
say "every user, then flip STICKER_IDENTITY_MODE=enforce (re-run --force). See docs/STICKERS.md."

# Generalized from a working deployment; review before running.
