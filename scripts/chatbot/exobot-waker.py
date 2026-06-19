#!/usr/bin/env python3
"""exobot-waker — lazy-start manager for the on-demand Gradio AI UI (exobot-ui.py).

OPTIONAL companion to exobot-ui (only used when EXOBOT_UI=true). The Gradio
backend idles at a non-trivial CPU cost, so instead of keeping it running this
tiny always-on stdlib listener (near-0 idle CPU) starts it on demand and
idle-stops it:

  * GET/POST/HEAD on any path — hit from the AI vhost's lazy-start "starting…"
    page. If the UI port is down, launch the UI start script in the background
    (idempotent + debounced) and return 202; if already up, return 200.
  * Background idle loop — when the UI is up but the AI vhost has had no traffic
    for EXOBOT_IDLE_SECS (judged by the Caddy access-log mtime + the last wake),
    run the UI start script with `--stop` to reclaim the CPU / RAM.

The actual Gradio proxying (websockets/SSE streaming) stays on Caddy -> the UI
port; this waker is only hit on the cold-start error path and the idle timer, so
it never touches the streaming path.

Runtime: TERMUX-NATIVE python3 (stdlib only). It orchestrates the host: it
shells out to a launcher script that supervises/stops the UI.

Env (all optional):
  EXOBOT_WAKER_HOST    bind address                 (default 127.0.0.1)
  EXOBOT_WAKER_PORT    bind port                    (default 9116)
  EXOBOT_UI_PORT       the UI's loopback port        (default 9114)
  EXOBOT_IDLE_SECS     idle seconds before stopping  (default 900)
  EXOBOT_UI_START_SH   path to the UI start script   (REQUIRED; takes [--stop])
  EXOBOT_ACCESS_LOG    AI vhost access-log path to watch for activity (optional)
"""
import os
import socket
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = os.environ.get("EXOBOT_WAKER_HOST", "127.0.0.1")
WAKER_PORT = int(os.environ.get("EXOBOT_WAKER_PORT", "9116"))
UI_PORT = int(os.environ.get("EXOBOT_UI_PORT", "9114"))
IDLE_SECS = int(os.environ.get("EXOBOT_IDLE_SECS", "900"))
# The launcher that supervises the UI (start) and stops it (--stop). Supplied by
# scripts/steps/81-install-exobot.sh. No operator-specific path is baked in.
START_SH = os.environ.get("EXOBOT_UI_START_SH", "")
# Optional: active Gradio use writes to this Caddy access log continuously; idle
# = no writes. If unset, only the last /wake hit drives the idle decision.
ACCESS_LOG = os.environ.get("EXOBOT_ACCESS_LOG", "")

_lock = threading.Lock()
_last_wake = 0.0
_last_start = 0.0


def log(msg):
    print(f"[{time.strftime('%H:%M:%SZ', time.gmtime())}] {msg}", flush=True)


def _port_up(port):
    s = socket.socket()
    s.settimeout(1.5)
    try:
        return s.connect_ex(("127.0.0.1", port)) == 0
    except OSError:
        return False
    finally:
        s.close()


def _start_backend():
    """Launch the Gradio backend (idempotent: the start script no-ops if already
    up). Debounced so a burst of cold-start hits cannot spawn duplicates."""
    global _last_start
    if not START_SH:
        log("EXOBOT_UI_START_SH unset — cannot start the UI backend")
        return
    with _lock:
        if time.time() - _last_start < 25:
            return
        _last_start = time.time()
    subprocess.Popen(["bash", START_SH],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True)


def _stop_backend():
    if not START_SH:
        return
    try:
        subprocess.run(["bash", START_SH, "--stop"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
    except Exception:
        pass


def _last_activity():
    """Newest of: the last wake hit, and the AI vhost access-log mtime (active
    Gradio use writes there continuously; idle = no writes)."""
    t = _last_wake
    if ACCESS_LOG:
        try:
            t = max(t, os.path.getmtime(ACCESS_LOG))
        except OSError:
            pass
    return t


def _idle_loop():
    while True:
        time.sleep(60)
        try:
            if _port_up(UI_PORT) and time.time() - _last_activity() > IDLE_SECS:
                _stop_backend()
        except Exception:
            pass


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _handle(self):
        global _last_wake
        _last_wake = time.time()
        if _port_up(UI_PORT):
            code, body = 200, b'{"status":"up"}'
        else:
            _start_backend()
            code, body = 202, b'{"status":"starting"}'
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except Exception:
            pass

    do_GET = _handle
    do_POST = _handle
    do_HEAD = _handle


def main():
    log(f"booting exobot-waker — bind {HOST}:{WAKER_PORT} ui_port={UI_PORT} "
        f"idle={IDLE_SECS}s start_sh={START_SH or '(unset)'}")
    threading.Thread(target=_idle_loop, daemon=True).start()
    ThreadingHTTPServer((HOST, WAKER_PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
