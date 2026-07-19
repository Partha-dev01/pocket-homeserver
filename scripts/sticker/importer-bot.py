#!/usr/bin/env python3
"""Sticker-importer Matrix bot for pocket-homeserver.

Mobile-native sticker import + send for Element clients whose widget WebView
can't bridge file inputs (e.g. older Element Android builds whose WebView only
overrides onPermissionRequest, not onShowFileChooser — see docs/STICKERS.md). It
runs TERMUX-NATIVE and talks to the loopback Matrix client-server API + the
loopback sticker backend; no userland needed.

Capabilities (all in 1:1 DMs with the bot):

  - Send any image (m.image) -> bot adds it to your "Mobile imports" pack via
    /api/import-mxc. An optional caption (the message body) becomes the sticker
    label. The bot replies with the new pack sticker count.

  - !help / help     -> list commands
  - !list / list     -> list your packs and counts
  - !random [pack]   -> the bot picks a random sticker from your packs (or a
                        specific pack, fuzzy match) and sends it as an m.sticker
                        event in the DM
  - !delete <pack>   -> drop a whole pack from your private packs (hard delete;
                        the image bytes stay on the homeserver)

In group rooms (when invited) it only responds to commands prefixed by the bot's
mxid mention or `!sticker`. The same `!random [pack]` works.

Config (env; the launcher sources a 0600 secrets file):
  STICKER_BOT_TOKEN          — Matrix access_token for the bot account
  STICKER_BOT_MXID           — the bot's mxid (e.g. @sticker-importer:server)
  STICKER_BOT_NAME           — display name used for mention matching
  HS_URL                     — loopback Matrix CS API (default 127.0.0.1:8448)
  STICKER_BACKEND_URL        — loopback sticker backend (default 127.0.0.1:8451)
  STICKER_PACKS_DIR          — path to the picker's packs/ root (read for !list/!random)
  MATRIX_SERVER_NAME         — this homeserver's server_name
  STICKER_URL_SECRET         — HMAC secret shared with the backend (signed identity)
"""
import hashlib
import hmac
import json
import os
import random
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

BOT_TOKEN  = os.environ["STICKER_BOT_TOKEN"]
BOT_MXID   = os.environ["STICKER_BOT_MXID"]
BOT_NAME   = os.environ.get("STICKER_BOT_NAME", "sticker-importer")
HS_URL     = os.environ.get("HS_URL", "http://127.0.0.1:8448").rstrip("/")
BACKEND    = os.environ.get("STICKER_BACKEND_URL", "http://127.0.0.1:8451").rstrip("/")
PACKS_DIR  = Path(os.environ.get("STICKER_PACKS_DIR", "/var/www/stickerpicker/packs"))
SERVER_NAME = os.environ.get("MATRIX_SERVER_NAME", "")

# The sticker backend verifies a signed identity (<mxid>|<hmac>) on its write
# endpoints. The bot is a trusted server-side proxy — it imports the
# *authenticated* DM sender's image to that sender's own pack — so it signs the
# sender's mxid with the shared secret (the same one the install step bakes into
# the per-user widget URLs). Read from the environment (set by the launcher);
# falls back to the on-disk secret file if present.
#
# SECURITY NOTE: the HMAC signing in _signed() below must stay byte-identical
# to sticker-backend.py:_sign_mxid() — same secret, message bytes, and digest —
# or the backend rejects every import in enforce mode.
_URL_SECRET = os.environ.get("STICKER_URL_SECRET", "")
if not _URL_SECRET:
    _secret_path = os.environ.get("STICKER_URL_SECRET_FILE", "")
    if _secret_path:
        try:
            _URL_SECRET = Path(_secret_path).read_text().strip()
        except Exception:
            _URL_SECRET = ""


def _signed(mxid):
    """Return <mxid>|<hmac> for the backend's identity check, or the bare mxid if
    no secret is available (the backend tolerates that in log mode).

    The HMAC is byte-identical to sticker-backend.py:_sign_mxid() (same secret,
    message bytes, and digest) — required, or the backend rejects every import in
    enforce mode.
    """
    if not _URL_SECRET:
        return mxid
    sig = hmac.new(_URL_SECRET.encode(), mxid.encode(), hashlib.sha256).hexdigest()
    return f"{mxid}|{sig}"


LOG_TS = lambda: time.strftime("%H:%M:%SZ", time.gmtime())
def log(msg): print(f"[{LOG_TS()}] {msg}", flush=True)

MXID_RE = re.compile(r"^@[a-z0-9._=\-/+]+:[a-z0-9.-]+$", re.I)

# ---------------------------------------------------------------- HTTP helpers

def _matrix(method, path, data=None, timeout=35, raw=False):
    url = f"{HS_URL}{path}"
    body = None
    headers = {"Authorization": f"Bearer {BOT_TOKEN}"}
    if data is not None:
        body = json.dumps(data).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=body, method=method, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        b = r.read()
        return b if raw else (json.loads(b) if b else {})

def _backend(method, path, data=None, timeout=15):
    url = f"{BACKEND}{path}"
    body = None
    headers = {}
    if data is not None:
        body = json.dumps(data).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=body, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read() or b"{}")
        except Exception:
            return e.code, {"error": str(e)}
    except Exception as e:
        return 0, {"error": str(e)}

# ---------------------------------------------------------------- Matrix verbs

def post_text(room_id, text, html=None):
    txn = f"sticker-importer-{int(time.time()*1000)}"
    payload = {"msgtype": "m.text", "body": text}
    if html:
        payload["format"] = "org.matrix.custom.html"
        payload["formatted_body"] = html
    try:
        _matrix("PUT", f"/_matrix/client/v3/rooms/{urllib.parse.quote(room_id)}/send/m.room.message/{txn}", data=payload, timeout=15)
    except Exception as e:
        log(f"post_text failed: {e}")

def post_sticker(room_id, sticker):
    """Send an m.sticker event using the sticker descriptor we stored."""
    txn = f"sticker-{int(time.time()*1000)}"
    info = sticker.get("info", {}) or {}
    payload = {
        "body": sticker.get("body", "sticker"),
        "info": info,
        "url": sticker.get("url"),
    }
    try:
        _matrix("PUT", f"/_matrix/client/v3/rooms/{urllib.parse.quote(room_id)}/send/m.sticker/{txn}", data=payload, timeout=15)
    except Exception as e:
        log(f"post_sticker failed: {e}")

def join_room(room_id):
    try:
        _matrix("POST", f"/_matrix/client/v3/rooms/{urllib.parse.quote(room_id)}/join", data={})
        log(f"joined {room_id}")
    except Exception as e:
        log(f"join {room_id} failed: {e}")

# ---------------------------------------------------------------- Packs

def _encode_mxid(mxid):
    # ":" must be in `safe` — the backend stores pack dirs as @user:server (raw
    # colon). Encoding ":" as %3A produces a path mismatch: list_user_packs finds
    # nothing, running_total stays 0, and all stickers label as "Sticker 1".
    return urllib.parse.quote(mxid, safe="@.:")

def user_pack_dir(mxid):
    return PACKS_DIR / "users" / _encode_mxid(mxid)

def list_user_packs(mxid):
    d = user_pack_dir(mxid)
    idx_path = d / "index.json"
    try:
        idx = json.loads(idx_path.read_text())
    except Exception:
        return []
    out = []
    for fn in idx.get("packs", []) or []:
        try:
            pdata = json.loads((d / fn).read_text())
            out.append({"file": fn, "id": pdata.get("id", fn), "title": pdata.get("title", fn), "stickers": pdata.get("stickers", []) or []})
        except Exception:
            continue
    return out

def pick_random_sticker(mxid, pack_filter=None):
    packs = list_user_packs(mxid)
    if pack_filter:
        pf = pack_filter.lower()
        packs = [p for p in packs if pf in (p["id"] or "").lower() or pf in (p["title"] or "").lower()]
    pool = []
    for p in packs:
        pool.extend(p["stickers"])
    if not pool:
        return None, packs
    return random.choice(pool), packs

def delete_user_pack(mxid, pack_match):
    d = user_pack_dir(mxid)
    idx_path = d / "index.json"
    try:
        idx = json.loads(idx_path.read_text())
    except Exception:
        return None
    pm = pack_match.lower()
    keep = []
    removed = None
    for fn in idx.get("packs", []) or []:
        try:
            pdata = json.loads((d / fn).read_text())
        except Exception:
            keep.append(fn); continue
        pid = (pdata.get("id") or fn).lower()
        ptitle = (pdata.get("title") or "").lower()
        if pm == pid or pm in ptitle or pm in pid or pm == fn.lower():
            removed = pdata.get("title", fn)
            try:
                (d / fn).unlink()
            except Exception:
                pass
            continue
        keep.append(fn)
    idx["packs"] = keep
    idx_path.write_text(json.dumps(idx, indent=2))
    return removed

# ---------------------------------------------------------------- Commands

HELP_TEXT = (
    "Send me an image and I'll add it to your private \"Mobile imports\" pack. "
    "Caption becomes the sticker label.\n\n"
    "Commands:\n"
    "  !help                     this message\n"
    "  !list                     list your packs (count + title)\n"
    "  !random [pack]            send a random sticker from your packs (or a specific pack)\n"
    "  !delete <pack>            drop a whole pack from your private packs"
)

def _render_help_html():
    return (
        "Send me an image and I'll add it to your private <b>Mobile imports</b> pack. "
        "Caption becomes the sticker label.<br><br>"
        "<b>Commands</b><br>"
        "<code>!help</code> — this message<br>"
        "<code>!list</code> — list your packs<br>"
        "<code>!random [pack]</code> — random sticker from your packs<br>"
        "<code>!delete &lt;pack&gt;</code> — drop a pack"
    )

def cmd_help(room, sender):
    post_text(room, HELP_TEXT, html=_render_help_html())

def cmd_list(room, sender):
    packs = list_user_packs(sender)
    if not packs:
        post_text(room, "You have no private packs yet. Send me an image to start one.")
        return
    lines = [f"You have {len(packs)} pack{'s' if len(packs)!=1 else ''}:"]
    for p in packs:
        n = len(p["stickers"])
        lines.append(f"• {p['title']} — {n} sticker{'s' if n!=1 else ''}")
    post_text(room, "\n".join(lines))

def cmd_random(room, sender, pack_filter=None):
    sticker, packs = pick_random_sticker(sender, pack_filter)
    if sticker is None:
        if pack_filter and not packs:
            post_text(room, f"No pack matched “{pack_filter}”.")
        else:
            post_text(room, "You have no stickers yet. Send me an image to get started.")
        return
    post_sticker(room, sticker)

def cmd_delete(room, sender, pack_filter):
    if not pack_filter:
        post_text(room, "Tell me which pack to delete: !delete <name>")
        return
    removed = delete_user_pack(sender, pack_filter)
    if removed:
        post_text(room, f"Removed pack “{removed}”. Sticker images stay on the server but won't show up for you any more.")
    else:
        post_text(room, f"No pack matched “{pack_filter}”.")

# ---------------------------------------------------------------- Event handler

def _clean_default_label(body: str, running_total: int) -> str:
    """Pick a sane default label for a mobile-uploaded sticker.

    Element Android sets the message body to the source file name (e.g.
    "Screenshot_20260428-203330.png" or "IMG_20260425.webp"). Those names are
    useless as a sticker label. If the body looks like one of those camera-roll
    patterns, fall back to a numbered "Sticker N"; otherwise treat the body as a
    user-supplied caption and keep it.
    """
    body = (body or "").strip()
    # Strip the extension first.
    stem = re.sub(r"\.[a-z0-9]{1,5}$", "", body, flags=re.I)
    if not stem:
        return f"Sticker {running_total + 1}"
    # Common camera-roll / screenshot patterns from Android, iOS, OEM galleries.
    junk = (
        r"^screenshot[\s_\-]*\d",        # Screenshot_2026..., Screenshot 2026...
        r"^img[\s_\-]*\d",                # IMG_20260425, IMG-1234
        r"^vid[\s_\-]*\d",                # video clips
        r"^image[\s_\-]*\d",              # image001, IMAGE_2026...
        r"^photo[\s_\-]*\d",              # photo_2026...
        r"^pxl[_\-]?\d",                  # Pixel naming
        r"^dsc[_\-]?\d",                  # DSCN/DSC files
        r"^snapchat",                     # Snapchat-... saves
        r"^whatsapp",                     # WhatsApp Image-...
        r"^\d{8}[_\-]\d",                 # 20260428-001234
    )
    s = stem.lower()
    if any(re.match(p, s) for p in junk):
        return f"Sticker {running_total + 1}"
    # Looks like a real caption — keep it (truncated to 64 chars).
    return stem[:64]


def handle_image(room, sender, ev):
    """User sent an image in DM -> import to their pack."""
    content = ev.get("content") or {}
    mxc = content.get("url") or ""
    info = content.get("info") or {}
    body = (content.get("body") or "").strip()
    existing_packs = list_user_packs(sender)
    running_total = sum(len(p["stickers"]) for p in existing_packs)
    label = _clean_default_label(body, running_total)
    if not mxc.startswith("mxc://"):
        post_text(room, "That's not a Matrix media URL — try uploading via Element's attach button.")
        return
    payload = {
        "user_id": _signed(sender),
        "mxc": mxc,
        "label": label,
        "mimetype": info.get("mimetype") or "image/png",
        "w": int(info.get("w") or 256),
        "h": int(info.get("h") or 256),
        "size": int(info.get("size") or 0),
    }
    code, resp = _backend("POST", "/api/import-mxc", data=payload, timeout=15)
    if code == 200:
        n_total = running_total + 1
        post_text(room, f"✓ Added “{label}” to your stickers. ({n_total} total — long-press in the picker to remove.)")
    else:
        post_text(room, f"Couldn't import: {resp.get('error', code)}")

def parse_command(text):
    """Returns (cmd, arg) or (None, None). Strips leading ! and bot mention."""
    text = (text or "").strip()
    # Remove the bot mention prefix if present.
    text = re.sub(rf"^@?{re.escape(BOT_NAME)}[:\s]+", "", text, flags=re.I)
    text = re.sub(rf"^@?{re.escape(BOT_MXID)}[:\s]+", "", text, flags=re.I)
    # Remove the leading !.
    if text.startswith("!"):
        text = text[1:]
    parts = text.split(None, 1)
    if not parts:
        return None, None
    cmd = parts[0].lower()
    arg = parts[1].strip() if len(parts) > 1 else ""
    return cmd, arg

# Per-room DM cache. Reading m.room.member events from the INCREMENTAL sync delta
# is unreliable (it is almost always empty), which would misclassify every group
# room as a DM and auto-stickerify uploads. We hit /joined_members directly with
# a TTL cache instead.
_DM_CACHE: dict = {}
_DM_TTL_S = 300

def _dm_cache_invalidate(room_id):
    _DM_CACHE.pop(room_id, None)

def is_dm(room_id):
    """A 1:1 DM has exactly two joined members (the user + the bot).

    Queries /joined_members once per room, cached for _DM_TTL_S seconds. The
    cache is invalidated by process_sync when an m.room.member timeline event is
    seen for the room.
    """
    now = time.time()
    cached = _DM_CACHE.get(room_id)
    if cached and (now - cached[0]) < _DM_TTL_S:
        return cached[1]
    try:
        resp = _matrix("GET", f"/_matrix/client/v3/rooms/{urllib.parse.quote(room_id)}/joined_members", timeout=15)
        joined = resp.get("joined") or {}
        verdict = len(joined) <= 2
    except Exception as e:
        log(f"joined_members lookup failed for {room_id}: {e} — defaulting to non-DM")
        verdict = False
    _DM_CACHE[room_id] = (now, verdict)
    return verdict

def handle_message(room_id, ev, in_dm):
    sender = ev.get("sender") or ""
    if sender == BOT_MXID or not MXID_RE.match(sender):
        return
    content = ev.get("content") or {}
    msgtype = content.get("msgtype") or ""
    body = (content.get("body") or "").strip()

    if msgtype == "m.image":
        # Only auto-import in DM. In group rooms we'd be too noisy.
        if in_dm:
            handle_image(room_id, sender, ev)
        return

    if msgtype != "m.text":
        return

    # In group rooms, only respond if mentioned or `!sticker` prefixed.
    if not in_dm:
        if not (body.startswith("!sticker") or BOT_MXID in body or BOT_NAME in body):
            return
        # Strip the `!sticker ` prefix if present.
        body = re.sub(r"^!sticker\s*", "", body)

    cmd, arg = parse_command(body)
    if cmd in ("help", "?"):
        cmd_help(room_id, sender)
    elif cmd == "list":
        cmd_list(room_id, sender)
    elif cmd in ("random", "rand"):
        cmd_random(room_id, sender, pack_filter=arg or None)
    elif cmd in ("delete", "del", "remove"):
        cmd_delete(room_id, sender, arg)
    elif in_dm and not cmd:
        # Empty DM message — just nudge with help.
        cmd_help(room_id, sender)

# ---------------------------------------------------------------- Sync loop

def initial_sync():
    try:
        resp = _matrix("GET", "/_matrix/client/v3/sync?timeout=0", timeout=15)
        return resp.get("next_batch", "")
    except Exception as e:
        log(f"initial sync failed: {e}")
        return ""

def process_sync(resp):
    invites = (resp.get("rooms") or {}).get("invite") or {}
    for room_id in invites.keys():
        log(f"invite -> joining {room_id}")
        join_room(room_id)
    joins = (resp.get("rooms") or {}).get("join") or {}
    for room_id, rdata in joins.items():
        events = (rdata.get("timeline") or {}).get("events") or []
        # Invalidate the DM cache if membership changed in this batch — a
        # join/leave/invite flips DM-vs-group classification.
        for ev in events:
            if ev.get("type") == "m.room.member":
                _dm_cache_invalidate(room_id)
                break
        in_dm = is_dm(room_id)
        for ev in events:
            if ev.get("type") == "m.room.message":
                try:
                    handle_message(room_id, ev, in_dm)
                except Exception as e:
                    log(f"handle_message error in {room_id}: {e}")

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
            time.sleep(backoff); backoff = min(backoff * 2, 60)
        except Exception as e:
            log(f"sync error: {e}")
            time.sleep(backoff); backoff = min(backoff * 2, 60)

def main():
    log(f"booting as {BOT_MXID} (name={BOT_NAME})")
    log(f"  STICKER_PACKS_DIR={PACKS_DIR}, BACKEND={BACKEND}")
    if not PACKS_DIR.exists():
        log("WARN: STICKER_PACKS_DIR doesn't exist yet — !random / !list stay empty until users upload")
    try:
        sync_loop()
    except KeyboardInterrupt:
        log("shutdown (SIGINT)")

if __name__ == "__main__":
    main()
