#!/usr/bin/env python3
"""Sticker picker backend for pocket-homeserver.

Runs TERMUX-NATIVE on a loopback port (default 127.0.0.1:8451); Caddy fronts it.
It backs the (third-party, upstream-fetched) Maunium sticker picker widget with
three things the static widget can't do on its own:

  1. Uploading user stickers — Element widgets have no upload capability, so we
     proxy: the widget POSTs the binary, we use a Matrix service token to
     /_matrix/media/v3/upload, then append the result to the user's pack JSON.
  2. Giphy SEARCH — keep the API key server-side instead of shipping it in the JS
     bundle (a browser cannot keep a secret; this also keeps the rate-limit from
     being drained by anyone with curl).
  3. Giphy PICK — same upload-to-homeserver path so the resulting m.sticker event
     references our OWN mxc:// (with federation off, a foreign mxc never renders).

Endpoints (served under whatever base path Caddy maps to /api/* here):
  POST /api/upload-sticker  multipart  file=<bin>, body=<text>, user_id=<mxid|sig>
                            -> uploads to the homeserver, appends to the user pack
  POST /api/giphy-pick      json       {giphy_id, body, user_id}
                            -> downloads from Giphy, uploads to the homeserver,
                               returns {sticker, pack_id} for widgetAPI.sendSticker
  POST /api/import-mxc      json       {user_id, mxc, label, ...}  (the importer bot)
  POST /api/delete-sticker  json       {user_id, sticker_id}
  GET  /api/giphy-search?q=…           server-side Giphy proxy (key never leaves)
  GET  /api/user-packs?user=…          the user's pack index.json (or empty)
  GET  /api/health                     liveness probe

Config (all from the environment; the launcher sources a 0600 secrets file):
  STICKER_SERVICE_TOKEN  — Matrix access_token used to upload media (a real user
                           on this homeserver, e.g. the admin/bot account)
  GIPHY_API_KEY          — free Giphy key; empty disables the Giphy tab (503)
  STICKER_URL_SECRET     — HMAC secret for the signed widget-URL identity scheme
  STICKER_IDENTITY_MODE  — log | enforce (rollout safety; see _verify_identity)
  STICKER_PACKS_DIR      — absolute path to the picker's packs/ root (writable)
  MATRIX_SERVER_NAME     — this homeserver's server_name (mxc validation + index)
  STICKER_WIDGET_ORIGIN  — public https origin the widget is served from (CORS)
  HS_LOCAL               — loopback Matrix client-server API (default 127.0.0.1:8448)
  STICKER_BIND_HOST / STICKER_BIND_PORT — loopback bind (default 127.0.0.1:8451)

Trust model: the picker forwards the widget URL's `matrix_user_id` (substituted
by Element from the authenticated session) as `user_id`. A DIRECT API caller
could otherwise pass any mxid, so the widget URL carries a signed `<mxid>|<hmac>`
(see the install step) that this server verifies. Per-user rate limiting bounds
abuse. Generalized from a working deployment; review before exposing.
"""
import io
import json
import hashlib
import hmac
import os
import re
import sys
import time
import threading
import urllib.parse
import urllib.request
import urllib.error
from email.parser import BytesParser
from email.policy import default as default_policy
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

try:
    from PIL import Image, ImageOps
    _HAS_PIL = True
except ImportError:
    _HAS_PIL = False

BIND_HOST = os.environ.get("STICKER_BIND_HOST", "127.0.0.1")
BIND_PORT = int(os.environ.get("STICKER_BIND_PORT", "8451"))
SERVICE_TOKEN = os.environ.get("STICKER_SERVICE_TOKEN", "")
GIPHY_API_KEY = os.environ.get("GIPHY_API_KEY", "")
PACKS_DIR = Path(os.environ.get("STICKER_PACKS_DIR", "/var/www/stickerpicker/packs"))
HS_LOCAL = os.environ.get("HS_LOCAL", "http://127.0.0.1:8448").rstrip("/")
SERVER_NAME = os.environ.get("MATRIX_SERVER_NAME", "")
# Public origin the widget is served from (e.g. https://stickers.example.com).
# Used only for the CORS allow-origin check; defaults to https://<SERVER_NAME>.
WIDGET_ORIGIN = os.environ.get(
    "STICKER_WIDGET_ORIGIN", f"https://{SERVER_NAME}" if SERVER_NAME else ""
).rstrip("/")
# Neutral User-Agent for outbound Giphy requests (operator identity removed).
USER_AGENT = os.environ.get("STICKER_USER_AGENT", "pocket-homeserver-stickerpicker/1.0")

MAX_UPLOAD_BYTES = 5 * 1024 * 1024  # 5 MB per sticker — generous for animated webp
ALLOWED_MIMES = {"image/png", "image/jpeg", "image/webp", "image/gif"}
MXID_RE = re.compile(r"^@[a-z0-9._=\-/+]+:[a-z0-9.-]+$", re.I)
SHORT_TEXT = re.compile(r"^[\w\s\-_:,.!?'()]{1,64}$")

# ── Caller-identity verification (signed widget URLs) ────────────────────────
# The picker forwards the widget URL's `matrix_user_id` as `user_id`; a DIRECT
# API caller could otherwise pass any mxid -> cross-user pack write / rate-limit
# drain. The install step bakes <mxid>|<hmac> into each per-user widget URL,
# signed with STICKER_URL_SECRET; here we split it and require the HMAC to match.
# With federation off, the Matrix widget OpenID-token path is unavailable, so
# this signed-URL scheme is the federation-independent equivalent (a secret in
# the public JS bundle would be worthless). The picker never builds paths from
# the value (it only forwards it), so no JS rebuild is needed. Rollout is
# log->enforce (STICKER_IDENTITY_MODE) so a stale cached widget URL can't break
# the picker mid-migration. '|' is excluded from MXID_RE -> safe delimiter.
#
# Signed-identity scheme: each per-user widget URL carries `<mxid>|<hmac>`, the
# HMAC keyed by STICKER_URL_SECRET (a per-deployment secret generated 0600 by
# steps/82-install-stickers.sh). The signing here MUST stay byte-identical to the
# importer bot's _signed() AND to the openssl HMAC in steps/82 §7 — all three use
# HMAC-SHA256(secret, mxid) hex; verified equal openssl⇄python before shipping.
STICKER_URL_SECRET = os.environ.get("STICKER_URL_SECRET", "")
STICKER_IDENTITY_MODE = os.environ.get("STICKER_IDENTITY_MODE", "log").strip().lower()


def _sign_mxid(mxid):
    # HMAC-SHA256(STICKER_URL_SECRET, mxid) as hex — the canonical signature the
    # widget URL embeds and the registration/importer paths reproduce exactly.
    return hmac.new(STICKER_URL_SECRET.encode(), mxid.encode(), hashlib.sha256).hexdigest()


def _verify_identity(raw, client_ip="?"):
    """Return the verified mxid from a `user_id` value of the form <mxid>|<sig>,
    else None (the caller should respond 403). In `log` mode an unsigned/bad-sig
    value is allowed but logged (migration safety); in `enforce` mode a valid
    HMAC signature is required.

    Constant-time compare (hmac.compare_digest) avoids a timing leak. In `enforce`
    mode this fails CLOSED: an empty STICKER_URL_SECRET makes the guard below False
    for every input, so all signatures are rejected (steps/82 always generates a
    secret, so a correctly-installed deployment never hits that).
    """
    raw = (raw or "").strip()
    mxid, sep, sig = raw.rpartition("|")
    if not sep:                                   # unsigned (legacy / direct caller)
        mxid = raw
        if not MXID_RE.match(mxid):
            return None
        if STICKER_IDENTITY_MODE == "enforce":
            sys.stderr.write(f"sticker-identity REJECT unsigned mxid={mxid} ip={client_ip}\n")
            return None
        sys.stderr.write(f"sticker-identity unsigned-allowed (log mode) mxid={mxid} ip={client_ip}\n")
        return mxid
    if not MXID_RE.match(mxid):
        return None
    # Require a non-empty secret AND a constant-time signature match. Empty secret
    # ⇒ False ⇒ fall through to the mode gate below (reject in enforce).
    if STICKER_URL_SECRET and hmac.compare_digest(sig, _sign_mxid(mxid)):
        return mxid                               # signature verified
    if STICKER_IDENTITY_MODE == "enforce":
        sys.stderr.write(f"sticker-identity REJECT bad-sig mxid={mxid} ip={client_ip}\n")
        return None
    sys.stderr.write(f"sticker-identity bad-sig-allowed (log mode) mxid={mxid} ip={client_ip}\n")
    return mxid


# Per-user rate limiter — N writes per window
_RATE_LOCK = threading.Lock()
_RATE = {}
RATE_LIMIT_N = 30
RATE_LIMIT_WINDOW_S = 600

# Giphy id -> mxc cache; survives across requests (in memory)
_GIPHY_CACHE_LOCK = threading.Lock()
_GIPHY_CACHE = {}


def _now():
    return time.time()


def _allow(user_id):
    with _RATE_LOCK:
        bucket = _RATE.setdefault(user_id, [])
        cutoff = _now() - RATE_LIMIT_WINDOW_S
        bucket[:] = [t for t in bucket if t > cutoff]
        if len(bucket) >= RATE_LIMIT_N:
            return False
        bucket.append(_now())
        return True


def _encode_mxid(mxid):
    # Keep ':' raw on disk + in URLs. Caddy's file_server URL-decodes path
    # components before mapping to disk, so a percent-encoded %3A in the URL
    # becomes ':' on lookup; if the dir on disk were named with a literal %3A the
    # lookup would fail. The picker uses encodeURIComponent(mxid) which sends
    # %40user%3Aserver, again decoded by Caddy to @user:server before disk
    # lookup. So the disk name MUST be @user:server (raw colons + raw @). ext4 +
    # Linux allow ':' in filenames; only / and NUL are forbidden.
    return urllib.parse.quote(mxid, safe="@.:")


def _user_pack_dir(mxid):
    return PACKS_DIR / "users" / _encode_mxid(mxid)


def _read_pack(path):
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        return None


def _write_atomic(path: Path, content: str):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(content)
    tmp.replace(path)


def _hs_upload(content: bytes, mimetype: str, filename: str) -> str:
    """Upload bytes to our homeserver, return the mxc:// URL.

    SECURITY CARVE-OUT — the human reviewer confirms the service-token handling:
    the Bearer token is read from the environment (sourced from a 0600 secrets
    file by the launcher), NEVER logged, and NEVER placed on argv.
    """
    qs = urllib.parse.urlencode({"filename": filename})
    url = f"{HS_LOCAL}/_matrix/media/v3/upload?{qs}"
    req = urllib.request.Request(
        url,
        data=content,
        method="POST",
        headers={
            # Bearer SERVICE_TOKEN: a real homeserver account's access token with
            # media-upload rights, read from the 0600 secrets file via the env
            # (never logged, never on argv). The widget can't upload directly, so
            # the backend uploads on the verified caller's behalf.
            "Authorization": f"Bearer {SERVICE_TOKEN}",
            "Content-Type": mimetype,
        },
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        body = resp.read()
        j = json.loads(body)
        if "content_uri" not in j:
            raise RuntimeError(f"upload missing content_uri: {body[:200]!r}")
        return j["content_uri"]


def _hs_download(mxc: str) -> bytes:
    """Download bytes from our homeserver by mxc URI (used to backfill thumbnails
    for the importer-bot flow, where the bot only sends us the mxc).
    Authenticated download via /_matrix/client/v1/media (recent homeserver
    versions require the auth header — anonymous /_matrix/media/v3/download
    refuses for new uploads)."""
    if not mxc.startswith("mxc://"):
        raise ValueError("not an mxc url")
    server, media_id = mxc[len("mxc://"):].split("/", 1)
    url = f"{HS_LOCAL}/_matrix/client/v1/media/download/{server}/{media_id}"
    req = urllib.request.Request(
        url,
        headers={"Authorization": f"Bearer {SERVICE_TOKEN}"},
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.read()


def _save_thumbnail(content: bytes, mxc_id: str, mimetype: str = "image/png") -> bool:
    """Resize `content` to 256x256 max preserving aspect, save under
    PACKS_DIR/thumbnails/<mxc_id>. The picker's makeThumbnailURL fetches this
    exact path; without it both pack-nav icons and in-pack previews 404. Returns
    True on success.

    Falls back to writing the raw bytes if PIL isn't available — the browser
    will resize via CSS, but bandwidth-on-load gets worse.
    """
    thumb_dir = PACKS_DIR / "thumbnails"
    thumb_dir.mkdir(parents=True, exist_ok=True)
    thumb_path = thumb_dir / mxc_id

    if not _HAS_PIL:
        try:
            thumb_path.write_bytes(content)
            return True
        except Exception as e:
            sys.stderr.write(f"thumbnail raw-write failed for {mxc_id}: {e}\n")
            return False

    try:
        with Image.open(io.BytesIO(content)) as im:
            im = ImageOps.exif_transpose(im)
            # Animated images: drop frames except the first to keep the picker
            # render cheap. Static stickers use the source frame.
            if getattr(im, "is_animated", False):
                im.seek(0)
            im = im.convert("RGBA") if im.mode in ("P", "RGBA", "LA") else im.convert("RGB")
            im.thumbnail((256, 256), Image.LANCZOS)
            buf = io.BytesIO()
            # PNG keeps alpha for stickers; small enough for 256-max images.
            im.save(buf, format="PNG", optimize=True)
            thumb_path.write_bytes(buf.getvalue())
        return True
    except Exception as e:
        sys.stderr.write(f"thumbnail PIL gen failed for {mxc_id}: {e}\n")
        # Last-resort: write source bytes so the picker still shows something.
        try:
            thumb_path.write_bytes(content)
            return True
        except Exception:
            return False


def _giphy_get(path: str, params: dict) -> dict:
    params = dict(params)
    params["api_key"] = GIPHY_API_KEY
    qs = urllib.parse.urlencode(params)
    url = f"https://api.giphy.com/v1/{path}?{qs}"
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.loads(resp.read())


def _giphy_download(giphy_id: str):
    """Fetch the original webp for a giphy id. Returns (bytes, mimetype)."""
    # Use the redirect-style URL Maunium hardcodes. Both stickers + GIFs respond
    # at i.giphy.com; the webp is animated for stickers too.
    url = f"https://i.giphy.com/{giphy_id}.webp"
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=15) as resp:
        data = resp.read()
        mime = resp.headers.get("Content-Type", "image/webp")
    if len(data) > MAX_UPLOAD_BYTES:
        raise RuntimeError(f"giphy item too large: {len(data)} bytes")
    # Width/height come from the API result, not from the bytes — keeps deps zero.
    return data, mime


def _append_global_index(rel_path: str) -> None:
    """Add a user pack's relative path to packs/index.json so the picker iframe
    sees it. The picker only reads the global index — without this entry, user
    packs are orphaned on disk.

    Cross-user visibility tradeoff: every user's packs become visible to every
    other picker user. Acceptable for a small invite-only server (see
    docs/STICKERS.md), NOT acceptable on a public homeserver.
    """
    global_idx_path = PACKS_DIR / "index.json"
    idx = _read_pack(global_idx_path) or {
        "homeserver_url": f"https://{SERVER_NAME}",
        "packs": [],
    }
    if rel_path not in idx.get("packs", []):
        idx.setdefault("packs", []).append(rel_path)
        _write_atomic(global_idx_path, json.dumps(idx, indent=2))


def _append_user_pack(mxid: str, pack_id: str, pack_title: str, sticker: dict) -> None:
    """Add a sticker to <user>/<pack_id>.json; create if absent. Update the
    per-user + global indexes."""
    user_dir = _user_pack_dir(mxid)
    pack_path = user_dir / f"{pack_id}.json"
    user_idx_path = user_dir / "index.json"

    pack = _read_pack(pack_path) or {
        "title": pack_title,
        "id": pack_id,
        "stickers": [],
    }
    # Dedupe by sticker id
    pack["stickers"] = [s for s in pack["stickers"] if s.get("id") != sticker.get("id")]
    pack["stickers"].append(sticker)
    _write_atomic(pack_path, json.dumps(pack, indent=2))

    # Update users/<mxid>/index.json — list of pack files for this user
    idx = _read_pack(user_idx_path) or {
        "homeserver_url": f"https://{SERVER_NAME}",
        "packs": [],
    }
    pack_file = f"{pack_id}.json"
    if pack_file not in idx["packs"]:
        idx["packs"].append(pack_file)
        _write_atomic(user_idx_path, json.dumps(idx, indent=2))

    # Surface the pack in the global picker index as well.
    rel = f"users/{_encode_mxid(mxid)}/{pack_file}"
    _append_global_index(rel)


def _delete_user_sticker(mxid: str, sticker_id: str) -> dict:
    """Remove a sticker (by id) from every pack of a single user. Returns
    {"removed": <count>, "packs_affected": [...]}. Cleans up the thumbnail file
    on the way out (best-effort).
    """
    user_dir = _user_pack_dir(mxid)
    if not user_dir.exists():
        return {"removed": 0, "packs_affected": []}
    removed = 0
    affected = []
    for pack_path in sorted(user_dir.glob("*.json")):
        if pack_path.name == "index.json":
            continue
        pack = _read_pack(pack_path)
        if not pack or not isinstance(pack.get("stickers"), list):
            continue
        before = len(pack["stickers"])
        pack["stickers"] = [s for s in pack["stickers"] if s.get("id") != sticker_id]
        if len(pack["stickers"]) != before:
            removed += before - len(pack["stickers"])
            affected.append(pack_path.name)
            _write_atomic(pack_path, json.dumps(pack, indent=2))
    if removed:
        # Drop the cached thumbnail. Don't drop the mxc itself — other users /
        # message timelines may still reference it.
        thumb = PACKS_DIR / "thumbnails" / sticker_id
        try:
            thumb.unlink()
        except FileNotFoundError:
            pass
        except Exception as e:
            sys.stderr.write(f"thumbnail unlink failed for {sticker_id}: {e}\n")
    return {"removed": removed, "packs_affected": affected}


def _make_sticker_event(mxc: str, body: str, mime: str, w: int, h: int, size: int, sid: str) -> dict:
    """Maunium pack-item shape: matches what the upstream web/src/index.js consumes."""
    return {
        "body": body,
        "url": mxc,
        "info": {
            "w": w,
            "h": h,
            "size": size,
            "mimetype": mime,
            "thumbnail_url": mxc,
            "thumbnail_info": {"w": w, "h": h, "size": size, "mimetype": mime},
        },
        "msgtype": "m.sticker",
        "id": sid,
    }


# ----------------------------------------------------------------------
# HTTP handler

def _json(handler, status, obj):
    body = json.dumps(obj).encode()
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.send_header("Cache-Control", "no-store")
    handler.end_headers()
    handler.wfile.write(body)


def _err(handler, status, msg):
    _json(handler, status, {"error": msg})


def _parse_multipart(handler):
    ct = handler.headers.get("Content-Type", "")
    if "multipart/form-data" not in ct:
        return None, "expected multipart/form-data"
    length = int(handler.headers.get("Content-Length", "0"))
    if length <= 0 or length > MAX_UPLOAD_BYTES + 8192:
        return None, "missing or oversized payload"
    raw = handler.rfile.read(length)
    # email.parser handles RFC 2046 multipart cleanly
    msg = BytesParser(policy=default_policy).parsebytes(
        b"Content-Type: " + ct.encode() + b"\r\n\r\n" + raw
    )
    parts = {"file": None, "body": "", "user_id": "", "pack_id": "", "pack_title": ""}
    for part in msg.iter_parts():
        cd = part["Content-Disposition"] or ""
        m = re.search(r'name="([^"]+)"', cd)
        if not m:
            continue
        name = m.group(1)
        if name == "file":
            parts["file"] = (
                part.get_payload(decode=True),
                part.get_content_type(),
                re.search(r'filename="([^"]+)"', cd),
            )
        else:
            v = part.get_payload(decode=True) or b""
            parts[name] = v.decode("utf-8", "replace").strip()
    return parts, None


class Handler(BaseHTTPRequestHandler):
    server_version = "stickerbackend/1.0"

    def log_message(self, fmt, *args):
        sys.stderr.write(f"[{time.strftime('%H:%M:%SZ', time.gmtime())}] {fmt % args}\n")

    # CORS isn't strictly needed (the picker fetches are same-origin via Caddy),
    # but Element's webview can be flaky about it; allow only the explicit origin.
    def _cors_origin(self):
        origin = self.headers.get("Origin", "")
        if WIDGET_ORIGIN and origin == WIDGET_ORIGIN:
            return origin
        return None

    def do_OPTIONS(self):
        origin = self._cors_origin()
        self.send_response(204)
        if origin:
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
            self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def _path(self):
        return urllib.parse.urlparse(self.path)

    def _query(self):
        return dict(urllib.parse.parse_qsl(self._path().query))

    # GET ------------------------------------------------------------------
    def do_GET(self):
        p = self._path().path
        # Caddy strips the widget base path via handle_path, so we see /api/* here.
        if p == "/api/giphy-search":
            return self._giphy_search()
        if p == "/api/user-packs":
            return self._user_packs()
        if p == "/api/health":
            return _json(self, 200, {"ok": True})
        return _err(self, 404, "not found")

    def _giphy_search(self):
        if not GIPHY_API_KEY:
            return _err(self, 503, "giphy not configured")
        q = self._query()
        term = (q.get("q") or "").strip()
        if not term or len(term) > 64:
            return _err(self, 400, "missing or invalid q")
        limit = max(1, min(50, int(q.get("limit", "25"))))
        try:
            data = _giphy_get("stickers/search", {"q": term, "limit": limit, "rating": "g"})
        except urllib.error.HTTPError as e:
            return _err(self, 502, f"giphy {e.code}")
        except Exception as e:
            return _err(self, 502, f"giphy: {e}")
        # Sanitize — only return what the widget needs.
        results = []
        for g in data.get("data", []):
            try:
                results.append({
                    "id": g["id"],
                    "title": g.get("title", ""),
                    "preview_url": g["images"]["fixed_height_small"]["url"],
                    "w": int(g["images"]["original"]["width"]),
                    "h": int(g["images"]["original"]["height"]),
                })
            except (KeyError, ValueError):
                continue
        _json(self, 200, {"results": results})

    def _user_packs(self):
        # The picker passes the signed compound (<mxid>|<sig>) here too, so parse
        # it with the same verifier (log mode tolerates a bare/legacy value;
        # enforce requires a valid signature).
        q = self._query()
        mxid = _verify_identity(q.get("user", ""), self.client_address[0])
        if not mxid:
            return _err(self, 403, "identity not verified")
        idx_path = _user_pack_dir(mxid) / "index.json"
        try:
            _json(self, 200, json.loads(idx_path.read_text()))
        except FileNotFoundError:
            _json(self, 200, {"homeserver_url": f"https://{SERVER_NAME}", "packs": []})

    # POST -----------------------------------------------------------------
    def do_POST(self):
        p = self._path().path
        if p == "/api/upload-sticker":
            return self._upload_sticker()
        if p == "/api/giphy-pick":
            return self._giphy_pick()
        if p == "/api/import-mxc":
            return self._import_mxc()
        if p == "/api/delete-sticker":
            return self._delete_sticker()
        return _err(self, 404, "not found")

    def _delete_sticker(self):
        """Remove a sticker (by id) from the user's pack(s).

        Body (JSON): {user_id, sticker_id}
        """
        try:
            length = int(self.headers.get("Content-Length", "0"))
            payload = json.loads(self.rfile.read(length).decode("utf-8")) if length else {}
        except Exception:
            return _err(self, 400, "bad json")
        mxid = _verify_identity(payload.get("user_id"), self.client_address[0])
        sticker_id = (payload.get("sticker_id") or "").strip()
        if not mxid:
            return _err(self, 403, "identity not verified")
        # Sticker IDs are usually mxc media-ids — alnum + - + _ + ., 4-128 chars.
        if not re.match(r"^[A-Za-z0-9._\-]{4,128}$", sticker_id):
            return _err(self, 400, "invalid sticker_id")
        if not _allow(mxid):
            return _err(self, 429, "rate limit")
        try:
            res = _delete_user_sticker(mxid, sticker_id)
        except Exception as e:
            return _err(self, 500, f"delete failed: {e}")
        _json(self, 200, res)

    def _import_mxc(self):
        """Add an existing-on-our-homeserver mxc:// to a user's pack.

        Used by the importer bot when a user DMs an image: Element already
        uploaded the image to our homeserver via its native attachment flow, so
        we don't need the binary. Just append to the user's pack with the
        existing mxc URL.

        Body (JSON): {user_id, mxc, label, pack_id?, pack_title?,
                      mimetype?, w?, h?, size?}
        """
        try:
            length = int(self.headers.get("Content-Length", "0"))
            payload = json.loads(self.rfile.read(length).decode("utf-8")) if length else {}
        except Exception:
            return _err(self, 400, "bad json")
        mxid = _verify_identity(payload.get("user_id"), self.client_address[0])
        mxc = (payload.get("mxc") or "").strip()
        label = (payload.get("label") or "sticker").strip()[:64] or "sticker"
        if not mxid:
            return _err(self, 403, "identity not verified")
        if not mxc.startswith("mxc://"):
            return _err(self, 400, "invalid mxc")
        # Pin to our own homeserver — refuse a foreign mxc (federation is off
        # anyway, but defence in depth in case the bot is fed a poisoned event).
        rest = mxc[len("mxc://"):]
        srv = rest.split("/", 1)[0]
        if SERVER_NAME and srv != SERVER_NAME:
            return _err(self, 400, f"foreign mxc server: {srv}")
        if not _allow(mxid):
            return _err(self, 429, "rate limit")
        pack_id = (payload.get("pack_id") or "mobile-imports").strip().lower()
        pack_id = re.sub(r"[^a-z0-9_\-]+", "-", pack_id)[:48] or "mobile-imports"
        pack_title = (payload.get("pack_title") or "Mobile imports").strip()[:48] or "Mobile imports"
        mime = (payload.get("mimetype") or "image/png")
        w = int(payload.get("w") or 256)
        h = int(payload.get("h") or 256)
        size = int(payload.get("size") or 0)
        new_id = mxc.split("/", 3)[-1]
        sticker = _make_sticker_event(mxc, label, mime, w, h, size, new_id)
        try:
            _append_user_pack(mxid, pack_id, pack_title, sticker)
        except Exception as e:
            return _err(self, 500, f"pack write: {e}")
        # Generate the picker thumbnail. We need the source bytes; the bot only
        # sent us the mxc, so download from our homeserver first. Failure is
        # non-fatal — the sticker JSON still works, only its preview won't render.
        try:
            src_bytes = _hs_download(mxc)
            _save_thumbnail(src_bytes, new_id, mimetype=mime)
        except Exception as e:
            sys.stderr.write(f"thumbnail backfill failed for {new_id}: {e}\n")
        _json(self, 200, {"sticker": sticker, "pack_id": pack_id})

    def _upload_sticker(self):
        parts, err = _parse_multipart(self)
        if err:
            return _err(self, 400, err)
        if not parts["file"]:
            return _err(self, 400, "missing file")
        data, mime, fnm = parts["file"]
        if not data:
            return _err(self, 400, "empty file")
        if len(data) > MAX_UPLOAD_BYTES:
            return _err(self, 413, "too large")
        if mime not in ALLOWED_MIMES:
            return _err(self, 415, f"mime not allowed: {mime}")
        mxid = _verify_identity(parts["user_id"], self.client_address[0])
        if not mxid:
            return _err(self, 403, "identity not verified")
        body_text = parts["body"] or "sticker"
        if not SHORT_TEXT.match(body_text):
            return _err(self, 400, "invalid body")
        if not _allow(mxid):
            return _err(self, 429, "rate limit")
        # Pack target — defaults to "my-stickers" for the legacy single-pack
        # upload form. The pack-import flow passes a sanitised pack_id +
        # pack_title to land all stickers from a batch into one named pack.
        pack_id = (parts.get("pack_id") or "my-stickers").strip().lower()
        pack_id = re.sub(r"[^a-z0-9_\-]+", "-", pack_id)[:48] or "my-stickers"
        pack_title = (parts.get("pack_title") or "My stickers").strip()[:48] or "My stickers"
        try:
            mxc = _hs_upload(data, mime, f"{int(_now())}.{mime.split('/')[-1]}")
        except Exception as e:
            return _err(self, 502, f"hs upload: {e}")
        new_id = mxc.split("/", 3)[-1]
        sticker = _make_sticker_event(mxc, body_text, mime, 256, 256, len(data), new_id)
        try:
            _append_user_pack(mxid, pack_id, pack_title, sticker)
        except Exception as e:
            return _err(self, 500, f"pack write: {e}")
        _save_thumbnail(data, new_id, mimetype=mime)
        _json(self, 200, {"sticker": sticker, "pack_id": pack_id})

    def _giphy_pick(self):
        if not GIPHY_API_KEY:
            return _err(self, 503, "giphy not configured")
        try:
            length = int(self.headers.get("Content-Length", "0"))
            payload = json.loads(self.rfile.read(length).decode("utf-8")) if length else {}
        except Exception:
            return _err(self, 400, "bad json")
        gid = (payload.get("giphy_id") or "").strip()
        mxid = _verify_identity(payload.get("user_id"), self.client_address[0])
        body_text = (payload.get("body") or "").strip()[:64] or "Giphy sticker"
        w = int(payload.get("w") or 256)
        h = int(payload.get("h") or 256)
        if not re.match(r"^[a-zA-Z0-9_\-]+$", gid):
            return _err(self, 400, "bad giphy_id")
        if not mxid:
            return _err(self, 403, "identity not verified")
        if not _allow(mxid):
            return _err(self, 429, "rate limit")

        with _GIPHY_CACHE_LOCK:
            cached = _GIPHY_CACHE.get(gid)
        if cached:
            mxc, mime, size = cached
        else:
            try:
                data, mime = _giphy_download(gid)
            except Exception as e:
                return _err(self, 502, f"giphy fetch: {e}")
            try:
                mxc = _hs_upload(data, mime, f"giphy-{gid}.webp")
            except Exception as e:
                return _err(self, 502, f"hs upload: {e}")
            with _GIPHY_CACHE_LOCK:
                _GIPHY_CACHE[gid] = (mxc, mime, len(data))
            size = len(data)
        new_id = mxc.split("/", 3)[-1]
        sticker = _make_sticker_event(mxc, body_text, mime, w, h, size, new_id)
        try:
            _append_user_pack(mxid, "giphy-favorites", "Giphy favorites", sticker)
        except Exception as e:
            # Non-fatal — user still gets the sticker; the pack just won't update.
            sys.stderr.write(f"giphy pack write failed: {e}\n")
        # Best-effort: cache the giphy thumbnail too. If we hit the cache branch
        # above, `data` isn't bound — re-fetch quickly.
        try:
            if 'data' not in locals():
                data, _ = _giphy_download(gid)
            _save_thumbnail(data, new_id, mimetype=mime)
        except Exception as e:
            sys.stderr.write(f"giphy thumbnail save failed for {new_id}: {e}\n")
        _json(self, 200, {"sticker": sticker, "pack_id": "giphy-favorites"})


def main():
    if not SERVICE_TOKEN:
        print("FATAL: STICKER_SERVICE_TOKEN unset", file=sys.stderr)
        sys.exit(1)
    if not PACKS_DIR.exists():
        print(f"FATAL: STICKER_PACKS_DIR not found: {PACKS_DIR}", file=sys.stderr)
        sys.exit(1)
    print(f"sticker-backend listening on {BIND_HOST}:{BIND_PORT}", flush=True)
    print(f"  STICKER_PACKS_DIR={PACKS_DIR}", flush=True)
    print(f"  HS_LOCAL={HS_LOCAL}", flush=True)
    print(f"  identity_mode={STICKER_IDENTITY_MODE}", flush=True)
    print(f"  giphy={'on' if GIPHY_API_KEY else 'off'}", flush=True)
    srv = ThreadingHTTPServer((BIND_HOST, BIND_PORT), Handler)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
