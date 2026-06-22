#!/usr/bin/env python3
"""matrix_admin.py — drive continuwuity's admin command room from the CLI.

continuwuity (the conduwuit-family homeserver this stack runs) administers users
through an ADMIN ROOM, not a full HTTP admin API: you send a command as a message
in `#admins:<server>` and the server's admin bot replies in the room. This helper
does exactly that, robustly:

  1. read the operator's access token + MXID from the 0600 admin-credentials.env
     (written by bootstrap/create-admin.sh) — token via env/file, never on argv;
  2. resolve the admin room (alias #admins: then #admin:, or $ADMIN_ROOM_ID);
  3. make sure the operator's account has JOINED it (idempotent);
  4. send the command as a message;
  5. capture the bot's reply (the first non-operator message after ours) and print
     it VERBATIM, so this keeps working even as continuwuity's exact wording or the
     set of subcommands changes — we never parse the reply, we relay it.

Command prefix: continuwuity issues admin commands as `!admin <args>` (the default
here). If your build expects bare `<args>` in the admin room, set
MATRIX_ADMIN_PREFIX='' (empty). It is the one knob that absorbs version drift.

Usage:
    matrix_admin.py users list-users
    matrix_admin.py users create-user alice
    matrix_admin.py users deactivate @alice:example.org
(every argument after argv[0] becomes the command, joined by spaces).

IMPORTANT: anything the bot prints (e.g. a generated password) lands in the admin
room's history. Treat that room as sensitive. See docs/USERS.md.

Exit codes: 0 = sent and got a reply · 4 = sent but no reply within the timeout
· 2 = setup/usage error. Live verification is operator-owed (it needs the running
homeserver). Generalized from a working deployment; review before running.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

HS = (os.environ.get("MATRIX_HS_API") or os.environ.get("MATRIX_LOOPBACK")
      or "http://127.0.0.1:8448").rstrip("/")
DATA_DIR = os.environ.get("DATA_DIR", "")
CRED_FILE = os.environ.get("ADMIN_CRED_FILE") or os.path.join(
    DATA_DIR, "secrets", "admin-credentials.env")
PREFIX = os.environ.get("MATRIX_ADMIN_PREFIX", "!admin")
REPLY_TIMEOUT = int(os.environ.get("MATRIX_ADMIN_TIMEOUT", "25"))
UA = "pocket-matrix-admin/1"


def _die(msg, code=2):
    print(f"matrix_admin: {msg}", file=sys.stderr)
    sys.exit(code)


def _load_creds():
    if not os.path.isfile(CRED_FILE):
        _die(f"admin credentials not found at {CRED_FILE} — run "
             f"scripts/bootstrap/create-admin.sh first", code=2)
    d = {}
    try:
        with open(CRED_FILE) as fh:
            for ln in fh:
                ln = ln.strip()
                if not ln or ln.startswith("#") or "=" not in ln:
                    continue
                k, _, v = ln.partition("=")
                d[k.strip()] = v.strip().strip('"').strip("'")
    except OSError as ex:
        _die(f"cannot read {CRED_FILE}: {ex}", code=2)
    tok = d.get("ADMIN_TOKEN", "")
    if not tok:
        _die(f"ADMIN_TOKEN missing in {CRED_FILE}", code=2)
    return tok, d.get("ADMIN_MXID", ""), d.get("SERVER_NAME", "")


TOKEN, MXID, SERVER = _load_creds()


def _req(method, path, body=None, timeout=20):
    url = HS + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, method=method, data=data)
    req.add_header("Authorization", f"Bearer {TOKEN}")
    req.add_header("User-Agent", UA)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read()
        return resp.status, (json.loads(raw) if raw else {})


def _resolve_room():
    rid = os.environ.get("ADMIN_ROOM_ID")
    if rid:
        return rid
    if not SERVER:
        _die("SERVER_NAME unknown (not in admin-credentials.env) and ADMIN_ROOM_ID "
             "unset — cannot find the admin room", code=2)
    for alias in (f"#admins:{SERVER}", f"#admin:{SERVER}"):
        try:
            _, d = _req("GET", "/_matrix/client/v3/directory/room/"
                        + urllib.parse.quote(alias, safe=""))
            if d.get("room_id"):
                return d["room_id"]
        except urllib.error.HTTPError:
            continue
        except urllib.error.URLError as ex:
            _die(f"homeserver unreachable at {HS}: {ex.reason}", code=2)
    _die("could not resolve the admin room (#admins: / #admin:). If your server "
         "uses a different admin room, set ADMIN_ROOM_ID. The operator account may "
         "also need to be a server admin (see bootstrap/create-admin.sh).", code=2)


def _ensure_joined(room_id):
    try:
        _req("POST", "/_matrix/client/v3/join/"
             + urllib.parse.quote(room_id, safe=""), body={})
    except urllib.error.HTTPError as ex:
        # 403 = invite required / already-membership quirks; surface anything that
        # isn't a benign already-joined. Most servers return 200 even if joined.
        if ex.code not in (200, 403):
            _die(f"could not join the admin room ({ex.code}); is the operator "
                 f"account a member/admin? {ex.reason}", code=2)


def _send_and_reply(room_id, command):
    txn = str(int(time.time() * 1000))
    msg = (f"{PREFIX} {command}" if PREFIX else command)
    try:
        _, ev = _req("PUT", f"/_matrix/client/v3/rooms/"
                     f"{urllib.parse.quote(room_id, safe='')}"
                     f"/send/m.room.message/{txn}",
                     body={"msgtype": "m.text", "body": msg})
    except urllib.error.HTTPError as ex:
        _die(f"could not post the command ({ex.code}): {ex.reason}", code=2)
    our_id = ev.get("event_id")
    deadline = time.time() + REPLY_TIMEOUT
    while time.time() < deadline:
        time.sleep(1.5)
        try:
            _, data = _req("GET", f"/_matrix/client/v3/rooms/"
                           f"{urllib.parse.quote(room_id, safe='')}"
                           f"/messages?dir=b&limit=50")
        except urllib.error.HTTPError:
            continue
        replies = []
        for ev2 in data.get("chunk", []):  # newest-first
            if ev2.get("event_id") == our_id:
                break
            if ev2.get("type") != "m.room.message":
                continue
            if ev2.get("sender") == MXID:
                continue
            body = (ev2.get("content") or {}).get("body") or ""
            if body:
                replies.append(body)
        if replies:
            replies.reverse()  # oldest first = the order the bot answered
            return "\n".join(replies)
    return None


def main(argv):
    if len(argv) < 2:
        _die("usage: matrix_admin.py <command words...>   e.g. users list-users")
    command = " ".join(argv[1:]).strip()
    if not command:
        _die("empty command")
    room = _resolve_room()
    _ensure_joined(room)
    reply = _send_and_reply(room, command)
    if reply is None:
        print(f"(command sent to the admin room, but no reply within "
              f"{REPLY_TIMEOUT}s — open the admin room in Element to check)",
              file=sys.stderr)
        return 4
    print(reply)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except urllib.error.URLError as ex:
        _die(f"homeserver unreachable at {HS}: {ex.reason}", code=2)
