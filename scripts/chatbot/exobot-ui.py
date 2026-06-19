#!/usr/bin/env python3
"""exobot-ui — a minimal Gradio chat UI in front of the EXISTING exobot
llama-server (the same on-device llama.cpp /v1/chat/completions endpoint the
Matrix bot uses). This loads NO second model; it is a thin OpenAI-compatible
client that STREAMS tokens from the resident llama-server.

OPTIONAL: this web UI is gated behind EXOBOT_UI (default false). It is only
useful if you also run the exobot Matrix bot (which manages the llama-server
lifecycle) — this process is a pure client and cannot spawn the model itself.

Served on loopback (default 127.0.0.1:9114) and reverse-proxied by Caddy at a
hostname of your choosing (e.g. ai.${DOMAIN}). It carries NO native auth: gate
it at the Cloudflare edge (Cloudflare Access) and/or with the optional
Matrix-SSO gateway in its Caddy vhost — same model as SearXNG. Because the app
is mounted at the subdomain root, root_path is "".

If LLAMA_KEEP_WARM=false on the Matrix bot, llama-server idle-unloads its model;
the first request after idle reloads it and may answer 503 / connection-refused
for a few seconds. We surface a "waking up…" state and retry with backoff.

Runtime: python3 + gradio (pip-installed INSIDE the proot userland, where the
gradio dependency is acceptable). Outbound HTTP to the llama-server is stdlib
urllib only. Supervised by scripts/steps/81-install-exobot.sh.

Env (all optional; sane loopback defaults):
  EXOBOT_UI_HOST        bind address                   (default 127.0.0.1)
  EXOBOT_UI_PORT        bind port                      (default 9114)
  EXOBOT_UI_ROOT_PATH   Gradio root_path               (default "" = subdomain root)
  LLAMA_URL             llama-server base URL          (default http://127.0.0.1:8081)
  LLAMA_MAX_TOKENS      per-reply decode ceiling       (default 400)
  LLAMA_TEMPERATURE     sampling temperature           (default 0.6)
  LLAMA_WALL_S          per-request wall-clock cap (s)  (default 180)
  EXOBOT_UI_TITLE       page title                     (default "Self-hosted AI")
  EXOBOT_UI_SYSTEM      system prompt override
  EXOBOT_UI_DEBUG       surface tracebacks (default off)
  EXOBOT_UI_MAX_PROMPT_BYTES  input byte cap           (default 8192)
"""
import json
import os
import re
import time
import urllib.error
import urllib.request

import gradio as gr

# ------------------------------------------------------------------ config
HOST = os.environ.get("EXOBOT_UI_HOST", "127.0.0.1")
PORT = int(os.environ.get("EXOBOT_UI_PORT", "9114"))
# Mounted at the SUBDOMAIN ROOT, so root_path must be EMPTY, not "/". Gradio 6.x
# with root_path="/" 307-redirects / -> // and emits protocol-relative //asset
# URLs that break the SPA. "" = clean root.
ROOT_PATH = os.environ.get("EXOBOT_UI_ROOT_PATH", "")
LLAMA_URL = os.environ.get("LLAMA_URL", "http://127.0.0.1:8081").rstrip("/")

MAX_TOKENS = int(os.environ.get("LLAMA_MAX_TOKENS", "400"))
TEMPERATURE = float(os.environ.get("LLAMA_TEMPERATURE", "0.6"))
WALL_S = int(os.environ.get("LLAMA_WALL_S", "180"))

TITLE = os.environ.get("EXOBOT_UI_TITLE", "Self-hosted AI")

# Do NOT surface backend tracebacks / internal paths to authenticated members.
# show_error defaults OFF; set EXOBOT_UI_DEBUG=1 for local debugging.
UI_DEBUG = os.environ.get("EXOBOT_UI_DEBUG", "").lower() in ("1", "true", "yes")
# Hard cap on the incoming prompt so a member can't pin the single-threaded SoC
# / RAM with a multi-MB request. Decode length is already bounded by MAX_TOKENS
# + WALL_S; this only bounds the INPUT we encode.
MAX_PROMPT_BYTES = int(os.environ.get("EXOBOT_UI_MAX_PROMPT_BYTES", str(8 * 1024)))

# Slim system message (override via EXOBOT_UI_SYSTEM).
SYSTEM_PROMPT = os.environ.get(
    "EXOBOT_UI_SYSTEM",
    "You are a helpful self-hosted assistant; answer briefly, clearly, "
    "and only what is asked.",
)

# Idle-unload handling: the first request after idle reloads the model and may
# briefly 503 / refuse the connection. Retry with backoff while showing a
# waking-up state.
WAKE_RETRIES = int(os.environ.get("EXOBOT_UI_WAKE_RETRIES", "12"))
WAKE_BACKOFF_S = float(os.environ.get("EXOBOT_UI_WAKE_BACKOFF_S", "2.5"))
WAKING_MSG = "_Waking the model up… (it idle-unloads after a while). One moment._"

# Two reply modes (UI toggle).
#   Text — stateless single-shot: only the current question is sent → fastest.
#   Chat — the full conversation history is sent → the model remembers context.
MODE_TEXT = "⚡ Text — fast, single questions"
MODE_CHAT = "💬 Chat — remembers the conversation"


def log(msg):
    print(f"[{time.strftime('%H:%M:%SZ', time.gmtime())}] {msg}", flush=True)


# ------------------------------------------------------------------ llama-server client
def _build_messages(message, history):
    """Translate Gradio's messages-format history into the OpenAI-style
    `messages` list the llama-server /v1/chat/completions endpoint expects."""
    msgs = [{"role": "system", "content": SYSTEM_PROMPT}]
    for turn in history or []:
        role = turn.get("role")
        content = turn.get("content")
        if role in ("user", "assistant") and isinstance(content, str) and content:
            msgs.append({"role": role, "content": content})
    msgs.append({"role": "user", "content": message})
    return msgs


# <think>…</think> stripping — usually a no-op with enable_thinking=False below;
# kept as a defensive guard so a stray block never reaches the user mid-stream.
_THINK_RE = re.compile(r"<think>[\s\S]*?</think>", re.I)
_THINK_OPEN_RE = re.compile(r"<think>[\s\S]*$", re.I)


def _strip_think(text):
    t = _THINK_RE.sub("", text)
    t = _THINK_OPEN_RE.sub("", t)
    return t.lstrip()


def _stream_once(messages):
    """Open a STREAMING /v1/chat/completions request to the existing
    llama-server and yield assistant content deltas as they arrive. Raises
    urllib.error.URLError / HTTPError on transport failure so the caller can
    distinguish an idle-unload (503 / connection refused) from a real error."""
    body = {
        "messages": messages,
        "temperature": TEMPERATURE,
        "max_tokens": MAX_TOKENS,
        "cache_prompt": True,
        "t_max_predict_ms": WALL_S * 1000,
        "stream": True,
        # Direct answers — skip the model's <think> reasoning so web chat stays
        # snappy (the Matrix bot keeps its own deep-reason modes).
        "chat_template_kwargs": {"enable_thinking": False},
    }
    data = json.dumps(body).encode()
    req = urllib.request.Request(
        f"{LLAMA_URL}/v1/chat/completions",
        data=data, method="POST",
        headers={"Content-Type": "application/json",
                 "Accept": "text/event-stream"})
    with urllib.request.urlopen(req, timeout=WALL_S + 60) as r:
        for raw in r:               # iterate the SSE stream line by line
            line = raw.decode("utf-8", "replace").strip()
            if not line or not line.startswith("data:"):
                continue
            payload = line[5:].strip()
            if payload == "[DONE]":
                return
            try:
                chunk = json.loads(payload)
                delta = chunk["choices"][0]["delta"]
            except (ValueError, KeyError, IndexError, TypeError):
                continue
            piece = delta.get("content") or ""
            if not piece and delta.get("reasoning_content"):
                piece = delta["reasoning_content"]
            if piece:
                yield piece


def _is_idle_unload(exc):
    """True if the exception looks like the llama-server being idle-unloaded /
    not yet listening (503/502/504 or connection refused) rather than a hard
    error worth surfacing."""
    if isinstance(exc, urllib.error.HTTPError):
        return exc.code in (502, 503, 504)
    if isinstance(exc, urllib.error.URLError):
        return True
    return False


def chat(message, history, mode=MODE_TEXT):
    """Gradio ChatInterface fn. Generator: streams the reply token-by-token. If
    the model is briefly unavailable (reloading) it yields a waking-up
    placeholder and retries with backoff before giving up."""
    message = (message or "").strip()
    if not message:
        yield "Please type a message."
        return

    # Reject an oversized prompt before encoding so a member cannot pin the SoC.
    if len(message.encode("utf-8", "ignore")) > MAX_PROMPT_BYTES:
        yield (f"Your message is too long (limit ~{MAX_PROMPT_BYTES // 1024} KB). "
               "Please shorten it and send again.")
        return

    use_history = (mode == MODE_CHAT)
    messages = _build_messages(message, history if use_history else [])
    shown_waking = False
    last_exc = None

    for attempt in range(WAKE_RETRIES + 1):
        try:
            acc = ""
            for piece in _stream_once(messages):
                acc += piece
                shown = _strip_think(acc)
                if shown:
                    yield shown
            final = _strip_think(acc).strip()
            log(f"reply ok (attempt {attempt + 1}, {len(acc)} chars streamed)")
            yield final or "(empty response)"
            return
        except Exception as exc:  # noqa: BLE001 — classify below
            last_exc = exc
            if _is_idle_unload(exc) and attempt < WAKE_RETRIES:
                if not shown_waking:
                    log(f"llama-server waking up ({exc!r}); retrying")
                    shown_waking = True
                    yield WAKING_MSG
                time.sleep(WAKE_BACKOFF_S)
                continue
            break

    log(f"giving up after retries: {last_exc!r}")
    yield (
        "The model didn't respond in time — it may be reloading. "
        "Please send your message again in a few seconds."
    )


# ------------------------------------------------------------------ theme / css
# A neutral dark theme. All .set() variables below are valid tokens for the
# installed gradio; restyle freely.
EXO_THEME = gr.themes.Base(primary_hue="indigo", neutral_hue="slate").set(
    body_background_fill="#0a0d1e",
    body_background_fill_dark="#0a0d1e",
    body_text_color="#eef1ff",
    body_text_color_subdued="#9aa3c4",
    background_fill_primary="#141936",
    background_fill_secondary="#10142e",
    block_background_fill="#141936",
    block_label_background_fill="#141936",
    block_title_text_color="#eef1ff",
    block_border_color="rgba(255,255,255,0.07)",
    block_radius="18px",
    border_color_primary="rgba(255,255,255,0.07)",
    input_background_fill="#10142e",
    input_border_color="rgba(255,255,255,0.12)",
    input_placeholder_color="#6b7398",
    button_primary_background_fill="linear-gradient(135deg,#5f8cff,#8a7cff)",
    button_primary_background_fill_hover="linear-gradient(135deg,#7a9bff,#9b8cff)",
    button_primary_text_color="#ffffff",
    button_primary_border_color="rgba(255,255,255,0.12)",
    button_secondary_background_fill="#1a1f42",
    button_secondary_text_color="#eef1ff",
    color_accent="#8a7cff",
    color_accent_soft="rgba(138,124,255,0.18)",
    link_text_color="#9cc0ff",
)

# Finishing touches the theme tokens can't express: an animated aurora, the
# system font stack, a gradient title, and hiding the Gradio footer (its
# Settings/Use-via-API links are N/A behind the gate).
EXO_CSS = """
body, gradio-app, .gradio-container { background:#0a0d1e !important; }
.gradio-container { position:relative; max-width:1000px !important; margin:0 auto !important; }
.gradio-container::before{
  content:""; position:fixed; inset:-30vmax; z-index:0; pointer-events:none;
  filter:blur(95px); opacity:.50;
  background:
    radial-gradient(42vmax 42vmax at 10% 6%,  #1f4fff 0, transparent 60%),
    radial-gradient(38vmax 38vmax at 90% 12%, #7a4dff 0, transparent 60%),
    radial-gradient(34vmax 34vmax at 22% 94%, #e6559b 0, transparent 60%),
    radial-gradient(28vmax 28vmax at 92% 90%, #1fb6a8 0, transparent 60%);
  animation:exo-drift 22s ease-in-out infinite;
}
@keyframes exo-drift{0%,100%{transform:translate(0,0) scale(1)}50%{transform:translate(-3vmax,3vmax) scale(1.06)}}
.gradio-container > *{ position:relative; z-index:1; }
.gradio-container, .gradio-container *{
  font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif !important;
}
.gradio-container h1{
  font-weight:850 !important; letter-spacing:-1px; text-align:center;
  font-size:clamp(34px,6vw,52px) !important;
  background:linear-gradient(100deg,#9cc0ff,#c4b6ff 35%,#ffb3d9 65%,#9cc0ff);
  background-size:220% auto; -webkit-background-clip:text; background-clip:text;
  -webkit-text-fill-color:transparent; color:transparent !important;
  animation:exo-flow 7s linear infinite;
}
@keyframes exo-flow{to{background-position:220% center}}
.gradio-container h1::before{
  content:"✦"; display:block; font-size:30px; line-height:1; margin:0 auto 6px;
  -webkit-text-fill-color:#c4b6ff; color:#c4b6ff;
}
@media(prefers-reduced-motion:reduce){ .gradio-container::before,.gradio-container h1{animation:none!important} }
footer{ display:none !important; }
"""


def build_demo():
    # Gradio 6.x: ChatInterface dropped the `type` kwarg ("messages" is the only
    # format now) AND moved `theme`/`css` to .launch() — passing any of them to
    # the constructor raises TypeError.
    demo = gr.ChatInterface(
        fn=chat,
        title=TITLE,
        description=(
            "Your on-device assistant. **⚡ Text mode** answers each question on "
            "its own (fastest). **💬 Chat mode** remembers the conversation. The "
            "model may idle-unload after a while, so the first reply after a "
            "pause can take a few seconds to wake it."
        ),
        additional_inputs=[
            gr.Radio(
                choices=[MODE_TEXT, MODE_CHAT],
                value=MODE_TEXT,
                label="Mode",
                info="Text = fast & stateless · Chat = remembers context",
            )
        ],
        additional_inputs_accordion=gr.Accordion("⚙ Mode", open=True),
        fill_height=True,
    )
    return demo


def main():
    log(f"booting exobot-ui (gradio {gr.__version__}) — "
        f"bind {HOST}:{PORT} root_path={ROOT_PATH!r} llama={LLAMA_URL}")
    demo = build_demo()
    # queue() enables the streaming/websocket transport that Caddy proxies
    # transparently. root_path matches the Caddy mount (subdomain root = "").
    demo.queue().launch(
        server_name=HOST,
        server_port=PORT,
        root_path=ROOT_PATH,
        # Tracebacks/internal paths stay OFF for the deployed instance;
        # EXOBOT_UI_DEBUG=1 flips it on for local debugging only.
        show_error=UI_DEBUG,
        # Gradio 6.x: theme + css are LAUNCH args (moved off the constructor).
        theme=EXO_THEME,
        css=EXO_CSS,
        # No public Gradio share tunnel — Caddy + the CF tunnel are the only edge.
        share=False,
        # Don't auto-open a browser on the headless phone.
        inbrowser=False,
    )


if __name__ == "__main__":
    main()
