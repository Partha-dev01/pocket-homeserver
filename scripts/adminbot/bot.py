#!/usr/bin/env python3
"""pocket-homeserver — admin bot (operator-restricted Matrix ops bot).

A tiny Matrix bot that lets the OPERATOR drive the stack from a chat room. It
listens in ONE admin room (ADMIN_ROOM), accepts `!commands` ONLY from the
operator's MXID (ADMIN_MXID), and maps each command to a small, fixed set of
actions:

  * a SHELL dispatch table -> the repo's ops scripts (scripts/ops/*.sh). The
    bot never passes user input to a shell: each command maps to a FIXED argv,
    invoked with subprocess (no shell=True). stdout+stderr is posted back as a
    code block, truncated.
  * a few in-process Matrix queries (list users sharing a room with the
    operator, current registration token) over the loopback client-server API.
  * the user-directory PRIVATE list (private-users.txt): list / add / remove
    MXIDs that should be hidden from directory search. Edited in-process — never
    via a shell — and each MXID is validated against a strict regex first.

stdlib only — no third-party packages. The homeserver is reached on loopback
(http://127.0.0.1:8448 by default). Everything operator-specific (server name,
room, operator MXID, tokens, data dir) comes from the environment / a 0600
secrets file that the launcher (steps/83-install-adminbot.sh) sources; nothing
operator-specific is baked in.

Config via env (the install step sets these from .env + secrets/adminbot.env):
  HS_API        — Matrix client-server API base (default http://127.0.0.1:8448)
  BOT_TOKEN     — @adminbot access token (REQUIRED; off-argv, from 0600 file)
  ADMIN_ROOM    — room ID the bot listens in        (REQUIRED)
  ADMIN_MXID    — the operator MXID allowed to act   (REQUIRED)
  ADMIN_TOKEN   — operator access token for admin-scope queries (OPTIONAL)
  POCKET_ROOT   — repo root; ops scripts live in ${POCKET_ROOT}/scripts/ops
  DATA_DIR      — large volume; secrets under ${DATA_DIR}/secrets
  MATRIX_SERVER_NAME — the :server half of an MXID (for display only)

Generalized from a working deployment; review before running on a fresh phone.
"""
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

# ---- config (env-overridable; the install step wires these) ----------------
HS_API      = os.environ.get("HS_API", "http://127.0.0.1:8448").rstrip("/")
# BOT_TOKEN / ADMIN_ROOM / ADMIN_MXID are REQUIRED and come from the 0600
# secrets file the launcher sources — never embedded, never on argv.
BOT_TOKEN   = os.environ.get("BOT_TOKEN", "")
ADMIN_ROOM  = os.environ.get("ADMIN_ROOM", "")
ADMIN_MXID  = os.environ.get("ADMIN_MXID", "")
SERVER_NAME = os.environ.get("MATRIX_SERVER_NAME", "")

# Repo root → where the ops scripts live. The dispatch table (below) maps each
# `!command` to a FIXED relative path under this directory.
POCKET_ROOT = os.environ.get("POCKET_ROOT", os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
OPS_DIR     = os.path.join(POCKET_ROOT, "scripts", "ops")

# Per-component data: secrets live under ${DATA_DIR}/secrets, the private-users
# list among them. DATA_DIR is required for the private-list commands.
DATA_DIR     = os.environ.get("DATA_DIR", "")
SECRETS_DIR  = os.path.join(DATA_DIR, "secrets") if DATA_DIR else ""
PRIVATE_FILE = os.path.join(SECRETS_DIR, "private-users.txt") if SECRETS_DIR else ""

# Append-only audit trail for operator-impacting commands (mirrors the admin
# panel's audit schema). Under ${POCKET_LOG_DIR} so it survives userland wipes.
LOG_DIR    = os.environ.get("POCKET_LOG_DIR") or (
    os.path.join(DATA_DIR, "logs") if DATA_DIR else "")
AUDIT_FILE = os.path.join(LOG_DIR, "admin-audit.log") if LOG_DIR else ""


# ════════════════════════════════════════════════════════════════════════════
# SECURITY MODEL — the operator-restriction gate + the command->script map are
# the entire trust boundary of this bot:
#
#   1. ADMIN_MXID restriction — handle() drops every message whose `sender` is
#      not EXACTLY ADMIN_MXID (a single exact-string compare; no prefix/substring
#      match). An empty ADMIN_MXID fails CLOSED (refuses every command). This is
#      the only gate before dispatch.
#
#   2. COMMANDS map — a FIXED dict of command -> (argv-list, timeout). Every
#      argv[0] is a literal script name; nothing from the chat message is ever
#      interpolated. run_script() uses subprocess with a list argv and NO
#      shell=True, and asserts the resolved path stays under POCKET_ROOT/scripts.
#      Destructive ops also go through the _need_confirm() two-step gate.
#
#   3. BOT_TOKEN / ADMIN_TOKEN — BOT_TOKEN is REQUIRED, arrives via the env
#      (sourced from a 0600 file by the launcher), never on argv, never logged.
#      ADMIN_TOKEN is OPTIONAL; when absent, privileged queries fail loud rather
#      than downgrading to BOT_TOKEN scope.
# ════════════════════════════════════════════════════════════════════════════

# command -> (argv-after-OPS_DIR, max-seconds). FIXED — no chat input is ever
# appended to these argv lists. These mirror the repo's ops scripts (NOT the
# private source's numbered scripts).
#
# Each path resolves under POCKET_ROOT/scripts (run_script asserts this): status
# is read-only; the rest mutate state, and restart-stack is confirm-gated.
COMMANDS = {
    "status":         (["status.sh"],                       30),
    "backup-now":     (["backup-db.sh"],                    300),
    "full-backup":    (["backup-all.sh"],                   900),
    "rotate-backups": (["rotate-backups.sh"],               60),
    "restart-stack":  (["../start-stack.sh", "--restart"],  180),
}

# Commands worth recording in the audit trail (anything that mutates user state,
# reveals a secret, or runs a script). Read-only help/whoami are skipped. The
# COMMANDS keys are added dynamically in handle().
AUDITED_COMMANDS = {
    "invite-token", "private-add", "private-remove", "restart-stack",
    "backup-now", "full-backup", "rotate-backups",
}


def handle(event):
    """Dispatch ONE m.room.message event. The SECURITY GATE lives here: only the
    exact operator MXID is obeyed, and dispatch goes only through fixed branches."""
    c = event.get("content", {}) or {}
    body = (c.get("body") or "").strip()
    sender = event.get("sender")
    # --- operator restriction: the ONLY gate. Exact-match; empty ADMIN_MXID
    #     refuses everything (fail-closed). ---
    if not ADMIN_MXID or sender != ADMIN_MXID or not body.startswith("!"):
        return
    parts = body[1:].split()
    if not parts:
        return
    cmd, args = parts[0], parts[1:]
    log(f"cmd from {sender}: !{' '.join(parts)}")

    # Audit operator-impacting commands BEFORE execution, so a crashing script
    # still leaves a trace.
    if cmd in AUDITED_COMMANDS or cmd in COMMANDS:
        _audit(sender, cmd, args, body)

    if cmd == "help":
        reply(help_text())
    elif cmd == "whoami":
        reply(f"I am the pocket-homeserver admin bot. Listening in room `{ADMIN_ROOM}`.")
    elif cmd == "invite-token":
        reply(cmd_invite_token())
    elif cmd == "users":
        out = cmd_users()
        if len(out) > 16384:
            out = out[:16384] + "\n\n…[truncated]"
        reply(out)
    elif cmd == "private-list":
        reply(cmd_private_list())
    elif cmd == "private-add":
        reply(cmd_private_add(args))
    elif cmd == "private-remove":
        reply(cmd_private_remove(args))
    elif cmd in COMMANDS:
        spec, timeout = COMMANDS[cmd]
        # Destructive script ops require a confirm-within-60s re-run.
        if cmd in ("restart-stack",):
            confirmed, msg = _need_confirm(sender, cmd, " ".join(args),
                f"⚠ `!{cmd}` will restart the stack (brief outage). "
                f"Re-run `!{cmd}` within 60s to confirm.")
            if not confirmed:
                reply(msg)
                return
        reply(f"▶ running `!{cmd}`…")
        rc, out = run_script(spec, timeout)
        icon = "✅" if rc == 0 else "❌"
        send(f"{icon} exit={rc}\n{out}", html=f"{icon} exit={rc}{code_block(out)}")
    else:
        reply(f"❓ unknown: `!{cmd}` (try `!help`)")


def run_script(argv, timeout):
    """Run a FIXED ops script (argv[0] is a literal name from the COMMANDS dict,
    never chat input). subprocess with a list argv + NO shell=True.

    Defense-in-depth: although argv[0] is never user-controlled, assert the
    resolved path stays under POCKET_ROOT/scripts (this allows scripts/ops/* and
    the one deliberate `../start-stack.sh`, and refuses anything that escapes the
    scripts tree) so a future bad COMMANDS entry can't run an arbitrary path."""
    scripts_root = os.path.realpath(os.path.join(POCKET_ROOT, "scripts"))
    script = os.path.realpath(os.path.join(OPS_DIR, argv[0]))
    if script != scripts_root and not script.startswith(scripts_root + os.sep):
        return -2, f"refused: {argv[0]} resolves outside {scripts_root}"
    cmd = ["bash", script] + argv[1:]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, (p.stdout + p.stderr).strip()
    except subprocess.TimeoutExpired:
        return -1, f"timed out after {timeout}s"
    except Exception as e:
        return -2, f"error: {e}"


# ---- confirm-gate for destructive commands ----------------------------------
# First call → store the pending request + reply with a prompt. A second
# matching call within _CONFIRM_TTL → execute. The key includes the args so two
# different targets don't satisfy each other.
_PENDING_CONFIRMS = {}  # (operator, cmd_name) -> {"args": str, "ts": float}
_CONFIRM_TTL = 60.0


def _need_confirm(operator, cmd_name, args_str, prompt_msg):
    key = (operator, cmd_name)
    now = time.time()
    p = _PENDING_CONFIRMS.get(key)
    if p and p["args"] == args_str and now - p["ts"] < _CONFIRM_TTL:
        del _PENDING_CONFIRMS[key]
        return True, None
    _PENDING_CONFIRMS[key] = {"args": args_str, "ts": now}
    return False, prompt_msg


# ---- Matrix HTTP helpers -----------------------------------------------------
def _req(method, path, data=None, timeout=35, tok_override=None):
    """Low-level client-server API call. Uses BOT_TOKEN unless `tok_override` is
    given. The credential is interpolated into the Authorization header only and
    is never logged."""
    body = json.dumps(data).encode() if data is not None else None
    tok = tok_override if tok_override else BOT_TOKEN
    req = urllib.request.Request(
        HS_API + path, data=body, method=method,
        headers={"Authorization": f"Bearer {tok}",
                 "Content-Type":  "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read() or b"{}")


def _admin_req(method, path, data=None, timeout=35):
    """Request using the operator's ADMIN_TOKEN — for privileged queries (user
    listing etc.). ADMIN_TOKEN comes only from the env (sourced from the 0600
    adminbot.env by the launcher); this fails LOUD when it is absent rather than
    silently downgrading to BOT_TOKEN scope."""
    tok = os.environ.get("ADMIN_TOKEN", "")
    if not tok:
        raise RuntimeError("ADMIN_TOKEN unavailable (set it in the 0600 adminbot.env)")
    return _req(method, path, data, timeout, tok_override=tok)


def log(msg):
    print(f"[{time.strftime('%H:%M:%SZ', time.gmtime())}] {msg}", flush=True)


def send(text, html=None):
    """Send a message to ADMIN_ROOM. `text` is the plain body; `html` (if given)
    is the formatted_body. Clients that ignore HTML still see text."""
    txn = str(time.time_ns())
    content = {"msgtype": "m.text", "body": text}
    if html:
        content["format"]         = "org.matrix.custom.html"
        content["formatted_body"] = html
    path = f"/_matrix/client/v3/rooms/{urllib.parse.quote(ADMIN_ROOM)}/send/m.room.message/{txn}"
    try:
        _req("PUT", path, content)
    except Exception as e:
        log(f"send error: {e}")


# ---- markdown-ish → HTML renderer (subset Matrix clients actually render) ----
_BOLD_RE   = re.compile(r"\*\*([^\*]+?)\*\*")
_ITALIC_RE = re.compile(r"(?<![\w_])_([^_\n]+?)_(?![\w_])")
_CODE_RE   = re.compile(r"`([^`]+?)`")
_LINK_RE   = re.compile(r"\[([^\]]+)\]\((https?://[^)\s]+|mxc://[^)\s]+|matrix:[^)\s]+)\)")
_HEADER_RE = re.compile(r"^(#{1,6})\s+(.+)$")
_HR_RE     = re.compile(r"^---+\s*$")
_UL_RE     = re.compile(r"^[-*•]\s+(.+)$")
_OL_RE     = re.compile(r"^\d+\.\s+(.+)$")
_QUOTE_RE  = re.compile(r"^&gt;\s+(.+)$")


def _md_inline(text):
    """Inline markdown (bold/italic/code/links) on an already-HTML-escaped line."""
    out = _CODE_RE.sub(r"<code>\1</code>", text)
    out = _BOLD_RE.sub(r"<strong>\1</strong>", out)
    out = _ITALIC_RE.sub(r"<em>\1</em>", out)
    # HTML-escape the href so a URL containing `"` can't break out of the
    # attribute and inject new attributes into the rendered <a> tag (defence in
    # depth; the link TEXT was already escaped in _md_to_html before this runs).
    def _link_repl(m):
        href = (m.group(2).replace("&", "&amp;").replace('"', "&quot;")
                .replace("<", "&lt;").replace(">", "&gt;"))
        return f'<a href="{href}">{m.group(1)}</a>'
    out = _LINK_RE.sub(_link_repl, out)
    return out


def _md_to_html(text):
    """Markdown → HTML for a Matrix m.room.message formatted_body. HTML-escapes
    first so user-supplied `<script>` becomes literal."""
    text = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    lines = text.split("\n")
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
        lead = len(line) - len(line.lstrip(" "))
        rendered = "&nbsp;" * lead + _md_inline(line[lead:])
        para = [rendered]
        i += 1
        while i < len(lines):
            nxt = lines[i]
            if (not nxt.strip() or _HR_RE.match(nxt) or _HEADER_RE.match(nxt)
                    or _UL_RE.match(nxt) or _OL_RE.match(nxt) or _QUOTE_RE.match(nxt)):
                break
            lead = len(nxt) - len(nxt.lstrip(" "))
            para.append("&nbsp;" * lead + _md_inline(nxt[lead:]))
            i += 1
        out.append("<p>" + "<br>".join(para) + "</p>")
    return "".join(out)


def _md_to_plain(text):
    """Strip markdown syntax for the plain fallback body."""
    out = _BOLD_RE.sub(r"\1", text)
    out = _ITALIC_RE.sub(r"\1", out)
    out = _LINK_RE.sub(r"\1 (\2)", out)
    out = re.sub(r"^(#{1,6})\s+", "", out, flags=re.MULTILINE)
    out = re.sub(r"^&gt;\s+", "> ", out, flags=re.MULTILINE)
    return out


def reply(md_text):
    """Send a markdown-ish message; clients see rendered HTML, others see plain."""
    send(_md_to_plain(md_text), html=_md_to_html(md_text))


def code_block(text):
    if len(text) > 3000:
        text = text[:3000] + "\n... [truncated]"
    esc = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    return f"<pre><code>{esc}</code></pre>"


def help_text():
    lines = ["**commands**:"]
    for k in sorted(COMMANDS):
        lines.append(f"  !{k}")
    lines.extend([
        "  !invite-token          — current registration token",
        "  !whoami                — bot identity",
        "  !users                 — users sharing rooms with the operator",
        "  !private-list          — list private (hidden-from-search) users",
        "  !private-add <mxid>    — hide a user from directory search",
        "  !private-remove <mxid> — unhide a user",
        "  !help                  — this list",
    ])
    return "\n".join(lines)


# ---- MXID validator (strict, to prevent file-injection via an argument) ------
MXID_RE = re.compile(r"^@[A-Za-z0-9._=\-/]{1,64}:[A-Za-z0-9.\-]{1,255}$")


# ---- registration token ------------------------------------------------------
def cmd_invite_token():
    """Reveal the current registration token from the 0600 secrets file
    (${DATA_DIR}/secrets/registration-token.txt — the same file
    ops/rotate-registration-token.sh writes). Only the operator can reach this
    (handle()'s gate) and it is audited; the value is shown only in the private
    admin-ops room."""
    if not SECRETS_DIR:
        return "⚠ DATA_DIR not set — can't locate the registration token file"
    try:
        with open(os.path.join(SECRETS_DIR, "registration-token.txt")) as f:
            return f"**registration token** → `{f.read().strip()}`"
    except Exception as e:
        return f"⚠ couldn't read the registration token ({e})"


# ---- private-user management (in-process, no shell) --------------------------
def _read_private():
    if not PRIVATE_FILE:
        return []
    try:
        with open(PRIVATE_FILE) as f:
            return [l.strip() for l in f if l.strip() and not l.startswith("#")]
    except FileNotFoundError:
        return []
    except Exception as e:
        log(f"read private-users: {e}")
        return []


def _write_private(entries):
    """entries is a list of MXIDs. Keeps a fixed header; atomic replace."""
    header = [
        "# Private users (hidden from user_directory/search results).",
        "# One MXID per line. Lines starting with # are ignored.",
        "# Managed by the admin bot (!private-add / !private-remove / !private-list).",
    ]
    lines = header + [""] + entries + [""]
    tmp = PRIVATE_FILE + ".tmp"
    with open(tmp, "w") as f:
        f.write("\n".join(lines))
    os.replace(tmp, PRIVATE_FILE)


def cmd_private_add(args):
    if not SECRETS_DIR:
        return "⚠ DATA_DIR not set — can't manage the private list"
    if not args:
        return "usage: !private-add <mxid>"
    mxid = args[0]
    if not MXID_RE.match(mxid):
        return f"invalid MXID format: {mxid}"
    current = _read_private()
    if mxid in current:
        return f"{mxid} already in private list"
    _write_private(current + [mxid])
    return f"✅ added {mxid} to private list (now hidden from user-directory search)"


def cmd_private_remove(args):
    if not SECRETS_DIR:
        return "⚠ DATA_DIR not set — can't manage the private list"
    if not args:
        return "usage: !private-remove <mxid>"
    mxid = args[0]
    if not MXID_RE.match(mxid):
        return f"invalid MXID format: {mxid}"
    current = _read_private()
    if mxid not in current:
        return f"{mxid} not in private list"
    _write_private([x for x in current if x != mxid])
    return f"✅ removed {mxid} from private list (now visible again)"


def cmd_private_list():
    current = _read_private()
    if not current:
        return "private list is empty — all users are discoverable"
    return "**private users (hidden from search):**\n" + "\n".join(f"  • {x}" for x in current)


# ---- user listing (needs operator/admin scope) ------------------------------
def cmd_users():
    """List users sharing ≥1 room with the operator, via the operator's
    joined_rooms + joined_members. On a small invite-only server this catches
    everyone who joined at least one room the operator is in."""
    try:
        rooms = _admin_req("GET", "/_matrix/client/v3/joined_rooms",
                           timeout=10).get("joined_rooms", [])
    except Exception as e:
        return f"⚠ couldn't enumerate (need ADMIN_TOKEN): {e}"

    all_users = {}  # mxid → set of room_ids
    errors = 0
    for rid in rooms:
        try:
            enc = urllib.parse.quote(rid)
            r = _admin_req("GET", f"/_matrix/client/v3/rooms/{enc}/joined_members", timeout=10)
            for mxid in (r.get("joined") or {}).keys():
                all_users.setdefault(mxid, set()).add(rid)
        except Exception:
            errors += 1

    if not all_users:
        return f"no users found (scanned {len(rooms)} rooms, {errors} errors)"

    priv = set(_read_private())
    total = len(all_users)
    real = sorted(m for m in all_users if m != ADMIN_MXID)
    lines = [f"**users sharing a room with the operator: {total} total** ({errors} errors)"]
    lines.append("")
    lines.append("**operator (1):**")
    lines.append(f"  • {ADMIN_MXID}  ({len(all_users.get(ADMIN_MXID, []))} rooms)")
    if real:
        lines.append("")
        lines.append(f"**other users ({len(real)}):**")
        for m in real:
            nrooms = len(all_users[m])
            marker = " 🔒 PRIVATE" if m in priv else ""
            lines.append(f"  • {m}{marker}  ({nrooms} shared room{'s' if nrooms != 1 else ''})")
    lines.append("")
    lines.append("_Note_: shows users sharing ≥1 room with the operator. Someone who "
                 "signed up but joined no shared room won't appear here.")
    return "\n".join(lines)


# ---- audit -------------------------------------------------------------------
def _audit(operator, cmd, args, body):
    """Append a JSON line to the audit log (best-effort; never raises). Matches
    the admin panel's schema: ts, user, source, action, cmd, args, body_prefix."""
    if not AUDIT_FILE:
        return
    try:
        os.makedirs(os.path.dirname(AUDIT_FILE), exist_ok=True)
        rec = {
            "ts":     time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "user":   operator,
            "source": "adminbot",
            "action": "cmd",
            "cmd":    cmd,
            "args":   " ".join(args)[:200].replace("\n", " "),
            "body_prefix": body[:160].replace("\n", " "),
        }
        with open(AUDIT_FILE, "a") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    except Exception as e:
        log(f"audit write failed: {e}")


# ---- main loop ---------------------------------------------------------------
def main():
    # Fail-closed on missing required config so a misconfigured bot can't run
    # wide-open. (The operator gate in handle() also fails closed.)
    if not BOT_TOKEN:
        sys.stderr.write("FATAL: BOT_TOKEN is empty — set it in the 0600 adminbot.env\n")
        sys.exit(1)
    if not ADMIN_ROOM or not ADMIN_MXID:
        sys.stderr.write("FATAL: ADMIN_ROOM and ADMIN_MXID are required\n")
        sys.exit(1)

    log(f"booting; bot_token_len={len(BOT_TOKEN)}")
    try:
        init = _req("GET", "/_matrix/client/v3/sync?timeout=0", timeout=10)
        since = init.get("next_batch", "")
        log(f"initial sync got next_batch (len {len(since)})")
    except Exception as e:
        log(f"initial sync failed: {e}; will retry in main loop")
        since = ""

    send(f"🤖 adminbot online at {time.strftime('%Y-%m-%d %H:%M:%SZ', time.gmtime())}. try !help")

    backoff = 2
    while True:
        try:
            params = urllib.parse.urlencode({"timeout": 25000, "since": since})
            resp = _req("GET", f"/_matrix/client/v3/sync?{params}", timeout=35)
            since = resp.get("next_batch", since)
            backoff = 2
            room_data = resp.get("rooms", {}).get("join", {}).get(ADMIN_ROOM, {})
            for event in room_data.get("timeline", {}).get("events", []):
                if event.get("type") == "m.room.message":
                    handle(event)
        except urllib.error.HTTPError as e:
            log(f"http {e.code}: {e.reason}")
            time.sleep(backoff); backoff = min(backoff * 2, 60)
        except Exception as e:
            log(f"sync error: {e}")
            time.sleep(backoff); backoff = min(backoff * 2, 60)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        log("shutting down (SIGINT)")
