#!/usr/bin/env python3
"""On-phone LLM Matrix bot (exobot) — BYO llama.cpp + GGUF.

This bot ships NO model and NO binary. You bring your own:
  * a llama.cpp `llama-server` build that matches YOUR phone's CPU
    (point LLAMA_SERVER_BIN at it), and
  * a GGUF model file (point MODEL_PATH at it).

The bot subprocess-manages that llama-server: it lazy-loads the model on the
first @-mention after idle, idle-unloads it to free RAM, and re-warms it when
the phone is not under load. It listens on every joined room via /sync
long-poll and answers only when tagged (`@<localpart> …` or `!chat …`). A
five-tier speed/quality "mode" split (ultrafast → deepreason) trades latency
for answer depth, and four optional background daemons (interject / seed /
crossbot / revive) keep small communities lively. A /proc-based pressure check
drops the model and declines work while the phone is busy.

Runtime: TERMUX-NATIVE python3 (stdlib only — no third-party deps). The
llama-server binary is launched inside the Debian userland via `proot-distro`
(set EXOBOT_PROOT_DISTRO=debian; set EXOBOT_PROOT_DISTRO="" to run the binary
directly, e.g. if it is a Termux-native build).

All configuration is env-driven; nothing operator-specific is baked in. The
launcher (scripts/steps/81-install-exobot.sh) sources a 0600 secrets file so
the access token never reaches argv / /proc/<pid>/cmdline.

Key env (see .env.example + scripts/steps/81-install-exobot.sh):
  EXOBOT_TOKEN        — the bot account's Matrix access token (SECRET, off-argv)
  EXOBOT_MXID         — the bot's full MXID, e.g. @exobot:${MATRIX_SERVER_NAME}
  EXOBOT_HS_URL       — homeserver client-server API base (default loopback)
  LLAMA_SERVER_BIN    — path to YOUR llama.cpp llama-server build (REQUIRED)
  MODEL_PATH          — path to YOUR GGUF model file (REQUIRED)
  LLAMA_SERVER_PORT   — loopback port to bind llama-server (default 8081)
  EXOBOT_PROOT_DISTRO — proot-distro name to run the binary in (default debian;
                        "" = run LLAMA_SERVER_BIN directly, no proot)
  EXOBOT_IDLE_TIMEOUT_S, LLAMA_KEEP_WARM, N_PREDICT, CTX_SIZE, N_THREADS,
  N_THREADS_BATCH, per-mode caps, EXOBOT_ALLOWED_ROOMS, daemon toggles, …
"""
import hashlib
import json
import os
import random as _random
import re
import signal
import socket
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import deque
from contextlib import closing

# ------------------------------------------------------------------ config
#
# Token + MXID are user-supplied at runtime (the launcher sources a 0600
# secrets file). We read them defensively so a misconfigured launch fails with
# a clear message instead of a KeyError traceback.

BOT_TOKEN = os.environ.get("EXOBOT_TOKEN", "")
BOT_MXID = os.environ.get("EXOBOT_MXID", "")
HS_URL = os.environ.get("EXOBOT_HS_URL", "http://127.0.0.1:8448").rstrip("/")

# BYO requirement: the binary + model are always supplied by the operator. The
# install step fail-louds when these are unset/missing; we re-check here so a
# direct run also gives a clear error.
MODEL_PATH = os.environ.get("MODEL_PATH", "")
LLAMA_BIN = os.environ.get("LLAMA_SERVER_BIN", "")
LLAMA_PORT = int(os.environ.get("LLAMA_SERVER_PORT", "8081"))

# How llama-server is launched. Most on-phone builds are aarch64-Debian-glibc
# and must run inside the proot userland (Termux is bionic). Set to "" to run
# the binary directly (e.g. a Termux-native build).
PROOT_DISTRO = os.environ.get("EXOBOT_PROOT_DISTRO", "debian").strip()

IDLE_TIMEOUT_S = int(os.environ.get("EXOBOT_IDLE_TIMEOUT_S", "600"))  # 10 min
# Keep the model resident (re-warm instead of idle-unloading) so a companion
# web UI and the Matrix bot always have a live llama-server — both are pure
# clients that can't spawn it themselves. The idle_watcher re-warms within
# ~15 s if it's down and the phone isn't pressured; pressure-unload still frees
# RAM under genuine load. Set LLAMA_KEEP_WARM=false for lazy load-on-mention +
# idle-unload.
LLAMA_KEEP_WARM = os.environ.get("LLAMA_KEEP_WARM", "true").lower() in ("1", "true", "yes")
N_PREDICT = int(os.environ.get("N_PREDICT", "300"))   # server -n upper bound
CTX_SIZE = int(os.environ.get("CTX_SIZE", "2048"))
N_THREADS = int(os.environ.get("N_THREADS", "2"))      # decode threads (fast cores)
# Decouple prefill (batch) threads from decode threads: on many big.LITTLE SoCs
# decode peaks at the 2 big cores while prefill scales with all cores. Tune for
# your phone — these defaults are conservative.
N_THREADS_BATCH = int(os.environ.get("N_THREADS_BATCH", str(os.cpu_count() or 4)))

# Cap concurrent llama-server calls across ALL callers (the @-mention handler
# plus the interject/seed/crossbot/revive watchers). llama-server serializes
# generation itself, but without this gate a flood of mentions forks parallel
# HTTP calls each holding a socket + a Python thread. Default 1 = strictly
# serial; raise only on beefier hardware.
LLM_CONCURRENT_MAX = int(os.environ.get("LLM_CONCURRENT_MAX", "1"))
LLM_ACQUIRE_TIMEOUT_S = float(os.environ.get("LLM_ACQUIRE_TIMEOUT_S", "2"))
_LLM_INFLIGHT = threading.Semaphore(LLM_CONCURRENT_MAX)


class LLMBusyError(Exception):
    """Raised by LlamaServer.generate when the concurrency semaphore can't be
    acquired within LLM_ACQUIRE_TIMEOUT_S — another generation is already in
    flight. handle_message turns it into a friendly 'busy' reply; the watchers
    (which wrap generate in `except Exception`) just skip that cycle."""
    pass


LLAMA_URL = f"http://127.0.0.1:{LLAMA_PORT}"
HISTORY_TURNS = 2     # past turns kept per room — only used in reason/deepreason
MAX_PROMPT_CHAR = 2000  # clip user messages longer than this

# Self localpart (e.g. "exobot") — used in mention parsing + self-tag scrubbing.
# Derived from EXOBOT_MXID; falls back to a neutral handle if unset so the regex
# below is always valid.
SELF_LOCAL = (BOT_MXID.split(":")[0].lstrip("@") or "exobot")

# ----- Interjection ("active participant") mode -----
# When a room is busy (>=INTERJECT_TRIGGER_N human messages from
# >=INTERJECT_MIN_DISTINCT senders within the last INTERJECT_WINDOW_S), the bot
# chimes in with one short line — without being explicitly tagged. Cooldown
# INTERJECT_MIN_GAP_S between interjections per room.
INTERJECT_ENABLED = os.environ.get("INTERJECT_ENABLED", "false").lower() in ("1", "true", "yes")
INTERJECT_TRIGGER_N = int(os.environ.get("INTERJECT_TRIGGER_N", "3"))
INTERJECT_WINDOW_S = int(os.environ.get("INTERJECT_WINDOW_S", "600"))
INTERJECT_MIN_GAP_S = int(os.environ.get("INTERJECT_MIN_GAP_S", "1800"))
INTERJECT_MIN_DISTINCT = int(os.environ.get("INTERJECT_MIN_DISTINCT", "2"))
INTERJECT_HISTORY_MSGS = int(os.environ.get("INTERJECT_HISTORY_MSGS", "6"))
# Empty allowlist = unrestricted (among rooms the bot tracks); non-empty = only
# interject in these room IDs.
INTERJECT_ALLOWLIST = {r.strip() for r in os.environ.get("INTERJECT_ALLOWLIST", "").split(",") if r.strip()}
INTERJECT_DENYLIST = {r.strip() for r in os.environ.get("INTERJECT_DENYLIST", "").split(",") if r.strip()}

# ----- Dry-room seeding ("engagement watcher") -----
# Every SEED_INTERVAL_S, if the whole space has been dry for SEED_DRY_THRESHOLD_S,
# post one topic-aware engagement starter to a general room + a few random rooms.
SEED_ENABLED = os.environ.get("SEED_ENABLED", "false").lower() in ("1", "true", "yes")
SEED_INTERVAL_S = int(os.environ.get("SEED_INTERVAL_S", "43200"))      # 12 h
SEED_DRY_THRESHOLD_S = int(os.environ.get("SEED_DRY_THRESHOLD_S", "86400"))  # 24 h
SEED_FIRST_DELAY_S = int(os.environ.get("SEED_FIRST_DELAY_S", "43200"))  # don't seed on boot
SEED_PICK_K = int(os.environ.get("SEED_PICK_K", "2"))
SEED_GENERAL_ROOM_ID = os.environ.get("SEED_GENERAL_ROOM_ID", "").strip()
SEED_CANDIDATE_ROOMS = {r.strip() for r in os.environ.get("SEED_CANDIDATE_ROOMS", "").split(",") if r.strip()}

# ----- Conversation revival ("reply to recent context" daemon) -----
# Every REVIVE_INTERVAL_S, pick a random room from REVIVE_CANDIDATE_ROOMS (or
# EXOBOT_ALLOWED_ROOMS minus CROSSBOT_ROOM_ID if unset), pull recent messages,
# and post a contextual reply — unless the room had a human message within
# REVIVE_QUIET_S, or the server is pressured.
REVIVE_ENABLED = os.environ.get("REVIVE_ENABLED", "false").lower() in ("1", "true", "yes")
REVIVE_INTERVAL_S = int(os.environ.get("REVIVE_INTERVAL_S", "21600"))   # 6 h
REVIVE_FIRST_DELAY_S = int(os.environ.get("REVIVE_FIRST_DELAY_S", "21600"))
REVIVE_HISTORY_MSGS = int(os.environ.get("REVIVE_HISTORY_MSGS", "5"))
REVIVE_QUIET_S = int(os.environ.get("REVIVE_QUIET_S", "3600"))          # last msg >= 1 h old
REVIVE_CANDIDATE_ROOMS = {r.strip() for r in os.environ.get("REVIVE_CANDIDATE_ROOMS", "").split(",") if r.strip()}

# ----- Cross-bot chat ("inter-bot conversation" daemon) -----
# Every CROSSBOT_INTERVAL_S, in CROSSBOT_ROOM_ID, kick off a few-round
# conversation between this bot and a randomly-picked companion bot (you supply
# the companions' MXIDs via CROSSBOT_TARGETS). Skipped if humans chatted within
# CROSSBOT_QUIET_S. Empty CROSSBOT_TARGETS / unset CROSSBOT_ROOM_ID = no-op.
CROSSBOT_ENABLED = os.environ.get("CROSSBOT_ENABLED", "false").lower() in ("1", "true", "yes")
CROSSBOT_INTERVAL_S = int(os.environ.get("CROSSBOT_INTERVAL_S", "21600"))   # 6 h
CROSSBOT_FIRST_DELAY_S = int(os.environ.get("CROSSBOT_FIRST_DELAY_S", "21600"))
CROSSBOT_QUIET_S = int(os.environ.get("CROSSBOT_QUIET_S", "1800"))          # 30 min human-quiet
CROSSBOT_ROOM_ID = os.environ.get("CROSSBOT_ROOM_ID", "").strip()
CROSSBOT_TARGETS = [s.strip() for s in os.environ.get("CROSSBOT_TARGETS", "").split(",") if s.strip()]
CROSSBOT_ROUNDS = int(os.environ.get("CROSSBOT_ROUNDS", "3"))
CROSSBOT_REPLY_WAIT_S = int(os.environ.get("CROSSBOT_REPLY_WAIT_S", "60"))

# ----- Server-load offline mode -----
# When the phone is under load (memory or CPU), the bot stops loading the
# model + skips daemon work + declines mentions. Resumes when load drops.
PRESSURE_MEM_PCT = int(os.environ.get("PRESSURE_MEM_PCT", "85"))
PRESSURE_LOAD_PCT = int(os.environ.get("PRESSURE_LOAD_PCT", "85"))  # of ncpu
PRESSURE_ENABLED = os.environ.get("PRESSURE_ENABLED", "true").lower() in ("1", "true", "yes")

# Other bot MXIDs to recognise so interjection doesn't fire on bot replies and
# the cross-bot daemon doesn't chain on itself. Comma-separated full MXIDs; the
# bot's own MXID is always included. Defaults to just this bot (no companions).
KNOWN_BOT_MXIDS = {s.strip() for s in os.environ.get("KNOWN_BOT_MXIDS", "").split(",") if s.strip()}
if BOT_MXID:
    KNOWN_BOT_MXIDS.add(BOT_MXID)

# Rooms the bot is allowed to operate in. Empty/unset = no rooms (fail-closed):
# the bot auto-leaves invites from rooms not in this set and ignores tagged
# messages from other rooms. Set it to the room IDs you want the bot in.
EXOBOT_ALLOWED_ROOMS = {r.strip() for r in os.environ.get("EXOBOT_ALLOWED_ROOMS", "").split(",") if r.strip()}

# ------------------------------------------------------------------ mode config
#
# Modes selected by a leading keyword on the prompt:
#   "<bot> fast <q>"           -> MODE_FAST   — greedy, no thinking, tiny answer
#   "<bot> <q>"                -> MODE_NORMAL — sampled, no thinking, short answer
#   "<bot> reason|think <q>"   -> MODE_REASON — sampled, thinking on, longer
#
# Wall caps (`wall_s`) become `t_max_predict_ms` per request — llama-server
# stops cleanly when hit. `enable_thinking` is forwarded as
# `chat_template_kwargs.enable_thinking` — thinking-capable templates (e.g.
# Qwen3) skip/keep the <think> opener accordingly. Greedy decode (top_k=1,
# temperature=0) is the fastest CPU sampling — used in fast modes only.

MODE_ULTRAFAST = "ultrafast"
MODE_FAST = "fast"
MODE_NORMAL = "normal"
MODE_REASON = "reason"
MODE_DEEPREASON = "deepreason"
MODE_INTERJECT = "interject"   # internal: active-mode auto-replies
MODE_CROSSBOT = "crossbot"     # internal: bot-to-bot rounds (high temp, random seed)
MODE_REVIVE = "revive"         # internal: periodic revival in dormant rooms

# Per-mode params:
#   max_tokens       — hard ceiling on decode tokens
#   temperature/top_k/top_p — sampling; greedy (top_k=1, temp=0) is fastest
#   enable_thinking  — chat_template_kwargs.enable_thinking (skips <think>)
#   reasoning_budget — per-request budget (server --reasoning-budget backstop)
#   wall_s           — per-request t_max_predict_ms wall-clock cap
#   show_reasoning   — render the spoiler/reasoning block in the reply
#   system_prompt    — per-mode system prompt; shorter for fast modes
#
# Defaults are tuned for a small quantized model on a mid-range phone CPU. Tune
# them for your model/hardware.
MODE_CONFIG = {
    MODE_ULTRAFAST: {
        "max_tokens": 40,
        "temperature": 0.0,
        "top_k": 1,
        "enable_thinking": False,
        "wall_s": 25,
        "show_reasoning": False,
        "system_prompt": "Reply in one short line.",
    },
    MODE_FAST: {
        "max_tokens": 100,
        "temperature": 0.0,
        "top_k": 1,
        "enable_thinking": False,
        "wall_s": 40,
        "show_reasoning": False,
        "system_prompt": "Be brief.",
    },
    MODE_NORMAL: {
        "max_tokens": 250,
        "temperature": 0.4,
        "top_k": 20,
        "top_p": 0.9,
        "enable_thinking": False,
        "wall_s": 70,
        "show_reasoning": False,
        "system_prompt": "You are a helpful chat assistant. Be concise and helpful.",
    },
    MODE_REASON: {
        "max_tokens": 350,
        "temperature": 0.6,
        "top_k": 20,
        "top_p": 0.95,
        "enable_thinking": True,
        "reasoning_budget": 60,
        "wall_s": 90,
        "show_reasoning": True,
        "system_prompt": "You are a helpful chat assistant. Think briefly then give a clear answer.",
    },
    MODE_DEEPREASON: {
        "max_tokens": 600,
        "temperature": 0.6,
        "top_k": 20,
        "top_p": 0.95,
        "enable_thinking": True,
        "reasoning_budget": 150,
        "wall_s": 180,
        "show_reasoning": True,
        "system_prompt": "You are a helpful chat assistant. Think step-by-step then give a clear final answer.",
    },
    # Internal mode used by interject_watcher. Thinking on so the model reasons
    # before writing; show_reasoning False so the chain-of-thought is stripped
    # before posting. Generous budget so the reply isn't a truncated reasoning
    # fragment (a common small-model failure when the budget is hit mid-think).
    MODE_INTERJECT: {
        "max_tokens": 500,
        "temperature": 0.6,
        "top_k": 20,
        "top_p": 0.9,
        "enable_thinking": True,
        "reasoning_budget": 220,
        "wall_s": 240,
        "show_reasoning": False,
        "system_prompt": "",   # set per-call (room context goes in)
    },
    MODE_CROSSBOT: {
        "max_tokens": 120,
        "temperature": 0.95,   # high — heavily-quantized models need diversity
        "top_k": 60,
        "top_p": 0.92,
        "enable_thinking": False,
        "wall_s": 90,
        "show_reasoning": False,
        "system_prompt": "",
        "seed": -1,            # random per call (default seed=42 in generate())
    },
    # Internal mode used by revive_watcher: ultra-reasoning with hidden
    # chain-of-thought + room for a complete reply (no mid-sentence truncation).
    MODE_REVIVE: {
        "max_tokens": 1000,
        "temperature": 0.6,
        "top_k": 25,
        "top_p": 0.9,
        "enable_thinking": True,
        "reasoning_budget": 400,
        "wall_s": 420,
        "show_reasoning": False,   # hidden — leak-strip in format_reply protects
        "system_prompt": "",       # set per-call (room context goes in)
    },
}

# Server-level reasoning budget — caps tokens spent inside <think>…</think> if a
# per-request `reasoning_budget` field isn't honoured by this build. Set to the
# largest mode's value so we never truncate below the per-request cap.
REASONING_BUDGET = 150

# Order matters: longest mode keyword first so e.g. "deepreason" doesn't match
# the prefix "reason". Numeric shortcuts (1..5) match the speed order.
MODE_KEYWORDS = (
    ("deepreason ", MODE_DEEPREASON),
    ("ultrafast ", MODE_ULTRAFAST),
    ("reason ", MODE_REASON),
    ("normal ", MODE_NORMAL),
    ("fast ", MODE_FAST),
    ("think ", MODE_REASON),       # legacy alias
    ("5 ", MODE_DEEPREASON),
    ("4 ", MODE_REASON),
    ("3 ", MODE_NORMAL),
    ("2 ", MODE_FAST),
    ("1 ", MODE_ULTRAFAST),
)
DEFAULT_MODE = MODE_NORMAL  # untagged prompts run in this mode

# ------------------------------------------------------------------ logging

def log(msg):
    print(f"[{time.strftime('%H:%M:%SZ', time.gmtime())}] {msg}", flush=True)

# ------------------------------------------------------------------ Matrix client

def _matrix(method, path, data=None, timeout=35, tok_override=None):
    body = json.dumps(data).encode() if data is not None else None
    tok = tok_override or BOT_TOKEN
    req = urllib.request.Request(
        HS_URL + path, data=body, method=method,
        headers={"Authorization": f"Bearer {tok}",
                 "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read() or b"{}")

def post(room_id, text, html=None):
    """Send m.room.message. If html is None, auto-render text as markdown so
    **bold** / `code` etc. in loading/ready/idle messages render properly."""
    txn = str(time.time_ns())
    if html is None:
        html = md_to_html(text)
    plain = _BOLD_RE.sub(r"\1", text)
    plain = _ITALIC_RE.sub(r"\1", plain)
    content = {
        "msgtype": "m.text",
        "body": plain,
        "format": "org.matrix.custom.html",
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
        _matrix("POST", path, {})
        return True
    except Exception as e:
        log(f"join failed for {room_id}: {e}")
        return False

def set_typing(room_id, active, timeout_ms=25000):
    """Show/hide the bot's typing indicator in the room."""
    path = (f"/_matrix/client/v3/rooms/{urllib.parse.quote(room_id)}/"
            f"typing/{urllib.parse.quote(BOT_MXID)}")
    body = {"typing": True, "timeout": timeout_ms} if active else {"typing": False}
    try:
        _matrix("PUT", path, body, timeout=5)
    except Exception as e:
        log(f"set_typing({active}) failed: {e}")


class TypingKeepalive:
    """Refreshes the typing indicator every 15 s while active. Matrix typing
    notifications expire (we use 25 s); without refresh clients would hide the
    indicator mid-generation."""
    def __init__(self, room_id):
        self.room_id = room_id
        self._stop = threading.Event()
        self._thread = None

    def __enter__(self):
        set_typing(self.room_id, True, 25000)

        def _loop():
            while not self._stop.wait(15):
                set_typing(self.room_id, True, 25000)
        self._thread = threading.Thread(target=_loop, daemon=True)
        self._thread.start()
        return self

    def __exit__(self, *exc):
        self._stop.set()
        set_typing(self.room_id, False)

# ------------------------------------------------------------------ markdown -> html

_BOLD_RE = re.compile(r"\*\*([^\*]+?)\*\*")
_ITALIC_RE = re.compile(r"(?<![\w_])_([^_\n]+?)_(?![\w_])")
_CODE_RE = re.compile(r"`([^`]+?)`")
_LINK_RE = re.compile(r"\[([^\]]+)\]\((https?://[^)\s]+|mxc://[^)\s]+|matrix:[^)\s]+)\)")
_HEADER_RE = re.compile(r"^(#{1,6})\s+(.+)$")
_HR_RE = re.compile(r"^---+\s*$")
_UL_RE = re.compile(r"^[-*]\s+(.+)$")
_OL_RE = re.compile(r"^\d+\.\s+(.+)$")
_QUOTE_RE = re.compile(r"^&gt;\s+(.+)$")
_CODEBLOCK_RE = re.compile(r"^```(\w*)\n([\s\S]*?)\n```$", re.MULTILINE)

def _md_inline(text):
    """Inline md on an already-HTML-escaped single line/paragraph fragment."""
    out = _CODE_RE.sub(r"<code>\1</code>", text)
    out = _BOLD_RE.sub(r"<strong>\1</strong>", out)
    out = _ITALIC_RE.sub(r"<em>\1</em>", out)
    # HTML-escape href content so a URL with `"` can't break out of the
    # attribute and inject extras.
    def _link_repl(m):
        href = m.group(2).replace("&", "&amp;").replace('"', "&quot;").replace("<", "&lt;").replace(">", "&gt;")
        return f'<a href="{href}">{m.group(1)}</a>'
    out = _LINK_RE.sub(_link_repl, out)
    return out

def md_to_html(text):
    """Markdown -> HTML within the Matrix allowlist. Supports:
    block: # H1..###### H6, '- '/'* '/'1. ' lists, '---' HR, '> ' blockquote,
           fenced ```code``` blocks, blank-line paragraph break.
    inline: **bold**, _italic_, `code`, [text](url)."""
    blocks = {}

    def _cb(m):
        lang = m.group(1) or ""
        body = m.group(2).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
        key = f"\x00CB{len(blocks)}\x00"
        cls = f' class="language-{lang}"' if lang else ""
        blocks[key] = f"<pre><code{cls}>{body}</code></pre>"
        return key
    text_stripped_blocks = _CODEBLOCK_RE.sub(_cb, text)

    escaped = text_stripped_blocks.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    lines = escaped.split("\n")
    out = []
    i = 0
    while i < len(lines):
        line = lines[i]
        if not line.strip():
            i += 1
            continue
        if _HR_RE.match(line):
            out.append("<hr>")
            i += 1
            continue
        m = _HEADER_RE.match(line)
        if m:
            lvl = len(m.group(1))
            out.append(f"<h{lvl}>{_md_inline(m.group(2))}</h{lvl}>")
            i += 1
            continue
        if line.strip().startswith("\x00CB"):
            out.append(blocks.get(line.strip(), ""))
            i += 1
            continue
        if _UL_RE.match(line):
            items = []
            while i < len(lines) and _UL_RE.match(lines[i]):
                items.append("<li>" + _md_inline(_UL_RE.match(lines[i]).group(1)) + "</li>")
                i += 1
            out.append("<ul>" + "".join(items) + "</ul>")
            continue
        if _OL_RE.match(line):
            items = []
            while i < len(lines) and _OL_RE.match(lines[i]):
                items.append("<li>" + _md_inline(_OL_RE.match(lines[i]).group(1)) + "</li>")
                i += 1
            out.append("<ol>" + "".join(items) + "</ol>")
            continue
        if _QUOTE_RE.match(line):
            quoted = []
            while i < len(lines) and _QUOTE_RE.match(lines[i]):
                quoted.append(_md_inline(_QUOTE_RE.match(lines[i]).group(1)))
                i += 1
            out.append("<blockquote>" + "<br>".join(quoted) + "</blockquote>")
            continue
        para = [_md_inline(line)]
        i += 1
        while i < len(lines):
            nxt = lines[i]
            if (not nxt.strip() or _HR_RE.match(nxt) or _HEADER_RE.match(nxt)
                    or _UL_RE.match(nxt) or _OL_RE.match(nxt) or _QUOTE_RE.match(nxt)
                    or nxt.strip().startswith("\x00CB")):
                break
            para.append(_md_inline(nxt))
            i += 1
        out.append("<p>" + "<br>".join(para) + "</p>")

    html = "".join(out)
    for key, val in blocks.items():
        html = html.replace(key, val)
    return html


_THINK_RE = re.compile(r"<think>([\s\S]*?)</think>", re.DOTALL)
_THINK_OPEN_RE = re.compile(r"<think>([\s\S]*)$", re.DOTALL)  # opened but never closed

# Heuristic patterns small models use when they stream chain-of-thought as plain
# prose (no <think> tag). Matched at the start of the candidate answer so we
# don't false-positive on normal sentences.
_RAW_REASONING_PREFIXES = (
    "okay, so ",
    "okay so ",
    "alright, so ",
    "let me think",
    "let's think",
    "i need to ",
    "i should think",
    "first, i ",
    "the user is ",
    "the user just ",
    "the user wants ",
    "the conversation is ",
    "this is asking ",
)

def _looks_like_raw_reasoning(text):
    if not text:
        return False
    head = text.lstrip().lower()[:60]
    return any(head.startswith(p) for p in _RAW_REASONING_PREFIXES)

# Many Matrix clients don't render LaTeX `$…$` / `$$…$$` natively — they show as
# raw dollar signs. Strip the markers but keep the inner text.
_LATEX_BLOCK_RE = re.compile(r"\$\$([\s\S]+?)\$\$")
_LATEX_INLINE_RE = re.compile(r"\$([^$\n]+?)\$")

def _strip_latex(text):
    if not text:
        return text
    text = re.sub(r"\\times\b", "×", text)
    text = re.sub(r"\\div\b", "÷", text)
    text = re.sub(r"\\cdot\b", "·", text)
    text = re.sub(r"\\pm\b", "±", text)
    text = re.sub(r"\\approx\b", "≈", text)
    text = re.sub(r"\\neq\b", "≠", text)
    text = re.sub(r"\\leq\b", "≤", text)
    text = re.sub(r"\\geq\b", "≥", text)
    text = re.sub(r"\\sqrt\b", "√", text)
    text = re.sub(r"\\frac\{([^{}]+?)\}\{([^{}]+?)\}", r"(\1)/(\2)", text)
    text = re.sub(r"\\text\{([^{}]+?)\}", r"\1", text)
    text = _LATEX_BLOCK_RE.sub(lambda m: m.group(1).strip(), text)
    text = _LATEX_INLINE_RE.sub(lambda m: m.group(1), text)
    return text

# Inline-reasoning markers some models emit instead of <think>…</think>.
_ANSWER_MARKER_RE = re.compile(
    r"(?im)^[\s\*_]*(?:final\s+answer|answer|conclusion|result)[\s\*_]*:[\s\*_]*",
    re.MULTILINE)
_HEADER_PEEL_RE = re.compile(
    r"(?im)^\s*(?:thought|reasoning|working|let\s+me\s+think|step\s*\d*)\s*:\s*",
    re.MULTILINE)
_CONCLUSION_RE = re.compile(
    r"\b(?:So,|Therefore,|Thus,|Hence,|In conclusion,|Finally,)\s+", re.IGNORECASE)

def _split_inline_reasoning(raw):
    """For reason/deepreason replies that lack a <think>…</think> block. Tries
    (in order): explicit answer marker -> conjunction conclusion ->
    multi-paragraph (last para = answer) -> multi-sentence (last = answer) ->
    fallback (whole reply is the answer). Returns (think, answer)."""
    raw = raw.strip()
    if not raw:
        return "", ""
    m = _ANSWER_MARKER_RE.search(raw)
    if m:
        think = raw[:m.start()].strip()
        answer = raw[m.end():].strip()
        think = _HEADER_PEEL_RE.sub("", think, count=1).strip()
        return think, answer
    paragraphs = [p.strip() for p in re.split(r"\n\s*\n", raw) if p.strip()]
    if len(paragraphs) >= 2:
        think = "\n\n".join(paragraphs[:-1])
        answer = paragraphs[-1]
        think = _HEADER_PEEL_RE.sub("", think, count=1).strip()
        return think, answer
    cm = _CONCLUSION_RE.search(raw)
    if cm and cm.start() > 30:
        return raw[:cm.start()].strip(), raw[cm.start():].strip()
    parts = re.split(r"(?<=[.!?])\s+", raw)
    parts = [p for p in parts if p.strip()]
    if len(parts) >= 3:
        return " ".join(parts[:-1]).strip(), parts[-1].strip()
    return "", raw

def _format_footer(timings, mode_label=None):
    """Compact one-line performance footer drawn from llama-server timings."""
    if not timings:
        return ""
    pp_n = timings.get("prompt_n", 0)
    pp_s = timings.get("prompt_per_second", 0.0)
    pp_ms = timings.get("prompt_ms", 0.0)
    tg_n = timings.get("predicted_n", 0)
    tg_s = timings.get("predicted_per_second", 0.0)
    tg_ms = timings.get("predicted_ms", 0.0)
    total_s = (pp_ms + tg_ms) / 1000.0
    prefix = f"`{mode_label}` · " if mode_label else ""
    return (f"{prefix}⚡ **{tg_n} tok** @ **{tg_s:.2f} tok/s** ({tg_ms/1000:.1f} s) · "
            f"prefill {pp_n} tok @ {pp_s:.2f} tok/s · total {total_s:.1f} s")

def format_reply(raw, timings=None, show_reasoning=True, mode_label=None):
    """Format an assistant reply for Matrix.

    show_reasoning=True (reason mode): extract <think>…</think>, render it as a
        click-to-reveal spoiler above the answer.
    show_reasoning=False (fast/normal): strip any <think>…</think> defensively.

    Always appends a one-line performance footer. Returns (plain_body, html_body)."""
    think = ""
    answer = raw
    think_match = _THINK_RE.search(raw)
    if think_match:
        think = think_match.group(1).strip()
        answer = _THINK_RE.sub("", raw).strip()
    if not think and show_reasoning:
        think, answer = _split_inline_reasoning(answer)
    elif not show_reasoning:
        if "<think>" in raw:
            answer = re.sub(r"<think>[\s\S]*?</think>", "", raw)
            answer = _THINK_OPEN_RE.sub("", answer)
            answer = answer.strip()
        if not answer or _looks_like_raw_reasoning(answer):
            _, candidate = _split_inline_reasoning(answer)
            answer = candidate.strip() if candidate else ""

    think = _strip_latex(think)
    answer = _strip_latex(answer)
    footer = _format_footer(timings or {}, mode_label)

    plain_parts = []
    if show_reasoning and think:
        for ln in think.splitlines():
            plain_parts.append(f"> {ln}" if ln.strip() else ">")
        plain_parts.append("")
    plain_parts.append(answer or "(empty)")
    if footer:
        plain_parts.append("")
        plain_parts.append(_BOLD_RE.sub(r"\1", footer))
    plain = "\n".join(plain_parts).strip()

    html_parts = []
    if show_reasoning and think:
        spoiler = (think.replace("&", "&amp;")
                        .replace("<", "&lt;")
                        .replace(">", "&gt;")
                        .replace("\n", "<br>"))
        html_parts.append(
            f'<blockquote><span data-mx-spoiler="thinking">{spoiler}</span></blockquote>')
    html_parts.append(md_to_html(answer) if answer else "<p><em>(empty reply)</em></p>")
    if footer:
        html_parts.append("<p><small>"
                          + _md_inline(footer.replace("<", "&lt;").replace(">", "&gt;"))
                          + "</small></p>")
    html = "".join(html_parts)
    return plain, html

# ------------------------------------------------------------------ llama-server lifecycle

class LlamaServer:
    def __init__(self):
        self.proc = None
        self.last_activity = 0
        self.last_timings = {}
        self.active_requests = 0   # >0 while generate() is in-flight; idle_watcher must not kill
        self.lock = threading.Lock()

    def is_up(self):
        return self.proc is not None and self.proc.poll() is None

    def _port_open(self, timeout=1):
        with closing(socket.socket(socket.AF_INET, socket.SOCK_STREAM)) as s:
            s.settimeout(timeout)
            try:
                s.connect(("127.0.0.1", LLAMA_PORT))
                return True
            except Exception:
                return False

    def _spawn_argv(self):
        """Build the argv to launch the user-supplied llama-server. When
        PROOT_DISTRO is set the binary runs inside that proot userland (typical
        for an aarch64-glibc build on bionic Termux); when empty the binary is
        run directly (e.g. a Termux-native build)."""
        server_args = [
            LLAMA_BIN,
            "-m", MODEL_PATH,
            "--host", "127.0.0.1",
            "--port", str(LLAMA_PORT),
            "-t", str(N_THREADS),
            "-tb", str(N_THREADS_BATCH),
            "-b", "256",
            "-ub", "64",
            "-c", str(CTX_SIZE),
            "-n", str(N_PREDICT),
            # Keep <think>…</think> inline in content (default "deepseek"
            # extracts it into a separate reasoning_content field).
            "--reasoning-format", "none",
            "--reasoning", "on",
            "--reasoning-budget", str(REASONING_BUDGET),
            "--no-warmup",
            "--log-disable",
        ]
        if PROOT_DISTRO:
            return ["proot-distro", "login", PROOT_DISTRO, "--", *server_args]
        return server_args

    def start(self, on_progress=None):
        """Start llama-server; block until /health responds ok. Returns (ok, err)."""
        with self.lock:
            if self.is_up():
                return True, None
            launch = (f"inside proot-distro '{PROOT_DISTRO}'" if PROOT_DISTRO else "directly")
            log(f"starting llama-server on :{LLAMA_PORT} ({launch})")
            # Prime last_activity NOW so idle_watcher can't fire during the
            # cold-load window and SIGTERM the just-spawned server.
            self.last_activity = time.time()
            args = self._spawn_argv()
            try:
                self.proc = subprocess.Popen(
                    args,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    preexec_fn=os.setsid)
            except Exception as e:
                return False, f"spawn failed: {e}"
            deadline = time.time() + 60
            step = 0
            while time.time() < deadline:
                if self.proc.poll() is not None:
                    return False, f"llama-server exited rc={self.proc.returncode}"
                if self._port_open():
                    try:
                        with urllib.request.urlopen(
                                f"{LLAMA_URL}/health", timeout=3) as r:
                            hb = json.loads(r.read() or b"{}")
                            if hb.get("status") in ("ok", "no slot available"):
                                self.last_activity = time.time()
                                log("llama-server ready")
                                return True, None
                    except Exception:
                        pass
                time.sleep(1)
                step += 1
                if on_progress and step % 3 == 0:
                    on_progress(step)
            return False, "timeout waiting for /health"

    def stop(self):
        with self.lock:
            if not self.is_up():
                self.proc = None
                return
            log("stopping llama-server")
            try:
                os.killpg(os.getpgid(self.proc.pid), signal.SIGTERM)
            except Exception:
                pass
            deadline = time.time() + 5
            while time.time() < deadline and self.proc.poll() is None:
                time.sleep(0.3)
            if self.proc.poll() is None:
                try:
                    os.killpg(os.getpgid(self.proc.pid), signal.SIGKILL)
                except Exception:
                    pass
            # Belt-and-braces: proot may have forked away; hunt lingering
            # llama-server processes by the binary's basename.
            self._pkill_lingering()
            self.proc = None

    def _pkill_lingering(self):
        """Kill any llama-server left over after the process group dies. Matches
        on the binary basename so it works regardless of the install path."""
        binbase = os.path.basename(LLAMA_BIN) or "llama-server"
        try:
            if PROOT_DISTRO:
                subprocess.run(
                    ["proot-distro", "login", PROOT_DISTRO, "--", "pkill", "-f", binbase],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                    timeout=10, check=False)
            else:
                subprocess.run(
                    ["pkill", "-f", binbase],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                    timeout=10, check=False)
        except Exception:
            pass

    def generate(self, messages, mode):
        """messages: [{role, content}]. mode selects a MODE_CONFIG entry.
        Uses /v1/chat/completions so llama-server applies the model's native
        template; chat_template_kwargs.enable_thinking is the real speed knob.
        Returns the raw assistant content (with <think> if reasoning is on)."""
        cfg = MODE_CONFIG[mode]
        seed = cfg.get("seed", 42)
        if seed == -1:
            seed = int(time.time() * 1000) & 0x7fffffff
        body = {
            "messages": messages,
            "temperature": cfg["temperature"],
            "max_tokens": cfg["max_tokens"],
            "top_k": cfg["top_k"],
            "seed": seed,
            "cache_prompt": True,
            "t_max_predict_ms": cfg["wall_s"] * 1000,
            "chat_template_kwargs": {"enable_thinking": cfg["enable_thinking"]},
        }
        if "top_p" in cfg:
            body["top_p"] = cfg["top_p"]
        if "reasoning_budget" in cfg:
            body["reasoning_budget"] = cfg["reasoning_budget"]
        data = json.dumps(body).encode()
        req = urllib.request.Request(
            f"{LLAMA_URL}/v1/chat/completions",
            data=data, method="POST",
            headers={"Content-Type": "application/json"})
        if not _LLM_INFLIGHT.acquire(timeout=LLM_ACQUIRE_TIMEOUT_S):
            raise LLMBusyError("another generation is already in flight")
        self.active_requests += 1
        self.last_activity = time.time()
        try:
            with urllib.request.urlopen(req, timeout=cfg["wall_s"] + 60) as r:
                resp = json.loads(r.read())
        finally:
            self.active_requests -= 1
            self.last_activity = time.time()
            _LLM_INFLIGHT.release()
        try:
            msg = resp["choices"][0]["message"]
        except (KeyError, IndexError):
            return f"(unexpected response shape: {resp})"
        content = msg.get("content") or ""
        reasoning_sep = msg.get("reasoning_content") or ""
        if reasoning_sep and "<think>" not in content:
            content = f"<think>\n{reasoning_sep.strip()}\n</think>\n\n{content.strip()}"
        self.last_timings = resp.get("timings") or {}
        return content.strip()

    def is_idle(self):
        # Never unload while a request is in-flight (a long generation would
        # cross IDLE_TIMEOUT_S and get SIGTERM'd mid-reply).
        if LLAMA_KEEP_WARM:
            return False  # keep-warm: idle_watcher re-warms instead of unloading
        return (self.is_up()
                and self.active_requests == 0
                and (time.time() - self.last_activity) > IDLE_TIMEOUT_S)

llama = LlamaServer()

# ------------------------------------------------------------------ room state

class RoomState:
    def __init__(self):
        self.history = deque(maxlen=HISTORY_TURNS * 2)  # user+assistant pairs
        self.last_touch = 0      # most recent mention activity
        self.recent_human_msgs = deque()             # ts of human (non-bot) messages in window
        self.recent_chat_log = deque(maxlen=10)      # (sender_short, body, ts) tuples
        self.last_interject_ts = 0
        self.last_human_msg_ts = 0                   # for activity-aware idle decision

rooms = {}  # room_id -> RoomState

def touch(room_id):
    if room_id not in rooms:
        rooms[room_id] = RoomState()
    rooms[room_id].last_touch = time.time()

def recent_rooms(seconds=600):
    now = time.time()
    return [rid for rid, rs in rooms.items() if now - rs.last_touch < seconds]

def is_bot_sender(sender):
    return sender in KNOWN_BOT_MXIDS

def any_room_active(seconds):
    """True if ANY tracked room has had a human message in the last `seconds`.
    Keeps the model warm while conversations are happening."""
    cutoff = time.time() - seconds
    for rs in rooms.values():
        if rs.last_human_msg_ts >= cutoff:
            return True
    return False

# ----- Server pressure detection -----

_LAST_PRESSURE = (False, "")

def server_under_pressure():
    """Cheap check of /proc/meminfo + /proc/loadavg. Returns (bool, reason).
    Pressure = mem-used >= PRESSURE_MEM_PCT OR loadavg-1min >= ncpu*PRESSURE_LOAD_PCT/100."""
    global _LAST_PRESSURE
    if not PRESSURE_ENABLED:
        _LAST_PRESSURE = (False, "")
        return _LAST_PRESSURE
    try:
        with open("/proc/meminfo") as f:
            mi = f.read()
        mt = int(re.search(r"MemTotal:\s+(\d+)", mi).group(1))
        ma = int(re.search(r"MemAvailable:\s+(\d+)", mi).group(1))
        used_pct = 100.0 * (1.0 - ma / mt) if mt else 0
        if used_pct >= PRESSURE_MEM_PCT:
            _LAST_PRESSURE = (True, f"mem {used_pct:.0f}% >= {PRESSURE_MEM_PCT}%")
            return _LAST_PRESSURE
    except Exception:
        pass
    try:
        with open("/proc/loadavg") as f:
            la_1 = float(f.read().split()[0])
        ncpu = os.cpu_count() or 8
        thresh = ncpu * (PRESSURE_LOAD_PCT / 100.0)
        if la_1 >= thresh:
            _LAST_PRESSURE = (True, f"loadavg {la_1:.1f} >= {thresh:.1f} (ncpu={ncpu})")
            return _LAST_PRESSURE
    except Exception:
        pass
    _LAST_PRESSURE = (False, "")
    return _LAST_PRESSURE

# ------------------------------------------------------------------ mention / link normalisation

# Clients serialise a mention pill into the PLAIN body as a markdown link
#   "[exobot](https://matrix.to/#/@exobot:server) hi"
# or, less often, a bare matrix.to / matrix: URI. Convert any such mention back
# to a bare "@localpart" token so the mention-prefix logic can strip it cleanly.
_MD_MENTION_RE = re.compile(
    r"\[[^\]]*\]\("
    r"\s*(?:https?://matrix\.to/#/|matrix:u/|matrix:r/)"
    r"@?(?P<local>[A-Za-z0-9._=\-]+):[A-Za-z0-9.\-]+[^)]*"
    r"\)", re.IGNORECASE)
_BARE_MENTION_RE = re.compile(
    r"(?:https?://matrix\.to/#/|matrix:u/)"
    r"@?(?P<local>[A-Za-z0-9._=\-]+):[A-Za-z0-9.\-]+", re.IGNORECASE)

def _demote_mention_links(text):
    """Turn markdown-link / URI mention chrome in a plain body into bare
    '@localpart ' tokens, so extract_prompt sees a clean mention."""
    if not text or ("matrix.to" not in text and "matrix:" not in text):
        return text
    text = _MD_MENTION_RE.sub(lambda m: f"@{m.group('local')} ", text)
    text = _BARE_MENTION_RE.sub(lambda m: f"@{m.group('local')} ", text)
    return text

# The bot must never tag ITSELF — small models sometimes echo the bot's own
# handle (pulled from the room topic or transcript format). Scrub the bot's own
# handle from any GENERATED message (seed / revive / interject / crossbot). Tags
# for OTHER bots (the crossbot target) are left intact on purpose.
_SELF_TAG_RE = re.compile(
    r"(?:\[[^\]]*\]\([^)]*@?" + re.escape(SELF_LOCAL) + r":[^)]*\)"
    r"|https?://matrix\.to/#/@?" + re.escape(SELF_LOCAL) + r":[A-Za-z0-9.\-]+"
    r"|@" + re.escape(SELF_LOCAL) + r"(?::[A-Za-z0-9.\-]+)?)",
    re.IGNORECASE)

def _strip_self_tags(text):
    """Remove the bot's own @-mention from generated output, then tidy leftover
    whitespace / dangling punctuation so the sentence reads naturally."""
    if not text:
        return text
    text = _SELF_TAG_RE.sub(" ", text)
    text = re.sub(r"\s+([,.!?;:])", r"\1", text)
    text = re.sub(r"\s{2,}", " ", text)
    text = re.sub(r"^[\s,:;]+", "", text)
    return text.strip()

def _topic_for_prompt(topic):
    """Strip @-mention tokens (and a trailing comma) from a room topic before
    feeding it to the model, so it doesn't parrot them."""
    if not topic:
        return topic
    t = re.sub(r"\s*@[A-Za-z0-9._=\-]+(?::[A-Za-z0-9.\-]+)?[,;]?", " ", topic)
    t = re.sub(r"\s+([,.!?;:])", r"\1", t)
    return re.sub(r"\s{2,}", " ", t).strip(" ,;:")

# ------------------------------------------------------------------ mention detection

# Matches the start of a body containing the mention chrome clients emit:
#   "@<bot> hi"                  plain typed
#   "@<bot>:server hi"           full MXID
#   "<bot>: hi"                  client pill plain-text rendering
#   "<bot> (display): 1 hi"      pill with display-name + paren suffix
#   "!chat hi"                   legacy explicit prefix
# Built from SELF_LOCAL so it tracks whatever localpart the operator chose.
_MENTION_PREFIX_RE = re.compile(
    r"^[\s>]*"
    r"(?:"
    r"@?" + re.escape(SELF_LOCAL) +
    r"(?::[A-Za-z0-9.\-]+)?"
    r"(?:\s*\([^)]*\))?"
    r"(?:\s*:)?"
    r"|!chat"
    r")"
    r"\s+",
    re.IGNORECASE)

# Anywhere-in-body fallback strip (when the mention is not at the front).
_MENTION_ANY_RE = re.compile(
    r"@?" + re.escape(SELF_LOCAL) + r"(?::[A-Za-z0-9.\-]+)?(?:\s*\([^)]*\))?:?",
    re.IGNORECASE)

def extract_prompt(body, sender_mxid):
    """Returns (is_mention, cleaned_prompt). Strips ALL forms of the mention
    chrome from the front of the body."""
    if not body:
        return False, ""
    body = _demote_mention_links(body)
    body_lc = body.lower()
    # Cheap pre-filter: must mention the bot somehow.
    if SELF_LOCAL.lower() not in body_lc and not body_lc.lstrip().startswith("!chat"):
        return False, ""
    cleaned = body
    m = _MENTION_PREFIX_RE.match(cleaned)
    if m:
        cleaned = cleaned[m.end():]
    else:
        cleaned = _MENTION_ANY_RE.sub(" ", cleaned)
        if BOT_MXID:
            cleaned = cleaned.replace(BOT_MXID, " ")
    cleaned = re.sub(r"\s{2,}", " ", cleaned).strip()
    if len(cleaned) > MAX_PROMPT_CHAR:
        cleaned = cleaned[:MAX_PROMPT_CHAR] + "…"
    return True, cleaned

# ------------------------------------------------------------------ message handler

HELP_TEXT = (
    "**Modes** — prefix your prompt with one of these (or skip → defaults to `normal`):\n"
    "- `1` / `ultrafast` — greedy, 1 short line\n"
    "- `2` / `fast` — greedy, 1-2 sentences\n"
    "- `3` / `normal` — sampled, full answer _(default)_\n"
    "- `4` / `reason` — thinking + answer\n"
    "- `5` / `deepreason` — extended thinking\n"
    "\n"
    "Examples:\n"
    f"- `@{SELF_LOCAL} 1 hi`\n"
    f"- `@{SELF_LOCAL} fast capital of France?`\n"
    f"- `@{SELF_LOCAL} 4 what is 13*47?`\n"
    f"- `@{SELF_LOCAL} what is gravity?` _(implicit normal)_\n"
    "\n"
    "_Tip: pick the smallest mode that fits — speed scales with mode._"
)

def parse_mode(prompt):
    """Detect leading mode keyword. Returns (mode, stripped_prompt, is_help)."""
    p = prompt.lstrip()
    p_low = p.lower()
    if p_low in ("help", "?", "h") or p_low.startswith(("help ", "? ", "h ")):
        return None, "", True
    for kw, mode in MODE_KEYWORDS:
        if p_low.startswith(kw):
            return mode, p[len(kw):].lstrip(), False
    return DEFAULT_MODE, p, False

def handle_message(room_id, event):
    body = (event.get("content") or {}).get("body") or ""
    sender = event.get("sender", "")
    if sender == BOT_MXID:
        return  # don't reply to self
    # Always track activity — even non-mention messages — so the interjection
    # daemon and the idle-while-active rule have signal.
    if room_id not in rooms:
        rooms[room_id] = RoomState()
    state = rooms[room_id]
    short_sender = sender.split(":")[0].lstrip("@")
    state.recent_chat_log.append((short_sender, body[:200], time.time()))
    if not is_bot_sender(sender):
        state.recent_human_msgs.append(time.time())
        state.last_human_msg_ts = time.time()
    is_mention, prompt = extract_prompt(body, sender)
    if not is_mention:
        return
    # Only respond to @-mentions in allowed rooms; tags from other rooms are
    # ignored (the bot may still be a passive observer there).
    if room_id not in EXOBOT_ALLOWED_ROOMS:
        log(f"room={room_id[:12]} not in EXOBOT_ALLOWED_ROOMS — ignoring tag")
        return
    if not prompt:
        post(room_id, HELP_TEXT)
        return
    touch(room_id)
    pressed, reason = server_under_pressure()
    if pressed:
        log(f"  declining ({reason})")
        post(room_id,
             f"⏸ The server phone is under load (`{reason}`) — "
             f"I'll be back in a minute. Try again shortly.")
        return

    mode, stripped, is_help = parse_mode(prompt)
    if is_help:
        log(f"room={room_id[:12]} sender={sender} help-request")
        post(room_id, HELP_TEXT)
        return
    prompt = stripped
    # Never log the literal prompt body (privacy). A sha256 prefix is enough to
    # cross-reference a specific request without storing its content.
    pdigest = hashlib.sha256(prompt.encode("utf-8", "replace")).hexdigest()[:8]
    log(f"room={room_id[:12]} sender={sender} mode={mode} prompt_sha={pdigest} prompt_len={len(prompt)}")

    if not llama.is_up():
        post(room_id, "🔄 **Loading model** (this can take a few seconds)…")
        ok, err = llama.start()
        if not ok:
            post(room_id, f"⚠ model failed to start: `{err}`")
            return

    cfg = MODE_CONFIG[mode]
    state = rooms[room_id]
    msgs = [{"role": "system", "content": cfg["system_prompt"]}]
    # Only reason/deepreason keep conversation history — fast modes go stateless
    # so their prefill stays short.
    if mode in (MODE_REASON, MODE_DEEPREASON):
        msgs.extend(state.history)
    msgs.append({"role": "user", "content": prompt})

    try:
        with TypingKeepalive(room_id):
            reply = llama.generate(msgs, mode)
    except LLMBusyError:
        post(room_id, "⏳ Busy with another reply — give me a few seconds and try again.")
        return
    except urllib.error.HTTPError as e:
        reply = f"⚠ generate HTTP {e.code}: {e.read()[:200]}"
    except Exception as e:
        reply = f"⚠ generate failed: {e}"

    plain, html = format_reply(reply, llama.last_timings,
                               show_reasoning=cfg["show_reasoning"],
                               mode_label=mode)
    if mode in (MODE_REASON, MODE_DEEPREASON):
        clean_for_history = _THINK_RE.sub("", reply).strip()
        state.history.append({"role": "user", "content": prompt})
        state.history.append({"role": "assistant", "content": clean_for_history})

    post(room_id, plain, html)

# ------------------------------------------------------------------ idle watcher

def idle_watcher():
    while True:
        time.sleep(15)
        try:
            pressed, reason = server_under_pressure()
            if pressed and llama.is_up() and llama.active_requests == 0:
                log(f"pressure → unloading ({reason})")
                with llama.lock:
                    pass  # serialize against start/stop
                llama.stop()
                continue
            if LLAMA_KEEP_WARM:
                if not pressed and not llama.is_up():
                    ok, err = llama.start()
                    if not ok:
                        log(f"keep-warm start failed: {err}")
                continue
            with llama.lock:
                if not llama.is_idle():
                    continue
                if INTERJECT_ENABLED and any_room_active(IDLE_TIMEOUT_S):
                    continue
                log("idle timeout → unloading (no recent room activity)")
            llama.stop()
        except Exception as e:
            log(f"idle_watcher error: {e}")

# ----- Interjection daemon -----

# Plain functional prompt — heavily-quantized models echo memorable phrases.
# Don't include the room name/topic (small models read them as directives and
# steer the conversation back to the "official" topic). Just react to messages.
INTERJECT_SYSTEM_PROMPT_TMPL = (
    "You are a friendly observer in a chat room. The user message below "
    "contains the recent conversation between humans, then asks you for a "
    "reply. Read the conversation carefully and add ONE genuine short comment "
    "(1-2 sentences) — agree, joke, react, or share a small relevant thought.\n\n"
    "RULES:\n"
    "- DO NOT repeat or quote what anyone said. If you find yourself echoing "
    "their words, stop and write something fresh.\n"
    "- DO NOT prefix your reply with any name. Just write the reply text.\n"
    "- DO NOT introduce yourself or say things like 'I am here to help'.\n"
    "- If the conversation is private, sensitive, or you genuinely have nothing "
    "useful to add, output the single word: SKIP\n"
    "Keep it casual."
)

# Post-filter: zap leaked system-prompt phrases + bot-y openings.
_BOT_PHRASE_RE = re.compile(
    r"(?:^(?:i'?m\s+(?:here\s+to|just\s+here|happy\s+to|always\s+here)|"
    r"as\s+(?:a|an)\s+(?:bot|ai|assistant)|"
    r"hey\s*[!,]?\s*(?:i'?m|i\s+am)|"
    r"hello[!,]?\s+i'?m)\b[^.!?]*[.!?]?\s*)",
    re.IGNORECASE)

# Phrases the model has been observed to echo from prompts; strip anywhere.
_PROMPT_LEAK_RE = re.compile(
    r"\s*[—\-–]?\s*(?:"
    r"customer\s+service"
    r"|max\s+\d+\s+words?"
    r"|no\s+questions"
    r"|no\s+introductions?"
    r"|reply\s+casually"
    r"|in\s+one\s+short\s+sentence"
    r")\b[\s\.\!\?]*",
    re.IGNORECASE)

def _interject_room_eligible(room_id, state):
    """True if this room should be considered for interjection right now."""
    if INTERJECT_ALLOWLIST and room_id not in INTERJECT_ALLOWLIST:
        return False
    if room_id in INTERJECT_DENYLIST:
        return False
    cutoff = time.time() - INTERJECT_WINDOW_S
    while state.recent_human_msgs and state.recent_human_msgs[0] < cutoff:
        state.recent_human_msgs.popleft()
    if len(state.recent_human_msgs) < INTERJECT_TRIGGER_N:
        return False
    if time.time() - state.last_interject_ts < INTERJECT_MIN_GAP_S:
        return False
    bot_short = {m.split(":")[0].lstrip("@") for m in KNOWN_BOT_MXIDS}
    distinct = set()
    for sender_short, _body, ts in state.recent_chat_log:
        if ts < cutoff or sender_short in bot_short:
            continue
        distinct.add(sender_short)
    if len(distinct) < INTERJECT_MIN_DISTINCT:
        return False
    if state.recent_chat_log:
        last_sender, _b, _t = state.recent_chat_log[-1]
        if last_sender in bot_short:
            return False
    return True

def _interject_in(room_id, state):
    log(f"interjecting in {room_id[:18]}… "
        f"(humans={len(state.recent_human_msgs)} senders="
        f"{len({s for s,_,_ in state.recent_chat_log})})")
    if not llama.is_up():
        ok, err = llama.start()  # silent — no channel post for cold-start
        if not ok:
            log(f"  llama.start failed: {err}")
            return
    bot_handle = SELF_LOCAL
    msgs_for_ctx = []
    for sender, body, _ts in list(state.recent_chat_log)[-INTERJECT_HISTORY_MSGS:]:
        if sender == bot_handle:
            continue
        msgs_for_ctx.append(f"{sender}: {body[:200].strip()}")
    if not msgs_for_ctx:
        log("  no usable context (all bot msgs); skipping")
        return
    transcript = "\n".join(msgs_for_ctx)
    msgs = [
        {"role": "system", "content": INTERJECT_SYSTEM_PROMPT_TMPL},
        {"role": "user", "content":
            "=== RECENT MESSAGES (oldest first) ===\n"
            f"{transcript}\n"
            "=== END MESSAGES ===\n\n"
            "Now write your reply (no prefix, no quoting, no name):"},
    ]
    try:
        with TypingKeepalive(room_id):
            reply = llama.generate(msgs, MODE_INTERJECT)
    except Exception as e:
        log(f"  generate failed: {e}")
        return
    raw_reply = reply or ""
    reply = re.sub(r"<think>[\s\S]*?</think>", "", raw_reply).strip()
    reply = _THINK_OPEN_RE.sub("", reply).strip()
    if _looks_like_raw_reasoning(reply):
        _, candidate = _split_inline_reasoning(reply)
        candidate = candidate.strip() if candidate else ""
        if not candidate or _looks_like_raw_reasoning(candidate):
            log(f"  declined (raw-reasoning leak, no clean answer found): {reply[:80]!r}…")
            return
        reply = candidate
    reply = re.sub(r"^[\*_>]*\s*" + re.escape(SELF_LOCAL) + r"[:\s]*", "", reply, flags=re.IGNORECASE).strip()
    reply = _BOT_PHRASE_RE.sub("", reply).strip()
    reply = _PROMPT_LEAK_RE.sub("", reply).strip().rstrip("—-–,").strip()
    reply = re.sub(r"^[a-zA-Z0-9_\-\.]{2,30}:\s+", "", reply, count=1).strip()
    reply = reply.strip('"“”\'')
    reply = _strip_self_tags(reply)
    if re.fullmatch(r"[\(\[\*_\s]*skip[\)\]\*_\s\.\!]*", reply, re.IGNORECASE):
        log(f"  declined (skip marker: {reply!r})")
        return
    if len(reply) < 5:
        log(f"  declined (too short: {reply!r})")
        return
    if _looks_like_raw_reasoning(reply):
        log(f"  declined (raw-reasoning survived post-strip): {reply[:80]!r}…")
        return
    if len(reply) > 280:
        reply = reply[:260].rstrip() + "…"
    post(room_id, reply)
    state.last_interject_ts = time.time()
    # Clear the counter so the same conversation can't keep re-triggering.
    state.recent_human_msgs.clear()
    log(f"  → {reply!r}")

def interject_watcher():
    while True:
        time.sleep(30)
        if not INTERJECT_ENABLED:
            continue
        try:
            pressed, reason = server_under_pressure()
            if pressed:
                continue  # silent skip under load
            for room_id, state in list(rooms.items()):
                if not _interject_room_eligible(room_id, state):
                    continue
                _interject_in(room_id, state)
        except Exception as e:
            log(f"interject_watcher error: {e}")

# ----- Dry-room seed daemon -----

SEED_SYSTEM_PROMPT = (
    "Drop a casual conversation starter for this chat room. ONE sentence, max "
    "18 words. No questions to admin, no 'how is everyone'. Spark interest tied "
    "to the room's topic."
)

def _get_room_topic(room_id):
    try:
        path = (f"/_matrix/client/v3/rooms/{urllib.parse.quote(room_id)}"
                f"/state/m.room.topic/")
        return (_matrix("GET", path).get("topic") or "").strip()
    except Exception:
        return ""

def _get_room_name(room_id):
    try:
        path = (f"/_matrix/client/v3/rooms/{urllib.parse.quote(room_id)}"
                f"/state/m.room.name/")
        return (_matrix("GET", path).get("name") or "").strip()
    except Exception:
        return ""

def _space_is_dry():
    """True if NOT A SINGLE candidate room has had a human message in the last
    SEED_DRY_THRESHOLD_S — the seed daemon fires only when the space is asleep."""
    cutoff = time.time() - SEED_DRY_THRESHOLD_S
    for rid in SEED_CANDIDATE_ROOMS:
        state = rooms.get(rid)
        if state and state.last_human_msg_ts > cutoff:
            return False, rid
    return True, None

def _seed_room(room_id):
    name = _get_room_name(room_id) or room_id[:18]
    topic = _topic_for_prompt(_get_room_topic(room_id)) or "general chat"
    log(f"seeding {name} (topic={topic[:60]!r})")
    if not llama.is_up():
        ok, err = llama.start()
        if not ok:
            log(f"  llama.start failed: {err}")
            return
    msgs = [
        {"role": "system", "content": SEED_SYSTEM_PROMPT},
        {"role": "user", "content":
            f"Room: {name}\nTopic: {topic}\n\nPost ONE engagement-starter sentence."},
    ]
    try:
        with TypingKeepalive(room_id):
            reply = llama.generate(msgs, MODE_FAST)
    except Exception as e:
        log(f"  generate failed: {e}")
        return
    reply = re.sub(r"<think>[\s\S]*?</think>", "", reply or "").strip()
    reply = re.sub(r"^[\*_>]*\s*" + re.escape(SELF_LOCAL) + r"[:\s]*", "", reply, flags=re.IGNORECASE).strip()
    reply = _BOT_PHRASE_RE.sub("", reply).strip()
    reply = _PROMPT_LEAK_RE.sub("", reply).strip().rstrip("—-–,").strip()
    reply = reply.strip('"“”\'')
    reply = _strip_self_tags(reply)
    if len(reply) < 8:
        log(f"  seed declined (too short: {reply!r})")
        return
    if len(reply) > 300:
        reply = reply[:280].rstrip() + "…"
    post(room_id, reply)
    log(f"  → {reply!r}")

# ----- Cross-bot chat daemon -----

# Per-round system prompts fight a quantized model's tendency to converge on a
# single topic across rounds. {target} = the companion bot's short handle.
CROSSBOT_SYSTEM_PROMPTS = {
    1: (
        "You are in a public chat room. Pick ONE concrete topic from the recent "
        "chat — name it explicitly — and ask @{target} a short specific question "
        "about it. 25 words max, single sentence. Do NOT ask 'what if'. Do NOT "
        "ask about real-time, AI, or bots in general. Don't greet, don't "
        "introduce yourself."
    ),
    2: (
        "You are in a public chat room. {target} just replied to you. Pick ONE "
        "specific claim or word from {target}'s last message, then respond with "
        "a short reaction or counter-point — NOT another open-ended question. "
        "25 words max. Don't repeat your previous message. Don't start with "
        "'What if'."
    ),
    3: (
        "The conversation with {target} has gone two rounds. Now pivot: "
        "introduce a completely new, concrete topic (a place, a person, a "
        "real-world event, a hobby, a food, a game) and ask {target} something "
        "specific about it. 25 words max. Avoid topics from earlier rounds."
    ),
}
# Topic-seed pool to break a quantized model out of self-similar convergence.
_CROSSBOT_TOPIC_SEEDS = [
    "favourite food", "movies you would watch this weekend",
    "the last song stuck in your head", "rainy afternoon plans",
    "a city you would love to visit", "an old book worth re-reading",
    "an underrated TV show", "a small habit that improves your day",
    "best instant snack", "a piece of tech you wish existed",
    "a memorable street market", "monsoon vs summer",
    "best coffee or tea routine", "an unsolved mystery",
    "your dream board-game night", "a hobby you want to pick up",
]

def _too_similar(a: str, b: str, threshold: float = 0.65) -> bool:
    """Cheap Jaccard word-overlap check between two short messages — used to cut
    off a cross-bot session when the model is converging on the same question."""
    if not a or not b:
        return False

    def toks(s):
        s = re.sub(r"[^a-z0-9 ]+", " ", s.lower())
        return {w for w in s.split() if len(w) > 3}
    A, B = toks(a), toks(b)
    if not A or not B:
        return False
    inter = len(A & B)
    union = len(A | B)
    return union and (inter / union) >= threshold

def _wait_for_reply_from(target_mxid, room_id, after_ts, max_wait_s):
    """Poll the room's recent messages until target_mxid posts something after
    `after_ts`. Returns the message body or None on timeout."""
    deadline = time.time() + max_wait_s
    while time.time() < deadline:
        try:
            params = urllib.parse.urlencode({"dir": "b", "limit": "10"})
            resp = _matrix("GET",
                f"/_matrix/client/v3/rooms/{urllib.parse.quote(room_id)}/messages?{params}")
            for ev in resp.get("chunk", []):
                if ev.get("type") != "m.room.message":
                    continue
                if ev.get("sender", "") != target_mxid:
                    continue
                if ev.get("origin_server_ts", 0) <= after_ts * 1000:
                    continue
                return (ev.get("content") or {}).get("body") or ""
        except Exception as e:
            log(f"  wait_for_reply error: {e}")
        time.sleep(3)
    return None

def _run_cross_bot_chat():
    if not CROSSBOT_ROOM_ID:
        log("crossbot: CROSSBOT_ROOM_ID unset — skipping")
        return
    if not CROSSBOT_TARGETS:
        log("crossbot: CROSSBOT_TARGETS empty — skipping")
        return
    state = rooms.get(CROSSBOT_ROOM_ID)
    if state is None:
        log("crossbot: room not in cache yet — skipping")
        return
    if state.last_human_msg_ts and (time.time() - state.last_human_msg_ts) < CROSSBOT_QUIET_S:
        secs = int(time.time() - state.last_human_msg_ts)
        log(f"crossbot: skipping — human msg {secs}s ago (need {CROSSBOT_QUIET_S}s quiet)")
        return
    last = getattr(_run_cross_bot_chat, "_last_target", None)
    if last and last in CROSSBOT_TARGETS and len(CROSSBOT_TARGETS) > 1:
        choices = [t for t in CROSSBOT_TARGETS if t != last]
        target = _random.choice(choices)
    else:
        target = _random.choice(CROSSBOT_TARGETS)
    _run_cross_bot_chat._last_target = target
    target_short = target.split(":")[0].lstrip("@")
    seed_topic = _random.choice(_CROSSBOT_TOPIC_SEEDS)
    log(f"crossbot: starting {CROSSBOT_ROUNDS}-round chat with {target_short} in "
        f"{CROSSBOT_ROOM_ID[:18]}… (seed={seed_topic!r})")
    if not llama.is_up():
        ok, err = llama.start()
        if not ok:
            log(f"  llama.start failed: {err}")
            return
    last_question = None
    last_reply = None
    for round_n in range(CROSSBOT_ROUNDS):
        msgs_for_ctx = []
        for sender, body, _ts in list(state.recent_chat_log)[-8:]:
            msgs_for_ctx.append(f"{sender}: {body[:200].strip()}")
        transcript = "\n".join(msgs_for_ctx) if msgs_for_ctx else "(no recent context)"

        sys_template = CROSSBOT_SYSTEM_PROMPTS.get(round_n + 1, CROSSBOT_SYSTEM_PROMPTS[3])
        sys_prompt = sys_template.format(target=target_short)

        if round_n == 0:
            user_prompt = (
                f"Forced topic: {seed_topic}.\n"
                f"Recent chat (for tone only):\n{transcript}\n\n"
                f"Write ONE short message to @{target_short} about \"{seed_topic}\". "
                f"Start with @{target_short}:"
            )
        else:
            forbid = f"\nDo NOT repeat or paraphrase: {last_question!r}" if last_question else ""
            user_prompt = (
                f"Last thing {target_short} said:\n  {(last_reply or '')[:300]}\n\n"
                f"Recent chat (for tone only):\n{transcript}\n\n"
                f"Write your reply to @{target_short}. Be specific and react to "
                f"the words above — don't ask another open-ended question."
                f"{forbid}\nStart with @{target_short}:"
            )

        gen_msgs = [
            {"role": "system", "content": sys_prompt},
            {"role": "user", "content": user_prompt},
        ]
        try:
            with TypingKeepalive(CROSSBOT_ROOM_ID):
                question = llama.generate(gen_msgs, MODE_CROSSBOT)
        except Exception as e:
            log(f"  generate failed (round {round_n+1}): {e}")
            return
        question = re.sub(r"<think>[\s\S]*?</think>", "", question or "").strip()
        question = re.sub(r"^[\*_>]*\s*" + re.escape(SELF_LOCAL) + r"[:\s]*", "", question, flags=re.IGNORECASE).strip()
        question = _BOT_PHRASE_RE.sub("", question).strip()
        question = _PROMPT_LEAK_RE.sub("", question).strip().rstrip("—-–,").strip()
        question = re.sub(r"^[a-zA-Z0-9_\-\.]{2,30}:\s+", "", question, count=1).strip()
        question = question.strip('"“”\'')
        question = _strip_self_tags(question)   # drop self-tags; target tag re-added below
        if len(question) < 5:
            log(f"  crossbot round {round_n+1}: too short, aborting")
            return
        if last_question and _too_similar(last_question, question):
            log(f"  crossbot round {round_n+1}: too similar to previous question — aborting session")
            return
        if f"@{target_short}" not in question.lower():
            question = f"@{target_short} {question}"
        if len(question) > 280:
            question = question[:260].rstrip() + "…"
        post(CROSSBOT_ROOM_ID, question)
        log(f"  round {round_n+1} → {question!r}")
        last_question = question
        sent_ts = time.time()
        reply = _wait_for_reply_from(target, CROSSBOT_ROOM_ID, sent_ts, CROSSBOT_REPLY_WAIT_S)
        if reply is None:
            log(f"  round {round_n+1}: no reply from {target_short} within {CROSSBOT_REPLY_WAIT_S}s — aborting")
            return
        last_reply = reply
        log(f"  round {round_n+1} ← {reply[:80]!r}")
        time.sleep(8)

def cross_bot_watcher():
    if not CROSSBOT_ENABLED:
        log("cross_bot_watcher: disabled by env")
        return
    log(f"cross_bot_watcher: first run in {CROSSBOT_FIRST_DELAY_S}s, "
        f"interval={CROSSBOT_INTERVAL_S}s, room={CROSSBOT_ROOM_ID[:18]}, "
        f"targets={[t.split(':')[0] for t in CROSSBOT_TARGETS]}")
    time.sleep(CROSSBOT_FIRST_DELAY_S)
    while True:
        try:
            pressed, reason = server_under_pressure()
            if pressed:
                log(f"cross_bot_watcher: skipping ({reason})")
            else:
                _run_cross_bot_chat()
        except Exception as e:
            log(f"cross_bot_watcher error: {e}")
        time.sleep(CROSSBOT_INTERVAL_S)

def seed_watcher():
    """Every SEED_INTERVAL_S, IF the entire space has been dry for
    SEED_DRY_THRESHOLD_S, seed the general room + SEED_PICK_K random other rooms
    with engagement starters."""
    if not SEED_ENABLED:
        log("seed_watcher: disabled by env")
        return
    log(f"seed_watcher: first run in {SEED_FIRST_DELAY_S}s, interval={SEED_INTERVAL_S}s, "
        f"space-dry-threshold={SEED_DRY_THRESHOLD_S}s")
    time.sleep(SEED_FIRST_DELAY_S)
    while True:
        try:
            pressed, reason = server_under_pressure()
            if pressed:
                log(f"seed_watcher: skipping ({reason})")
                time.sleep(SEED_INTERVAL_S)
                continue
            dry, active_rid = _space_is_dry()
            if not dry:
                log(f"seed_watcher: space active (recent msg in {active_rid[:18]}…) — skipping")
                time.sleep(SEED_INTERVAL_S)
                continue
            seeds = []
            if SEED_GENERAL_ROOM_ID:
                seeds.append(SEED_GENERAL_ROOM_ID)
            pool = [r for r in SEED_CANDIDATE_ROOMS if r != SEED_GENERAL_ROOM_ID]
            _random.shuffle(pool)
            for r in pool[:SEED_PICK_K]:
                seeds.append(r)
            log(f"seed_watcher: space is dry — seeding {len(seeds)} rooms")
            for rid in seeds:
                _seed_room(rid)
                time.sleep(60)
        except Exception as e:
            log(f"seed_watcher error: {e}")
        time.sleep(SEED_INTERVAL_S)

# ----- Conversation revival daemon -----

REVIVE_SYSTEM_PROMPT = (
    "You are a casual chat participant in a small private community. Read the "
    "recent messages below and add a thoughtful reply that fits the "
    "conversation. Be friendly, on-topic, 1-3 sentences. Do not introduce "
    "yourself, do not narrate your reasoning out loud, do not echo previous "
    "messages back. Just respond naturally."
)

def _fetch_recent_messages(room_id, limit):
    """Pull last `limit` m.room.message events from the server. Returns list of
    (sender_mxid, body, ts_ms) ordered oldest->newest; m.text only."""
    try:
        path = (f"/_matrix/client/v3/rooms/{urllib.parse.quote(room_id)}"
                f"/messages?dir=b&limit={max(limit*4, 20)}")
        resp = _matrix("GET", path, timeout=20)
    except Exception as e:
        log(f"_fetch_recent_messages({room_id[:18]}…) failed: {e}")
        return []
    out = []
    for ev in (resp.get("chunk") or []):
        if ev.get("type") != "m.room.message":
            continue
        c = ev.get("content") or {}
        if c.get("msgtype") != "m.text":
            continue
        if (c.get("m.relates_to") or {}).get("rel_type") == "m.replace":
            continue
        sender = ev.get("sender") or ""
        body = (c.get("body") or "").strip()
        ts = int(ev.get("origin_server_ts") or 0)
        if not sender or not body:
            continue
        out.append((sender, body, ts))
    out.reverse()  # /messages?dir=b returns newest-first; flip to oldest-first
    return out[-limit:]

def _revive_reply(room_id, msgs):
    """Build conversation context from `msgs` and post a contextual reply."""
    if not llama.is_up():
        ok, err = llama.start()
        if not ok:
            log(f"  revive llama.start failed: {err}")
            return
    bot_handle = SELF_LOCAL
    transcript_lines = []
    for sender, body, _ts in msgs:
        handle = sender.split(":")[0].lstrip("@")
        if handle == bot_handle:
            continue
        transcript_lines.append(f"{handle}: {body[:240].strip()}")
    if not transcript_lines:
        log("  revive: no usable context (all bot); skipping")
        return
    transcript = "\n".join(transcript_lines)
    name = _get_room_name(room_id) or room_id[:18]
    topic = _topic_for_prompt(_get_room_topic(room_id)) or ""
    user_prompt = (
        f"Room: {name}\nTopic: {topic}\n\n"
        f"=== RECENT MESSAGES (oldest first) ===\n"
        f"{transcript}\n"
        f"=== END MESSAGES ===\n\n"
        f"Now write your reply (no prefix, no quoting, no name, 1-3 sentences):"
    )
    llama_msgs = [
        {"role": "system", "content": REVIVE_SYSTEM_PROMPT},
        {"role": "user", "content": user_prompt},
    ]
    try:
        with TypingKeepalive(room_id):
            reply = llama.generate(llama_msgs, MODE_REVIVE)
    except Exception as e:
        log(f"  revive generate failed: {e}")
        return
    raw = reply or ""
    reply = re.sub(r"<think>[\s\S]*?</think>", "", raw).strip()
    reply = _THINK_OPEN_RE.sub("", reply).strip()
    if _looks_like_raw_reasoning(reply):
        _, answer = _split_inline_reasoning(reply)
        reply = (answer or "").strip()
    reply = re.sub(r"^[\*_>]*\s*" + re.escape(SELF_LOCAL) + r"[:\s]*", "", reply, flags=re.IGNORECASE).strip()
    reply = _BOT_PHRASE_RE.sub("", reply).strip()
    reply = _PROMPT_LEAK_RE.sub("", reply).strip().rstrip("—-–,").strip()
    reply = re.sub(r"^[a-zA-Z0-9_\-\.]{2,30}:\s+", "", reply, count=1).strip()
    reply = reply.strip('"“”\'')
    reply = _strip_self_tags(reply)
    if re.fullmatch(r"[\(\[\*_\s]*skip[\)\]\*_\s\.\!]*", reply, re.IGNORECASE):
        log(f"  revive declined (skip marker: {reply!r})")
        return
    if len(reply) < 8:
        log(f"  revive declined (too short: {reply!r})")
        return
    if len(reply) > 600:
        reply = reply[:580].rstrip() + "…"
    post(room_id, reply)
    log(f"  revive → {reply[:80]!r}")

def revive_watcher():
    """Every REVIVE_INTERVAL_S, pick a random room from the candidate pool, pull
    recent messages, post a contextual reply. Skips active rooms, bot-only
    history, and pressured server."""
    if not REVIVE_ENABLED:
        log("revive_watcher: disabled by env")
        return
    pool = REVIVE_CANDIDATE_ROOMS or (
        EXOBOT_ALLOWED_ROOMS - {CROSSBOT_ROOM_ID} if CROSSBOT_ROOM_ID else EXOBOT_ALLOWED_ROOMS
    )
    pool = {r for r in pool if r}
    if not pool:
        log("revive_watcher: empty pool — disabled")
        return
    log(f"revive_watcher: first run in {REVIVE_FIRST_DELAY_S}s, interval={REVIVE_INTERVAL_S}s, "
        f"pool={len(pool)} rooms, history={REVIVE_HISTORY_MSGS}, quiet>={REVIVE_QUIET_S}s")
    time.sleep(REVIVE_FIRST_DELAY_S)
    while True:
        try:
            pressed, reason = server_under_pressure()
            if pressed:
                log(f"revive_watcher: skipping ({reason})")
                time.sleep(REVIVE_INTERVAL_S)
                continue
            rid = _random.choice(list(pool))
            msgs = _fetch_recent_messages(rid, REVIVE_HISTORY_MSGS)
            if not msgs:
                log(f"revive_watcher: no recent messages in {rid[:18]}…; skip")
                time.sleep(REVIVE_INTERVAL_S)
                continue
            last_ts_s = msgs[-1][2] / 1000.0
            now_s = time.time()
            if now_s - last_ts_s < REVIVE_QUIET_S:
                log(f"revive_watcher: {rid[:18]}… active "
                    f"({int(now_s - last_ts_s)}s ago, need {REVIVE_QUIET_S}s); skip")
                time.sleep(REVIVE_INTERVAL_S)
                continue
            human_count = sum(1 for s, _, _ in msgs if s not in KNOWN_BOT_MXIDS)
            if human_count == 0:
                log(f"revive_watcher: {rid[:18]}… history is bot-only; skip")
                time.sleep(REVIVE_INTERVAL_S)
                continue
            log(f"revive_watcher: reviving {rid[:18]}… "
                f"(last msg {int((now_s - last_ts_s)/60)}min ago, "
                f"history={len(msgs)} msgs, humans={human_count})")
            _revive_reply(rid, msgs)
        except Exception as e:
            log(f"revive_watcher error: {e}")
        time.sleep(REVIVE_INTERVAL_S)

# ------------------------------------------------------------------ sync loop

def initial_sync():
    try:
        resp = _matrix("GET", "/_matrix/client/v3/sync?timeout=0", timeout=10)
        return resp.get("next_batch", "")
    except Exception as e:
        log(f"initial sync failed: {e}")
        return ""

def process_sync(resp):
    # Only auto-accept invites to allowed rooms; reject everything else. Empty
    # EXOBOT_ALLOWED_ROOMS = reject all (fail-closed).
    invites = (resp.get("rooms") or {}).get("invite") or {}
    for room_id in invites.keys():
        if room_id not in EXOBOT_ALLOWED_ROOMS:
            log(f"invite → REJECTING (not in EXOBOT_ALLOWED_ROOMS): {room_id}")
            try:
                _matrix("POST", f"/_matrix/client/v3/rooms/{urllib.parse.quote(room_id)}/leave", {})
            except Exception as e:
                log(f"reject_invite failed: {e}")
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
    since = initial_sync()
    log(f"sync start; since_len={len(since)}")
    backoff = 2
    while True:
        try:
            params = urllib.parse.urlencode({"timeout": 25000, "since": since})
            resp = _matrix("GET", f"/_matrix/client/v3/sync?{params}", timeout=35)
            since = resp.get("next_batch", since)
            backoff = 2
            process_sync(resp)
        except urllib.error.HTTPError as e:
            log(f"sync http {e.code}: {e.reason}")
            time.sleep(backoff)
            backoff = min(backoff * 2, 60)
        except Exception as e:
            log(f"sync error: {e}")
            time.sleep(backoff)
            backoff = min(backoff * 2, 60)

# ------------------------------------------------------------------ main

def _preflight():
    """Fail loud + early on the BYO requirements + identity, with guidance.
    The install step also checks these, but a direct run should be clear too."""
    missing = []
    if not BOT_TOKEN:
        missing.append("EXOBOT_TOKEN (the bot's Matrix access token — keep it in a 0600 secrets file)")
    if not BOT_MXID:
        missing.append("EXOBOT_MXID (e.g. @exobot:your-matrix-server)")
    if not LLAMA_BIN:
        missing.append("LLAMA_SERVER_BIN (path to YOUR llama.cpp llama-server build)")
    elif not os.path.exists(LLAMA_BIN) and not PROOT_DISTRO:
        # When running directly we can check the path; under proot the binary
        # lives inside the userland filesystem, so skip the host-side check.
        missing.append(f"LLAMA_SERVER_BIN points at a missing file: {LLAMA_BIN}")
    if not MODEL_PATH:
        missing.append("MODEL_PATH (path to YOUR GGUF model file)")
    if missing:
        log("FATAL — required configuration is missing:")
        for m in missing:
            log(f"  - {m}")
        log("This bot is BYO: you supply your own llama-server binary + GGUF model.")
        log("See docs/CHATBOTS.md and scripts/steps/81-install-exobot.sh.")
        raise SystemExit(2)

def main():
    _preflight()
    log(f"booting as {BOT_MXID}; hs={HS_URL}; model={MODEL_PATH}")
    log(f"  llama_bin={LLAMA_BIN} proot={PROOT_DISTRO or '(direct)'} port={LLAMA_PORT}")
    log(f"  idle_timeout={IDLE_TIMEOUT_S}s keep_warm={LLAMA_KEEP_WARM} · "
        f"pressure: mem>={PRESSURE_MEM_PCT}% load>={PRESSURE_LOAD_PCT}%")
    log(f"  allowed_rooms={len(EXOBOT_ALLOWED_ROOMS)}")
    log(f"  interject: enabled={INTERJECT_ENABLED} trig={INTERJECT_TRIGGER_N}/"
        f"{INTERJECT_WINDOW_S}s gap={INTERJECT_MIN_GAP_S}s "
        f"allowlist={len(INTERJECT_ALLOWLIST)} denylist={len(INTERJECT_DENYLIST)}")
    log(f"  seed: enabled={SEED_ENABLED} interval={SEED_INTERVAL_S}s "
        f"dry_threshold={SEED_DRY_THRESHOLD_S}s pick_k={SEED_PICK_K} "
        f"general={SEED_GENERAL_ROOM_ID[:18] if SEED_GENERAL_ROOM_ID else 'unset'}")
    log(f"  crossbot: enabled={CROSSBOT_ENABLED} interval={CROSSBOT_INTERVAL_S}s "
        f"rounds={CROSSBOT_ROUNDS} targets={len(CROSSBOT_TARGETS)} "
        f"room={CROSSBOT_ROOM_ID[:18] if CROSSBOT_ROOM_ID else 'unset'}")
    log(f"  revive: enabled={REVIVE_ENABLED} interval={REVIVE_INTERVAL_S}s "
        f"history={REVIVE_HISTORY_MSGS} quiet={REVIVE_QUIET_S}s")
    threading.Thread(target=idle_watcher, daemon=True).start()
    threading.Thread(target=interject_watcher, daemon=True).start()
    threading.Thread(target=seed_watcher, daemon=True).start()
    threading.Thread(target=cross_bot_watcher, daemon=True).start()
    threading.Thread(target=revive_watcher, daemon=True).start()
    try:
        sync_loop()
    except KeyboardInterrupt:
        log("shutdown (SIGINT)")
        llama.stop()


if __name__ == "__main__":
    main()
