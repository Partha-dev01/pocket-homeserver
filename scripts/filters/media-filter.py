#!/usr/bin/env python3
"""Media-filter proxy for the Matrix homeserver.

Sits between Caddy and the homeserver on the media routes:

    Caddy → 127.0.0.1:${MEDIA_FILTER_PORT} (this) → 127.0.0.1:8448 (homeserver)

Some homeserver builds leave Content-Type empty on the og:image fetches done by
URL-preview, and on certain media downloads. Browsers sniff and render those
fine; some native mobile Matrix clients don't sniff and fail to render the
thumbnail. This proxy reads the upstream response, peeks the first bytes when
Content-Type is missing/empty/octet-stream, and sets it from a magic-bytes
lookup. The rest of the body is streamed straight through.

Bind: 127.0.0.1:${MEDIA_FILTER_PORT} (default 8450) — same loopback-only
pattern as the user-filter (:8449). Caddy is the only front door.
Auth: passes the caller's Authorization header through unchanged.
Routes intercepted (everything else 404s — Caddy only routes media here):
    GET  /_matrix/media/v3/download/<server>/<id>[/<filename>]
    GET  /_matrix/media/v3/thumbnail/<server>/<id>[?...]
    GET  /_matrix/client/v1/media/download/<server>/<id>[/<filename>]
    GET  /_matrix/client/v1/media/thumbnail/<server>/<id>[?...]
    GET  /_matrix/media/v3/preview_url[?url=...]
    GET  /_matrix/client/v1/media/preview_url[?url=...]

stdlib only (native Termux python3; NOT inside the proot userland — it just
proxies the loopback homeserver). Everything operator-specific (the upstream
address, the bind port, the log file) comes from the environment; the install
step (scripts/steps/78-install-filters.sh) wires it.
"""
from __future__ import annotations
import http.server
import logging
import os
import socketserver
import sys
import threading  # noqa: F401  (ThreadingMixIn needs the threading machinery)
import time
import urllib.parse
import urllib.request
import urllib.error

# ── Config (all env-driven; defaults match the framework conventions) ────────
# The Matrix homeserver's loopback listener (continuwuity binds 127.0.0.1:8448;
# see scripts/steps/40-install-matrix.sh + the core Caddyfile /_matrix route).
UPSTREAM = os.environ.get("MATRIX_LOOPBACK", "http://127.0.0.1:8448").rstrip("/")
BIND_ADDR = os.environ.get("MEDIA_FILTER_BIND", "127.0.0.1")
BIND_PORT = int(os.environ.get("MEDIA_FILTER_PORT", "8450"))

# Log file. POCKET_LOG_DIR is exported by lib/common.sh (derived from DATA_DIR).
_DATA_DIR = os.environ.get("DATA_DIR", "").rstrip("/")
_LOG_DIR = os.environ.get("POCKET_LOG_DIR") or (
    f"{_DATA_DIR}/logs" if _DATA_DIR else
    os.path.normpath(os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "..", ".run", "logs")))
LOG_FILE = os.environ.get("MEDIA_FILTER_LOG", f"{_LOG_DIR}/media-filter.log")

CHUNK = 64 * 1024

os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
logging.Formatter.converter = time.gmtime  # %(asctime)s in UTC; the literal "Z" is then truthful
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)sZ %(levelname)s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
    handlers=[logging.FileHandler(LOG_FILE), logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger("media-filter")


def sniff(buf: bytes) -> str | None:
    """Best-effort magic-bytes Content-Type. Covers the formats Matrix media
    commonly carries (JPEG/PNG/WEBP/GIF/AVIF/HEIC/MP4/SVG/PDF/BMP)."""
    if not buf:
        return None
    if buf.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if buf.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if buf[:6] in (b"GIF87a", b"GIF89a"):
        return "image/gif"
    if buf.startswith(b"RIFF") and buf[8:12] == b"WEBP":
        return "image/webp"
    if buf.startswith(b"BM"):
        return "image/bmp"
    if buf.startswith(b"%PDF-"):
        return "application/pdf"
    if buf[4:8] == b"ftyp":
        brand = bytes(buf[8:12]).rstrip(b"\x00")
        if brand in (b"avif", b"avis"):
            return "image/avif"
        if brand in (b"heic", b"heix", b"mif1", b"msf1", b"hevc", b"hevx"):
            return "image/heic"
        # mp42, isom, avc1, M4V , M4A , dash etc
        return "video/mp4"
    head = buf[:64].lstrip()
    if head.startswith(b"<?xml") or head.startswith(b"<svg"):
        return "image/svg+xml"
    return None


def _proxy_GET(handler):
    target = f"{UPSTREAM}{handler.path}"
    headers = {}
    for k, v in handler.headers.items():
        # Hop-by-hop headers — drop. Host gets rewritten by urllib.
        if k.lower() in ("connection", "keep-alive", "proxy-authenticate",
                         "proxy-authorization", "te", "trailers",
                         "transfer-encoding", "upgrade", "host"):
            continue
        headers[k] = v
    req = urllib.request.Request(target, headers=headers, method="GET")
    try:
        upstream = urllib.request.urlopen(req, timeout=30)
    except urllib.error.HTTPError as e:
        body = e.read()
        handler.send_response(e.code)
        for k, v in e.headers.items():
            if k.lower() in ("transfer-encoding", "connection",
                             "content-encoding"):
                continue
            handler.send_header(k, v)
        handler.send_header("Content-Length", str(len(body)))
        handler.end_headers()
        try:
            handler.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass
        return
    except Exception as ex:
        log.warning("upstream error %s: %s", target, ex)
        handler.send_response(502)
        handler.end_headers()
        return

    # Peek first chunk so we can sniff Content-Type if upstream omitted it.
    first = upstream.read(CHUNK)
    up_headers = upstream.headers

    # Detect missing/empty Content-Type. Some homeservers return it set but
    # empty so .get() yields "" not None — both must be handled, as must the
    # generic octet-stream fallbacks.
    ctype_in = (up_headers.get("Content-Type") or "").strip()
    if not ctype_in or ctype_in.lower() in ("application/octet-stream",
                                            "binary/octet-stream"):
        sniffed = sniff(first)
        if sniffed:
            ctype_out = sniffed
            log.info("sniffed %s for %s (was %r)", sniffed, handler.path,
                     ctype_in or "<empty>")
        else:
            ctype_out = ctype_in or "application/octet-stream"
    else:
        ctype_out = ctype_in

    handler.send_response(upstream.status or 200)
    for k, v in up_headers.items():
        kl = k.lower()
        if kl in ("transfer-encoding", "connection", "content-type",
                  "content-length"):
            # We rewrite Content-Type below; Content-Length is re-emitted from
            # the upstream value when present, else the connection closes to
            # delimit the body.
            continue
        handler.send_header(k, v)
    handler.send_header("Content-Type", ctype_out)
    cl = up_headers.get("Content-Length")
    if cl:
        handler.send_header("Content-Length", cl)
    handler.end_headers()

    try:
        if first:
            handler.wfile.write(first)
        while True:
            chunk = upstream.read(CHUNK)
            if not chunk:
                break
            handler.wfile.write(chunk)
    except (BrokenPipeError, ConnectionResetError):
        pass
    finally:
        upstream.close()


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "matrix-media-filter/1.0"
    sys_version = ""

    def log_message(self, fmt, *args):
        log.info("%s %s", self.address_string(), fmt % args)

    def do_GET(self):
        if self.path == "/healthz":
            body = b'{"ok":true,"service":"media-filter"}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        # Only proxy known media routes; reject everything else.
        path = urllib.parse.urlsplit(self.path).path
        if not (path.startswith("/_matrix/media/v3/") or
                path.startswith("/_matrix/client/v1/media/")):
            self.send_response(404)
            self.end_headers()
            return
        _proxy_GET(self)

    def do_HEAD(self):
        # Same routing as GET so HEAD on a media URL gets the fixed Content-Type.
        self.do_GET()


class ThreadingServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    # Hard refuse to bind anything but loopback — Caddy is the only front door.
    if BIND_ADDR != "127.0.0.1":
        raise RuntimeError("MEDIA_FILTER_BIND must be loopback (127.0.0.1)")
    log.info("media-filter starting on %s:%d (upstream=%s)",
             BIND_ADDR, BIND_PORT, UPSTREAM)
    srv = ThreadingServer((BIND_ADDR, BIND_PORT), Handler)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        srv.server_close()


if __name__ == "__main__":
    main()
