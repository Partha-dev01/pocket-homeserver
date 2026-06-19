# Chat bots — cloud-LLM Matrix bots (optional, off by default)

pocket-homeserver can run **optional** Matrix chat bots that answer when you
`@`-mention them, powered by any **OpenAI-compatible** chat-completions endpoint.
This page covers the **cloud bots** — a small, faithful template you point at a
hosted provider (Groq's free tier, OpenRouter, …) or any local LLM server that
speaks the OpenAI API.

> Prefer to run the **model on the phone itself** (no cloud, no API key)? See
> [On-phone LLM (advanced / BYO)](#on-phone-llm-exobot--advanced--byo) at the end
> of this page. The cloud bots below are the simpler option.

They are **off by default**. Enable them with `ENABLE_CLOUD_BOTS=true` in `.env`,
then configure one bot per `0600` env file (below).

## What they are — and what they are not

- **No inbound listener, no new attack surface.** Each bot is a Matrix `/sync`
  client. It reaches your homeserver on **loopback** and makes exactly **one
  outbound HTTPS call per reply** to the LLM endpoint. It opens no socket and
  makes no Caddy change.
- **Native, not in the userland.** Like the admin panel, the bots run
  Termux-native — they only need loopback to the homeserver and one outbound
  call, not the proot userland. stdlib-only Python.
- **Fail-closed on rooms.** A bot only operates in rooms you list in
  `ALLOWED_ROOMS`. With that empty/unset it talks **nowhere** and auto-rejects
  every invite — a leaked or half-configured env file can't turn it into a bot
  that answers anywhere it's invited.
- **Free-tier-safe by design.** Each bot self-imposes a per-minute and per-day
  request ceiling (`RATE_LIMIT_RPM` / `RATE_LIMIT_RPD`), caps concurrent calls,
  and never echoes a provider error body back into the room.

## Run more than one bot

You can run several bots at once from the same template — for example one on
Groq's Llama model and one on Groq's Qwen model **sharing a single API key**.
Drop one env file per bot:

```
${DATA_DIR}/secrets/cloud-bot-llama.env
${DATA_DIR}/secrets/cloud-bot-qwen.env
```

The `<name>` part of the filename becomes the supervised service name
(`cloud-bot-llama`, `cloud-bot-qwen`, …). The bots differ **only** in their env
file (token, mxid, model, endpoint, prompt, rate limits).

> If two bots sit in the **same** room, set each bot's `KNOWN_BOT_MXIDS` to the
> *other* bot's MXID so they ignore each other — otherwise each reply triggers
> the other bot and both burn through their rate-limit budgets.
>
> When two bots share one API key, keep the **sum** of their `RATE_LIMIT_RPM`
> under the provider ceiling (e.g. 10 RPM each under a 30 RPM free tier).

## Enabling them

1. Register a dedicated **Matrix account for each bot** on your homeserver
   (don't reuse a human account), and obtain its access token. Then set in
   `.env`:

   ```sh
   ENABLE_CLOUD_BOTS=true
   ```

2. (Re-)run the installer. The cloud-bots step self-gates on the flag and, on
   the first enabled run, writes a **template** env file you copy per bot:

   ```sh
   ./pocket.sh        # menu → Install   (or: bash scripts/install.sh --force)
   ```

   On that first run (no bot env files yet) it prints the template path and
   exits cleanly — nothing is started until you configure a bot.

3. Create one env file per bot from the template, `chmod 600` it, and fill it in:

   ```sh
   cd "${DATA_DIR}/secrets"
   cp cloud-bot-example.env.template cloud-bot-llama.env
   chmod 600 cloud-bot-llama.env
   $EDITOR cloud-bot-llama.env        # BOT_TOKEN, BOT_MXID, LLM_API_KEY, ALLOWED_ROOMS
   ```

4. Re-run the step (or `scripts/start-stack.sh`) to supervise each configured
   bot. Then invite the bot's `@mxid` to one of its `ALLOWED_ROOMS` from your
   client and `@`-mention it.

## Configuration (per-bot env file)

Each `cloud-bot-<name>.env` is sourced **in-process** by the supervised launcher
— the secrets enter only the bot's environment, never its command line. Keys:

| Key | Required | Meaning |
| --- | --- | --- |
| `BOT_TOKEN` | yes | Matrix bot access token (**secret**) |
| `BOT_MXID` | yes | bot's `@localpart:server_name` |
| `HS_URL` | — | homeserver C-S API base (default `http://127.0.0.1:8448`) |
| `BOT_NAME` | — | display / mention name (e.g. `llamabot`) |
| `LLM_PROVIDER` | — | short id shown in the reply footer (`groq`, …) |
| `LLM_BASE_URL` | yes | OpenAI-compatible `/v1` base URL |
| `LLM_MODEL` | yes | model name sent in the request |
| `LLM_API_KEY` | yes | provider API key, sent as a Bearer token (**secret**) |
| `LLM_SYSTEM_PROMPT` | — | system prompt prepended to every conversation |
| `LLM_MAX_TOKENS` | — | per-reply token cap (default 600) |
| `LLM_TEMPERATURE` | — | sampling temperature (default 0.7) |
| `LLM_TIMEOUT_S` | — | HTTP timeout for the LLM call (default 60) |
| `HISTORY_TURNS` | — | past user/assistant pairs kept as context (default 4) |
| `LLM_DISABLE_THINKING` | — | `true` appends `/no_think` for Qwen / DeepSeek-R1 |
| `ALLOWED_ROOMS` | yes* | comma-separated room IDs the bot may operate in |
| `RATE_LIMIT_RPM` | — | self-imposed requests/min ceiling (default 10) |
| `RATE_LIMIT_RPD` | — | self-imposed requests/day ceiling (default 800) |
| `KNOWN_BOT_MXIDS` | — | other bot MXIDs to ignore as senders |
| `EXTRA_HEADERS_JSON` | — | JSON dict of extra request headers (OpenRouter likes `HTTP-Referer` + `X-Title`) |

\* `ALLOWED_ROOMS` is technically optional, but with it empty the bot talks in no
room (fail-closed), so you almost always set it.

## Reasoning models (Qwen3, DeepSeek-R1, …)

Hybrid-thinking models emit `<think>…</think>` blocks. The bot extracts the
reasoning and hides it behind a **Matrix spoiler**, so the visible reply is just
the answer and the chain of thought is one tap away. Bump `LLM_MAX_TOKENS` (e.g.
1500) so both the reasoning and the answer fit, or set
`LLM_DISABLE_THINKING=true` to skip reasoning entirely (faster, no spoiler).

## Secrets and safety

- `BOT_TOKEN` and `LLM_API_KEY` live **only** in the `0600` env file under
  `${DATA_DIR}/secrets/` — never in `.env`, never on the command line. The
  install step refuses to start a bot whose `LLM_API_KEY` is still the
  placeholder and whose required keys are missing.
- The bot **never logs the prompt text** — only a sha256 prefix, room id, and
  length, so the on-disk log doesn't leak conversation content.
- Provider error bodies (which may contain auth diagnostics) are logged for the
  operator but **never** posted back into the room; the user sees a generic,
  actionable message.

## Restart / status

- The admin panel shows the cloud bots' collective health (a single `cloud-bots`
  row — bot names are dynamic, so there is no per-bot button).
- From the shell: `bash scripts/ops/restart.sh cloud-bot-<name>` re-supervises a
  single bot from its recorded launch command; `scripts/start-stack.sh` brings
  up every configured bot on a fresh boot.
- Logs: `${POCKET_LOG_DIR}/cloud-bot-<name>.log`.

---

## On-phone LLM (exobot) — advanced / BYO

`exobot` runs an LLM **on the device itself** — no cloud, no API key, no data
leaving the phone. It is **advanced and bring-your-own**: pocket-homeserver ships
**no model and no binary**. You supply both, because the right build depends on
your phone's exact CPU. It is **off by default** (`ENABLE_EXOBOT`).

The bot subprocess-manages a [llama.cpp](https://github.com/ggml-org/llama.cpp)
`llama-server`, lazy-loading the model on the first mention and idle-unloading it
to save RAM (or keeping it warm). It talks to the homeserver on loopback and binds
nothing inbound.

### What you must supply (BYO)

1. **`llama-server`** — build llama.cpp for **your phone's CPU**. Build it inside
   the proot userland (the default) so the aarch64-glibc binary runs there, and
   use the correct `-march`/flags for your SoC — a binary built for ISA extensions
   your CPU lacks will `SIGILL` on first use. Point `LLAMA_SERVER_BIN` at it.
2. **A GGUF model** — small + quantized works best on a phone (e.g. a 0.5–3B model
   at Q4). Point `MODEL_PATH` at it.

With the default `EXOBOT_PROOT_DISTRO=debian`, both paths are interpreted **inside
the userland**. Set `EXOBOT_PROOT_DISTRO=` (empty) if you built a Termux-native
binary and want host paths. The installer **fail-louds** if either is unset/missing.

### Register the bot account + mint its token (OFF-ARGV)

`exobot` needs its own Matrix account's access token in
`${DATA_DIR}/secrets/exobot.env` as `EXOBOT_TOKEN=`. Register a dedicated account
(don't reuse a human one) — e.g. with an invite token from
`scripts/bootstrap/mint-invite-token.sh` — then mint the token **without putting
the password on a command line**:

```sh
read -rsp 'exobot password: ' PW; echo
TOKEN=$(PW="$PW" jq -n --arg u exobot \
          '{type:"m.login.password",identifier:{type:"m.id.user",user:$u},password:$ENV.PW}' \
        | curl -sS -X POST http://127.0.0.1:8448/_matrix/client/v3/login \
            -H 'Content-Type: application/json' --data-binary @- \
        | jq -r '.access_token'); unset PW
umask 077
printf 'EXOBOT_TOKEN=%s\n' "$TOKEN" > "${DATA_DIR}/secrets/exobot.env"
chmod 600 "${DATA_DIR}/secrets/exobot.env"; unset TOKEN
```

The password reaches `jq` via its environment (`$ENV.PW`) and the request body via
`curl` stdin — neither it nor the token ever appears on a command line. The
installer refuses to start the bot while `EXOBOT_TOKEN` is still the placeholder.

### Enabling it

```sh
# in .env
ENABLE_EXOBOT=true
EXOBOT_LOCALPART=exobot
LLAMA_SERVER_BIN=/root/llama.cpp/build/bin/llama-server   # inside the userland
MODEL_PATH=/root/models/your-model.gguf                   # inside the userland
EXOBOT_ALLOWED_ROOMS=!yourroom:your-server                # fail-closed if empty
```

Then add the token (above) and run the installer (`./pocket.sh` → Install, or
`bash scripts/install.sh --force`). Invite `@exobot:<server>` to a room listed in
`EXOBOT_ALLOWED_ROOMS` and tag it: `@exobot help`.

Like the cloud bots, `EXOBOT_ALLOWED_ROOMS` is **fail-closed** — empty means the
bot operates nowhere and rejects every invite. The optional engagement daemons
(`INTERJECT_ENABLED`, `SEED_ENABLED`, `REVIVE_ENABLED`, `CROSSBOT_ENABLED`) are all
**off by default**.

### Optional web UI (`EXOBOT_UI`)

A [Gradio](https://www.gradio.app/) chat UI in front of the same model, served at
`ai.${DOMAIN}` (override with `EXOBOT_UI_HOST_PUBLIC`). It is **off by default and
double-opt-in** (`EXOBOT_UI=true`). The install step installs `gradio` inside the
userland (`pip --break-system-packages`), writes a `/etc/caddy/apps/exobot-ui.caddy`
vhost, and runs a tiny **lazy-start waker** that brings the (heavier) UI up on
demand and idle-stops it. The UI has **no login of its own** — you **must** protect
`ai.${DOMAIN}` with a Cloudflare Access policy at the edge (the default) or the
optional Matrix-SSO gateway (see [APP_AUTH.md](APP_AUTH.md)). The installer prints
the manual Cloudflare Tunnel hostname + Access steps.

### Secrets and safety

- `EXOBOT_TOKEN` lives **only** in `${DATA_DIR}/secrets/exobot.env` (`0600`),
  sourced in-process by the launcher — never in `.env`, never on argv.
- The model and all inference run **on the device**; nothing is sent to a third
  party (unlike the cloud bots).
- `EXOBOT_ALLOWED_ROOMS` is fail-closed; the bot never logs the access token.

Generalized from a working deployment; review before running.
