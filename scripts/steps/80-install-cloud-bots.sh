#!/usr/bin/env bash
#
# steps/80-install-cloud-bots.sh — install + supervise one OR MORE cloud-LLM
# Matrix chat bots (OPTIONAL, OFF by default).
#
# Each bot is a native python3 process (scripts/chatbot/cloud_chatbot.py) that
# signs in to your homeserver on loopback, watches the rooms you allow, and
# answers @-mentions by calling an OpenAI-compatible chat-completions endpoint
# (Groq's free tier, OpenRouter, a local LLM, …). It runs TERMUX-NATIVE — it only
# needs loopback to the homeserver and one outbound HTTPS call per reply, not the
# proot userland. It has NO inbound listener, so it adds no edge attack surface.
#
# MULTIPLE BOTS: drop one 0600 env file per bot at
#   ${DATA_DIR}/secrets/cloud-bot-<name>.env
# (e.g. cloud-bot-llama.env + cloud-bot-qwen.env, which can share one Groq key).
# This step discovers every such file and supervises one `cloud-bot-<name>`
# process per bot, each sourcing ONLY its own env file. With no env files present
# it prints how to create one and exits cleanly (still success — nothing to do).
#
# This is a core step that SELF-GATES on ENABLE_CLOUD_BOTS (install.sh runs it
# unconditionally; it no-ops when disabled). ENABLE_CLOUD_BOTS defaults to false.
#
# What it does (idempotent — safe to re-run):
#   1. ensures ${DATA_DIR}/secrets exists (0700) + the log/state dirs exist,
#   2. seeds a TEMPLATE env file (0600) on first run if no bot env files exist,
#   3. for each cloud-bot-<name>.env it finds: validates it has the required
#      keys and is NOT still the placeholder API key, then supervises the bot,
#   4. records each bot's launch argv (.cmd) so start-stack.sh re-supervises it
#      on every bring-up and ops/restart.sh can restart it.
#
# SECRETS: the bot's Matrix access token (BOT_TOKEN) and the LLM API key
# (LLM_API_KEY) live ONLY in the 0600 env file. They are NEVER passed on argv —
# the supervised launcher `source`s the env file in-process and execs python.
# Secrets never go in .env either; only the ENABLE flag + non-secret defaults do.
#
# Generalized from a working deployment; review before running on a fresh phone.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env

# ── Self-gate: only run when enabled (default off) ───────────────────────────
if [ "${ENABLE_CLOUD_BOTS:-false}" != "true" ]; then
  ok "cloud bots disabled (ENABLE_CLOUD_BOTS != true) — skipping"
  exit 0
fi

require_var DATA_DIR "folder on your large volume / SD card"
require_cmd python3

# ── Paths ─────────────────────────────────────────────────────────────────────
SECRETS_DIR="${DATA_DIR}/secrets"
CHATBOT_DIR="${POCKET_ROOT}/scripts/chatbot"
BOT_SCRIPT="${CHATBOT_DIR}/cloud_chatbot.py"
TEMPLATE="${SECRETS_DIR}/cloud-bot-example.env.template"

mkdir -p "${SECRETS_DIR}" "${POCKET_LOG_DIR}" "${POCKET_STATE_DIR}"
chmod 700 "${SECRETS_DIR}" 2>/dev/null || true

# ── Preflight: the bot module must be present + parse-clean (fail-closed) ─────
# Catch a broken/forgotten module at install time, not at first respawn (where
# it would just crash-loop). stdlib-only native python; no userland needed.
[ -f "${BOT_SCRIPT}" ] || die "cloud bot module missing: ${BOT_SCRIPT} — the chatbot module was not shipped"
python3 -c "import ast,sys; ast.parse(open('${BOT_SCRIPT}').read())" \
  || die "cloud_chatbot.py failed to parse under python3"
ok "cloud bot module present + parse-clean (${BOT_SCRIPT})"

# ── 1. Seed a template env file if the operator has none yet ─────────────────
# We never put real secrets here — only the shape + placeholders. The operator
# copies it to cloud-bot-<name>.env, fills in BOT_TOKEN / BOT_MXID / LLM_API_KEY
# / ALLOWED_ROOMS, then re-runs this step (or start-stack.sh).
shopt -s nullglob
ENV_FILES=( "${SECRETS_DIR}"/cloud-bot-*.env )
shopt -u nullglob

if [ "${#ENV_FILES[@]}" -eq 0 ]; then
  if [ ! -e "${TEMPLATE}" ]; then
    cat > "${TEMPLATE}" <<'TEMPLATE_EOF'
# Cloud-LLM Matrix bot config — copy this to cloud-bot-<name>.env and fill it in.
#   cp cloud-bot-example.env.template cloud-bot-llama.env
#   chmod 600 cloud-bot-llama.env
# Run one file per bot; the <name> in the filename becomes the supervised
# service name (cloud-bot-llama, cloud-bot-qwen, …). Then re-run this step or
# scripts/start-stack.sh. SECRETS LIVE ONLY IN THIS FILE — never in .env.

# ── Matrix identity (register a bot account on your homeserver first) ────────
# The bot's access token + MXID. Create a dedicated Matrix user for the bot and
# log it in once to obtain an access token; do NOT reuse a human account.
BOT_TOKEN=REPLACE_ME_WITH_MATRIX_ACCESS_TOKEN
BOT_MXID=@yourbot:your-matrix-server-name
HS_URL=http://127.0.0.1:8448
BOT_NAME=yourbot

# ── LLM provider (any OpenAI-compatible chat-completions endpoint) ───────────
# Example below targets Groq's free tier; swap LLM_BASE_URL/LLM_MODEL for
# OpenRouter, a local server, etc. Get a Groq key at https://console.groq.com/keys
LLM_PROVIDER=groq
LLM_BASE_URL=https://api.groq.com/openai/v1
LLM_MODEL=llama-3.3-70b-versatile
LLM_API_KEY=gsk_REPLACE_ME

LLM_SYSTEM_PROMPT='You are a helpful chat bot. Be concise and friendly.'
LLM_MAX_TOKENS=600
LLM_TEMPERATURE=0.7
LLM_TIMEOUT_S=60
HISTORY_TURNS=4
# Set to true to append /no_think for Qwen/DeepSeek-R1 models (skips reasoning).
LLM_DISABLE_THINKING=false

# ── Rooms (FAIL-CLOSED: empty = no rooms; the bot rejects every invite) ──────
# Comma-separated Matrix room IDs the bot may operate in. Invite the bot to one
# of these from your client; it leaves any room not listed here.
ALLOWED_ROOMS=

# ── Self-imposed rate limits (stay under the provider free-tier ceiling) ─────
# Groq free tier ~30 RPM / 1000 RPD. If you run two bots on ONE key, keep the
# SUM under the ceiling (e.g. 10 RPM each).
RATE_LIMIT_RPM=10
RATE_LIMIT_RPD=800

# ── Multi-bot hygiene (only needed when >1 bot shares a room) ────────────────
# Comma-separated MXIDs of your OTHER bots so this bot ignores them as senders
# (prevents bot↔bot ping-pong burning both budgets). Empty = ignore none.
KNOWN_BOT_MXIDS=
TEMPLATE_EOF
    chmod 600 "${TEMPLATE}" 2>/dev/null || true
  fi
  echo
  warn "No cloud-bot env files found in ${SECRETS_DIR}."
  say  "A template was written to: ${TEMPLATE}"
  say  "To add a bot:"
  say  "  1. cp '${TEMPLATE}' '${SECRETS_DIR}/cloud-bot-<name>.env'"
  say  "  2. chmod 600 '${SECRETS_DIR}/cloud-bot-<name>.env'"
  say  "  3. fill in BOT_TOKEN, BOT_MXID, LLM_API_KEY, ALLOWED_ROOMS"
  say  "  4. re-run this step (or scripts/start-stack.sh) to start it"
  say  "See docs/CHATBOTS.md for the full walkthrough."
  ok   "cloud bots enabled but not yet configured — nothing to start."
  exit 0
fi

# ── 2. For each configured bot: validate + supervise ─────────────────────────
started=0
for envf in "${ENV_FILES[@]}"; do
  base="$(basename "${envf}" .env)"           # e.g. cloud-bot-llama
  name="${base}"                              # supervised service name
  # Defensive: filename must match the safe pattern (no shell/exFAT-hostile chars).
  case "${name}" in
    cloud-bot-*[!A-Za-z0-9_.-]*)
      warn "skipping '${envf}' — name '${name}' has unsafe characters"; continue ;;
  esac

  # Tighten perms in case the operator created it with a loose umask. We refuse
  # to start a bot whose secret file is group/world-readable would be ideal, but
  # we only WARN (some filesystems — exFAT SD cards — can't store unix perms).
  chmod 600 "${envf}" 2>/dev/null || true

  # Refuse to start with the placeholder LLM API key (avoids a crash-loop and a
  # confusing 401 from the provider). Grep only the key NAME line; never echo
  # the value.
  if grep -Eq '^LLM_API_KEY=(gsk_REPLACE_ME|REPLACE[_-]?ME)' "${envf}"; then
    warn "skipping '${name}' — LLM_API_KEY is still the placeholder in ${envf} (fill it in)"
    continue
  fi
  # Require the must-have keys to be present (we check key NAMES, not values).
  missing=""
  for k in BOT_TOKEN BOT_MXID LLM_BASE_URL LLM_MODEL LLM_API_KEY; do
    grep -Eq "^${k}=." "${envf}" || missing="${missing} ${k}"
  done
  if [ -n "${missing}" ]; then
    warn "skipping '${name}' — ${envf} is missing required key(s):${missing}"
    continue
  fi

  say "supervising cloud bot '${name}' (env: ${envf})"

  # ── SECRETS OFF-ARGV (security-critical) ───────────────────────────────────
  # The supervised command is a bash -c launcher that (a) `source`s the 0600 env
  # file IN-PROCESS (set -a → the sourced vars export into the child env), then
  # (b) execs python on the bot module. BOT_TOKEN + LLM_API_KEY therefore reach
  # the bot ONLY via the environment — never on argv / /proc/<pid>/cmdline. The
  # only argv elements are the launcher, the env-file PATH, and the module PATH
  # (none secret). `supervise` records that argv to ${POCKET_STATE_DIR}/${name}.cmd,
  # which start-stack.sh / ops/restart.sh replay verbatim.
  #
  # The launcher MUST stay a SINGLE LINE: supervise records argv one element per
  # line (printf '%s\n') and restart.sh reads it back with `mapfile -t`, so a
  # newline inside this -c string would split into bogus argv elements and break
  # re-supervision. ("$1" stays double-quoted so the path can't word-split/glob.)
  # shellcheck disable=SC1090
  supervise "${name}" -- bash -c 'set -a; . "$1"; set +a; exec python3 "$2"' _bot "${envf}" "${BOT_SCRIPT}"
  started=$((started + 1))
done

if [ "${started}" -eq 0 ]; then
  warn "found ${#ENV_FILES[@]} cloud-bot env file(s) but started none — see the warnings above"
  exit 0
fi

# ── 3. Confirm the bots came up ──────────────────────────────────────────────
# There is no port to probe (they are Matrix /sync clients), so we look for the
# live python child by the bot module's path.
say "confirming the cloud bot(s) came up"
up=0
for _ in $(seq 1 10); do
  if pgrep -f 'cloud_chatbot\.py' >/dev/null 2>&1; then
    up=1; break
  fi
  sleep 1
done
[ "${up}" -eq 1 ] && ok "cloud bot(s) running (python child up)" \
  || warn "no cloud bot appeared yet — check ${POCKET_LOG_DIR}/cloud-bot-*.log"

# ── Closing notes ─────────────────────────────────────────────────────────────
echo
ok "Cloud bot(s) installed + supervised (${started} bot(s) started)"
say "Invite each bot's @mxid to one of its ALLOWED_ROOMS, then @-mention it."
say "Each bot reads its secrets from its 0600 env file under ${SECRETS_DIR};"
say "logs are at ${POCKET_LOG_DIR}/cloud-bot-<name>.log. See docs/CHATBOTS.md."

# Generalized from a working deployment; review before running.
