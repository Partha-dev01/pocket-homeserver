#!/usr/bin/env python3
"""User-directory filter proxy — hide chosen accounts from member search.

Binds 127.0.0.1:${USER_FILTER_PORT} (default 8449). Caddy routes the Matrix
user-directory search endpoint through here:

    Caddy → 127.0.0.1:8449 (this) → 127.0.0.1:8448 (the Matrix homeserver)

We forward the search request to the homeserver loopback, parse the JSON
response, drop any MXID listed in the private-users file, and return the rest.
EVERY other /_matrix path bypasses this filter entirely (Caddy routes those
straight to the homeserver), so this proxy only ever sees search traffic.

It FAILS OPEN: any forwarding/parse error returns the upstream response
unchanged, so a bug here can never break member search — it can only fail to
hide an account (which the operator notices), never deny service.

Private-users list format: one MXID per line (e.g. @alice:${MATRIX_SERVER_NAME}).
Lines starting with '#' or blank are ignored. The file is re-read on EVERY
request — no cache, no restart needed when you edit it.

Everything operator-specific (the private-users file path, the homeserver
loopback address, the bind port, the log file) comes from the environment; the
install step (scripts/steps/78-install-filters.sh) wires it. stdlib + Flask
only (Flask is already present for the admin panel).
"""
import json
import os
import time
import urllib.request
import urllib.error

# Force UTC for the process (incl. the WSGI server's request-access logger) so
# every timestamp this proxy emits is unambiguous regardless of the phone's
# system timezone. The _log() helper below already uses time.gmtime().
os.environ["TZ"] = "UTC"
try:
    time.tzset()
except AttributeError:  # tzset is POSIX-only; harmless to skip elsewhere.
    pass

from flask import Flask, request, Response

# ── Config (all env-driven; defaults match the framework conventions) ────────
BIND_HOST = "127.0.0.1"  # loopback ONLY — Caddy fronts us; see _sanity().
BIND_PORT = int(os.environ.get("USER_FILTER_PORT", "8449"))
# The Matrix homeserver's loopback listener (continuwuity binds 127.0.0.1:8448;
# see scripts/steps/40-install-matrix.sh + the core Caddyfile /_matrix route).
BACKEND_URL = os.environ.get("MATRIX_LOOPBACK", "http://127.0.0.1:8448").rstrip("/")

# Path to the private-users list. The install step sets PRIVATE_USERS_FILE to
# ${DATA_DIR}/secrets/private-users.txt; the fallback keeps a bare run working.
_DATA_DIR = os.environ.get("DATA_DIR", "").rstrip("/")
_SECRETS = (f"{_DATA_DIR}/secrets" if _DATA_DIR else
            os.path.normpath(os.path.join(
                os.path.dirname(os.path.abspath(__file__)), "..", "..",
                ".run", "secrets")))
PRIVATE_FILE = os.environ.get("PRIVATE_USERS_FILE",
                              f"{_SECRETS}/private-users.txt")

# Log file. POCKET_LOG_DIR is exported by lib/common.sh (derived from DATA_DIR).
_LOG_DIR = os.environ.get("POCKET_LOG_DIR") or (
    f"{_DATA_DIR}/logs" if _DATA_DIR else
    os.path.normpath(os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "..", ".run", "logs")))
LOG_FILE = os.environ.get("USER_FILTER_LOG", f"{_LOG_DIR}/user-filter.log")

app = Flask(__name__)


def _log(msg):
    line = f"[{time.strftime('%FT%TZ', time.gmtime())}] {msg}\n"
    try:
        with open(LOG_FILE, "a") as f:
            f.write(line)
    except Exception:
        pass


def _private_mxids():
    """Set of MXIDs to hide. Re-read every request; missing file ⇒ empty set."""
    try:
        with open(PRIVATE_FILE) as f:
            return set(
                line.strip()
                for line in f
                if line.strip() and not line.startswith("#")
            )
    except FileNotFoundError:
        return set()
    except Exception as ex:
        _log(f"private-list read error: {ex}")
        return set()


def _forward(method, path, headers, body):
    url = BACKEND_URL + path
    fwd_headers = {}
    # Drop hop-by-hop + host headers; urllib sets Host from the URL.
    for k, v in headers.items():
        lk = k.lower()
        if lk in ("host", "content-length", "connection", "transfer-encoding"):
            continue
        fwd_headers[k] = v
    req = urllib.request.Request(url, method=method, data=body, headers=fwd_headers)
    try:
        resp = urllib.request.urlopen(req, timeout=30)
        return resp.status, dict(resp.getheaders()), resp.read()
    except urllib.error.HTTPError as ex:
        return ex.code, dict(ex.headers), ex.read()


def _get_header_ci(headers, name):
    """Case-insensitive header getter. Some homeservers emit lowercase headers,
    others Title-Case — this handles both."""
    name_low = name.lower()
    for k, v in headers.items():
        if k.lower() == name_low:
            return v
    return ""


@app.route("/_matrix/client/v3/user_directory/search", methods=["POST"])
@app.route("/_matrix/client/r0/user_directory/search", methods=["POST"])
@app.route("/_matrix/client/unstable/user_directory/search", methods=["POST"])
def user_dir_search():
    status, resp_headers, body = _forward(
        "POST", request.path, dict(request.headers), request.get_data()
    )
    # Only attempt filtering when the response is JSON + success + known shape.
    # Anything else passes through verbatim (FAIL OPEN).
    ctype = _get_header_ci(resp_headers, "Content-Type").lower()
    if "application/json" in ctype and 200 <= status < 300:
        try:
            data = json.loads(body)
            priv = _private_mxids()
            if priv and isinstance(data.get("results"), list):
                before = len(data["results"])
                data["results"] = [
                    u for u in data["results"] if u.get("user_id") not in priv
                ]
                removed = before - len(data["results"])
                if removed > 0:
                    try:
                        term = json.loads(
                            request.get_data() or b"{}").get("search_term", "?")
                    except Exception:
                        term = "?"
                    _log(f"filtered {removed} private user(s) from search (term={term!r})")
                body = json.dumps(data).encode()
                # Refresh Content-Length (case-insensitively).
                for k in list(resp_headers.keys()):
                    if k.lower() == "content-length":
                        resp_headers[k] = str(len(body))
                        break
                else:
                    resp_headers["Content-Length"] = str(len(body))
        except Exception as ex:
            _log(f"json-filter error: {ex} (passing original)")
    # Strip hop-by-hop response headers (case-insensitive).
    for hbh in ("connection", "transfer-encoding", "keep-alive"):
        for k in list(resp_headers.keys()):
            if k.lower() == hbh:
                resp_headers.pop(k, None)
    return Response(body, status=status, headers=resp_headers)


@app.route("/healthz")
def healthz():
    return {"ok": True, "private_count": len(_private_mxids())}, 200


def _sanity():
    # Hard refuse to bind anything but loopback — Caddy is the only front door.
    if BIND_HOST != "127.0.0.1":
        raise RuntimeError("BIND_HOST must be loopback (127.0.0.1)")
    # Create the private-users file if absent so the first search doesn't error.
    os.makedirs(os.path.dirname(PRIVATE_FILE), exist_ok=True)
    if not os.path.exists(PRIVATE_FILE):
        with open(PRIVATE_FILE, "w") as f:
            f.write("# One MXID per line (e.g. @alice:example.com). "
                    "'#' and blank lines ignored.\n")


if __name__ == "__main__":
    _sanity()
    print(f"[user-filter] binding {BIND_HOST}:{BIND_PORT} "
          f"(backend={BACKEND_URL})", flush=True)
    app.run(host=BIND_HOST, port=BIND_PORT, debug=False, use_reloader=False)
