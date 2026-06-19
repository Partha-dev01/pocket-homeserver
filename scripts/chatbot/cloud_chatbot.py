#!/usr/bin/env python3
"""Cloud-LLM Matrix chat bot for pocket-homeserver (stdlib only).

One small process that signs in to your Matrix homeserver as a bot account,
watches the rooms you allow, and answers when someone @-mentions it by calling
any OpenAI-compatible chat-completions endpoint (Groq's free tier, OpenRouter,
a local LLM server, …). It is OPTIONAL and OFF by default; enable it with
ENABLE_CLOUD_BOTS in .env and configure one bot per 0600 env file under
${DATA_DIR}/secrets/ (see scripts/steps/80-install-cloud-bots.sh and
docs/CHATBOTS.md).

You can run several bots from the same template at once — e.g. one on Groq's
Llama model and one on Groq's Qwen model sharing a single API key — by dropping
one env file per bot. Each bot is a separate supervised process; they differ
ONLY in their env file (token, mxid, model, endpoint, prompt, rate limits).

The bot reaches the homeserver over loopback, makes ONE outbound HTTPS call per
reply to the configured LLM endpoint, and has NO inbound listener — so it adds
no new attack surface to your edge.

Configuration via env (loaded by the launcher from the bot's 0600 env file —
NEVER passed on the command line; see the install step):
  BOT_TOKEN          — Matrix bot access token (SECRET)
  BOT_MXID           — Matrix bot @localpart:server_name
  HS_URL             — homeserver client-server API base, default http://127.0.0.1:8448
  BOT_NAME           — display/mention name (e.g. "llamabot", "qwenbot")
  LLM_PROVIDER       — short id ("groq", "openrouter", …) shown in the footer
  LLM_BASE_URL       — OpenAI-compatible /v1 base URL
  LLM_MODEL          — model name sent in the request `model` field
  LLM_API_KEY        — provider API key, sent as a Bearer token (SECRET)
  LLM_SYSTEM_PROMPT  — system prompt prepended to every conversation
  LLM_MAX_TOKENS     — per-reply token cap (default 600)
  LLM_TEMPERATURE    — sampling temperature (default 0.7)
  LLM_TIMEOUT_S      — HTTP timeout for the LLM call (default 60)
  HISTORY_TURNS      — past user/assistant pairs kept as context (default 4)
  ALLOWED_ROOMS      — comma-separated room IDs the bot may operate in.
                       Empty/unset = NO rooms (fail-closed: rejects every invite).
  RATE_LIMIT_RPM     — self-imposed requests-per-minute ceiling (default 10)
  RATE_LIMIT_RPD     — self-imposed requests-per-day ceiling (default 800)
  KNOWN_BOT_MXIDS    — comma-separated other bot mxids to ignore as senders
                       (prevents two bots ping-ponging and burning their budgets)
  EXTRA_HEADERS_JSON — optional JSON dict of extra request headers
                       (OpenRouter likes HTTP-Referer + X-Title)
  LLM_DISABLE_THINKING — "true" appends /no_think for Qwen/DeepSeek-R1 models
  LLM_CONCURRENT_MAX — max concurrent LLM calls per bot (default 1)
  SYNC_WATCHDOG_S    — hard-exit-for-respawn if /sync stalls this long (default 300)

Generalized from a working deployment; review before running.
"""
import json
import os
import re
import socket
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import deque

# ------------------------------------------------------------------ config
# SECRETS HANDLING: BOT_TOKEN + LLM_API_KEY arrive ONLY via the environment —
# the supervised launcher in scripts/steps/80-install-cloud-bots.sh `source`s the
# bot's 0600 env file in-process (set -a) before exec'ing python, so the secrets
# never touch argv / /proc/<pid>/cmdline and are never hard-coded here. This
# module must never log or echo their values (it logs only sha-prefixed prompt
# ids + token counts).

BOT_TOKEN     = os.environ["BOT_TOKEN"]
BOT_MXID      = os.environ["BOT_MXID"]
HS_URL        = os.environ.get("HS_URL", "http://127.0.0.1:8448").rstrip("/")
BOT_NAME      = os.environ.get("BOT_NAME", "cloudbot")
LLM_PROVIDER  = os.environ.get("LLM_PROVIDER", "cloud")
LLM_BASE_URL  = os.environ["LLM_BASE_URL"].rstrip("/")
LLM_MODEL     = os.environ["LLM_MODEL"]
LLM_API_KEY   = os.environ["LLM_API_KEY"]
LLM_SYSTEM_PROMPT = os.environ.get(
    "LLM_SYSTEM_PROMPT",
    f"You are {BOT_NAME}, a helpful chat bot. Be concise.")
LLM_MAX_TOKENS  = int(os.environ.get("LLM_MAX_TOKENS", "600"))
LLM_TEMPERATURE = float(os.environ.get("LLM_TEMPERATURE", "0.7"))
LLM_TIMEOUT_S   = int(os.environ.get("LLM_TIMEOUT_S", "60"))
HISTORY_TURNS   = int(os.environ.get("HISTORY_TURNS", "4"))
EXTRA_HEADERS   = json.loads(os.environ.get("EXTRA_HEADERS_JSON", "{}"))

# Rooms the bot is allowed to operate in. Comma-separated Matrix room IDs.
# Empty / unset = NO rooms allowed (fail-closed). The bot auto-rejects every
# invite and ignores every message until at least one room ID is set. An empty
# default that meant "unrestricted" would silently turn a leaked/misconfigured
# env file into a bot that talks anywhere it is invited.
ALLOWED_ROOMS = {r.strip() for r in
                 os.environ.get("ALLOWED_ROOMS", "").split(",")
                 if r.strip()}

# Other bot mxids this bot should ignore as senders. Without this, two cloud
# bots in the same room reply to each other's replies → an infinite ping-pong
# that burns both bots' rate-limit budgets. Comma-separated full MXIDs; empty
# by default (set it when you run more than one bot in the same room).
KNOWN_BOT_MXIDS = {
    s.strip() for s in os.environ.get("KNOWN_BOT_MXIDS", "").split(",")
    if s.strip()
}

# Cap concurrent LLM calls per bot. Without this, a flood of tagged messages can
# fork N parallel HTTP calls, each holding an LLM_TIMEOUT_S connection — an easy
# way to chew through a provider's RPM budget and stack futures in memory. One
# in flight at a time is fine for a chat bot's pace; if a request arrives while
# one is running, this semaphore queues briefly (the rate-limiter below may also
# bounce it outright).
_LLM_INFLIGHT = threading.Semaphore(int(os.environ.get("LLM_CONCURRENT_MAX", "1")))

# Self-imposed rate limits to stay under provider free-tier ceilings. Defaults
# leave margin under Groq's free tier (30 RPM / 1000 RPD): at LLM_MAX_TOKENS=600
# and 10 RPM, peak token throughput is 6000/min, which matches the per-minute
# token cap, so 10 RPM is the safe ceiling.
RATE_LIMIT_RPM = int(os.environ.get("RATE_LIMIT_RPM", "10"))
RATE_LIMIT_RPD = int(os.environ.get("RATE_LIMIT_RPD", "800"))

MAX_PROMPT_CHAR = 4000  # cloud LLMs handle longer prompts than a tiny local one

# Module-level socket timeout so urllib's underlying socket.read() can't hang
# forever on a half-open TCP connection. A per-request timeout only covers
# connect+headers, not the long-poll body read of /sync, so a dead connection
# after a server outage could wedge the sync forever. setdefaulttimeout applies
# to every socket op including read(), so a dead connection fires
# socket.timeout and the sync_loop except-block retries cleanly.
# 40s = 25s server-side long-poll + 15s slack.
socket.setdefaulttimeout(40)

# Watchdog state — sync_loop updates this on every successful return. A separate
# thread (sync_watchdog) hard-exits the process if there is no progress for
# SYNC_WATCHDOG_S so the supervisor respawns it; covers the residual class of
# wedges the socket timeout doesn't catch.
SYNC_WATCHDOG_S = int(os.environ.get("SYNC_WATCHDOG_S", "300"))
_LAST_SYNC_RETURN = time.time()


def log(msg):
    print(f"[{time.strftime('%H:%M:%SZ', time.gmtime())}] [{BOT_NAME}] {msg}",
          flush=True)

# ------------------------------------------------------------------ Matrix client

def _matrix(method, path, data=None, timeout=35):
    body = json.dumps(data).encode() if data is not None else None
    req = urllib.request.Request(
        HS_URL + path, data=body, method=method,
        headers={"Authorization": f"Bearer {BOT_TOKEN}",
                 "Content-Type":  "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read() or b"{}")

# Markdown → HTML — a minimal renderer (bold/italic/code/links/headers/lists/
# blockquote/code-fences). Inlined so the bot needs no third-party deps.
_BOLD_RE   = re.compile(r"\*\*([^\*]+?)\*\*")
_ITALIC_RE = re.compile(r"(?<![\w_])_([^_\n]+?)_(?![\w_])")
_CODE_RE   = re.compile(r"`([^`]+?)`")
_LINK_RE   = re.compile(r"\[([^\]]+)\]\((https?://[^)\s]+|mxc://[^)\s]+|matrix:[^)\s]+)\)")
_HEADER_RE = re.compile(r"^(#{1,6})\s+(.+)$")
_HR_RE     = re.compile(r"^---+\s*$")
_UL_RE     = re.compile(r"^[-*]\s+(.+)$")
_OL_RE     = re.compile(r"^\d+\.\s+(.+)$")
_QUOTE_RE  = re.compile(r"^&gt;\s+(.+)$")
_CODEBLOCK_RE = re.compile(r"^```(\w*)\n([\s\S]*?)\n```$", re.MULTILINE)

def _md_inline(text):
    out = _CODE_RE.sub(r"<code>\1</code>", text)
    out = _BOLD_RE.sub(r"<strong>\1</strong>", out)
    out = _ITALIC_RE.sub(r"<em>\1</em>", out)
    # HTML-escape href content so a URL with `"` can't break out of the
    # attribute and inject extras (e.g. onclick=). Element strips disallowed
    # attrs downstream — defense-in-depth at the rendering layer.
    def _link_repl(m):
        href = m.group(2).replace("&", "&amp;").replace('"', "&quot;").replace("<", "&lt;").replace(">", "&gt;")
        return f'<a href="{href}">{m.group(1)}</a>'
    out = _LINK_RE.sub(_link_repl, out)
    return out

def md_to_html(text):
    blocks = {}
    def _cb(m):
        lang = m.group(1) or ""
        body = m.group(2).replace("&","&amp;").replace("<","&lt;").replace(">","&gt;")
        key = f"\x00CB{len(blocks)}\x00"
        cls = f' class="language-{lang}"' if lang else ""
        blocks[key] = f"<pre><code{cls}>{body}</code></pre>"
        return key
    text2 = _CODEBLOCK_RE.sub(_cb, text)
    escaped = text2.replace("&","&amp;").replace("<","&lt;").replace(">","&gt;")
    lines = escaped.split("\n"); out = []; i = 0
    while i < len(lines):
        line = lines[i]
        if not line.strip(): i += 1; continue
        if _HR_RE.match(line): out.append("<hr>"); i += 1; continue
        m = _HEADER_RE.match(line)
        if m:
            lvl = len(m.group(1))
            out.append(f"<h{lvl}>{_md_inline(m.group(2))}</h{lvl}>"); i += 1; continue
        if line.strip().startswith("\x00CB"):
            out.append(blocks.get(line.strip(), "")); i += 1; continue
        if _UL_RE.match(line):
            items = []
            while i < len(lines) and _UL_RE.match(lines[i]):
                items.append("<li>" + _md_inline(_UL_RE.match(lines[i]).group(1)) + "</li>")
                i += 1
            out.append("<ul>" + "".join(items) + "</ul>"); continue
        if _OL_RE.match(line):
            items = []
            while i < len(lines) and _OL_RE.match(lines[i]):
                items.append("<li>" + _md_inline(_OL_RE.match(lines[i]).group(1)) + "</li>")
                i += 1
            out.append("<ol>" + "".join(items) + "</ol>"); continue
        if _QUOTE_RE.match(line):
            quoted = []
            while i < len(lines) and _QUOTE_RE.match(lines[i]):
                quoted.append(_md_inline(_QUOTE_RE.match(lines[i]).group(1)))
                i += 1
            out.append("<blockquote>" + "<br>".join(quoted) + "</blockquote>"); continue
        para = [_md_inline(line)]; i += 1
        while i < len(lines):
            nxt = lines[i]
            if (not nxt.strip() or _HR_RE.match(nxt) or _HEADER_RE.match(nxt)
                    or _UL_RE.match(nxt) or _OL_RE.match(nxt) or _QUOTE_RE.match(nxt)
                    or nxt.strip().startswith("\x00CB")):
                break
            para.append(_md_inline(nxt)); i += 1
        out.append("<p>" + "<br>".join(para) + "</p>")
    html = "".join(out)
    for key, val in blocks.items():
        html = html.replace(key, val)
    return html

def post(room_id, text, html=None):
    txn = str(time.time_ns())
    if html is None:
        html = md_to_html(text)
    plain = _BOLD_RE.sub(r"\1", text)
    plain = _ITALIC_RE.sub(r"\1", plain)
    content = {
        "msgtype":        "m.text",
        "body":           plain,
        "format":         "org.matrix.custom.html",
        "formatted_body": html,
    }
    path = f"/_matrix/client/v3/rooms/{urllib.parse.quote(room_id)}/send/m.room.message/{txn}"
    try:
        _matrix("PUT", path, content)
    except Exception as e:
        log(f"post failed in {room_id}: {e}")

def join_room(room_id):
    path = f"/_matrix/client/v3/rooms/{urllib.parse.quote(room_id)}/join"
    try:
        _matrix("POST", path, {}); return True
    except Exception as e:
        log(f"join failed for {room_id}: {e}"); return False

def leave_room(room_id):
    path = f"/_matrix/client/v3/rooms/{urllib.parse.quote(room_id)}/leave"
    try:
        _matrix("POST", path, {}); return True
    except Exception as e:
        log(f"leave failed for {room_id}: {e}"); return False

def is_room_allowed(room_id):
    """True ONLY if room is explicitly in ALLOWED_ROOMS. Empty set means no
    rooms — fail-closed."""
    return room_id in ALLOWED_ROOMS

def reject_invite(room_id):
    """For invites to rooms outside ALLOWED_ROOMS — leave so the bot is visibly
    absent from rooms it is not supposed to be in."""
    path = f"/_matrix/client/v3/rooms/{urllib.parse.quote(room_id)}/leave"
    try:
        _matrix("POST", path, {}); return True
    except Exception as e:
        log(f"reject_invite failed for {room_id}: {e}"); return False

def set_typing(room_id, active, timeout_ms=25000):
    path = (f"/_matrix/client/v3/rooms/{urllib.parse.quote(room_id)}/"
            f"typing/{urllib.parse.quote(BOT_MXID)}")
    body = {"typing": True, "timeout": timeout_ms} if active else {"typing": False}
    try:
        _matrix("PUT", path, body, timeout=5)
    except Exception as e:
        log(f"set_typing({active}) failed: {e}")

class TypingKeepalive:
    def __init__(self, room_id):
        self.room_id = room_id
        self._stop = threading.Event()
    def __enter__(self):
        set_typing(self.room_id, True, 25000)
        def _loop():
            while not self._stop.wait(15):
                set_typing(self.room_id, True, 25000)
        threading.Thread(target=_loop, daemon=True).start()
        return self
    def __exit__(self, *a):
        self._stop.set()
        set_typing(self.room_id, False)

# ------------------------------------------------------------------ mention parsing

# Parameterised on BOT_NAME so it also handles a pill display-name suffix like
# "llamabot (Llama 4 Scout): hi".
_NAME_RE_BARE = re.escape(BOT_NAME.lower())
_MENTION_PREFIX_RE = re.compile(
    r"^[\s>]*(?:@?" + _NAME_RE_BARE +
    r"(?::[A-Za-z0-9.\-]+)?(?:\s*\([^)]*\))?(?:\s*:)?)\s+",
    re.IGNORECASE)

def extract_prompt(body):
    """Match @<botname> or pill-rendered '<botname>: …' / '<botname> (...): …'."""
    if not body or BOT_NAME.lower() not in body.lower():
        return False, ""
    m = _MENTION_PREFIX_RE.match(body)
    if m:
        cleaned = body[m.end():]
    else:
        # mid-body mention — strip occurrences and use the rest
        cleaned = re.sub(
            r"@?" + _NAME_RE_BARE + r"(?::[A-Za-z0-9.\-]+)?(?:\s*\([^)]*\))?:?",
            " ", body, flags=re.IGNORECASE)
        cleaned = cleaned.replace(BOT_MXID, " ")
    cleaned = cleaned.strip()
    if len(cleaned) > MAX_PROMPT_CHAR:
        cleaned = cleaned[:MAX_PROMPT_CHAR] + "…"
    return True, cleaned

# ------------------------------------------------------------------ rate limit

class RateLimiter:
    """Sliding-window rate limiter with both per-minute and per-day caps.
    Thread-safe; check_or_block() returns (allowed, retry_after_seconds, scope)."""
    def __init__(self, rpm, rpd):
        self.rpm = rpm
        self.rpd = rpd
        self._minute = deque()  # ts of requests in last 60 s
        self._day    = deque()  # ts of requests in last 86400 s
        self._lock = threading.Lock()

    def check_or_block(self):
        now = time.time()
        with self._lock:
            # Prune
            while self._minute and now - self._minute[0] > 60:
                self._minute.popleft()
            while self._day and now - self._day[0] > 86400:
                self._day.popleft()
            # Per-minute cap
            if len(self._minute) >= self.rpm:
                wait = 60 - (now - self._minute[0])
                return False, max(1.0, wait), "minute"
            # Per-day cap
            if len(self._day) >= self.rpd:
                wait = 86400 - (now - self._day[0])
                return False, max(60.0, wait), "day"
            # Allowed — record
            self._minute.append(now)
            self._day.append(now)
            return True, 0, None

rate_limiter = RateLimiter(RATE_LIMIT_RPM, RATE_LIMIT_RPD)

# ------------------------------------------------------------------ LLM call

def llm_chat(messages):
    """Call the configured OpenAI-compatible /chat/completions endpoint.
    Returns (reply_text, latency_s, usage_dict).

    Hybrid-thinking models (Qwen3, DeepSeek-R1) emit <think>…</think> blocks; we
    let them — render_reply hides the reasoning in a Matrix spoiler so users see
    the answer first but can tap to reveal the chain of thought. Set
    LLM_DISABLE_THINKING=true in the env file to append /no_think and skip
    reasoning entirely (faster but no spoiler)."""
    msgs_out = list(messages)
    if (os.environ.get("LLM_DISABLE_THINKING", "").lower() in ("1","true","yes")
            and ("qwen" in LLM_MODEL.lower() or "deepseek-r1" in LLM_MODEL.lower())):
        for i in range(len(msgs_out) - 1, -1, -1):
            if msgs_out[i].get("role") == "user":
                msgs_out[i] = {**msgs_out[i],
                               "content": msgs_out[i]["content"] + " /no_think"}
                break
    body = {
        "model":       LLM_MODEL,
        "messages":    msgs_out,
        "temperature": LLM_TEMPERATURE,
        "max_tokens":  LLM_MAX_TOKENS,
    }
    data = json.dumps(body).encode()
    headers = {
        "Authorization": f"Bearer {LLM_API_KEY}",
        "Content-Type":  "application/json",
        # Some providers (e.g. Groq) sit behind a WAF that blocks Python's
        # default `Python-urllib/3.x` User-Agent. Send a generic, identifiable
        # one so the request gets through.
        "User-Agent":    f"matrix-{BOT_NAME}/1.0",
    }
    headers.update(EXTRA_HEADERS)
    req = urllib.request.Request(
        f"{LLM_BASE_URL}/chat/completions",
        data=data, method="POST", headers=headers)
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=LLM_TIMEOUT_S) as r:
        resp = json.loads(r.read())
    latency = time.time() - t0
    try:
        text = resp["choices"][0]["message"]["content"]
    except (KeyError, IndexError):
        text = f"(unexpected LLM response: {resp})"
    usage = resp.get("usage") or {}
    return text, latency, usage

# ------------------------------------------------------------------ rendering

_THINK_RE = re.compile(r"<think>([\s\S]*?)</think>", re.DOTALL)

def render_reply(reply, latency, usage):
    # Hybrid-thinking models (Qwen3, GPT-OSS, DeepSeek-R1) emit <think>…</think>
    # blocks even when asked not to (the provider may ignore the kwarg). Extract
    # and hide them in a Matrix spoiler so the visible reply is just the answer;
    # the reasoning is one tap away for the curious.
    think = ""
    answer = reply
    m = _THINK_RE.search(reply)
    if m:
        think = m.group(1).strip()
        answer = _THINK_RE.sub("", reply).strip()
    # Defensive: handle an unclosed <think> (model truncated before emitting
    # </think>). Treat everything from <think> onward as reasoning, and what
    # comes before as the answer (usually empty if <think> is at the start).
    if "<think>" in answer:
        head, _, tail = answer.partition("<think>")
        if tail.strip():
            think = (think + "\n\n" + tail).strip() if think else tail.strip()
        answer = head.strip() or "(reasoning truncated — try a shorter prompt)"

    footer = ""
    if usage:
        prompt_t = usage.get("prompt_tokens", "?")
        compl_t  = usage.get("completion_tokens", "?")
        total_t  = usage.get("total_tokens", "?")
        rate     = (compl_t / latency) if isinstance(compl_t, (int, float)) and latency > 0 else 0
        footer = (f"`{LLM_PROVIDER}/{LLM_MODEL}` · "
                  f"⚡ {compl_t} tok @ {rate:.1f} tok/s ({latency:.1f} s) · "
                  f"prompt {prompt_t} tok · total {total_t}")
    else:
        footer = f"`{LLM_PROVIDER}/{LLM_MODEL}` · ⚡ ({latency:.1f} s)"

    # Plain fallback
    plain_parts = []
    if think:
        for ln in think.splitlines():
            plain_parts.append(f"> {ln}" if ln.strip() else ">")
        plain_parts.append("")
    plain_parts.append(answer or "(empty)")
    if footer:
        plain_parts.append("")
        plain_parts.append(_BOLD_RE.sub(r"\1", footer))
    plain = "\n".join(plain_parts).strip()

    # HTML — Matrix spoiler for the reasoning, then the answer + footer.
    html_parts = []
    if think:
        spoiler = (think.replace("&", "&amp;").replace("<", "&lt;")
                        .replace(">", "&gt;").replace("\n", "<br>"))
        html_parts.append(
            f'<blockquote><span data-mx-spoiler="thinking">{spoiler}</span></blockquote>')
    html_parts.append(md_to_html(answer) if answer else "<p><em>(empty reply)</em></p>")
    if footer:
        html_parts.append("<p><small>"
                          + _md_inline(footer.replace("<","&lt;").replace(">","&gt;"))
                          + "</small></p>")
    html = "".join(html_parts)
    return plain, html

# ------------------------------------------------------------------ room state

class RoomState:
    def __init__(self):
        self.history = deque(maxlen=HISTORY_TURNS * 2)

rooms = {}

# ------------------------------------------------------------------ handler

_room_scope = (
    f"only in {len(ALLOWED_ROOMS)} room"
    if ALLOWED_ROOMS else "no rooms (set ALLOWED_ROOMS)")
HELP_TEXT = (
    f"**{BOT_NAME}** ({LLM_PROVIDER} · `{LLM_MODEL}`) — tag me with anything:\n"
    f"- `@{BOT_NAME} hi` — say hello\n"
    f"- `@{BOT_NAME} <question>` — ask me anything (cloud LLM)\n"
    f"- `@{BOT_NAME} help` — this message\n"
    f"\n"
    f"Limits: **{RATE_LIMIT_RPM} req/min · {RATE_LIMIT_RPD} req/day** (free-tier safe). "
    f"I run {_room_scope}.\n"
)

def handle_message(room_id, event):
    body = (event.get("content") or {}).get("body") or ""
    sender = event.get("sender", "")
    if sender == BOT_MXID:
        return
    # Ignore other known bots by default to prevent bot↔bot ping-pong (each
    # reply would trigger the other bot, burning both rate-limit budgets).
    if sender in KNOWN_BOT_MXIDS:
        return
    is_mention, prompt = extract_prompt(body)
    if not is_mention:
        return
    if not is_room_allowed(room_id):
        # Bot was tagged in a room it shouldn't be operating in. Leave silently;
        # the operator can re-invite it in an allowed room.
        log(f"room={room_id[:12]} not allowed — leaving")
        leave_room(room_id)
        return
    if not prompt or prompt.lower() in ("help", "?", "h"):
        post(room_id, HELP_TEXT)
        return
    # Never log the literal prompt (privacy + exfil risk on a shared-disk log).
    # A sha256 prefix gives a deterministic id for cross-referencing without
    # leaking content.
    import hashlib
    pdigest = hashlib.sha256(prompt.encode("utf-8", "replace")).hexdigest()[:8]
    log(f"room={room_id[:12]} sender={sender} prompt_sha={pdigest} prompt_len={len(prompt)}")

    # Self-rate-limit BEFORE calling the provider so we don't even spend a 429
    # round-trip when we know we'd be over.
    allowed, wait_s, scope = rate_limiter.check_or_block()
    if not allowed:
        if scope == "minute":
            post(room_id,
                 f"⏳ I'm at my **{RATE_LIMIT_RPM} req/min** ceiling — "
                 f"try again in **{int(wait_s)} s**.")
        else:
            hrs = int(wait_s // 3600)
            post(room_id,
                 f"⏳ I'm at my **{RATE_LIMIT_RPD} req/day** ceiling — "
                 f"resets in **{hrs} h**.")
        return

    if room_id not in rooms:
        rooms[room_id] = RoomState()
    state = rooms[room_id]

    msgs = [{"role": "system", "content": LLM_SYSTEM_PROMPT}]
    msgs.extend(state.history)
    msgs.append({"role": "user", "content": prompt})

    # Semaphore-gate the actual LLM call so concurrent fan-out doesn't queue up
    # parallel API requests (each holds an LLM_TIMEOUT_S socket + RPM budget).
    if not _LLM_INFLIGHT.acquire(timeout=2):
        post(room_id, "⏳ Busy with another reply — try again in a few seconds.")
        return
    try:
        with TypingKeepalive(room_id):
            reply, latency, usage = llm_chat(msgs)
    except urllib.error.HTTPError as e:
        # Don't echo the provider's response body back into the room — it can
        # contain auth diagnostics, project IDs, internal rate-limit reasons,
        # etc. Log the body to disk (operator-only) and tell the user a
        # generic, actionable message.
        err_body = e.read().decode("utf-8", errors="replace")[:300]
        log(f"upstream_http_{e.code} body={err_body!r}")
        if e.code == 429:
            retry = e.headers.get("Retry-After", "60") if hasattr(e, "headers") else "60"
            post(room_id,
                 f"⏳ Provider rate-limited me — retry in **{retry} s**.")
        elif 500 <= e.code < 600:
            post(room_id, "⚠ Upstream provider 5xx — try again in a moment.")
        else:
            post(room_id, f"⚠ Upstream provider returned {e.code}.")
        return
    except Exception as e:
        # Generic too — exception messages from urllib can include URLs, IPs,
        # sometimes auth headers. Log full, surface short.
        log(f"llm_call_exc type={type(e).__name__} repr={e!r}")
        post(room_id, "⚠ Upstream call failed; see operator logs.")
        return
    finally:
        _LLM_INFLIGHT.release()

    state.history.append({"role": "user", "content": prompt})
    state.history.append({"role": "assistant", "content": reply.strip()})

    plain, html = render_reply(reply, latency, usage)
    post(room_id, plain, html)

# ------------------------------------------------------------------ sync loop

def initial_sync():
    try:
        resp = _matrix("GET", "/_matrix/client/v3/sync?timeout=0", timeout=10)
        return resp.get("next_batch", "")
    except Exception as e:
        log(f"initial sync failed: {e}")
        return ""

def process_sync(resp):
    invites = (resp.get("rooms") or {}).get("invite") or {}
    for room_id in invites.keys():
        if not is_room_allowed(room_id):
            log(f"invite → REJECTING (not in ALLOWED_ROOMS): {room_id}")
            reject_invite(room_id)
            continue
        log(f"invite → joining (allowed): {room_id}")
        join_room(room_id)
    joins = (resp.get("rooms") or {}).get("join") or {}
    for room_id, rdata in joins.items():
        events = (rdata.get("timeline") or {}).get("events") or []
        for ev in events:
            if ev.get("type") == "m.room.message":
                handle_message(room_id, ev)

def sync_loop():
    global _LAST_SYNC_RETURN
    since = initial_sync()
    _LAST_SYNC_RETURN = time.time()
    log(f"sync start; since_len={len(since)}")
    backoff = 2
    while True:
        try:
            params = urllib.parse.urlencode({"timeout": 25000, "since": since})
            resp = _matrix("GET", f"/_matrix/client/v3/sync?{params}", timeout=35)
            _LAST_SYNC_RETURN = time.time()
            since = resp.get("next_batch", since)
            backoff = 2
            process_sync(resp)
        except urllib.error.HTTPError as e:
            log(f"sync http {e.code}: {e.reason}")
            time.sleep(backoff); backoff = min(backoff * 2, 60)
        except Exception as e:
            log(f"sync error: {e}")
            time.sleep(backoff); backoff = min(backoff * 2, 60)

def sync_watchdog():
    """Hard-exit the process if sync_loop hasn't returned in SYNC_WATCHDOG_S.
    The supervisor respawns it. Belt-and-suspenders alongside the socket
    timeout — covers Python-level deadlocks the socket layer can't see."""
    while True:
        time.sleep(60)
        idle = time.time() - _LAST_SYNC_RETURN
        if idle > SYNC_WATCHDOG_S:
            log(f"WATCHDOG: no sync return in {int(idle)}s "
                f"(threshold {SYNC_WATCHDOG_S}s) — exiting for respawn")
            os._exit(2)

def main():
    log(f"booting as {BOT_MXID}; provider={LLM_PROVIDER} model={LLM_MODEL}")
    log(f"  rate limit: {RATE_LIMIT_RPM} RPM / {RATE_LIMIT_RPD} RPD")
    log(f"  sync watchdog: {SYNC_WATCHDOG_S}s; socket timeout: 40s")
    if ALLOWED_ROOMS:
        log(f"  allowed rooms: {sorted(ALLOWED_ROOMS)}")
    else:
        log("  allowed rooms: <none> (fail-closed; set ALLOWED_ROOMS)")
    threading.Thread(target=sync_watchdog, daemon=True).start()
    try:
        sync_loop()
    except KeyboardInterrupt:
        log("shutdown (SIGINT)")

if __name__ == "__main__":
    main()
