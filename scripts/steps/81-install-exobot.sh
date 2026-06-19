#!/usr/bin/env bash
#
# steps/81-install-exobot.sh — install + supervise the OPTIONAL on-phone LLM
# Matrix bot (exobot) and (optionally) its Gradio web UI.
#
# ADVANCED / BYO. This ships NO model and NO binary. You bring your own:
#   * LLAMA_SERVER_BIN — a llama.cpp `llama-server` build that matches YOUR
#     phone's CPU (e.g. an aarch64 build with the right -march for your SoC), and
#   * MODEL_PATH       — a GGUF model file (small + quantized is best on a phone).
# Both are validated fail-loud below; this step refuses to start the bot until
# they exist. See docs/CHATBOTS.md ("On-phone LLM (advanced)") for how to obtain
# them.
#
# RUNTIME (mixed):
#   * The bot (scripts/chatbot/exobot.py) runs TERMUX-NATIVE python3 (stdlib
#     only). It subprocess-manages llama-server, launching it inside the proot
#     userland via `proot-distro` (so your aarch64-glibc binary runs on bionic
#     Termux). Set EXOBOT_PROOT_DISTRO="" if your binary is a Termux-native build.
#   * The OPTIONAL web UI (scripts/chatbot/exobot-ui.py) needs the `gradio` pip
#     package, so it runs INSIDE the proot userland. Its lazy-start waker
#     (scripts/chatbot/exobot-waker.py) runs Termux-native.
#
# This is a core step that SELF-GATES on ENABLE_EXOBOT (install.sh runs it
# unconditionally; it no-ops unless you opt in). ENABLE_EXOBOT defaults to false.
#
# What it does (idempotent — safe to re-run):
#   1. fail-loud on the BYO requirements (LLAMA_SERVER_BIN + MODEL_PATH),
#   2. ensures the secrets + log dirs exist (0700 / 0600),
#   3. seeds a 0600 ${DATA_DIR}/secrets/exobot.env template the operator fills
#      in with the bot's Matrix access token (token NEVER goes in .env / argv),
#   4. writes a Termux-native launcher that sources that 0600 file + the .env
#      config and execs the bot, then supervises it,
#   5. when EXOBOT_UI=true: installs gradio in the userland, writes an
#      in-userland UI launcher + a Termux-native UI start/stop script, writes a
#      Caddy vhost for the AI host (no restart — prints the hint), and supervises
#      the waker.
#
# SECRET HANDLING: the bot's access token lives ONLY in the 0600 secrets file,
# which the launcher `source`s — it never reaches argv / /proc/<pid>/cmdline.
# Registering the bot account + minting that token is a manual operator step
# (see the TODO(human) block below + docs/CHATBOTS.md).
#
# Generalized from a working deployment; review before running on a fresh phone.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env

# ── Self-gate: only run when enabled (default off) ───────────────────────────
if [ "${ENABLE_EXOBOT:-false}" != "true" ]; then
  ok "exobot disabled (ENABLE_EXOBOT != true) — skipping (this is the default)"
  exit 0
fi

require_var DATA_DIR "folder on your large volume / SD card"
require_cmd python3

# ── Config (env-driven; all generalized) ─────────────────────────────────────
SERVER_NAME="${MATRIX_SERVER_NAME:-${DOMAIN:-}}"
require_var SERVER_NAME "your Matrix server_name (the ':server' half of an MXID)"

BOT_LOCALPART="${EXOBOT_LOCALPART:-exobot}"          # the bot account localpart
BOT_MXID="${EXOBOT_MXID:-@${BOT_LOCALPART}:${SERVER_NAME}}"
HS_URL="${EXOBOT_HS_URL:-http://127.0.0.1:8448}"     # Matrix client-server API base
PROOT_DISTRO="${EXOBOT_PROOT_DISTRO-debian}"         # "" = run the binary directly

# BYO: the user-supplied llama.cpp binary + GGUF model. These paths are
# interpreted in the context the binary runs in:
#   * with proot (default): a path INSIDE the proot userland filesystem,
#   * without proot:         a host (Termux) path.
LLAMA_SERVER_BIN="${LLAMA_SERVER_BIN:-}"
MODEL_PATH="${MODEL_PATH:-}"

SECRETS_DIR="${DATA_DIR}/secrets"
BOT_ENV="${SECRETS_DIR}/exobot.env"                  # 0600 — holds the access token
CB_DIR="${POCKET_ROOT}/scripts/chatbot"
BOT_SRC="${CB_DIR}/exobot.py"
UI_SRC="${CB_DIR}/exobot-ui.py"
WAKER_SRC="${CB_DIR}/exobot-waker.py"
RUN_DIR="${DATA_DIR}/exobot"                         # launchers live here (ext4 / large volume)
BOT_RUN="${RUN_DIR}/run-bot.sh"

mkdir -p "${SECRETS_DIR}" "${POCKET_LOG_DIR}" "${POCKET_STATE_DIR}" "${RUN_DIR}"
chmod 700 "${SECRETS_DIR}" 2>/dev/null || true

# ── Preflight: the bot source must be present (fail-closed) ──────────────────
[ -f "${BOT_SRC}" ] || die "exobot source missing: ${BOT_SRC} — the chatbot module was not shipped"
python3 -c "import ast,sys; ast.parse(open('${BOT_SRC}').read())" \
  || die "exobot.py failed to parse under python3"
ok "exobot source present + parse-clean (${BOT_SRC})"

# ── BYO requirement: fail LOUD if the binary or model is unset/missing ────────
# This is the whole point of the "bring your own" model — we cannot ship either,
# and a missing one is the most common misconfiguration. Be explicit + helpful.
if [ -z "${LLAMA_SERVER_BIN}" ] || [ -z "${MODEL_PATH}" ]; then
  warn "exobot is BYO (bring your own model): you must supply BOTH:"
  warn "  LLAMA_SERVER_BIN — a llama.cpp 'llama-server' build for YOUR phone's CPU"
  warn "  MODEL_PATH       — a GGUF model file"
  warn "Set them in .env (then re-run with --force), e.g.:"
  warn "  LLAMA_SERVER_BIN=/root/llama.cpp/build/bin/llama-server"
  warn "  MODEL_PATH=/root/models/your-model.gguf"
  warn "(with EXOBOT_PROOT_DISTRO=debian the paths are INSIDE the userland; set"
  warn " EXOBOT_PROOT_DISTRO= to use Termux-native host paths.) See docs/CHATBOTS.md."
  die "exobot enabled but LLAMA_SERVER_BIN and/or MODEL_PATH is unset"
fi

# Existence check. The binary/model live inside the userland when proot is used,
# so probe there; otherwise probe the host path.
_path_exists() {  # _path_exists <abs-path>
  if [ -n "${PROOT_DISTRO}" ]; then
    proot-distro login "${PROOT_DISTRO}" -- bash -lc "[ -e '$1' ]" >/dev/null 2>&1
  else
    [ -e "$1" ]
  fi
}
if [ -n "${PROOT_DISTRO}" ]; then
  require_cmd proot-distro
  proot-distro login "${PROOT_DISTRO}" -- true >/dev/null 2>&1 \
    || die "proot-distro '${PROOT_DISTRO}' not reachable — run scripts/install.sh first"
fi
_path_exists "${LLAMA_SERVER_BIN}" \
  || die "LLAMA_SERVER_BIN not found: ${LLAMA_SERVER_BIN} ${PROOT_DISTRO:+(inside proot '${PROOT_DISTRO}')} — build/copy your llama-server there (see docs/CHATBOTS.md)"
_path_exists "${MODEL_PATH}" \
  || die "MODEL_PATH not found: ${MODEL_PATH} ${PROOT_DISTRO:+(inside proot '${PROOT_DISTRO}')} — place your GGUF model there (see docs/CHATBOTS.md)"
ok "BYO binary + model present (bin=${LLAMA_SERVER_BIN} model=${MODEL_PATH})"

# ── Secrets template: the bot's Matrix access token (0600; off-argv) ─────────
#
# The bot needs a Matrix ACCESS TOKEN for its own account (@${BOT_LOCALPART}:
# ${SERVER_NAME}). Minting it touches a homeserver credential, so it is a
# deliberate OPERATOR step rather than something this installer automates — you
# register the bot account and obtain its token, then drop it into ${BOT_ENV}.
# docs/CHATBOTS.md gives the exact OFF-ARGV recipe (a hidden `read -rs` password
# prompt → curl /login → jq .access_token → write 0600), so the password/token
# never reach a command line / /proc/<pid>/cmdline.
#
# This step's contract: it seeds a 0600 placeholder template here and then
# FAIL-CLOSES below (die) until ${BOT_ENV} contains a real EXOBOT_TOKEN. The
# launcher (written further down) sources that 0600 file LAST so the token
# reaches the bot only via the environment — never echoed, never on argv.
if [ ! -s "${BOT_ENV}" ]; then
  umask 077
  cat > "${BOT_ENV}" <<EOF
# exobot secrets — chmod 600, sourced by the launcher (NEVER committed / on argv).
# Fill in the bot's Matrix access token (see scripts/steps/81-install-exobot.sh
# + docs/CHATBOTS.md for how to register the account + mint the token off-argv).
EXOBOT_TOKEN=REPLACE_WITH_BOT_ACCESS_TOKEN
EOF
  chmod 600 "${BOT_ENV}" 2>/dev/null || true
  warn "seeded the secrets template ${BOT_ENV} (chmod 600)"
  warn "  -> put the bot's Matrix access token there as EXOBOT_TOKEN=... then re-run"
else
  say "keeping existing secrets file ${BOT_ENV}"
fi

# Fail-closed: refuse to wire up a launcher that would boot with the placeholder.
if ! grep -q '^EXOBOT_TOKEN=' "${BOT_ENV}" 2>/dev/null \
   || grep -q '^EXOBOT_TOKEN=REPLACE_WITH_BOT_ACCESS_TOKEN' "${BOT_ENV}" 2>/dev/null; then
  die "EXOBOT_TOKEN is not set in ${BOT_ENV} — register the bot + add its token there, then re-run (see docs/CHATBOTS.md)"
fi

# ── Write the Termux-native bot launcher ─────────────────────────────────────
# All non-secret config is exported here from .env (known at install time). The
# 0600 secrets file is sourced LAST so EXOBOT_TOKEN reaches the bot via the
# environment, never via argv. The launcher path is what the supervisor records
# in its .cmd, so start-stack.sh re-supervises the same command on every bring-up.
say "writing the bot launcher → ${BOT_RUN}"
umask 077
cat > "${BOT_RUN}" <<EOF
#!/usr/bin/env bash
# Runs TERMUX-NATIVE; started + kept alive by steps/81-install-exobot.sh /
# start-stack.sh. The bot binds nothing inbound; it subprocess-manages
# llama-server and talks to the loopback Matrix API.
set -u
# Non-secret config (from .env at install time).
export EXOBOT_MXID='${BOT_MXID}'
export EXOBOT_HS_URL='${HS_URL}'
export EXOBOT_PROOT_DISTRO='${PROOT_DISTRO}'
export LLAMA_SERVER_BIN='${LLAMA_SERVER_BIN}'
export MODEL_PATH='${MODEL_PATH}'
export LLAMA_SERVER_PORT='${LLAMA_SERVER_PORT:-8081}'
export EXOBOT_ALLOWED_ROOMS='${EXOBOT_ALLOWED_ROOMS:-}'
export LLAMA_KEEP_WARM='${LLAMA_KEEP_WARM:-true}'
export EXOBOT_IDLE_TIMEOUT_S='${EXOBOT_IDLE_TIMEOUT_S:-600}'
export INTERJECT_ENABLED='${INTERJECT_ENABLED:-false}'
export SEED_ENABLED='${SEED_ENABLED:-false}'
export REVIVE_ENABLED='${REVIVE_ENABLED:-false}'
export CROSSBOT_ENABLED='${CROSSBOT_ENABLED:-false}'
export CROSSBOT_TARGETS='${CROSSBOT_TARGETS:-}'
export CROSSBOT_ROOM_ID='${CROSSBOT_ROOM_ID:-}'
export KNOWN_BOT_MXIDS='${KNOWN_BOT_MXIDS:-}'
# Secret LAST (0600 file; never on argv). It must export EXOBOT_TOKEN.
set -a; . '${BOT_ENV}'; set +a
exec python3 '${BOT_SRC}'
EOF
chmod 700 "${BOT_RUN}" 2>/dev/null || true
ok "wrote the bot launcher"

# ── Supervise the bot (Termux-native respawn loop + identity-checked pid) ─────
supervise exobot -- bash "${BOT_RUN}"

# Confirm the python child came up by looking for the "booting" log line.
say "confirming exobot came up"
up=0
for _ in $(seq 1 15); do
  if grep -q 'booting as' "${POCKET_LOG_DIR}/exobot.log" 2>/dev/null; then
    up=1; break
  fi
  sleep 1
done
[ "${up}" -eq 1 ] && ok "exobot booting (log: ${POCKET_LOG_DIR}/exobot.log)" \
  || warn "exobot did not log 'booting' yet — check ${POCKET_LOG_DIR}/exobot.log"

# ── OPTIONAL: the Gradio web UI + its lazy-start waker ───────────────────────
if [ "${EXOBOT_UI:-false}" = "true" ]; then
  [ -f "${UI_SRC}" ]    || die "exobot-ui source missing: ${UI_SRC}"
  [ -f "${WAKER_SRC}" ] || die "exobot-waker source missing: ${WAKER_SRC}"
  require_var DOMAIN "your public domain, e.g. example.com"
  require_cmd proot-distro

  UI_PORT="${EXOBOT_UI_PORT:-9114}"
  WAKER_PORT="${EXOBOT_WAKER_PORT:-9116}"
  AI_HOST="${EXOBOT_UI_HOST_PUBLIC:-ai.${DOMAIN}}"
  UI_DIR="/opt/exobot-ui"                       # install dir INSIDE the userland
  UI_RUN_USERLAND="${UI_DIR}/run-ui.sh"
  UI_START_SH="${RUN_DIR}/start-ui.sh"          # Termux-native start/stop wrapper
  UI_PIDFILE="${POCKET_STATE_DIR}/exobot-ui.pid"

  say "installing the web UI into ${UI_DIR} (inside proot '${PROOT_DISTRO:-debian}')"
  _ui_distro="${PROOT_DISTRO:-debian}"
  in_ui() { proot-distro login "${_ui_distro}" -- bash -lc "$1"; }

  # gradio (the only third-party dependency) goes INSIDE the userland.
  run_once exobot-ui-deps -- in_ui \
    "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends python3 python3-pip ca-certificates && python3 -m pip install --break-system-packages --upgrade gradio" \
    || die "failed to install gradio inside the userland"

  in_ui "mkdir -p '${UI_DIR}'" || die "could not create ${UI_DIR} in the userland"
  proot-distro login "${_ui_distro}" -- bash -lc "umask 022; cat > '${UI_DIR}/exobot-ui.py'" < "${UI_SRC}" \
    || die "failed to copy exobot-ui.py into the userland"
  in_ui "python3 -c 'import ast,sys; ast.parse(open(\"${UI_DIR}/exobot-ui.py\").read())'" \
    || die "the copied exobot-ui.py failed to parse under the userland python3"

  # In-userland UI launcher (config from .env at install time).
  proot-distro login "${_ui_distro}" -- bash -lc "umask 077; cat > '${UI_RUN_USERLAND}'" <<UILAUNCH
#!/bin/bash
# Runs INSIDE the userland; supervised by start-ui.sh (Termux-native).
export EXOBOT_UI_HOST=127.0.0.1
export EXOBOT_UI_PORT=${UI_PORT}
export EXOBOT_UI_ROOT_PATH=
export LLAMA_URL=http://127.0.0.1:${LLAMA_SERVER_PORT:-8081}
export EXOBOT_UI_TITLE='${EXOBOT_UI_TITLE:-Self-hosted AI}'
exec python3 ${UI_DIR}/exobot-ui.py
UILAUNCH
  in_ui "chmod 700 '${UI_RUN_USERLAND}'" || die "failed to chmod the UI launcher"

  # Termux-native start/stop wrapper. The waker shells out to this with [--stop]
  # to start/stop the (heavier) Gradio backend on demand. `supervise` /
  # `unsupervise` give it the same respawn + identity-checked pidfile as the
  # rest of the stack.
  say "writing the UI start/stop wrapper → ${UI_START_SH}"
  cat > "${UI_START_SH}" <<STARTUI
#!/usr/bin/env bash
# Termux-native: start (default) or --stop the Gradio UI backend (in proot).
set -u
. "\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/../.." && pwd)/pocket-homeserver/scripts/lib/common.sh" 2>/dev/null \\
  || . "${POCKET_ROOT}/scripts/lib/common.sh"
load_env
if [ "\${1:-}" = "--stop" ]; then
  unsupervise exobot-ui
  exit 0
fi
supervise exobot-ui -- proot-distro login "${_ui_distro}" -- bash "${UI_RUN_USERLAND}"
STARTUI
  chmod 700 "${UI_START_SH}" 2>/dev/null || true

  # Caddy vhost for the AI host. Plain HTTP on the local edge (the CF tunnel
  # terminates public TLS). NO native auth — gate at the Cloudflare edge and/or
  # with the optional Matrix-SSO gateway block (commented). Do NOT restart Caddy.
  say "writing the Caddy vhost → /etc/caddy/apps/exobot-ui.caddy"
  proot-distro login "${_ui_distro}" -- bash -lc 'mkdir -p /etc/caddy/apps && cat > /etc/caddy/apps/exobot-ui.caddy' <<CADDY
# ============================================================================
# exobot web UI (on-device AI chat) — ${AI_HOST}   (NO native auth)
# Public hostname ${AI_HOST}; bound to loopback (the Cloudflare Tunnel forwards
# public traffic here). Gradio app on 127.0.0.1:${UI_PORT}.
#
# AUTH (REQUIRED): this UI has NO login of its own. You MUST protect ${AI_HOST}
# either with a Cloudflare Access policy at the edge (the default) or with the
# OPTIONAL Matrix-SSO gateway block below (uncomment it; the /authgw/* handler
# MUST precede the gated catch-all). See docs/APP_AUTH.md.
# Installed by scripts/steps/81-install-exobot.sh.
# ============================================================================
http://${AI_HOST}:${CADDY_PORT} {
	bind ${CADDY_BIND}

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options nosniff
		Referrer-Policy strict-origin-when-cross-origin
		-Server
	}

	# ── OPTIONAL: Matrix-SSO gateway add-on (default is Cloudflare Access) ──
	# handle /authgw/* {
	# 	reverse_proxy 127.0.0.1:${AUTHGW_PORT:-9095} {
	# 		header_up X-Real-IP {client_ip}
	# 	}
	# }
	# request_header -Remote-User
	# forward_auth 127.0.0.1:${AUTHGW_PORT:-9095} {
	# 	uri /authgw/verify
	# 	copy_headers Remote-User
	# }

	# Stream Gradio (websockets / SSE) straight through to the loopback UI.
	reverse_proxy 127.0.0.1:${UI_PORT} {
		header_up Host {http.request.host}
		header_up X-Forwarded-Proto https
	}
}
CADDY
  ok "wrote /etc/caddy/apps/exobot-ui.caddy"

  in_ui 'caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile' \
    || die "caddy validate FAILED — refusing to leave a broken vhost in place (fix /etc/caddy/apps/exobot-ui.caddy)"
  ok "Caddyfile still valid with the exobot-ui vhost added"

  # Supervise the waker (Termux-native). It lazy-starts/idle-stops the UI via the
  # start-ui.sh wrapper, passed off-argv through the environment.
  supervise exobot-waker -- \
    env EXOBOT_WAKER_PORT="${WAKER_PORT}" EXOBOT_UI_PORT="${UI_PORT}" \
        EXOBOT_UI_START_SH="${UI_START_SH}" \
        EXOBOT_IDLE_SECS="${EXOBOT_IDLE_SECS:-900}" \
        python3 "${WAKER_SRC}"

  echo
  ok "exobot web UI installed (waker on 127.0.0.1:${WAKER_PORT}; UI lazy-starts on 127.0.0.1:${UI_PORT})"
  say "Manual Cloudflare steps (in the Cloudflare dashboard — NOT done by this script):"
  say "  1. In the Tunnel config add a Public Hostname:"
  say "       ${AI_HOST}  ->  http://localhost:${CADDY_PORT}  (the local Caddy edge, plain HTTP)"
  say "  2. Add a Cloudflare Access policy protecting ${AI_HOST} (REQUIRED — the UI has no login),"
  say "     OR enable the Matrix-SSO gateway block in the vhost (see docs/APP_AUTH.md)."
fi

# ── Closing notes ─────────────────────────────────────────────────────────────
echo
ok "exobot installed + supervised (Termux-native; talks to llama-server on 127.0.0.1:${LLAMA_SERVER_PORT:-8081})"
say "Invite ${BOT_MXID} to a room that is in EXOBOT_ALLOWED_ROOMS, then tag it:"
say "  @${BOT_LOCALPART} hello   ·   @${BOT_LOCALPART} help   ·   @${BOT_LOCALPART} 4 what is 13*47?"
say "The model is BYO and not loaded until the first mention (or kept warm if LLAMA_KEEP_WARM=true)."
say "If the core stack is already running, pick up any vhost change with:"
say "  bash ${POCKET_ROOT}/scripts/start-stack.sh --restart"

# Generalized from a working deployment; review before running.
