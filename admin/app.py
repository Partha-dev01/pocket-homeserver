#!/usr/bin/env python3
"""pocket-homeserver — web admin panel.

A small, single-file Flask app that gives you a phone-friendly control panel for
the stack: live health + device stats, a log viewer, service restarts, backups,
the registration token, and a guarded "danger zone" for break-glass actions
(rotations + panic kill-switches). It runs Termux-native (NOT inside the proot
userland) because its whole job is to orchestrate the host — it shells out to the
service scripts, reads the supervisor pidfiles, and pgrep's the host processes.

SECURITY INVARIANTS:
  - Binds 127.0.0.1 ONLY; reached via Caddy (public, behind Cloudflare Access) or
    a loopback `ssh -L` tunnel.
  - Auth: scrypt password + signed session cookie + idle timeout.
  - CSRF on every POST (double-submit token).
  - Per-IP brute-force lockout (in-memory + persisted) — REQUIRES a single worker.
  - Optional Cloudflare Access JWT validation (RS256, pure stdlib) on every request
    that carries the header.
  - Scripts: allowlist only, no shell=True, no user input reaches a shell.
  - Filesystem delete: strict basename + bucket validation + realpath containment.
  - Audit log: every action.

Generalized from a working deployment; review before running on a fresh phone.
"""
import base64
import hashlib
import hmac
import html
import json
import os
import re
import secrets
import subprocess
import sys
import threading
import time
import urllib.request
from functools import wraps

# Force this process (incl. Werkzeug's request logger) to stamp times in UTC,
# regardless of the device timezone, so logs/audits are consistent and comparable.
os.environ["TZ"] = "UTC"
try:
    time.tzset()
except Exception:
    pass

from flask import Flask, request, session, redirect, url_for, abort, make_response
from werkzeug.middleware.proxy_fix import ProxyFix


# ---------- config (all from the environment; set by steps/70-install-admin.sh) ----------
def _env(name, default=""):
    return os.environ.get(name, default)

def _flag(name):
    return _env(name, "false").strip().lower() == "true"

DATA_DIR    = _env("DATA_DIR")                       # large volume (required)
POCKET_ROOT = _env("POCKET_ROOT")                    # repo root — where scripts/ lives (required)
SCRIPTS     = os.path.join(POCKET_ROOT, "scripts")
SECRETS     = os.path.join(DATA_DIR, "secrets")
STATE       = _env("POCKET_STATE_DIR") or os.path.join(DATA_DIR, "state")
LOGS        = _env("POCKET_LOG_DIR")   or os.path.join(DATA_DIR, "logs")
BACKUP_DIR  = _env("BACKUP_DIR")       or os.path.join(DATA_DIR, "backups")

PASSWORD_FILE       = os.path.join(SECRETS, "adminweb-password.hash")
SESSION_SECRET_FILE = os.path.join(SECRETS, "adminweb-session.bin")
AUDIT_LOG           = os.path.join(LOGS, "admin-audit.log")

BIND_HOST   = "127.0.0.1"
BIND_PORT   = int(_env("ADMINWEB_PORT", "9000") or "9000")

DOMAIN      = _env("DOMAIN", "localhost")
ADMIN_HOST  = _env("ADMIN_HOST") or f"admin.{DOMAIN}"
ADMIN_USER  = _env("ADMIN_USER", "admin")
BRAND       = _env("ADMIN_BRAND") or "pocket-homeserver"
CADDY_BIND  = _env("CADDY_BIND", "127.0.0.1")
CADDY_PORT  = _env("CADDY_PORT", "8443")
AUTHGW_PORT = _env("AUTHGW_PORT", "9095")
IDLE_SECONDS = int(_env("ADMIN_IDLE_MINUTES", "30") or "30") * 60

# Which optional apps are enabled (drives the health checks + restart buttons so a
# disabled app is never shown as a false DOWN).
ENABLE = {
    "auth-gw":  _flag("ENABLE_AUTH_GATEWAY"),
    "linkding": _flag("ENABLE_LINKDING"),
    "pingvin":  _flag("ENABLE_PINGVIN"),
    "freshrss": _flag("ENABLE_FRESHRSS"),
    "memos":    _flag("ENABLE_MEMOS"),
    "vikunja":  _flag("ENABLE_VIKUNJA"),
    "searxng":  _flag("ENABLE_SEARXNG"),
    "ittools":  _flag("ENABLE_ITTOOLS"),
    "gatus":    _flag("ENABLE_GATUS"),
}

# Script allowlist — the ONLY scripts a click can run, relative to scripts/. No
# shell=True; no user input ever reaches a shell (run_script joins fixed argv).
SCRIPTS_OK = {
    "status":            {"argv": ["ops/status.sh"],                   "kind": "info"},
    "backup-now":        {"argv": ["ops/backup-db.sh"],                "kind": "mutate"},
    "full-backup":       {"argv": ["ops/backup-all.sh"],              "kind": "async"},
    "rotate-backups":    {"argv": ["ops/rotate-backups.sh"],          "kind": "mutate"},
    "restart-stack":     {"argv": ["start-stack.sh", "--restart"],    "kind": "restart"},
    # per-service restarts → ops/restart.sh <name> (re-supervises from the recorded cmd)
    "restart-matrix":      {"argv": ["ops/restart.sh", "matrix"],          "kind": "restart"},
    "restart-caddy":       {"argv": ["ops/restart.sh", "caddy"],           "kind": "restart"},
    "restart-cloudflared": {"argv": ["ops/restart.sh", "cloudflared"],     "kind": "restart"},
    "restart-auth-gw":     {"argv": ["ops/restart.sh", "auth-gw"],         "kind": "restart"},
    # restarting the panel kills the worker handling THIS request → run detached.
    "restart-adminweb":    {"argv": ["ops/restart.sh", "adminweb"],        "kind": "async"},
    "restart-linkding":      {"argv": ["ops/restart.sh", "linkding"],       "kind": "restart"},
    "restart-linkding-tasks":{"argv": ["ops/restart.sh", "linkding-tasks"], "kind": "restart"},
    "restart-pingvin":     {"argv": ["ops/restart.sh", "pingvin"],         "kind": "restart"},
    "restart-freshrss":    {"argv": ["ops/restart.sh", "freshrss"],        "kind": "restart"},
    "restart-searxng":     {"argv": ["ops/restart.sh", "searxng"],         "kind": "restart"},
    "restart-memos":       {"argv": ["ops/restart.sh", "memos"],           "kind": "restart"},
    "restart-vikunja":     {"argv": ["ops/restart.sh", "vikunja"],         "kind": "restart"},
    "restart-gatus":       {"argv": ["ops/restart.sh", "gatus"],           "kind": "restart"},
    # danger-tier (go through the two-page typed confirmation)
    "rotate-reg-token":  {"argv": ["ops/rotate-registration-token.sh"], "kind": "danger"},
    "rotate-admin-pass": {"argv": ["ops/rotate-admin-password.sh"],      "kind": "danger"},
    "panic-soft":        {"argv": ["ops/panic-soft.sh"],                "kind": "danger"},
    "panic-hard":        {"argv": ["ops/panic-hard.sh"],                "kind": "danger"},
}

# Danger metadata: impact + reversibility + a per-action confirmation phrase
# (deliberately varied to defeat muscle-memory).
DANGER_META = {
    "rotate-reg-token": {
        "title": "Rotate registration token",
        "phrase": "rotate token",
        "impact": [
            "The homeserver restarts → a brief (tens of seconds) chat interruption.",
            "The current shared invite token becomes INVALID immediately.",
            "Token-gated registration is (re)enabled with the new token.",
            "Anyone still mid-signup must be given the new token; already-registered users are unaffected.",
        ],
        "reversible": False,
    },
    "rotate-admin-pass": {
        "title": "Rotate admin password",
        "phrase": "change admin password",
        "impact": [
            "The web admin panel login password is replaced with a fresh random one.",
            "No server downtime; your CURRENT session stays signed in.",
            "The new password is shown ONCE on the result page — save it then.",
            "New logins require the new password.",
        ],
        "reversible": False,
    },
    "panic-soft": {
        "title": "Soft panic (cut public access)",
        "phrase": "soft panic",
        "impact": [
            "Stops the Cloudflare Tunnel — the box is no longer reachable from the internet.",
            "All local/loopback services keep running; you can still administer locally.",
            "Fully reversible: restart the stack to restore public access.",
        ],
        "reversible": True,
    },
    "panic-hard": {
        "title": "Hard panic (whole stack offline)",
        "phrase": "hard panic",
        "impact": [
            "Stops cloudflared, Caddy, the homeserver, the auth gateway, and all apps.",
            "The admin panel itself is preserved so you can recover from loopback.",
            "Reversible: restart the stack, then your app scripts.",
        ],
        "reversible": True,
    },
    "restart-stack": {
        "title": "Restart the core stack",
        "phrase": "restart stack",
        "impact": [
            "Restarts matrix + Caddy + cloudflared in order.",
            "Brief ingress outage while the tunnel reconnects (tens of seconds).",
            "Apps are not touched.",
        ],
        "reversible": True,
    },
    "delete-backup": {
        "title": "Delete backup",
        "phrase": "delete backup",
        "impact": [
            "Permanently removes the selected backup archive and its checksum sidecar.",
            "If this is your only copy of that snapshot, it cannot be recovered.",
        ],
        "reversible": False,
    },
}


# ---------- flask ----------
def _load_session_secret():
    os.makedirs(SECRETS, exist_ok=True)
    if not os.path.exists(SESSION_SECRET_FILE):
        with open(SESSION_SECRET_FILE, "wb") as f:
            f.write(secrets.token_bytes(32))
        try: os.chmod(SESSION_SECRET_FILE, 0o600)
        except Exception: pass
    with open(SESSION_SECRET_FILE, "rb") as f:
        return f.read()


app = Flask(__name__)
app.secret_key = _load_session_secret()
# SESSION_COOKIE_SECURE defaults OFF so the panel also works as a phone-local PWA
# on http://127.0.0.1 (Secure cookies never travel over plain-HTTP loopback). The
# public path is protected by: the Cloudflare Tunnel (TLS to the edge), Cloudflare
# Access in front of origin, HSTS from Caddy, and HttpOnly + SameSite=Lax + idle
# timeout. Set ADMINWEB_SECURE_COOKIE=1 to forbid loopback (HTTP) access.
#
# SameSite=Lax (not Strict): when the panel sits behind a Cloudflare Access gate
# the operator arrives via a cross-site redirect, and Strict would withhold the
# session cookie on that first navigation (breaking the first CSRF check). Lax
# sends it on top-level navigations while still withholding it on cross-site
# POSTs — and CSRF is independently enforced by the double-submit token.
_SECURE_COOKIE = _env("ADMINWEB_SECURE_COOKIE", "0") in ("1", "true", "yes")
app.config.update(
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SAMESITE="Lax",
    SESSION_COOKIE_SECURE=_SECURE_COOKIE,
    PERMANENT_SESSION_LIFETIME=IDLE_SECONDS,
)
# Trust X-Forwarded-* from Caddy (one hop only) so rate-limit + audit see the real
# client IP, not 127.0.0.1.
app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1)


# App-level CSP + security headers (defense in depth; Caddy also sets a CSP, but
# the loopback ssh -L path bypasses Caddy). 'unsafe-inline' covers the inline
# style attrs + the SSE <script>; connect-src 'self' allows the /events stream.
_CSP = ("default-src 'none'; script-src 'self' 'unsafe-inline'; "
        "style-src 'self' 'unsafe-inline'; img-src 'self' data:; "
        "connect-src 'self'; manifest-src 'self'; base-uri 'none'; "
        "form-action 'self'; frame-ancestors 'none'")


@app.after_request
def _security_headers(resp):
    resp.headers.setdefault("Content-Security-Policy", _CSP)
    resp.headers.setdefault("X-Content-Type-Options", "nosniff")
    resp.headers.setdefault("X-Frame-Options", "DENY")
    resp.headers.setdefault("Referrer-Policy", "no-referrer")
    return resp


def _load_env(path):
    d = {}
    try:
        with open(path) as f:
            for line in f:
                if "=" in line and not line.startswith("#"):
                    k, v = line.strip().split("=", 1)
                    d[k] = v
    except Exception:
        pass
    return d


# ---------- helpers ----------
def e(s):
    return html.escape(str(s), quote=True)


def log_audit(action, **extra):
    ua = ""
    try:
        ua = request.user_agent.string[:200] if request else ""
    except Exception:
        pass
    line = {
        "ts": time.strftime("%FT%TZ", time.gmtime()),
        "user": session.get("user", "<anon>"),
        "ip": request.remote_addr if request else None,
        "ua": ua,
        "action": action,
        **extra,
    }
    try:
        os.makedirs(LOGS, exist_ok=True)
        with open(AUDIT_LOG, "a") as f:
            f.write(json.dumps(line) + "\n")
    except Exception:
        pass


def scrypt_hash(pw, salt):
    return hashlib.scrypt(pw.encode(), salt=salt, n=2 ** 14, r=8, p=1, dklen=32)


def verify_password(pw):
    try:
        with open(PASSWORD_FILE) as f:
            stored = f.read().strip()
        salt_hex, hash_hex = stored.split(":", 1)
        salt = bytes.fromhex(salt_hex)
        return hmac.compare_digest(scrypt_hash(pw, salt).hex(), hash_hex)
    except Exception:
        return False


def new_csrf():
    if "csrf" not in session:
        session["csrf"] = secrets.token_urlsafe(32)
    return session["csrf"]


def csrf_ok():
    return (request.form.get("_csrf") and
            request.form.get("_csrf") == session.get("csrf"))


_FAILS = {}            # ip -> (count, last_ts); thread-safe via _FAILS_LOCK
_FAILS_LIFETIME = {}   # ip -> lifetime fail count (exponential backoff)
_FAILS_LOCK = threading.Lock()

# Persist _FAILS to disk so an adminweb restart doesn't reset the brute-force
# counter. Rewritten on every record_fail / clear_fail; trivially small.
_FAILS_FILE = os.path.join(STATE, "adminweb-fails.json")

def _save_fails_unlocked():
    """Persist current _FAILS / _FAILS_LIFETIME state. Caller holds _FAILS_LOCK.
    Best-effort: failures are logged, never raised."""
    try:
        os.makedirs(os.path.dirname(_FAILS_FILE), exist_ok=True)
        tmp = _FAILS_FILE + ".tmp"
        with open(tmp, "w") as f:
            json.dump({
                "fails":    {k: list(v) for k, v in _FAILS.items()},
                "lifetime": _FAILS_LIFETIME,
            }, f)
        os.replace(tmp, _FAILS_FILE)
    except Exception as ex:
        print(f"[adminweb] _FAILS persist failed: {ex}", file=sys.stderr)

def _load_fails():
    """Restore _FAILS / _FAILS_LIFETIME from disk on boot. Best-effort."""
    try:
        if not os.path.exists(_FAILS_FILE):
            return
        with open(_FAILS_FILE) as f:
            d = json.load(f)
        with _FAILS_LOCK:
            _FAILS.update({k: tuple(v) for k, v in (d.get("fails") or {}).items()})
            _FAILS_LIFETIME.update(d.get("lifetime") or {})
    except Exception as ex:
        print(f"[adminweb] _FAILS load failed: {ex}", file=sys.stderr)

# Regenerate this nonce on every adminweb boot so any session minted by a prior
# process is invalidated immediately (the cookie still decrypts with the same
# SECRET_KEY, but won't carry the current BOOT_NONCE → redirect to /login).
BOOT_NONCE = secrets.token_hex(16)

# Up to 5 fails / 15 min, then exponential backoff per-IP on lifetime fails:
# 6th fail = 30 min lockout, 7th = 60 min, ... capped at 24h.
_BASE_LOCKOUT_S = 15 * 60
_MAX_LOCKOUT_S = 24 * 3600

# The only legitimate path to the panel is Caddy on loopback, or a header-less
# `ssh -L` tunnel which is ALSO loopback. ProxyFix(x_for=1) trusts the FIRST
# X-Forwarded-For hop by COUNT, not by proxy address, so anything that could reach
# the bind port WITHOUT traversing Caddy could supply a forged XFF to evade the
# per-IP lockout or frame a victim IP. ProxyFix stashes the real pre-rewrite socket
# peer in environ['werkzeug.proxy_fix.orig_remote_addr']; if that is not loopback,
# the request did NOT come through Caddy and its XFF is untrustworthy.
def _socket_peer_trusted():
    env = request.environ
    peer = env.get("werkzeug.proxy_fix.orig_remote_addr") or env.get("REMOTE_ADDR")
    return peer in ("127.0.0.1", "::1")


def _lockout_ip():
    """The IP to key the brute-force lockout on. When the socket peer is loopback
    (the legit Caddy path) use the ProxyFix-resolved client IP. When it is NOT
    loopback (a direct-to-origin request with an attacker-controlled XFF), ignore
    the spoofable XFF and key on the real socket peer instead."""
    if _socket_peer_trusted():
        return request.remote_addr or "?"
    peer = request.environ.get("werkzeug.proxy_fix.orig_remote_addr") \
        or request.environ.get("REMOTE_ADDR") or "?"
    return f"untrusted:{peer}"


def rate_limit_login(ip):
    with _FAILS_LOCK:
        c, t = _FAILS.get(ip, (0, 0))
        lifetime = _FAILS_LIFETIME.get(ip, 0)
    if time.time() - t > _BASE_LOCKOUT_S:
        return True
    if c < 5:
        return True
    if lifetime > 5:
        extra = min(_MAX_LOCKOUT_S, _BASE_LOCKOUT_S * (2 ** (lifetime - 5)))
        if time.time() - t < extra:
            return False
    return False

def record_fail(ip):
    with _FAILS_LOCK:
        c, _ = _FAILS.get(ip, (0, 0))
        _FAILS[ip] = (c + 1, time.time())
        _FAILS_LIFETIME[ip] = _FAILS_LIFETIME.get(ip, 0) + 1
        _save_fails_unlocked()

def clear_fail(ip):
    with _FAILS_LOCK:
        _FAILS.pop(ip, None)
        _save_fails_unlocked()


def login_required(f):
    @wraps(f)
    def inner(*a, **kw):
        if not session.get("auth"):
            return redirect(url_for("login"))
        if session.get("boot_nonce") != BOOT_NONCE:
            session.clear()
            return redirect(url_for("login"))
        return f(*a, **kw)
    return inner


def run_script(key, timeout=600):
    spec = SCRIPTS_OK.get(key)
    if not spec: return -1, "not allowed"
    cmd = ["bash", os.path.join(SCRIPTS, spec["argv"][0])] + spec["argv"][1:]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout + p.stderr
    except subprocess.TimeoutExpired:
        return -1, f"timed out after {timeout}s"
    except Exception as ex:
        return -2, str(ex)


def run_script_detached(key):
    """Launch a long-running ("async") script detached from this gunicorn worker,
    so it survives the worker timeout (and, for restart-adminweb, the worker being
    killed). Output goes to logs/adminweb-async.log. Returns (ok, logname)."""
    spec = SCRIPTS_OK.get(key)
    if not spec:
        return False, ""
    argv0 = spec["argv"][0]
    logname = os.path.basename(argv0)
    logname = logname[:-3] + ".log" if logname.endswith(".sh") else logname + ".log"
    cmd = ["bash", os.path.join(SCRIPTS, argv0)] + spec["argv"][1:]
    sink = os.path.join(LOGS, "adminweb-async.log")
    try:
        os.makedirs(LOGS, exist_ok=True)
        with open(sink, "ab", buffering=0) as lf:
            subprocess.Popen(
                cmd, stdin=subprocess.DEVNULL, stdout=lf, stderr=lf,
                start_new_session=True, close_fds=True,
            )
        return True, logname
    except Exception:
        return False, logname


def read_file(path, default=""):
    try:
        with open(path) as f: return f.read()
    except Exception: return default


def human_bytes(n):
    for u in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024: return f"{n:.1f} {u}"
        n /= 1024
    return f"{n:.1f} PB"


def human_seconds(s):
    s = int(s)
    d, s = divmod(s, 86400)
    h, s = divmod(s, 3600)
    m, _ = divmod(s, 60)
    parts = []
    if d: parts.append(f"{d}d")
    if h: parts.append(f"{h}h")
    parts.append(f"{m}m")
    return " ".join(parts)


# ---------- sysinfo ----------
# Android (SELinux) denies the app domain several /proc & /sys files. The
# sysinfo(2) syscall gives uptime + load without /proc; everything else here
# degrades gracefully to "?" / None when a file is unreadable.
def _sysinfo():
    """(uptime_seconds, (load1, load5, load15)) via the sysinfo(2) syscall. None on
    failure."""
    try:
        import ctypes, struct
        buf = ctypes.create_string_buffer(128)
        libc = ctypes.CDLL(None, use_errno=True)
        if libc.sysinfo(buf) != 0:
            return None
        up, l1, l2, l3 = struct.unpack_from("=q3Q", buf.raw, 0)
        return up, (l1 / 65536.0, l2 / 65536.0, l3 / 65536.0)
    except Exception:
        return None

_NET_PREV = {}  # iface -> (rx_bytes, tx_bytes, monotonic_ts) — for throughput rate

def _gather_net():
    """Per-iface RX/TX bytes + live throughput from /proc/net/dev. On Android the
    app domain is often denied /proc/net/dev — returns None then, and the UI shows
    an honest 'restricted' note instead of a misleading blank."""
    try:
        with open("/proc/net/dev") as f:
            raw = f.read()
    except Exception:
        return None
    if not raw:
        return None
    now = time.monotonic()
    out = []
    for line in raw.splitlines()[2:]:
        if ":" not in line:
            continue
        iface, rest = line.split(":", 1)
        iface = iface.strip()
        parts = rest.split()
        if iface == "lo" or len(parts) < 9:
            continue
        try:
            rx, tx = int(parts[0]), int(parts[8])
        except ValueError:
            continue
        if rx == 0 and tx == 0:
            continue
        rrx = rtx = None
        prev = _NET_PREV.get(iface)
        if prev and now - prev[2] > 0.5:
            dt = now - prev[2]
            rrx = max(0.0, (rx - prev[0]) / dt)
            rtx = max(0.0, (tx - prev[1]) / dt)
        _NET_PREV[iface] = (rx, tx, now)
        out.append({"iface": iface, "rx": rx, "tx": tx, "rate_rx": rrx, "rate_tx": rtx})
    out.sort(key=lambda n: -(n["rx"] + n["tx"]))
    return out[:5]


# ---------- health probing ----------
# Loopback HTTP probes hit Caddy on ${CADDY_BIND}:${CADDY_PORT} (plain HTTP — TLS
# terminates at the Cloudflare edge) with an explicit Host header. This exercises
# Caddy + the upstream while bypassing the public edge. Built from the enabled
# apps so a disabled app is never a false failure.
def _build_http_probes():
    probes = [
        {"name": "conduwuit (local)", "host": "127.0.0.1:8448",
         "path": "/_matrix/client/versions", "expect": 200, "scheme": "http"},
        {"name": "matrix via caddy", "host": f"chat.{DOMAIN}",
         "path": "/_matrix/client/versions", "expect": 200, "scheme": "loopback"},
        {"name": "admin panel", "host": f"127.0.0.1:{BIND_PORT}",
         "path": "/login", "expect": 200, "scheme": "http"},
    ]
    if ENABLE["auth-gw"]:
        probes.append({"name": "auth-gw", "host": f"127.0.0.1:{AUTHGW_PORT}",
                       "path": "/authgw/health", "expect": 200, "scheme": "http"})
    if ENABLE["linkding"]:
        probes.append({"name": "linkding /health", "host": f"links.{DOMAIN}",
                       "path": "/health", "expect": 200, "scheme": "loopback"})
    if ENABLE["pingvin"]:
        probes.append({"name": "pingvin /api/health", "host": f"share.{DOMAIN}",
                       "path": "/api/health", "expect": 200, "scheme": "loopback"})
    return probes

HEALTH_HTTP_PROBES = _build_http_probes()

# Process aliveness — pgrep -f patterns. Built from the enabled apps. Patterns
# match each service's real process argv (cross-checked against the install
# scripts' supervise/exec lines).
def _build_health_procs():
    procs = [
        {"name": "matrix",      "pattern": "/opt/conduwuit/conduwuit"},
        {"name": "caddy",       "pattern": "caddy run"},
        {"name": "cloudflared", "pattern": "cloudflared.*tunnel"},
        {"name": "adminweb",    "pattern": "gunicorn.*app:app"},
    ]
    if ENABLE["auth-gw"]:
        procs.append({"name": "auth-gw", "pattern": "matrix-auth-gw\\.py"})
    if ENABLE["linkding"]:
        procs.append({"name": "linkding",       "pattern": "gunicorn.*bookmarks\\.wsgi"})
        procs.append({"name": "linkding-tasks", "pattern": "run_huey"})
    if ENABLE["pingvin"]:
        procs.append({"name": "pingvin", "pattern": "dist/src/main"})
    if ENABLE["freshrss"]:
        procs.append({"name": "freshrss", "pattern": "freshrss/php-fpm.conf"})
    if ENABLE["searxng"]:
        procs.append({"name": "searxng", "pattern": "searxng/uwsgi.ini"})
    if ENABLE["memos"]:
        procs.append({"name": "memos", "pattern": "/opt/memos/memos"})
    if ENABLE["vikunja"]:
        procs.append({"name": "vikunja", "pattern": "/opt/vikunja/run.sh"})
    if ENABLE["gatus"]:
        procs.append({"name": "gatus", "pattern": "/opt/gatus"})
    return procs

HEALTH_PROCS = _build_health_procs()


def _probe_http(probe, timeout=5):
    """Returns dict with code, latency_ms, ok bool, error str."""
    import urllib.request, urllib.error
    if probe["scheme"] == "loopback":
        # Caddy is plain HTTP on loopback (TLS terminates at the CF edge); send
        # http:// with the public hostname in the Host header.
        url = f"http://{CADDY_BIND}:{CADDY_PORT}{probe['path']}"
        host_header = probe["host"]
    else:
        url = f"http://{probe['host']}{probe['path']}"
        host_header = probe["host"]
    req = urllib.request.Request(
        url, method="GET",
        headers={"Host": host_header, "User-Agent": "pocket-homeserver-admin-health/1"})
    # A 30x to a login page proves the vhost AND its gate are live; urlopen would
    # FOLLOW it and report the login page's 200. A no-follow opener surfaces the
    # 30x as an HTTPError whose code we read as-is.
    opener = getattr(_probe_http, "_opener", None)
    if opener is None:
        class _NoFollow(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *a, **k):
                return None
        opener = urllib.request.build_opener(_NoFollow)
        _probe_http._opener = opener
    t0 = time.time()
    try:
        with opener.open(req, timeout=timeout) as r:
            code = r.status
    except urllib.error.HTTPError as ex:
        code = ex.code
    except Exception as ex:
        return {"code": 0, "latency_ms": int((time.time()-t0)*1000),
                "ok": False, "error": str(ex)[:80]}
    latency = int((time.time() - t0) * 1000)
    ok = (code == probe["expect"])
    return {"code": code, "latency_ms": latency, "ok": ok, "error": ""}


def _proc_alive(pattern):
    """Returns (alive_bool, pid_int_or_0)."""
    try:
        p = subprocess.run(["pgrep", "-f", pattern],
                           capture_output=True, text=True, timeout=3)
        if p.returncode == 0 and p.stdout.strip():
            pid = int(p.stdout.strip().splitlines()[0])
            return (True, pid)
    except Exception:
        pass
    return (False, 0)


def gather_health():
    """Run all probes and process checks. Returns structured report."""
    out = {"ts": time.strftime("%FT%TZ", time.gmtime()),
           "http": [], "procs": [], "summary": {}}
    http_ok = http_total = 0
    for probe in HEALTH_HTTP_PROBES:
        r = _probe_http(probe)
        out["http"].append({**probe, **r})
        http_total += 1
        if r["ok"]: http_ok += 1
    proc_ok = proc_total = 0
    for proc in HEALTH_PROCS:
        alive, pid = _proc_alive(proc["pattern"])
        out["procs"].append({**proc, "alive": alive, "pid": pid})
        proc_total += 1
        if alive: proc_ok += 1
    out["summary"] = {
        "http_ok": http_ok, "http_total": http_total,
        "proc_ok": proc_ok, "proc_total": proc_total,
        "all_green": http_ok == http_total and proc_ok == proc_total,
    }
    return out


# ---------- stat gathering ----------
def gather_stats():
    """Collect device + stack stats. Best-effort — never raises."""
    s = {}

    si = _sysinfo()
    if si:
        s["uptime"] = human_seconds(si[0])
        s["load"] = " / ".join(f"{x:.2f}" for x in si[1])
    else:
        s["uptime"] = s["load"] = "?"

    # CPU model + cores + per-core freq
    try:
        cpuinfo = read_file("/proc/cpuinfo")
        cores = cpuinfo.count("processor\t:")
        model = "?"
        for line in cpuinfo.splitlines():
            if line.startswith("Hardware") or line.startswith("model name"):
                model = line.split(":", 1)[1].strip(); break
        s["cpu_model"] = model
        s["cpu_cores"] = cores

        freqs = []
        for i in range(cores):
            f = read_file(f"/sys/devices/system/cpu/cpu{i}/cpufreq/scaling_cur_freq").strip()
            if f.isdigit():
                freqs.append(int(f) // 1000)  # kHz → MHz
        if freqs:
            s["cpu_freq"] = f"{min(freqs)}-{max(freqs)} MHz (avg {sum(freqs)//len(freqs)})"
        else:
            s["cpu_freq"] = "?"
    except Exception:
        s["cpu_model"] = s["cpu_cores"] = s["cpu_freq"] = "?"

    s["gpu_note"] = "GPU utilisation needs root (vendor sysfs is restricted)"

    # memory
    try:
        meminfo = {}
        for line in read_file("/proc/meminfo").splitlines():
            parts = line.split(":")
            if len(parts) == 2:
                meminfo[parts[0].strip()] = int(parts[1].strip().split()[0]) * 1024
        total = meminfo.get("MemTotal", 0)
        avail = meminfo.get("MemAvailable", meminfo.get("MemFree", 0))
        used = total - avail
        s["mem_used"] = used
        s["mem_total"] = total
        s["mem_pct"] = int(100 * used / total) if total else 0
        stotal = meminfo.get("SwapTotal", 0)
        sfree = meminfo.get("SwapFree", 0)
        s["swap_used"] = stotal - sfree
        s["swap_total"] = stotal
    except Exception:
        s["mem_used"] = s["mem_total"] = s["mem_pct"] = 0
        s["swap_used"] = s["swap_total"] = 0

    # Storage (via os.statvfs — toybox df can't do -B1). Probe the large data
    # volume and home; both are derived from config, no hardcoded mounts.
    s["storage"] = []
    seen = set()
    for mount, label in ((DATA_DIR or os.path.expanduser("~"), "data volume"),
                         (os.path.expanduser("~"), "home")):
        if not mount or mount in seen:
            continue
        seen.add(mount)
        try:
            st = os.statvfs(mount)
            total = st.f_blocks * st.f_frsize
            avail = st.f_bavail * st.f_frsize
            used = total - avail
            s["storage"].append({
                "label": label, "mount": mount,
                "used": used, "total": total, "avail": avail,
                "pct": int(100 * used / total) if total else 0,
            })
        except Exception:
            pass

    # battery
    try:
        p = subprocess.run(["termux-battery-status"], capture_output=True, text=True, timeout=5)
        b = json.loads(p.stdout)
        s["battery"] = {
            "pct": b.get("percentage", "?"),
            "temp": b.get("temperature", "?"),
            "status": b.get("status", "?").lower(),
            "plugged": b.get("plugged", "?").lower().replace("plugged_", "").replace("unplugged", "on battery"),
        }
    except Exception:
        s["battery"] = None

    # thermal zones
    try:
        temps = []
        for i in range(20):
            t = read_file(f"/sys/class/thermal/thermal_zone{i}/temp").strip()
            tp = read_file(f"/sys/class/thermal/thermal_zone{i}/type").strip()
            if t and t.isdigit():
                c = int(t) / 1000.0
                if 10 < c < 150 and tp:
                    temps.append({"zone": tp, "temp": c})
        s["thermal"] = temps[:8]
        s["max_temp"] = max((z["temp"] for z in temps), default=0)
    except Exception:
        s["thermal"] = []; s["max_temp"] = 0

    # network — /proc/net/dev may be blocked for the app domain (None then)
    s["net"] = _gather_net()

    # device
    try:
        p = subprocess.run(["getprop", "ro.product.model"], capture_output=True, text=True, timeout=3)
        s["device"] = p.stdout.strip() or "?"
        p2 = subprocess.run(["getprop", "ro.build.version.release"], capture_output=True, text=True, timeout=3)
        s["android"] = p2.stdout.strip() or "?"
    except Exception:
        s["device"] = s["android"] = "?"

    # kernel
    try:
        s["kernel"] = read_file("/proc/version").split()[2] if read_file("/proc/version") else "?"
    except Exception:
        s["kernel"] = "?"

    # Service health (loopback port probes)
    s["services"] = []
    port_checks = [("matrix", 8448), ("caddy", int(CADDY_PORT) if str(CADDY_PORT).isdigit() else 8443),
                   ("adminweb", BIND_PORT)]
    if ENABLE["auth-gw"]:
        port_checks.append(("auth-gw", int(AUTHGW_PORT) if str(AUTHGW_PORT).isdigit() else 9095))
    for name, port in port_checks:
        up = False
        try:
            import socket as _s
            sock = _s.socket(_s.AF_INET, _s.SOCK_STREAM)
            sock.settimeout(1.0)
            sock.connect(("127.0.0.1", port))
            sock.close(); up = True
        except Exception:
            pass
        s["services"].append({"name": name, "port": port, "up": up})

    # cloudflared — check its log for a recent tunnel connection
    try:
        log = read_file(os.path.join(LOGS, "cloudflared.log"))
        s["services"].append({
            "name": "cloudflared",
            "port": None,
            "up": ("Registered tunnel connection" in log) or ("Connection " in log and "registered" in log.lower()),
            "note": "tunnel",
        })
    except Exception:
        pass

    return s


# ---------- CSS + templates ----------
CSS = """
/* ===== design tokens (indigo/blue/teal) ===== */
:root {
  --bg:#f5f6fb; --fg:#1a1f36; --muted:#5b6480; --border:#e4e7f1; --panel:#ffffff;
  --card1:#ffffff; --card2:#f6f8fd;
  --pre-bg:#0f1430; --pre-fg:#dce2ff; --link:#3257d6; --brand:#5b46e0;
  --accent:#3257d6; --accent2:#6b4dff; --teal:#0f9b76; --pink:#d6498f; --amber:#b9791a;
  --btn-bg:#e9ecf7; --btn-hover:#dde2f2; --btn-fg:#2a3358;
  --btn-primary:#3257d6; --btn-primary-hover:#2746bf; --btn-primary-fg:#fff;
  --danger:#d23b54; --danger-hover:#b32942;
  --err-bg:#fde8ee; --err-fg:#9a1b3a; --err-border:#f0b9c7;
  --ok-bg:#e4f7ef; --ok-fg:#0a6b4d; --ok-border:#a9e3cf;
  --warn-bg:#fff4d6; --warn-fg:#7a5200; --warn-border:#e6cf8f;
  --code-bg:#eef0f8; --danger-bg:#fdeaee; --danger-border:#e7a9b6;
  --dot-up:#1faf6b; --dot-down:#d23b54;
  --shadow:0 4px 18px rgba(30,40,90,.08); --shadow-sm:0 1px 3px rgba(30,40,90,.06);
  --ring:rgba(50,87,214,.30); --grad:linear-gradient(100deg,#3257d6,#6b4dff 45%,#d6498f);
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg:#0a0d1e; --fg:#e9ecff; --muted:#98a1c6; --border:#232b50; --panel:#141936;
    --card1:#171c40; --card2:#0f1430;
    --pre-bg:#070a18; --pre-fg:#cdd6ff; --link:#86a9ff; --brand:#a99cff;
    --accent:#5f8cff; --accent2:#8a7cff; --teal:#40c8a0; --pink:#ec6ead; --amber:#f5b945;
    --btn-bg:#1f2750; --btn-hover:#293467; --btn-fg:#d8def7;
    --btn-primary:#3257d6; --btn-primary-hover:#436bef; --btn-primary-fg:#fff;
    --danger:#e0556b; --danger-hover:#f3667c;
    --err-bg:#2a1622; --err-fg:#ffb3c4; --err-border:#5b2740;
    --ok-bg:#0f2a22; --ok-fg:#7ff0c8; --ok-border:#1f5a47;
    --warn-bg:#2c2410; --warn-fg:#ffd58a; --warn-border:#6b5520;
    --code-bg:#1b2247; --danger-bg:#251320; --danger-border:#7a2740;
    --dot-up:#42d392; --dot-down:#ff5c7c;
    --shadow:0 8px 28px rgba(0,0,0,.40); --shadow-sm:0 1px 3px rgba(0,0,0,.30);
    --ring:rgba(124,156,255,.40); --grad:linear-gradient(100deg,#9cc0ff,#c4b6ff 38%,#ffb3d9 66%,#9cc0ff);
  }
}
body[data-theme=dark] {
  --bg:#0a0d1e; --fg:#e9ecff; --muted:#98a1c6; --border:#232b50; --panel:#141936;
  --card1:#171c40; --card2:#0f1430;
  --pre-bg:#070a18; --pre-fg:#cdd6ff; --link:#86a9ff; --brand:#a99cff;
  --accent:#5f8cff; --accent2:#8a7cff; --teal:#40c8a0; --pink:#ec6ead; --amber:#f5b945;
  --btn-bg:#1f2750; --btn-hover:#293467; --btn-fg:#d8def7;
  --btn-primary:#3257d6; --btn-primary-hover:#436bef; --btn-primary-fg:#fff;
  --danger:#e0556b; --danger-hover:#f3667c;
  --err-bg:#2a1622; --err-fg:#ffb3c4; --err-border:#5b2740;
  --ok-bg:#0f2a22; --ok-fg:#7ff0c8; --ok-border:#1f5a47;
  --warn-bg:#2c2410; --warn-fg:#ffd58a; --warn-border:#6b5520;
  --code-bg:#1b2247; --danger-bg:#251320; --danger-border:#7a2740;
  --dot-up:#42d392; --dot-down:#ff5c7c;
  --shadow:0 8px 28px rgba(0,0,0,.40); --shadow-sm:0 1px 3px rgba(0,0,0,.30);
  --ring:rgba(124,156,255,.40); --grad:linear-gradient(100deg,#9cc0ff,#c4b6ff 38%,#ffb3d9 66%,#9cc0ff);
}
body[data-theme=light] {
  --bg:#f5f6fb; --fg:#1a1f36; --muted:#5b6480; --border:#e4e7f1; --panel:#ffffff;
  --card1:#ffffff; --card2:#f6f8fd;
  --pre-bg:#0f1430; --pre-fg:#dce2ff; --link:#3257d6; --brand:#5b46e0;
  --accent:#3257d6; --accent2:#6b4dff; --teal:#0f9b76; --pink:#d6498f; --amber:#b9791a;
  --btn-bg:#e9ecf7; --btn-hover:#dde2f2; --btn-fg:#2a3358;
  --btn-primary:#3257d6; --btn-primary-hover:#2746bf; --btn-primary-fg:#fff;
  --danger:#d23b54; --danger-hover:#b32942;
  --err-bg:#fde8ee; --err-fg:#9a1b3a; --err-border:#f0b9c7;
  --ok-bg:#e4f7ef; --ok-fg:#0a6b4d; --ok-border:#a9e3cf;
  --warn-bg:#fff4d6; --warn-fg:#7a5200; --warn-border:#e6cf8f;
  --code-bg:#eef0f8; --danger-bg:#fdeaee; --danger-border:#e7a9b6;
  --dot-up:#1faf6b; --dot-down:#d23b54;
  --shadow:0 4px 18px rgba(30,40,90,.08); --shadow-sm:0 1px 3px rgba(30,40,90,.06);
  --ring:rgba(50,87,214,.30); --grad:linear-gradient(100deg,#3257d6,#6b4dff 45%,#d6498f);
}

/* ===== base — fluid full width ===== */
* { box-sizing: border-box }
html, body { background: var(--bg); color: var(--fg) }
body {
  font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,system-ui,sans-serif;
  width:100%; max-width:1900px; margin:0 auto; padding:0 clamp(1rem,2.2vw,2.6rem) 2.5rem; line-height:1.5;
  background:
    radial-gradient(1100px 420px at 108% -10%, color-mix(in srgb,var(--accent2) 13%,transparent), transparent 70%),
    radial-gradient(900px 380px at -8% -6%, color-mix(in srgb,var(--accent) 11%,transparent), transparent 70%),
    var(--bg);
  background-attachment:fixed;
}
a { color: var(--link); text-decoration: none } a:hover { text-decoration: underline }
h1,h2,h3 { margin:0 }

/* ===== top bar ===== */
header {
  position:sticky; top:0; z-index:20; display:flex; align-items:center; gap:.9rem; flex-wrap:wrap;
  padding:.7rem 0; margin-bottom:1.2rem; border-bottom:1px solid var(--border);
  background:color-mix(in srgb,var(--bg) 82%,transparent); backdrop-filter:saturate(140%) blur(10px);
}
.brand { display:flex; align-items:center; gap:.5rem; font-weight:700; font-size:1.12rem }
.brand .mark { width:1.6rem; height:1.6rem; display:grid; place-items:center; border-radius:8px;
  background:var(--grad); color:#fff; font-size:1rem; box-shadow:var(--shadow-sm) }
.brand .word { background:var(--grad); -webkit-background-clip:text; background-clip:text; color:transparent }
.brand .sub { color:var(--muted); font-weight:600; font-size:.78rem; letter-spacing:.12em; text-transform:uppercase; margin-left:.1rem }
nav { display:flex; gap:.3rem; flex-wrap:wrap; flex-grow:1 }
nav a { color:var(--muted); font-size:.86rem; font-weight:600; padding:.34rem .68rem; border-radius:999px;
  border:1px solid transparent; transition:background .15s,color .15s,border-color .15s }
nav a:hover { background:var(--btn-bg); color:var(--fg); text-decoration:none }
nav a.active { color:var(--accent); background:color-mix(in srgb,var(--accent) 14%,transparent);
  border-color:color-mix(in srgb,var(--accent) 35%,transparent) }
.theme-toggle,.logout-btn { border:1px solid var(--border); border-radius:999px; cursor:pointer;
  font-size:.8rem; font-weight:600; padding:.34rem .7rem; background:var(--btn-bg); color:var(--btn-fg); transition:background .15s }
.theme-toggle:hover,.logout-btn:hover { background:var(--btn-hover) }

/* ===== cards ===== */
.box { background:linear-gradient(180deg,var(--card1),var(--card2)); border:1px solid var(--border);
  border-radius:16px; padding:1.1rem 1.25rem; margin:.85rem 0; box-shadow:var(--shadow) }
.box h2 { font-size:1.02rem; display:flex; align-items:center; gap:.5rem; flex-wrap:wrap }
.box h2 .ico { font-size:1rem; opacity:.85 }
.box h3 { font-size:.82rem; color:var(--muted); text-transform:uppercase; letter-spacing:.06em; margin:.95rem 0 .4rem }
.grid2 { display:grid; grid-template-columns:1fr 1fr; gap:1rem; align-items:stretch }
.grid2 > .box, .grid2 > .col { margin:0 }
.col { display:flex; flex-direction:column; gap:1rem } .col .box { margin:0 }
.col .box:last-child { flex:1 1 auto }
.cardgrid { display:grid; grid-template-columns:repeat(auto-fit,minmax(290px,1fr)); gap:1rem } .cardgrid .box { margin:0 }
hr { border:0; border-top:1px solid var(--border); margin:.8rem 0 }
.box.danger-zone { border-color:var(--danger-border);
  background:linear-gradient(180deg,color-mix(in srgb,var(--danger) 9%,var(--card1)),var(--card2)) }

/* ===== stat chips ===== */
.statgrid { display:grid; grid-template-columns:repeat(4,1fr); gap:1rem; margin:.2rem 0 1rem }
.stat { position:relative; background:linear-gradient(180deg,var(--card1),var(--card2)); border:1px solid var(--border);
  border-radius:14px; padding:.8rem .95rem; box-shadow:var(--shadow-sm); overflow:hidden }
.stat .lbl { color:var(--muted); font-size:.7rem; font-weight:700; letter-spacing:.08em; text-transform:uppercase }
.stat .val { font-size:1.4rem; font-weight:700; margin-top:.18rem; line-height:1.15; font-variant-numeric:tabular-nums }
.stat .val small { font-size:.78rem; font-weight:600; color:var(--muted) }
.stat .spark { position:absolute; right:.6rem; bottom:.55rem; opacity:.9 }
.stat.accent { border-color:color-mix(in srgb,var(--accent) 40%,var(--border)) }

/* ===== metrics list ===== */
.metrics { display:grid; grid-template-columns:max-content 1fr; gap:.5rem .9rem; font-size:.9rem; align-items:baseline }
.metrics dt { color:var(--muted); font-weight:600 } .metrics dd { margin:0; font-variant-numeric:tabular-nums }

.dot { display:inline-block; width:.6rem; height:.6rem; border-radius:50%; vertical-align:middle; margin-right:.45rem }
.dot.up { background:var(--dot-up); box-shadow:0 0 0 3px color-mix(in srgb,var(--dot-up) 22%,transparent) }
.dot.down { background:var(--dot-down); box-shadow:0 0 0 3px color-mix(in srgb,var(--dot-down) 22%,transparent) }

/* ===== pills / badges / status ===== */
.pill { display:inline-flex; align-items:center; gap:.35rem; font-size:.74rem; font-weight:700;
  padding:.16rem .55rem; border-radius:999px; border:1px solid var(--border); background:var(--code-bg); color:var(--fg) }
.pill.ok { background:var(--ok-bg); color:var(--ok-fg); border-color:var(--ok-border) }
.pill.warn { background:var(--warn-bg); color:var(--warn-fg); border-color:var(--warn-border) }
.pill.down { background:var(--danger-bg); color:var(--danger); border-color:var(--danger-border) }
.badge { background:var(--code-bg); color:var(--muted); font-size:.72rem; font-weight:600;
  padding:.12rem .45rem; border-radius:6px; margin-left:.4rem }
.ok { color:var(--ok-fg); font-weight:600 } .err { color:var(--danger); font-weight:600 }

/* ===== progress bars ===== */
.bar { position:relative; height:7px; background:var(--border); border-radius:999px; overflow:hidden; width:100%; margin-top:.3rem }
.bar > span { display:block; height:100%; background:linear-gradient(90deg,var(--accent),var(--accent2)); border-radius:999px; transition:width .5s ease }
.bar.warn > span { background:linear-gradient(90deg,#e0a82e,#f5b945) }
.bar.danger > span { background:linear-gradient(90deg,#e0556b,#ff7a7a) }

/* ===== sparkline ===== */
svg.spark { display:block }
svg.spark .ln { fill:none; stroke:var(--accent); stroke-width:1.6; stroke-linejoin:round; stroke-linecap:round }
svg.spark .ar { fill:var(--accent); opacity:.13 }

/* ===== buttons / forms ===== */
button,a.btn { font:inherit; font-size:.86rem; font-weight:600; cursor:pointer; background:var(--btn-bg); color:var(--btn-fg);
  border:1px solid var(--border); border-radius:9px; padding:.42rem .8rem; margin:.18rem .18rem 0 0;
  display:inline-block; text-decoration:none; transition:background .15s,transform .05s }
button:hover,a.btn:hover { background:var(--btn-hover); text-decoration:none }
button:active,a.btn:active { transform:translateY(1px) }
button.primary { background:var(--btn-primary); color:var(--btn-primary-fg); border-color:transparent }
button.primary:hover { background:var(--btn-primary-hover) }
button.danger,a.btn.danger { background:var(--danger); color:#fff; border-color:transparent }
button.danger:hover,a.btn.danger:hover { background:var(--danger-hover) }
button.small,a.btn.small { font-size:.78rem; padding:.3rem .55rem; border-radius:8px }
form { margin:0; display:inline-block } form.block { display:block; margin-top:.8rem }
input[type=password],input[type=text] { font:inherit; padding:.5rem .65rem; border:1px solid var(--border);
  border-radius:9px; background:var(--panel); color:var(--fg); min-width:240px; margin:.15rem .2rem .15rem 0 }
input:focus { outline:2px solid var(--ring); outline-offset:1px; border-color:var(--accent) }

/* ===== tables ===== */
.tablewrap { overflow-x:auto; border:1px solid var(--border); border-radius:12px; margin-top:.5rem }
table { width:100%; border-collapse:collapse; font-size:.86rem }
.tablewrap table { min-width:640px }
th,td { padding:.5rem .7rem; text-align:left; border-bottom:1px solid var(--border); vertical-align:middle; white-space:nowrap }
thead th { position:sticky; top:0; background:var(--card2); color:var(--muted); font-size:.72rem;
  text-transform:uppercase; letter-spacing:.05em; font-weight:700; z-index:1 }
tbody tr:last-child td { border-bottom:0 }
tbody tr:hover { background:color-mix(in srgb,var(--accent) 6%,transparent) }
td.mono,.mono { font-family:ui-monospace,Menlo,Consolas,monospace; font-size:.82rem }
td.path { max-width:340px; overflow:hidden; text-overflow:ellipsis }

/* ===== misc ===== */
pre { background:var(--pre-bg); color:var(--pre-fg); padding:.8rem 1rem; border-radius:10px; overflow-x:auto;
  font-size:.82rem; line-height:1.4; white-space:pre-wrap }
code { background:var(--code-bg); padding:0 .3rem; border-radius:5px; font-size:.9rem; color:var(--fg) }
.small { font-size:.84rem; color:var(--muted) }
.botbar { display:flex; align-items:center; justify-content:space-between; gap:1rem; flex-wrap:wrap;
  margin:1rem 0 .3rem; padding:.6rem 1.15rem; border:1px solid var(--border); border-radius:12px;
  background:linear-gradient(180deg,var(--card1),var(--card2)); box-shadow:var(--shadow-sm);
  color:var(--muted); font-size:.83rem }
.botbar .bb-live { display:inline-flex; align-items:center; gap:.45rem }
.botbar a { color:var(--muted); text-decoration:none } .botbar a:hover { color:var(--accent) }
#live-dot { color:var(--dot-up); transition:opacity .25s }
.flash { padding:.65rem 1rem; border-radius:10px; margin:.6rem 0; border:1px solid var(--border) }
.flash.err { background:var(--err-bg); color:var(--err-fg); border-color:var(--err-border) }
.flash.ok { background:var(--ok-bg); color:var(--ok-fg); border-color:var(--ok-border) }
.flash.warn { background:var(--warn-bg); color:var(--warn-fg); border-color:var(--warn-border) }
.warn-box { background:var(--warn-bg); color:var(--warn-fg); border:1px solid var(--warn-border);
  padding:.75rem 1rem; border-radius:10px; margin:.7rem 0 }
.warn-box ul { margin:.4rem 0; padding-left:1.4rem } .warn-box li { margin:.2rem 0 }
.health-banner { display:inline-flex; align-items:center; gap:.35rem; font-size:.74rem; font-weight:700;
  padding:.16rem .55rem; border-radius:999px; border:1px solid var(--border); vertical-align:middle; margin-left:.4rem }
.health-banner.health-ok { background:var(--ok-bg); color:var(--ok-fg); border-color:var(--ok-border) }
.health-banner.health-warn { background:var(--warn-bg); color:var(--warn-fg); border-color:var(--warn-border) }
.health-banner.health-err { background:var(--danger-bg); color:var(--danger); border-color:var(--danger-border) }
tr.health-ok td:first-child::before { content:"\\25CF "; color:var(--dot-up) }
tr.health-err td:first-child::before { content:"\\25CF "; color:var(--dot-down) }

/* ===== responsive ===== */
@media (max-width:900px) { .statgrid { grid-template-columns:repeat(2,1fr) } .grid2 { grid-template-columns:1fr } }
@media (max-width:560px) {
  .statgrid { grid-template-columns:1fr } nav { order:3; width:100% }
  button,a.btn,.theme-toggle,.logout-btn { min-height:2.5rem }
  input[type=password],input[type=text] { min-height:2.5rem; width:100% } td.path { max-width:160px }
}
@media (prefers-reduced-motion:reduce) { * { transition:none!important; animation:none!important } }
"""

# Serve the CSS from a cached, content-hashed route (smaller pages + browser
# caching). ?v=<hash> changes only when the CSS changes, so it caches hard.
_CSS_VER = hashlib.sha256(CSS.encode("utf-8")).hexdigest()[:12]


def render(title, body_html, hide_nav=False):
    theme = request.cookies.get("theme", "auto")
    theme_attr = f' data-theme="{e(theme)}"' if theme in ("dark", "light") else ""
    theme_btn_label = {"auto": "\U0001F313", "light": "☀", "dark": "☾"}.get(theme, "\U0001F313")

    nav = ""
    actions = ""
    if not hide_nav and session.get("auth"):
        cur = request.path
        items = (
            ("/", "dashboard"), ("/health", "health"), ("/stats", "stats"),
            ("/backups", "backups"), ("/tokens", "tokens"), ("/logs", "logs"),
            ("/danger", "danger"),
        )
        links = ""
        for href, label in items:
            on = " class=active" if (cur == href if href == "/" else cur.startswith(href)) else ""
            links += f'<a href="{href}"{on}>{label}</a>'
        nav = f"<nav>{links}</nav>"
        actions = (
            '<form method=post action=/theme><input type=hidden name=_csrf value="'
            + e(new_csrf()) + f'"><button class=theme-toggle>{theme_btn_label} theme</button></form>'
            '<form method=post action=/logout><input type=hidden name=_csrf value="'
            + e(new_csrf()) + '"><button class=logout-btn type=submit>logout</button></form>'
        )
    flashes = ""
    for cat, msg in session.pop("_flashes", []):
        flashes += f'<div class="flash {e(cat)}">{e(msg)}</div>'
    pwa_head = (
        '<link rel="manifest" href="/manifest.json">'
        '<meta name="theme-color" content="#0a0d1e">'
        '<meta name="apple-mobile-web-app-capable" content="yes">'
        f'<meta name="apple-mobile-web-app-title" content="{e(BRAND)}">'
        '<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">'
        '<link rel="icon" type="image/svg+xml" href="/icon.svg">'
        '<link rel="apple-touch-icon" href="/icon.svg">'
    )
    brand = ('<div class=brand><span class=mark>✦</span>'
             f'<span class=word>{e(BRAND)}</span><span class=sub>admin</span></div>')
    return (
        "<!doctype html>"
        '<html lang=en><head><meta charset=utf-8>'
        '<meta name=viewport content="width=device-width,initial-scale=1">'
        + pwa_head +
        f"<title>{e(title)}</title>"
        f'<link rel="stylesheet" href="/admin.css?v={_CSS_VER}"></head>'
        f"<body{theme_attr}>"
        f"<header>{brand}{nav}{actions}</header>"
        f"{flashes}{body_html}</body></html>"
    )


def flash_msg(msg, cat="ok"):
    session.setdefault("_flashes", []).append((cat, msg))


def action_btn(cmd, label, cls=""):
    klass = f' class="{cls}"' if cls else ""
    return (
        '<form method=post action=/action style="display:inline">'
        f'<input type=hidden name=_csrf value="{e(new_csrf())}">'
        f'<input type=hidden name=cmd value="{e(cmd)}">'
        f"<button type=submit{klass}>{e(label)}</button></form>"
    )


# ---------- Cloudflare Access JWT validation (optional, RS256, pure stdlib) ----------
# When the panel's public hostname is protected by Cloudflare Access, requests
# arrive with a `Cf-Access-Jwt-Assertion` header. This validates that JWT against
# Cloudflare's published JWKS (RSASSA-PKCS1-v1.5: pow(sig,e,n) + PKCS#1 v1.5 unpad
# + SHA-256 DigestInfo), with a matching issuer/audience and an unexpired window —
# else 403 in enforce mode. Requests WITHOUT the header are loopback-only (Caddy
# blocks header-less public requests before they reach us), so they pass through to
# the normal login. This gate is purely ADDITIVE and the loopback escape hatch
# means a bug here cannot lock the operator out.
#
# Config (env vars, or ${DATA_DIR}/secrets/cf-access.env; all optional):
#   CF_ACCESS_MODE=log|enforce              (default log — observe before blocking)
#   CF_ACCESS_TEAM_DOMAIN=<team>.cloudflareaccess.com   (gate is inert if unset)
#   CF_ACCESS_AUD=<application audience tag> (aud enforced only when set)
_CFA = _load_env(os.path.join(SECRETS, "cf-access.env"))
def _cfa_cfg(key, default=""):
    return (os.environ.get(key) or _CFA.get(key) or default).strip()
CF_ACCESS_MODE = (_cfa_cfg("CF_ACCESS_MODE", "log")).lower()
CF_ACCESS_TEAM_DOMAIN = _cfa_cfg("CF_ACCESS_TEAM_DOMAIN", "")
CF_ACCESS_AUD = _cfa_cfg("CF_ACCESS_AUD", "")
CF_ACCESS_ISSUER = f"https://{CF_ACCESS_TEAM_DOMAIN}" if CF_ACCESS_TEAM_DOMAIN else ""
CF_ACCESS_CERTS_URL = f"{CF_ACCESS_ISSUER}/cdn-cgi/access/certs" if CF_ACCESS_ISSUER else ""
_CFA_LEEWAY = 60
_CFA_JWKS_TTL = 3600
_CFA_JWKS = {"keys": {}, "ts": 0.0}
_CFA_JWKS_LOCK = threading.Lock()
# ASN.1 DigestInfo prefix for SHA-256 (RFC 8017 §9.2, EMSA-PKCS1-v1_5).
_CFA_SHA256_DI = bytes.fromhex("3031300d060960864801650304020105000420")


def _cfa_b64d(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def _cfa_b64uint(s):
    return int.from_bytes(_cfa_b64d(s), "big")


def _cfa_jwks(force=False):
    """{kid: (n, e)} from Cloudflare Access, cached for _CFA_JWKS_TTL. Keeps the
    last good set if a refresh fails so a transient fetch error can't lock out
    every request."""
    now = time.time()
    with _CFA_JWKS_LOCK:
        if not force and _CFA_JWKS["keys"] and (now - _CFA_JWKS["ts"]) < _CFA_JWKS_TTL:
            return _CFA_JWKS["keys"]
        try:
            req = urllib.request.Request(
                CF_ACCESS_CERTS_URL, headers={"User-Agent": "pocket-homeserver-admin/1.0"})
            with urllib.request.urlopen(req, timeout=10) as r:
                doc = json.loads(r.read())
            keys = {}
            for k in doc.get("keys", []):
                if k.get("kty") == "RSA" and k.get("n") and k.get("e"):
                    keys[k.get("kid", "")] = (_cfa_b64uint(k["n"]), _cfa_b64uint(k["e"]))
            if keys:
                _CFA_JWKS["keys"], _CFA_JWKS["ts"] = keys, now
        except Exception as ex:
            log_audit("cf-access-jwks-fetch-failed", err=str(ex)[:120])
        return _CFA_JWKS["keys"]


def _cfa_verify_rs256(signing_input, sig, n, e):
    """RSASSA-PKCS1-v1.5 verify (pure stdlib). True iff sig is valid for n,e."""
    k = (n.bit_length() + 7) // 8
    if len(sig) != k:
        return False
    em = pow(int.from_bytes(sig, "big"), e, n).to_bytes(k, "big")
    t = _CFA_SHA256_DI + hashlib.sha256(signing_input).digest()
    ps = k - len(t) - 3
    if ps < 8:
        return False
    expected = b"\x00\x01" + b"\xff" * ps + b"\x00" + t
    return hmac.compare_digest(em, expected)


def _cfa_validate(token):
    """Validate a Cloudflare Access JWT; return claims dict or raise ValueError."""
    parts = token.split(".")
    if len(parts) != 3:
        raise ValueError("not a compact JWS")
    h_b64, p_b64, s_b64 = parts
    header = json.loads(_cfa_b64d(h_b64))
    if header.get("alg") != "RS256":
        raise ValueError(f"alg {header.get('alg')!r} != RS256")
    kid = header.get("kid", "")
    ke = _cfa_jwks().get(kid) or _cfa_jwks(force=True).get(kid)  # refetch once on rotation
    if not ke:
        raise ValueError(f"unknown kid {kid!r}")
    if not _cfa_verify_rs256((h_b64 + "." + p_b64).encode(), _cfa_b64d(s_b64), *ke):
        raise ValueError("bad signature")
    claims = json.loads(_cfa_b64d(p_b64))
    now = time.time()
    if claims.get("iss") != CF_ACCESS_ISSUER:
        raise ValueError(f"iss {claims.get('iss')!r}")
    exp = claims.get("exp")
    if not isinstance(exp, (int, float)) or now > exp + _CFA_LEEWAY:
        raise ValueError("expired")
    nbf = claims.get("nbf")
    if isinstance(nbf, (int, float)) and now + _CFA_LEEWAY < nbf:
        raise ValueError("not yet valid")
    if CF_ACCESS_AUD:
        aud = claims.get("aud")
        if CF_ACCESS_AUD not in (aud if isinstance(aud, list) else [aud]):
            raise ValueError("aud mismatch")
    return claims


# ---------- routes ----------
@app.before_request
def _cf_access_gate():
    """Validate the Cloudflare Access JWT on every request that carries one.
    Inert unless a team domain is configured. log mode = observe only; enforce
    mode = 403 on any invalid token."""
    if not CF_ACCESS_TEAM_DOMAIN or CF_ACCESS_MODE not in ("log", "enforce"):
        return None
    tok = request.headers.get("Cf-Access-Jwt-Assertion")
    if not tok:
        return None      # loopback-only path — allow
    try:
        claims = _cfa_validate(tok)
    except Exception as ex:
        log_audit("cf-access-reject", ip=request.remote_addr or "?",
                  mode=CF_ACCESS_MODE, err=str(ex)[:120])
        if CF_ACCESS_MODE == "enforce":
            abort(403)
        return None
    if CF_ACCESS_MODE == "log":
        log_audit("cf-access-ok", ip=request.remote_addr or "?",
                  email=(claims.get("email") or claims.get("sub") or "")[:80],
                  aud=claims.get("aud"), iss=claims.get("iss"))
    request.environ["cf_access_email"] = claims.get("email") or claims.get("sub") or ""
    return None


@app.before_request
def _permanent():
    session.permanent = True


@app.route("/login", methods=["GET", "POST"])
def login():
    if session.get("auth"):
        return redirect(url_for("dashboard"))
    error = None
    if request.method == "POST":
        ip = _lockout_ip()
        if not rate_limit_login(ip):
            error = "too many failed attempts; try again in 15 min"
            log_audit("login-blocked-ratelimit", ip=ip)
        elif not csrf_ok():
            error = "CSRF mismatch"
        else:
            pw = request.form.get("password", "")
            if verify_password(pw):
                session["auth"] = True; session["user"] = ADMIN_USER
                session["boot_nonce"] = BOOT_NONCE
                session.pop("csrf", None); new_csrf(); clear_fail(ip)
                log_audit("login", ok=True)
                return redirect(url_for("dashboard"))
            record_fail(ip); log_audit("login", ok=False)
            error = "wrong password"
    err_html = f'<div class="flash err">{e(error)}</div>' if error else ''
    body = f"""
<div class=box>
<h2>sign in</h2>{err_html}
<form method=post>
<input type=hidden name=_csrf value="{e(new_csrf())}">
<input name=password type=password placeholder=password autofocus required>
<button type=submit>sign in</button>
</form>
</div>"""
    return render(f"login — {BRAND} admin", body, hide_nav=True)


@app.route("/logout", methods=["POST"])
def logout():
    if not csrf_ok(): abort(403)
    log_audit("logout")
    session.clear()
    return redirect(url_for("login"))


@app.route("/theme", methods=["POST"])
def theme_toggle():
    if not csrf_ok(): abort(403)
    cur = request.cookies.get("theme", "auto")
    nxt = {"auto": "dark", "dark": "light", "light": "auto"}[cur]
    resp = make_response(redirect(request.referrer or url_for("dashboard")))
    resp.set_cookie("theme", nxt, max_age=60*60*24*365, samesite="Strict", httponly=False)
    return resp


# ---------- dashboard ----------
def _service_row(svc):
    dot_cls = "up" if svc["up"] else "down"
    port_s = f":{svc['port']}" if svc.get("port") else ""
    note = f' <span class=small>({e(svc["note"])})</span>' if svc.get("note") else ""
    return f'<span class="dot {dot_cls}"></span>{e(svc["name"])}{port_s}{note}'


def _bar(pct, threshold_warn=70, threshold_danger=90):
    cls = ""
    if pct >= threshold_danger: cls = "danger"
    elif pct >= threshold_warn: cls = "warn"
    return f'<div class="bar {cls}"><span style="width:{pct}%"></span></div>'


def _restart_buttons():
    btns = [("restart-matrix", "matrix"), ("restart-caddy", "caddy"),
            ("restart-cloudflared", "cloudflared")]
    if ENABLE["auth-gw"]:  btns.append(("restart-auth-gw", "auth-gw"))
    if ENABLE["linkding"]: btns += [("restart-linkding", "linkding"),
                                    ("restart-linkding-tasks", "linkding-tasks")]
    if ENABLE["pingvin"]:  btns.append(("restart-pingvin", "pingvin"))
    if ENABLE["freshrss"]: btns.append(("restart-freshrss", "freshrss"))
    if ENABLE["searxng"]:  btns.append(("restart-searxng", "searxng"))
    if ENABLE["memos"]:    btns.append(("restart-memos", "memos"))
    if ENABLE["vikunja"]:  btns.append(("restart-vikunja", "vikunja"))
    if ENABLE["gatus"]:    btns.append(("restart-gatus", "gatus"))
    out = "".join(action_btn(k, l, "small") for k, l in btns)
    out += ' <a href="/danger" class="btn danger small">full-stack restart…</a>'
    return out


@app.route("/")
@login_required
def dashboard():
    s = gather_stats()
    svc_html = "<br>".join(_service_row(x) for x in s["services"])
    restart_buttons = _restart_buttons()

    mem_pct = s.get("mem_pct", 0)
    mem_line = (
        f'{human_bytes(s.get("mem_used",0))} / {human_bytes(s.get("mem_total",0))} '
        f'({mem_pct}%)<br>{_bar(mem_pct)}'
    )

    storage_lines = []
    for d in s.get("storage", []):
        storage_lines.append(
            f"<dt>{e(d['label'])}</dt>"
            f"<dd>{human_bytes(d['used'])} / {human_bytes(d['total'])} "
            f"({d['pct']}%)<br>{_bar(d['pct'])}</dd>"
        )

    b = s.get("battery")
    if b:
        batt_line = f"{b['pct']}%, {b['temp']}°C, {e(b['status'])}, {e(b['plugged'])}"
    else:
        batt_line = "(termux-api unreachable)"

    thermal = s.get("thermal", [])
    if thermal:
        top = sorted(thermal, key=lambda z: -z["temp"])[:3]
        thermal_line = " · ".join(f"{e(z['zone'])}:{z['temp']:.0f}°C" for z in top)
    else:
        thermal_line = "?"

    net = s.get("net")
    if net is None:
        net_line = '<span class=small>restricted (the OS blocks /proc/net/dev for this app)</span>'
    elif net:
        def _nrate(n):
            if n.get("rate_rx") is None:
                return ""
            return f' <span class=small>({human_bytes(n["rate_rx"])}/s↓ {human_bytes(n["rate_tx"])}/s↑)</span>'
        net_line = "<br>".join(
            f"{e(n['iface'])}: ↓{human_bytes(n['rx'])} ↑{human_bytes(n['tx'])}{_nrate(n)}"
            for n in net[:3]
        )
    else:
        net_line = '<span class=small>no active interfaces</span>'

    load_full = s.get('load', '?')
    _lp = load_full.split(' / ')
    load1 = _lp[0] if _lp else '?'
    load_rest = ' / '.join(_lp[1:]) if len(_lp) > 1 else ''
    mem_used_gb = s.get('mem_used', 0) / 1073741824
    mem_total_gb = s.get('mem_total', 0) / 1073741824
    batt_pct = b['pct'] if b else '?'

    body = f"""
<div class=statgrid>
  <div class=stat><div class=lbl>uptime</div><div class=val>{e(s.get('uptime','?'))}</div></div>
  <div class="stat accent"><div class=lbl>load · 1/5/15m</div><div class=val><span id=k-load>{e(load1)}</span> <small>/ {e(load_rest)}</small></div>
    <svg class=spark width=70 height=24 viewBox="0 0 70 24" preserveAspectRatio=none><path id=k-load-ar class=ar d=""></path><path id=k-load-ln class=ln d=""></path></svg></div>
  <div class="stat accent"><div class=lbl>RAM</div><div class=val><span id=k-ram>{mem_used_gb:.1f}</span> <small>/ {mem_total_gb:.1f} GB · <span id=k-ram-pct>{mem_pct}</span>%</small></div>
    <div class=bar><span id=k-ram-bar style="width:{mem_pct}%"></span></div></div>
  <div class=stat><div class=lbl>battery · thermal</div><div class=val>{e(str(batt_pct))}% <small>· {s.get('max_temp',0):.0f}°C</small></div></div>
</div>

<div class=grid2>

<div class=box>
<h2><span class=ico>\U0001FA7A</span> stack health</h2>
<p id=svc-block style="margin-top:.5rem">{svc_html}</p>
<hr>
<h3>quick restart</h3>
<p>{restart_buttons}</p>
<p class=small>Each service auto-restarts on crash; buttons are for manual intervention.</p>
</div>

<div class=col>
<div class=box>
<h2><span class=ico>\U0001F4CA</span> glance metrics</h2>
<dl class=metrics style="margin-top:.5rem">
<dt>device</dt><dd>{e(s.get('device','?'))} · Android {e(s.get('android','?'))}</dd>
<dt>uptime</dt><dd>{e(s.get('uptime','?'))}</dd>
<dt>load 1/5/15m</dt><dd id=load-line>{e(s.get('load','?'))}</dd>
<dt>CPU</dt><dd>{s.get('cpu_cores','?')} cores — {e(s.get('cpu_freq','?'))}<br><span class=small>{e(s.get('cpu_model','?'))}</span></dd>
<dt>GPU</dt><dd><span class=small>{e(s.get('gpu_note','?'))}</span></dd>
<dt>RAM</dt><dd id=mem-line>{mem_line}</dd>
{''.join(storage_lines)}
<dt>battery</dt><dd>{e(batt_line)}</dd>
<dt>thermal</dt><dd>{thermal_line} <span class=small>(max {s.get('max_temp',0):.0f}°C)</span></dd>
<dt>network</dt><dd>{net_line}</dd>
</dl>
</div>
</div>

</div>

<div class=botbar>
  <span class=bb-live><span id=live-dot title="live">●</span> live · updates every second</span>
  <a href="/stats">full stats →</a>
</div>
{_SSE_SCRIPT}
"""
    return render(f"dashboard — {BRAND} admin", body)


@app.route("/health")
@login_required
def health_page():
    h = gather_health()
    s = h["summary"]
    overall_class = "ok" if s["all_green"] else ("warn" if s["http_ok"] == s["http_total"] else "err")
    overall_label = "ALL GREEN" if s["all_green"] else (
        "DEGRADED" if s["http_ok"] == s["http_total"] else "FAIL")

    http_rows = ""
    for r in h["http"]:
        cls = "ok" if r["ok"] else "err"
        code_disp = r["code"] if r["code"] else "—"
        err = e(r["error"]) if r["error"] else ""
        scheme_disp = "loop" if r["scheme"] == "loopback" else "http"
        http_rows += (
            f'<tr class="health-{cls}"><td>{e(r["name"])}</td>'
            f'<td>{e(r["host"])}{e(r["path"])}</td>'
            f'<td>{scheme_disp}</td>'
            f'<td>{code_disp} <span class=small>(want {r["expect"]})</span></td>'
            f'<td>{r["latency_ms"]} ms</td>'
            f'<td>{err}</td></tr>'
        )

    proc_rows = ""
    for r in h["procs"]:
        cls = "ok" if r["alive"] else "err"
        status = f"alive (pid {r['pid']})" if r["alive"] else "DOWN"
        proc_rows += (
            f'<tr class="health-{cls}"><td>{e(r["name"])}</td>'
            f'<td><code class=small>{e(r["pattern"])}</code></td>'
            f'<td>{status}</td></tr>'
        )

    body = f"""
<div class=box>
<h2><span class=ico>\U0001FA7A</span> health <span class="health-banner health-{overall_class}">{overall_label}</span></h2>
<p class=small>probed {e(h['ts'])} · auto-refresh every 30s</p>
<dl class=metrics style="margin-top:.4rem">
<dt>HTTP probes</dt><dd>{s['http_ok']} / {s['http_total']} ok</dd>
<dt>processes</dt><dd>{s['proc_ok']} / {s['proc_total']} alive</dd>
</dl>
</div>
<div class=box>
<h2><span class=ico>\U0001F310</span> HTTP endpoints</h2>
<p class=small>loopback probes hit <code>http://{e(CADDY_BIND)}:{e(CADDY_PORT)}</code> (Caddy is plain HTTP on-device; TLS terminates at the Cloudflare edge) with the public hostname in the Host header. A direct conduwuit probe verifies the upstream regardless of Caddy.</p>
<div class=tablewrap><table>
<thead><tr><th>name</th><th>endpoint</th><th>via</th><th>status</th><th>latency</th><th>error</th></tr></thead>
<tbody>{http_rows}</tbody>
</table></div>
</div>
<div class=box>
<h2><span class=ico>⚙️</span> processes</h2>
<div class=tablewrap><table>
<thead><tr><th>service</th><th>pgrep pattern</th><th>state</th></tr></thead>
<tbody>{proc_rows}</tbody>
</table></div>
</div>
<meta http-equiv="refresh" content="30">
"""
    return render(f"health — {BRAND} admin", body)


@app.route("/stats")
@login_required
def stats_page():
    s = gather_stats()
    body = f"""
<div class=cardgrid>
<div class=box>
<h2><span class=ico>\U0001F4F1</span> device</h2>
<dl class=metrics style="margin-top:.4rem">
<dt>model</dt><dd>{e(s.get('device','?'))}</dd>
<dt>Android</dt><dd>{e(s.get('android','?'))}</dd>
<dt>kernel</dt><dd>{e(s.get('kernel','?'))}</dd>
<dt>uptime</dt><dd>{e(s.get('uptime','?'))}</dd>
</dl>
</div>
<div class=box>
<h2><span class=ico>\U0001F9E0</span> CPU</h2>
<dl class=metrics style="margin-top:.4rem">
<dt>model</dt><dd>{e(s.get('cpu_model','?'))}</dd>
<dt>cores</dt><dd>{s.get('cpu_cores','?')}</dd>
<dt>freq</dt><dd>{e(s.get('cpu_freq','?'))}</dd>
<dt>load 1/5/15m</dt><dd>{e(s.get('load','?'))}</dd>
</dl>
</div>
<div class=box>
<h2><span class=ico>\U0001F3AE</span> GPU</h2>
<p style="margin-top:.4rem">{e(s.get('gpu_note','?'))}</p>
</div>
<div class=box>
<h2><span class=ico>\U0001F4BE</span> memory</h2>
<dl class=metrics style="margin-top:.4rem">
<dt>RAM</dt><dd>{human_bytes(s.get('mem_used',0))} / {human_bytes(s.get('mem_total',0))} ({s.get('mem_pct',0)}%){_bar(s.get('mem_pct',0))}</dd>
<dt>swap</dt><dd>{human_bytes(s.get('swap_used',0))} / {human_bytes(s.get('swap_total',0))}</dd>
</dl>
</div>
</div>
<div class=box>
<h2><span class=ico>\U0001F321️</span> thermal zones</h2>
<div class=tablewrap><table><thead><tr><th>zone</th><th>temp</th></tr></thead>
<tbody>{''.join(f'<tr><td>{e(z["zone"])}</td><td>{z["temp"]:.1f}°C</td></tr>' for z in s.get('thermal', []))}</tbody>
</table></div>
</div>
<div class=box>
<h2><span class=ico>\U0001F4E1</span> network interfaces</h2>
<div class=tablewrap><table><thead><tr><th>interface</th><th>rx</th><th>tx</th><th>rate</th></tr></thead>
<tbody>{('<tr><td colspan=4 class=small>restricted — the OS blocks /proc/net/dev for this app</td></tr>' if s.get('net') is None else ''.join(f'<tr><td class=mono>{e(n["iface"])}</td><td>{human_bytes(n["rx"])}</td><td>{human_bytes(n["tx"])}</td><td class=small>{(human_bytes(n["rate_rx"])+"/s↓ "+human_bytes(n["rate_tx"])+"/s↑") if n.get("rate_rx") is not None else "—"}</td></tr>' for n in (s.get('net') or [])))}</tbody>
</table></div>
</div>
"""
    return render(f"stats — {BRAND} admin", body)


# ---------- simple action dispatch (quick-click) ----------
@app.route("/action", methods=["POST"])
@login_required
def action():
    if not csrf_ok(): abort(403)
    cmd = request.form.get("cmd", "")
    spec = SCRIPTS_OK.get(cmd)
    if spec is None:
        abort(400, description="unknown command")
    if spec["kind"] == "danger":
        log_audit("action", cmd=cmd, ok=False, reason="danger-needs-explicit-confirm")
        flash_msg("that command is danger-tier — use the danger page", "err")
        return redirect(url_for("danger_page"))
    if cmd == "restart-stack":
        return redirect(url_for("confirm_action", action_key="restart-stack"))
    if spec["kind"] == "async":
        ok, logname = run_script_detached(cmd)
        log_audit("action-async", cmd=cmd, ok=ok, log=logname)
        icon = "\U0001F7E2" if ok else "❌"
        verb = "started in the background" if ok else "FAILED to launch"
        body = f"""
<div class=box>
<h2>{icon} {e(cmd)} {verb}</h2>
<p>This runs detached from the web worker, so this page does not block on it.</p>
<p class=small>Watch progress in <code>logs/{e(logname)}</code>. New archives appear
on the <a href="/backups">backups page</a> as they finish.</p>
<a href="/backups">← backups</a> &nbsp; <a href="/">dashboard</a>
</div>"""
        return render(f"{cmd} — {BRAND} admin", body)
    log_audit("action-start", cmd=cmd, kind=spec["kind"])
    rc, out = run_script(cmd)
    log_audit("action-end", cmd=cmd, rc=rc)
    icon = "✅" if rc == 0 else "❌"
    body = f"""
<div class=box>
<h2>{icon} {e(cmd)} → exit={rc}</h2>
<pre>{e(out)}</pre>
<a href="/">← dashboard</a>
</div>"""
    return render(f"{cmd} — {BRAND} admin", body)


# ---------- confirm-action page ----------
@app.route("/confirm/<action_key>", methods=["GET", "POST"])
@login_required
def confirm_action(action_key):
    """Two-page confirmation flow for any DANGER_META action:
      GET stage 1: show impact + Continue button.
      GET stage 2 (?stage=2): typed phrase + literal 'yes' + password.
      POST: validate all three, then dispatch.
    """
    meta = DANGER_META.get(action_key)
    if not meta or action_key not in SCRIPTS_OK:
        abort(404)

    if request.method == "POST":
        if not csrf_ok(): abort(403)
        typed_phrase = request.form.get("phrase", "").strip().lower()
        typed_yes    = request.form.get("yes", "").strip().lower()
        pw           = request.form.get("password", "")

        if typed_phrase != meta["phrase"]:
            log_audit("confirm", action=action_key, ok=False, reason="phrase-mismatch")
            flash_msg(f"confirmation phrase mismatch — type exactly: {meta['phrase']}", "err")
            return redirect(url_for("confirm_action", action_key=action_key, stage=2))
        if typed_yes != "yes":
            log_audit("confirm", action=action_key, ok=False, reason="yes-not-typed")
            flash_msg("you must literally type 'yes' to confirm", "err")
            return redirect(url_for("confirm_action", action_key=action_key, stage=2))
        if not pw or not verify_password(pw):
            log_audit("confirm", action=action_key, ok=False, reason="bad-password")
            flash_msg("password incorrect — re-auth required", "err")
            return redirect(url_for("confirm_action", action_key=action_key, stage=2))

        log_audit("confirm-go", action=action_key)
        rc, out = run_script(action_key)
        log_audit("action-end", cmd=action_key, rc=rc)
        icon = "✅" if rc == 0 else "❌"
        body = f"""
<div class=box>
<h2>{icon} {e(meta['title'])} → exit={rc}</h2>
<pre>{e(out)}</pre>
<a href="/">← dashboard</a>
</div>"""
        return render(f"{action_key} — {BRAND} admin", body)

    impact_html = "\n".join(f"<li>{e(x)}</li>" for x in meta["impact"])
    rev = "reversible" if meta.get("reversible") else "NOT reversible"
    stage = request.args.get("stage", "1")

    if stage == "1":
        body = f"""
<div class="box danger-zone">
<h2>⚠ {e(meta['title'])} — review</h2>
<div class=warn-box>
<strong>What this does:</strong>
<ul>{impact_html}</ul>
<p><strong>Reversibility:</strong> {rev}</p>
</div>
<p class=small style="margin-top:1rem">If you really want to proceed, click Continue. The next page asks for typed confirmation, the literal word <code>yes</code>, and your password — three independent inputs, designed to stop accidental clicks.</p>
<form method=get action="{url_for('confirm_action', action_key=action_key)}">
<input type=hidden name=stage value="2">
<button type=submit class=danger>Continue →</button>
<a href="/danger" class="btn small">cancel</a>
</form>
</div>"""
        return render(f"confirm step 1 — {meta['title']}", body)

    body = f"""
<div class="box danger-zone">
<h2>⚠ {e(meta['title'])} — final confirm</h2>
<div class=warn-box>
<p class=small><a href="{url_for('confirm_action', action_key=action_key)}">← back to impact summary</a></p>
<p>Three inputs. All required. None can be auto-completed.</p>
</div>
<form method=post>
<input type=hidden name=_csrf value="{e(new_csrf())}">
<p>1. Type exactly <code>{e(meta['phrase'])}</code>:</p>
<input name=phrase type=text autocomplete=off required placeholder="{e(meta['phrase'])}">
<p>2. Type literally <code>yes</code>:</p>
<input name=yes type=text autocomplete=off required placeholder="yes" pattern="[Yy][Ee][Ss]" maxlength=3>
<p>3. Re-enter your admin password:</p>
<input name=password type=password autocomplete=current-password required>
<button type=submit class=danger>confirm {e(meta['title'].lower())}</button>
<a href="/danger" class="btn small">cancel</a>
</form>
</div>"""
    return render(f"confirm step 2 — {meta['title']}", body)


# ---------- backups ----------
_SAFE_BKP_NAME = re.compile(r"^[\w.:\-+]+\.tar\.zst(\.age)?$")
_SAFE_BUCKET = re.compile(r"^(db|rootfs)$")


@app.route("/backups")
@login_required
def backups():
    rows_html = []
    for bucket in ("db", "rootfs"):
        d = os.path.join(BACKUP_DIR, bucket)
        if os.path.isdir(d):
            files = sorted(
                (f for f in os.listdir(d) if _SAFE_BKP_NAME.fullmatch(f)),
                key=lambda f: os.path.getmtime(os.path.join(d, f)),
                reverse=True,
            )
            for fn in files[:30]:
                path = os.path.join(d, fn)
                age_h = (time.time() - os.path.getmtime(path)) / 3600
                del_form = (
                    '<form method=get action="/backups/delete" style="display:inline">'
                    f'<input type=hidden name=bucket value="{e(bucket)}">'
                    f'<input type=hidden name=file value="{e(fn)}">'
                    '<button class="danger small" type=submit>delete…</button></form>'
                )
                rows_html.append(
                    f'<tr><td>{e(bucket)}</td><td>{e(fn)}</td>'
                    f'<td>{os.path.getsize(path)/1024/1024:.1f} MB</td>'
                    f'<td>{age_h:.1f} h</td><td>{del_form}</td></tr>'
                )
    table = "\n".join(rows_html) or '<tr><td colspan=5>no backups yet</td></tr>'
    body = f"""
<div class=box>
<h2><span class=ico>\U0001F5C4️</span> backups</h2>
<div class=tablewrap><table>
<thead><tr><th>bucket</th><th>file</th><th>size</th><th>age</th><th>actions</th></tr></thead>
<tbody>{table}</tbody>
</table></div>
<p class=small>Stored under <code>{e(BACKUP_DIR)}</code>. Copy them off-device for real durability. Retention keeps the newest few per bucket when <em>prune old</em> runs (see docs/BACKUPS.md).</p>
</div>
<div class=box>
<h2><span class=ico>▶️</span> trigger backup</h2>
{action_btn("full-backup", "FULL backup (whole userland rootfs)", "primary")}
<p class=small><strong>full-backup</strong> tars the entire Debian rootfs (~1 GB) and runs in the background — new files appear above as it finishes. The homeserver stops briefly during the tar.</p>
<hr>
{action_btn("backup-now", "backup the homeserver DB")}
{action_btn("rotate-backups", "prune old (apply retention)")}
<p class=small><strong>backup-now</strong> stops the homeserver for tens of seconds for a consistent DB snapshot. App data lives on the large volume (back that up by copying the volume).</p>
</div>"""
    return render(f"backups — {BRAND} admin", body)


@app.route("/backups/delete", methods=["GET", "POST"])
@login_required
def backups_delete():
    bucket = request.values.get("bucket", "")
    fn = request.values.get("file", "")
    if not _SAFE_BUCKET.fullmatch(bucket) or not _SAFE_BKP_NAME.fullmatch(fn):
        abort(400, description="invalid bucket or filename")
    path = os.path.join(BACKUP_DIR, bucket, fn)
    real = os.path.realpath(path)
    expected_prefix = os.path.realpath(os.path.join(BACKUP_DIR, bucket))
    if not real.startswith(expected_prefix + os.sep):
        abort(400, description="path traversal rejected")
    if not os.path.isfile(real):
        flash_msg(f"file not found: {fn}", "err")
        return redirect(url_for("backups"))

    meta = DANGER_META["delete-backup"]

    if request.method == "POST":
        if not csrf_ok(): abort(403)
        typed_phrase = request.form.get("phrase", "").strip().lower()
        typed_yes    = request.form.get("yes", "").strip().lower()
        pw           = request.form.get("password", "")
        if typed_phrase != meta["phrase"]:
            flash_msg(f"phrase mismatch — type exactly: {meta['phrase']}", "err")
            return redirect(url_for("backups_delete", bucket=bucket, file=fn, stage=2))
        if typed_yes != "yes":
            flash_msg("you must literally type 'yes' to confirm", "err")
            return redirect(url_for("backups_delete", bucket=bucket, file=fn, stage=2))
        if not pw or not verify_password(pw):
            log_audit("backup-delete", bucket=bucket, file=fn, ok=False, reason="bad-password")
            flash_msg("password incorrect — re-auth required", "err")
            return redirect(url_for("backups_delete", bucket=bucket, file=fn, stage=2))
        try:
            os.unlink(real)
            for side in (real + ".sha256", real + ".age.sha256"):
                if os.path.isfile(side):
                    os.unlink(side)
            log_audit("backup-delete", bucket=bucket, file=fn, ok=True)
            flash_msg(f"deleted {fn}", "ok")
        except Exception as ex:
            log_audit("backup-delete", bucket=bucket, file=fn, ok=False, reason=str(ex))
            flash_msg(f"delete failed: {ex}", "err")
        return redirect(url_for("backups"))

    size_mb = os.path.getsize(real) / 1024 / 1024
    age_h = (time.time() - os.path.getmtime(real)) / 3600
    impact_html = "\n".join(f"<li>{e(x)}</li>" for x in meta["impact"])
    stage = request.args.get("stage", "1")

    if stage == "1":
        body = f"""
<div class="box danger-zone">
<h2>⚠ Delete backup — review</h2>
<div class=warn-box>
<p><strong>File:</strong> <code>{e(bucket)}/{e(fn)}</code> — {size_mb:.1f} MB, {age_h:.1f} h old</p>
<strong>Impact:</strong>
<ul>{impact_html}</ul>
<p><strong>Reversibility:</strong> NOT reversible — keep another copy off-device.</p>
</div>
<p class=small style="margin-top:1rem">If you really want to delete this file, click Continue. The next page asks for the typed phrase, the literal word <code>yes</code>, and your password.</p>
<form method=get action="{url_for('backups_delete')}">
<input type=hidden name=stage value="2">
<input type=hidden name=bucket value="{e(bucket)}">
<input type=hidden name=file value="{e(fn)}">
<button type=submit class=danger>Continue →</button>
<a href="/backups" class="btn small">cancel</a>
</form>
</div>"""
        return render("review delete backup", body)

    body = f"""
<div class="box danger-zone">
<h2>⚠ Delete backup — final confirm</h2>
<div class=warn-box>
<p><strong>File:</strong> <code>{e(bucket)}/{e(fn)}</code> — {size_mb:.1f} MB, {age_h:.1f} h old</p>
<p class=small><a href="{url_for('backups_delete', bucket=bucket, file=fn)}">← back to impact summary</a></p>
</div>
<form method=post>
<input type=hidden name=_csrf value="{e(new_csrf())}">
<input type=hidden name=bucket value="{e(bucket)}">
<input type=hidden name=file value="{e(fn)}">
<p>1. Type exactly <code>{e(meta['phrase'])}</code>:</p>
<input name=phrase type=text autocomplete=off required placeholder="{e(meta['phrase'])}">
<p>2. Type literally <code>yes</code>:</p>
<input name=yes type=text autocomplete=off required placeholder="yes" pattern="[Yy][Ee][Ss]" maxlength=3>
<p>3. Re-enter your admin password:</p>
<input name=password type=password autocomplete=current-password required>
<button type=submit class=danger>delete backup</button>
<a href="/backups" class="btn small">cancel</a>
</form>
</div>"""
    return render("confirm delete backup", body)


# ---------- tokens / logs ----------
@app.route("/tokens", methods=["GET", "POST"])
@login_required
def tokens_page():
    """The registration token is masked by default. Reveal requires re-entering
    the admin password (POST), rate-limited via the same backoff as /login."""
    reg_full = ""
    try:
        with open(os.path.join(SECRETS, "registration-token.txt")) as f:
            reg_full = f.read().strip()
    except Exception:
        pass

    if len(reg_full) >= 12:
        reg_display = f"{reg_full[:4]}…{reg_full[-4:]}"
    elif reg_full:
        reg_display = "•" * len(reg_full)
    else:
        reg_display = "(no token set yet — rotate one from the danger zone)"

    revealed = False
    msg_html = ""
    if request.method == "POST":
        if not csrf_ok(): abort(403)
        ip = request.remote_addr or "?"
        if not rate_limit_login(ip):
            log_audit("tokens-reveal", ok=False, reason="ratelimit", ip=ip)
            msg_html = '<div class="flash err">too many recent failed reveals — try again later.</div>'
        else:
            pw = request.form.get("password", "")
            if verify_password(pw):
                revealed = True
                reg_display = reg_full or "(no token set yet)"
                clear_fail(ip)
                log_audit("tokens-reveal", ok=True, ip=ip)
            else:
                record_fail(ip)
                log_audit("tokens-reveal", ok=False, reason="bad-password", ip=ip)
                msg_html = '<div class="flash err">password incorrect — token still masked.</div>'

    if revealed:
        action_html = '<p class=small>Token revealed for this view only — refresh hides it.</p>'
    else:
        action_html = f"""
<form method=post>
<input type=hidden name=_csrf value="{e(new_csrf())}">
<p class=small>Token is masked. Re-enter your password to reveal.</p>
<input name=password type=password autocomplete=current-password required>
<button type=submit>reveal token</button>
</form>
"""
    body = f"""
<div class=box>
<h2>registration token (shared invite code)</h2>
<pre>{e(reg_display)}</pre>
{msg_html}
{action_html}
<p class=small>Distribute privately to invited users; never post it publicly. Rotate it from the <a href="/danger">danger zone</a> if it leaks.</p>
</div>
<div class=box>
<h2>admin user</h2>
<ul>
<li>Panel login user: <code>{e(ADMIN_USER)}</code></li>
<li>Rotate the panel password from the <a href="/danger">danger zone</a>.</li>
</ul>
</div>"""
    return render(f"tokens — {BRAND} admin", body)


@app.route("/logs")
@login_required
def logs_index():
    rows = []
    if os.path.isdir(LOGS):
        for fn in sorted(os.listdir(LOGS)):
            if fn.endswith(".log"):
                p = os.path.join(LOGS, fn)
                rows.append(
                    f'<tr><td><a href="/logs/{e(fn[:-4])}">{e(fn[:-4])}</a></td>'
                    f"<td>{os.path.getsize(p)/1024:.1f} KB</td></tr>"
                )
    table = "\n".join(rows) or '<tr><td colspan=2>no logs</td></tr>'
    body = f"""
<div class=box>
<h2>service logs</h2>
<table><tr><th>service</th><th>size</th></tr>{table}</table>
<p class=small>view shows the last 200 lines. Logs live under <code>{e(LOGS)}</code>.</p>
</div>"""
    return render(f"logs — {BRAND} admin", body)


@app.route("/logs/<name>")
@login_required
def logs_view(name):
    if "/" in name or ".." in name or not name.replace("-", "").replace("_", "").isalnum():
        abort(400)
    path = os.path.join(LOGS, name + ".log")
    if not os.path.isfile(path):
        abort(404)
    try:
        with open(path, errors="replace") as f:
            content = "".join(f.readlines()[-200:])
    except Exception as ex:
        content = f"[read error] {ex}"
    body = f"""
<div class=box>
<h2>log: {e(name)}</h2>
<pre>{e(content)}</pre>
<a href="/logs">← logs</a>
</div>"""
    return render(f"log {name} — {BRAND} admin", body)


# ---------- danger zone ----------
@app.route("/danger")
@login_required
def danger_page():
    panic_keys = ("panic-soft", "panic-hard")
    other_keys = ("rotate-reg-token", "rotate-admin-pass", "restart-stack")

    def _card(key):
        meta = DANGER_META[key]
        imp_short = meta["impact"][0] if meta["impact"] else ""
        return f"""
<div class=box>
<h3>{e(meta['title'])}</h3>
<p class=small>{e(imp_short)}</p>
<a href="/confirm/{e(key)}" class="btn danger">{e(meta['title'].lower())}…</a>
</div>"""

    panic_html = "".join(_card(k) for k in panic_keys)
    other_html = "".join(_card(k) for k in other_keys)

    _hdr = "color:var(--muted);text-transform:uppercase;letter-spacing:.06em;font-size:.82rem;margin:1.4rem 0 .5rem"
    body = f"""
<div class="box danger-zone">
<h2><span class=ico>⚠️</span> danger zone</h2>
<p>Every action below uses a <strong>two-page confirmation</strong>: an impact-review page first, then a final-confirm page that requires three independent inputs (typed phrase, the literal word <code>yes</code>, and your admin password). Designed to stop accidental clicks.</p>
<p class=small>Every attempt is audit-logged with timestamp + IP + UA to <code>{e(AUDIT_LOG)}</code>.</p>
</div>

<h3 style="{_hdr}">Panic buttons — kill switches</h3>
<p class=small>Soft panic stops only public access (the Cloudflare Tunnel) so you can keep working from loopback. Hard panic stops the whole stack except the admin panel, so you can recover from the loopback PWA at <code>http://127.0.0.1:{e(BIND_PORT)}/</code>.</p>
<div class=cardgrid>{panic_html}</div>

<h3 style="{_hdr}">Rotations + restarts</h3>
<div class=cardgrid>{other_html}</div>
"""
    return render(f"danger zone — {BRAND} admin", body)


# ---------- live updates via SSE ----------
_SSE_SCRIPT = """<script>
(function(){
  var dot = document.getElementById("live-dot");
  if (!window.EventSource) return;
  var hist = [];
  function set(id, t){ var el = document.getElementById(id); if (el) el.textContent = t; }
  function html(id, h){ var el = document.getElementById(id); if (el) el.innerHTML = h; }
  function spark(arr){
    var ln = document.getElementById("k-load-ln"); if (!ln || arr.length < 2) return;
    var w = 70, h = 24, mn = Math.min.apply(null, arr), mx = Math.max.apply(null, arr), rng = (mx - mn) || 1;
    var pts = arr.map(function(v, i){
      var x = (i / (arr.length - 1)) * w, y = h - 2 - ((v - mn) / rng) * (h - 4);
      return x.toFixed(1) + "," + y.toFixed(1);
    });
    ln.setAttribute("d", "M" + pts.join(" "));
    var ar = document.getElementById("k-load-ar");
    if (ar) ar.setAttribute("d", "M" + pts.join(" ") + " " + w + "," + h + " 0," + h + "Z");
  }
  var ev = new EventSource("/events");
  ev.onopen = function(){ if (dot) dot.style.opacity = "1"; };
  ev.onerror = function(){ if (dot) dot.style.opacity = ".3"; };
  ev.onmessage = function(e){
    try {
      var d = JSON.parse(e.data);
      if (d.svc_html) html("svc-block", d.svc_html);
      if (d.load) set("load-line", d.load);
      if (d.mem_html) html("mem-line", d.mem_html);
      if (d.load1 != null) set("k-load", d.load1);
      if (d.mem_used_gb != null) set("k-ram", d.mem_used_gb);
      if (d.mem_pct != null){ set("k-ram-pct", d.mem_pct);
        var bar = document.getElementById("k-ram-bar"); if (bar) bar.style.width = d.mem_pct + "%"; }
      if (d.load1 != null){ hist.push(parseFloat(d.load1)); if (hist.length > 20) hist.shift(); spark(hist); }
      if (dot){ dot.style.opacity = ".35"; setTimeout(function(){ dot.style.opacity = "1"; }, 150); }
    } catch(_) {}
  };
})();
</script>
"""

# A short-TTL global cache so concurrent SSE streams SHARE one probe instead of
# each forking; plus a per-session stream cap so one operator with several tabs
# can't multiply the loops.
_STATS_CACHE = {"data": None, "ts": 0.0}
_STATS_CACHE_LOCK = threading.Lock()
_STATS_TTL = 4.0
_SSE_SESSIONS = {}
_SSE_SESSIONS_LOCK = threading.Lock()
_SSE_MAX_PER_SESSION = 1


def gather_stats_cached(ttl=_STATS_TTL):
    now = time.time()
    with _STATS_CACHE_LOCK:
        if _STATS_CACHE["data"] is not None and (now - _STATS_CACHE["ts"]) < ttl:
            return _STATS_CACHE["data"]
        data = gather_stats()
        _STATS_CACHE["data"] = data
        _STATS_CACHE["ts"] = time.time()
        return data


def _quick_metrics():
    """Cheap stats safe to poll every second: uptime + load (sysinfo syscall) and
    RAM (/proc/meminfo). No subprocess forks — unlike gather_stats()."""
    q = {"uptime": "?", "load": "?", "load1": 0.0,
         "mem_used": 0, "mem_total": 0, "mem_pct": 0}
    si = _sysinfo()
    if si:
        q["uptime"] = human_seconds(si[0])
        q["load"] = " / ".join(f"{x:.2f}" for x in si[1])
        q["load1"] = round(si[1][0], 2)
    try:
        meminfo = {}
        for line in read_file("/proc/meminfo").splitlines():
            parts = line.split(":")
            if len(parts) == 2:
                meminfo[parts[0].strip()] = int(parts[1].strip().split()[0]) * 1024
        total = meminfo.get("MemTotal", 0)
        avail = meminfo.get("MemAvailable", meminfo.get("MemFree", 0))
        used = total - avail
        q["mem_used"] = used
        q["mem_total"] = total
        q["mem_pct"] = int(100 * used / total) if total else 0
    except Exception:
        pass
    return q


@app.route("/events")
@login_required
def sse_events():
    """Server-sent events for the dashboard — a small JSON payload each second
    with just the bits that change."""
    sid = request.cookies.get("session", "") or (request.remote_addr or "?")

    def stream():
        with _SSE_SESSIONS_LOCK:
            if _SSE_SESSIONS.get(sid, 0) >= _SSE_MAX_PER_SESSION:
                yield "retry: 30000\nevent: toomany\ndata: {}\n\n"
                return
            _SSE_SESSIONS[sid] = _SSE_SESSIONS.get(sid, 0) + 1
        try:
            i = 0
            svc_html = ""
            while True:
                try:
                    q = _quick_metrics()
                    mem_pct = q["mem_pct"]
                    mem_line = (
                        f'{human_bytes(q["mem_used"])} / {human_bytes(q["mem_total"])} '
                        f'({mem_pct}%)<br>{_bar(mem_pct)}'
                    )
                    if i % 5 == 0:
                        s = gather_stats_cached()
                        svc_html = "<br>".join(_service_row(x) for x in s["services"])
                    payload = json.dumps({
                        "ts": int(time.time()),
                        "load": q["load"],
                        "load1": q["load1"],
                        "uptime": q["uptime"],
                        "mem_html": mem_line,
                        "mem_pct": mem_pct,
                        "mem_used_gb": f'{q["mem_used"]/1073741824:.1f}',
                        "svc_html": svc_html,
                    })
                    yield f"data: {payload}\n\n"
                except GeneratorExit:
                    return
                except Exception as ex:
                    yield f": err {ex}\n\n"
                i += 1
                time.sleep(1)
        finally:
            with _SSE_SESSIONS_LOCK:
                n = _SSE_SESSIONS.get(sid, 1) - 1
                if n <= 0:
                    _SSE_SESSIONS.pop(sid, None)
                else:
                    _SSE_SESSIONS[sid] = n
    r = make_response(stream(), 200)
    r.headers["Content-Type"] = "text/event-stream"
    r.headers["Cache-Control"] = "no-cache"
    r.headers["X-Accel-Buffering"] = "no"
    r.headers["Connection"] = "keep-alive"
    return r


# ---------- PWA assets (no auth — these must load to install) ----------
_ICON_LETTER = (BRAND.strip()[:1] or "p").upper()
_ICON_SVG = (
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">'
    '<rect width="512" height="512" rx="80" fill="#101218"/>'
    '<text x="256" y="340" font-family="ui-monospace,Menlo,monospace" '
    f'font-size="280" font-weight="700" text-anchor="middle" fill="#e7e9ee">{html.escape(_ICON_LETTER)}</text>'
    '<rect x="64" y="430" width="384" height="14" rx="4" fill="#2c6dec"/>'
    "</svg>"
)

@app.route("/icon.svg")
def pwa_icon():
    r = make_response(_ICON_SVG)
    r.headers["Content-Type"] = "image/svg+xml"
    r.headers["Cache-Control"] = "public,max-age=86400"
    return r

@app.route("/admin.css")
def admin_css():
    r = make_response(CSS)
    r.headers["Content-Type"] = "text/css; charset=utf-8"
    r.headers["Cache-Control"] = "public,max-age=31536000,immutable"
    return r

@app.route("/manifest.json")
def pwa_manifest():
    m = {
        "name": f"{BRAND} admin",
        "short_name": (BRAND[:12] or "admin"),
        "description": f"Control panel for the {BRAND} server.",
        "start_url": "/",
        "scope": "/",
        "display": "standalone",
        "orientation": "any",
        "background_color": "#101218",
        "theme_color": "#101218",
        "icons": [
            {"src": "/icon.svg", "type": "image/svg+xml", "sizes": "any", "purpose": "any maskable"},
        ],
    }
    r = make_response(json.dumps(m))
    r.headers["Content-Type"] = "application/manifest+json"
    r.headers["Cache-Control"] = "public,max-age=86400"
    return r


# ---------- error handlers ----------
def _err_page(code, title, body_text):
    body = f"""
<div class=box>
<h2>{e(title)}</h2>
<p>{e(body_text)}</p>
<p><a href="/">← dashboard</a> &middot; <a href="/login">login</a></p>
</div>"""
    return render(f"{code} — {BRAND} admin", body), code

@app.errorhandler(403)
def _e403(_):
    return _err_page(403, "403 forbidden", "Action not allowed (CSRF or auth).")
@app.errorhandler(404)
def _e404(_):
    return _err_page(404, "404 not found", "That page does not exist.")
@app.errorhandler(405)
def _e405(_):
    return _err_page(405, "405 method not allowed", "Wrong HTTP method.")
@app.errorhandler(500)
def _e500(_):
    log_audit("error-500")
    return _err_page(500, "500 server error", "Something went wrong; check logs.")


# ---------- main ----------
def _sanity():
    if BIND_HOST != "127.0.0.1":
        raise RuntimeError("BIND_HOST must be 127.0.0.1")
    if not POCKET_ROOT:
        raise RuntimeError("POCKET_ROOT is not set — the launcher must export it")
    if not os.path.exists(PASSWORD_FILE):
        raise RuntimeError(f"password hash missing at {PASSWORD_FILE}; run scripts/steps/70-install-admin.sh")


# --- Startup init (runs on import) -------------------------------------------
# These run at module import so they execute under BOTH gunicorn AND the
# `python3 app.py` dev fallback. They MUST run per-worker and NOT behind
# `gunicorn --preload`: _load_fails() has to re-read the persisted brute-force
# counters on every worker (re)spawn, else the cross-restart fail tracking would
# silently revert to the startup snapshot. With workers=1 there's no --preload
# memory benefit anyway.
_sanity()
_load_fails()

if __name__ == "__main__":
    print(f"[adminweb] binding {BIND_HOST}:{BIND_PORT} boot_nonce={BOOT_NONCE[:8]}...", flush=True)
    app.run(host=BIND_HOST, port=BIND_PORT, debug=False, use_reloader=False)
