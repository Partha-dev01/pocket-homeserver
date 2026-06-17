#!/usr/bin/env python3
"""
matrix-auth-gw — a tiny auth gateway that lets your users sign into the apps
with their **Matrix (continuwuity / conduwuit) username + password**, so you
never have to hand out a second set of credentials.

It is an OPTIONAL, advanced add-on for pocket-homeserver. The default app
protection is Cloudflare Access at the edge plus each app's own login (see
docs/APP_AUTH.md); this gateway adds single sign-on tied to Matrix accounts.

Two integration models, both served by this one process:

  * forward_auth (header SSO) — Caddy asks the gateway to authenticate each
    request; a valid session returns `Remote-User: <localpart>`, otherwise a
    302 to the login form. This is the model the generated app vhosts hook
    into (the commented `forward_auth` block).
  * OIDC IdP (advanced) — a minimal OpenID Connect provider for apps that
    speak OIDC natively. It is DORMANT until you register at least one client
    (no clients -> the OIDC endpoints answer 503), so it has no effect unless
    you deliberately configure it.

Endpoints:
  * GET  /authgw/login   -> render login form (?next=<path>)
  * POST /authgw/login   -> validate creds against the homeserver
                            (POST /_matrix/client/v3/login, m.login.password)
                            with a pinned device_id, then immediately /logout
                            that token so no device/token accumulates.
                            On success set an HMAC-signed cookie + 302 to next.
  * GET  /authgw/verify  -> Caddy forward_auth target. Valid cookie -> 200 +
                            "Remote-User: <localpart>". Otherwise 302 to login.
  * GET  /authgw/logout  -> clear cookie, 302 to login.
  * GET  /authgw/health  -> 200 "ok" (health probe).
  * /authgw/oidc/*       -> OIDC IdP (HS256 realm), dormant w/o clients.
  * /authgw/oidc-rs/*    -> OIDC IdP (RS256 realm, for go-oidc clients).

stdlib only — no third-party packages. The homeserver is reached on loopback;
Caddy (the reverse proxy) reaches this gateway on loopback likewise. Everything
operator-specific (domain, server name, admins, branding) comes from the
environment; the install step (scripts/steps/60-install-auth-gw.sh) wires it.
"""
import base64
import hashlib
import hmac
import html
import json
import os
import re
import secrets
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# ---- config (env-overridable) --------------------------------------------
LISTEN_HOST = os.getenv("AUTHGW_HOST", "127.0.0.1")
LISTEN_PORT = int(os.getenv("AUTHGW_PORT", "9095"))
HS_API = os.getenv("AUTHGW_HS_API", "http://127.0.0.1:8448/_matrix/client/v3")
# Matrix server_name — the `:server` half of an MXID (@localpart:server_name).
# The install step sets this from MATRIX_SERVER_NAME in your .env.
SERVER_NAME = os.getenv("AUTHGW_SERVER_NAME", "localhost")
# The gateway can front MULTIPLE app vhosts, so the login-CSRF origin check is an
# allowlist, not a single origin. The request's OWN `https://<Host>` is always
# accepted (so an app that proxies /authgw/* under its own host needs no config);
# extra origins (e.g. when login is served from a different host than the app, as
# in the OIDC authorize flow) are added via AUTHGW_PUBLIC_ORIGINS. The legacy
# singular AUTHGW_PUBLIC_ORIGIN is honoured for back-compat and merged in.
PUBLIC_ORIGINS = set(
    o.strip()
    for o in (
        os.getenv("AUTHGW_PUBLIC_ORIGINS", "").split(",")
        + [os.getenv("AUTHGW_PUBLIC_ORIGIN", "")]
    )
    if o.strip()
)
# Login-page brand (shown on the sign-in form). Operator-set; defaults neutral.
BRAND = os.getenv("AUTHGW_BRAND", "Home Server").strip() or "Home Server"
PREFIX = "/authgw"
COOKIE_NAME = "authgw_session"
# Cookie scope. Empty (default) = host-only (each subdomain its own login). Set
# to a parent domain (e.g. "example.com") for ONE login across all
# *.example.com services (true SSO). Reversible: change the env + restart. The
# cookie stays HMAC-signed + HttpOnly + Secure + SameSite=Lax regardless.
COOKIE_DOMAIN = os.getenv("AUTHGW_COOKIE_DOMAIN", "").strip()
# Session lifetime. Default 30 days; set AUTHGW_TTL=604800 for a 7-day SSO TTL.
SESSION_TTL = int(os.getenv("AUTHGW_TTL", str(30 * 24 * 3600)))  # 30 days (env-tunable)
HTTP_TIMEOUT = int(os.getenv("AUTHGW_HTTP_TIMEOUT", "20"))
SECRET_FILE = os.getenv("AUTHGW_SECRET_FILE", "")

# ---- global session epoch (cheap global logout / revocation) --------------
# The HMAC session cookie has no server-side store, so individual revocation is
# impossible without rotating AUTHGW_SECRET (logs everyone out, heavy). Instead
# we fold a small integer EPOCH (read from a tiny file) into the signed payload.
# Bumping the file (echo a higher number) invalidates EVERY outstanding cookie
# on its next request — a cheap global logout — WITHOUT rotating the HMAC key.
# Absent/unreadable file = epoch 0 (back-compat: cookies signed before this
# carry no epoch and read as epoch 0, so they stay valid until the operator
# first bumps the file). Re-read on every sign/verify so an operator bump takes
# effect with NO gateway restart.
SESSION_EPOCH_FILE = os.getenv("AUTHGW_SESSION_EPOCH_FILE", "")


def _session_epoch():
    """Current global session epoch as a non-negative int. Any read/parse error
    yields 0 so a missing/garbled file can never lock users out (fail-open to the
    no-epoch behaviour), and an operator bump is picked up without a restart."""
    f = SESSION_EPOCH_FILE
    if not f:
        return 0
    try:
        with open(f) as fh:
            v = fh.read().strip()
        return int(v) if v else 0
    except Exception:
        return 0

# ---- abuse controls (defense-in-depth; the homeserver rate-limits /login too) -
# Per-IP login rate-limit: at most RATE_MAX POST /authgw/login attempts per
# RATE_WINDOW seconds, keyed on the real client IP (X-Real-IP, set by the
# /authgw/* Caddy blocks via {client_ip}). Past the threshold -> 429. When the
# IP can't be determined (loopback peer / header absent) the limit uses ONE
# shared low-rate bucket rather than collapsing every client into one global
# bucket (which would let a single attacker lock everyone out).
RATE_WINDOW = int(os.getenv("AUTHGW_RATE_WINDOW", "300"))   # 5 min
RATE_MAX = int(os.getenv("AUTHGW_RATE_MAX", "20"))          # attempts / window / IP
# Loopback / unknown-IP requests are NOT fully exempt. A request whose resolved
# client IP is a loopback literal (legit case: a request that genuinely lacks a
# forwarded header; abuse case: a forged `X-Real-IP: 127.0.0.1` reaching the
# gateway off the normal Caddy path) is throttled through ONE shared, low-rate
# global bucket. Real clients always carry the Caddy-set {client_ip} (never
# loopback) so they keep their own per-IP bucket and one attacker can't lock
# everyone out, while a forged loopback IP can't disable the limit entirely. The
# global cap is generous so legitimate header-less loopback traffic (health,
# `ssh -L`) is never the bottleneck.
RATE_GLOBAL_MAX = int(os.getenv("AUTHGW_RATE_GLOBAL_MAX", "60"))  # loopback attempts / window (shared)
# Login-form CSRF: double-submit cookie. GET /authgw/login mints a random token,
# sets it in an HttpOnly + SameSite=Lax cookie AND embeds it in a hidden form
# field; POST requires the two to match. A cross-site POST can neither read the
# token (to echo it) nor send the cookie (SameSite=Lax suppresses it on cross-
# site POST), so it can't satisfy both. Stateless — no server store; a gateway
# restart mid-flow just makes the user reload the form. Belt-and-braces alongside
# the Origin-allowlist check.
CSRF_COOKIE = "authgw_csrf"
CSRF_TTL = int(os.getenv("AUTHGW_CSRF_TTL", "3600"))        # form validity, 1h

# ---- OIDC IdP config ------------------------------------------------------
# A minimal OIDC provider for apps that speak OIDC natively. There are two
# realms:
#   * HS256 realm (/authgw/oidc/) — for clients that DON'T verify the id_token
#     signature asymmetrically (they verify HS256 with the shared client_secret,
#     or read identity from /userinfo). The id_token is HS256-signed with the
#     client's own secret; jwks is empty.
#   * RS256 realm (/authgw/oidc-rs/) — for go-oidc-style clients that REQUIRE an
#     asymmetric signature verified via the published JWKS and require the
#     discovery `issuer` to equal the configured auth URL (see further below).
#
# Loopback-vs-public split: a phone often cannot make an outbound HTTPS call to
# its own public edge, and OIDC clients do server-to-server fetches for
# discovery/token/userinfo. So discovery advertises LOOPBACK URLs for
# token/userinfo/jwks and only the `authorize` endpoint is the PUBLIC https URL
# (a browser redirect). Both bases are env-set by the install step.
OIDC_ENABLED = os.getenv("AUTHGW_OIDC_ENABLED", "true").lower() in ("1", "true", "yes")
OIDC_CLIENT_ID = os.getenv("AUTHGW_OIDC_CLIENT_ID", "")
OIDC_CLIENT_SECRET = os.getenv("AUTHGW_OIDC_CLIENT_SECRET", "")
OIDC_PUBLIC_BASE = os.getenv("AUTHGW_OIDC_PUBLIC_BASE", "").rstrip("/")
OIDC_LOOPBACK_BASE = os.getenv(
    "AUTHGW_OIDC_LOOPBACK_BASE", f"http://127.0.0.1:{LISTEN_PORT}/authgw/oidc"
).rstrip("/")
OIDC_REDIRECT_URIS = set(
    u.strip()
    for u in os.getenv("AUTHGW_OIDC_REDIRECT_URIS", "").split(",")
    if u.strip()
)
# Synthetic email domain for the `email` claim (some apps require a non-empty
# email even though no mail is ever sent). The install step sets this to your
# ${DOMAIN}; the address is synthetic, never mailed.
OIDC_EMAIL_DOMAIN = os.getenv("AUTHGW_OIDC_EMAIL_DOMAIN", "localhost")
OIDC_CODE_TTL = int(os.getenv("AUTHGW_OIDC_CODE_TTL", "120"))
OIDC_TOKEN_TTL = int(os.getenv("AUTHGW_OIDC_TOKEN_TTL", "300"))
# Localparts granted the "admin" role in the id_token (and surfaced as the
# Remote-Admin header on /verify). Apps that map an OIDC roles claim to admin
# (e.g. Pingvin, Gatus) promote these accounts. Set via AUTHGW_OIDC_ADMINS
# (bare localparts or full MXIDs); empty = nobody is auto-admin.
OIDC_ADMINS = set(
    a.strip().lstrip("@").split(":", 1)[0]
    for a in os.getenv("AUTHGW_OIDC_ADMINS", "").split(",")
    if a.strip()
)


# Registered OIDC clients: client_id -> client_secret. The primary client comes
# from AUTHGW_OIDC_CLIENT_ID/SECRET; additional clients are added via
# AUTHGW_OIDC_EXTRA_CLIENTS as a comma/semicolon list of "client_id=secret"
# pairs. Each client's HS256 id_token is signed with ITS OWN secret.
def _parse_oidc_clients():
    clients = {}
    if OIDC_CLIENT_ID and OIDC_CLIENT_SECRET:
        clients[OIDC_CLIENT_ID] = OIDC_CLIENT_SECRET
    for pair in re.split(r"[;,]", os.getenv("AUTHGW_OIDC_EXTRA_CLIENTS", "")):
        pair = pair.strip()
        if "=" in pair:
            cid, sec = pair.split("=", 1)
            cid, sec = cid.strip(), sec.strip()
            if cid and sec:
                clients[cid] = sec
    return clients


OIDC_CLIENTS = _parse_oidc_clients()


# ---- RS256 OIDC realm (go-oidc clients, e.g. Vikunja, Gatus) --------------
# coreos/go-oidc verifies the id_token signature against the discovery jwks_uri
# and accepts ONLY asymmetric algs (RS256/ES256), AND requires the discovery
# `issuer` to equal the configured auth URL. The HS256 / empty-jwks realm above
# cannot satisfy either, so RS clients use a SEPARATE realm (/authgw/oidc-rs/)
# with a LOOPBACK issuer + a real RSA JWKS. Non-breaking by construction: the
# HS256 realm and its clients are untouched; the ONLY crossover is one
# client-gated branch in _oidc_token (RS clients -> RS256). If no RSA key is
# present the RS realm is inert (jwks empty, RS token-signing 500s) and the
# HS256 behaviour is unaffected.
OIDC_RS_CLIENTS = set(
    c.strip() for c in os.getenv("AUTHGW_OIDC_RS_CLIENTS", "").split(",")
    if c.strip()
)
OIDC_RS_ISSUER = os.getenv(
    "AUTHGW_OIDC_RS_ISSUER", f"http://127.0.0.1:{LISTEN_PORT}/authgw/oidc-rs"
).rstrip("/")
OIDC_RS_KID = os.getenv("AUTHGW_OIDC_RS_KID", "authgw-rs256")
OIDC_RS_KEY_FILE = os.getenv("AUTHGW_OIDC_RS_KEY_FILE", "")
# kid-rollover support. During a key rotation the OLD public key must stay in the
# published JWKS for an overlap window so id_tokens already issued under the old
# kid still validate at the relying parties (go-oidc caches keys briefly + tokens
# live OIDC_TOKEN_TTL). Set AUTHGW_OIDC_RS_OLD_KEYS to a comma/semicolon list of
# `kid:/path/to/old-key.json` pairs: each is published (public half only) in the
# RS JWKS ALONGSIDE the current signing key, but is NEVER used to sign (signing
# always uses OIDC_RS_KID / OIDC_RS_KEY_FILE). Empty (default) = single-key
# behaviour. After the overlap window the operator clears this env to drop the
# retired key.
OIDC_RS_OLD_KEYS = os.getenv("AUTHGW_OIDC_RS_OLD_KEYS", "")


# Matrix localpart -> canonical, weird-character-free identity used for the
# `email` and `preferred_username` claims (NOT for `sub`, which stays the raw
# MXID `@localpart:server` so it remains a stable match key for already-
# provisioned accounts — many apps key on sub). Lowercased, restricted to
# [a-z0-9._-], collapsed dots, trimmed separators. Clean localparts map
# byte-identically; only exotic localparts (=, /, +) get sanitized into a valid
# email / username instead of a malformed one.
_CANON_DROP = re.compile(r"[^a-z0-9._-]+")


def canonical_localpart(localpart):
    s = _CANON_DROP.sub("", localpart.lower())
    s = re.sub(r"\.{2,}", ".", s).strip(".-_")
    return s or "user"


def canonical_email(localpart):
    return f"{canonical_localpart(localpart)}@{OIDC_EMAIL_DOMAIN}"


# Short-lived in-memory stores (single process, lock-guarded). A gateway
# restart mid-flow just makes the user retry the sign-in — acceptable.
_oidc_lock = threading.Lock()
_oidc_codes = {}   # auth code   -> {client_id,localpart,sub,email,preferred_username,roles,nonce,redirect_uri,exp}
_oidc_tokens = {}  # access_token -> {sub,email,preferred_username,exp}

# Per-IP login rate-limit state (module-level, lock-guarded like the OIDC stores)
_rate_lock = threading.Lock()
_rate = {}  # client_ip -> [recent POST /authgw/login attempt epoch seconds]
_rate_loopback = []  # shared global bucket for loopback / unknown-IP attempts


def _oidc_purge(now):
    for store in (_oidc_codes, _oidc_tokens):
        for k in [k for k, v in store.items() if v["exp"] < now]:
            store.pop(k, None)


def _rate_allow(ip):
    """Return True if this IP may make another login attempt now.

    Loopback / unknown IPs (no forwarded header — OR a forged
    `X-Real-IP: 127.0.0.1`) share ONE low-rate global bucket
    (RATE_GLOBAL_MAX/window): distinct REAL clients always carry the Caddy-set
    {client_ip} (never loopback) so they keep their own per-IP bucket and one
    attacker can't lock everyone out, while a forged loopback IP is throttled
    instead of disabling the limit. The global cap is generous so legitimate
    header-less loopback traffic (health, `ssh -L`) is never blocked."""
    now = time.time()
    cutoff = now - RATE_WINDOW
    if not ip or ip in ("127.0.0.1", "::1"):
        with _rate_lock:
            hits = [t for t in _rate_loopback if t >= cutoff]
            if len(hits) >= RATE_GLOBAL_MAX:
                _rate_loopback[:] = hits
                return False
            hits.append(now)
            _rate_loopback[:] = hits
            return True
    with _rate_lock:
        # bound memory: opportunistically drop fully-expired IP buckets
        if len(_rate) > 4096:
            for k in [k for k, v in _rate.items() if not v or v[-1] < cutoff]:
                _rate.pop(k, None)
        hits = [t for t in _rate.get(ip, []) if t >= cutoff]
        if len(hits) >= RATE_MAX:
            _rate[ip] = hits
            return False
        hits.append(now)
        _rate[ip] = hits
        return True


def _oidc_discovery():
    return {
        "issuer": OIDC_PUBLIC_BASE,
        "authorization_endpoint": f"{OIDC_PUBLIC_BASE}/authorize",
        "token_endpoint": f"{OIDC_LOOPBACK_BASE}/token",
        "userinfo_endpoint": f"{OIDC_LOOPBACK_BASE}/userinfo",
        "jwks_uri": f"{OIDC_LOOPBACK_BASE}/jwks",
        "response_types_supported": ["code"],
        "subject_types_supported": ["public"],
        "id_token_signing_alg_values_supported": ["HS256"],
        "scopes_supported": ["openid", "email", "profile"],
        "claims_supported": [
            "sub", "email", "email_verified", "preferred_username",
            "name", "nonce", "iss", "aud", "exp", "iat",
        ],
        "grant_types_supported": ["authorization_code"],
        "token_endpoint_auth_methods_supported": [
            "client_secret_post", "client_secret_basic",
        ],
    }


def _oidc_discovery_rs():
    """Discovery for the RS256 realm (go-oidc clients). Derived from the HS256
    discovery, overriding ONLY issuer (loopback, so go-oidc's `issuer == authurl`
    check passes and discovery is fetched over loopback), jwks_uri (the RS realm's
    real RSA key set) and the advertised alg. authorization/token/userinfo stay
    the EXISTING shared /authgw/oidc/ endpoints (the token handler RS256-signs for
    RS clients)."""
    d = _oidc_discovery()
    d["issuer"] = OIDC_RS_ISSUER
    d["jwks_uri"] = f"{OIDC_RS_ISSUER}/jwks"
    d["id_token_signing_alg_values_supported"] = ["RS256"]
    return d


def _jwt_hs256(payload, key):
    """Compact HS256 JWS. Emits a real signature so the token is standards-
    conformant for any verifier (clients that verify HS256 check it; clients that
    only read /userinfo ignore it)."""
    if isinstance(key, str):
        key = key.encode()

    def seg(obj):
        return _b64e(json.dumps(obj, separators=(",", ":")).encode())

    signing_input = f'{seg({"alg": "HS256", "typ": "JWT", "kid": "authgw-oidc"})}.{seg(payload)}'
    sig = hmac.new(key, signing_input.encode(), hashlib.sha256).digest()
    return f"{signing_input}.{_b64e(sig)}"

# ---- secret key ------------------------------------------------------------
def _load_secret():
    if SECRET_FILE and os.path.exists(SECRET_FILE):
        with open(SECRET_FILE, "rb") as f:
            data = f.read().strip()
        if data:
            return data
    env = os.getenv("AUTHGW_SECRET", "")
    if env:
        return env.encode()
    sys.stderr.write("FATAL: no signing secret (set AUTHGW_SECRET_FILE or AUTHGW_SECRET)\n")
    sys.exit(1)

SECRET = _load_secret()


def _b64e(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def _b64d(s):
    pad = "=" * (-len(s) % 4)
    return base64.urlsafe_b64decode(s + pad)


# ---- RS256 signing for the go-oidc realm (pure stdlib, no deps) ------------
def _load_rsa_key():
    """Load the RSA private key {n,e,d} from AUTHGW_OIDC_RS_KEY_FILE (a JSON
    written once by the install step: openssl keygen -> PKCS#1 DER -> stdlib
    parse). Returns None if absent/unreadable or too small, so the RS realm just
    stays inert and the HS256 behaviour is unaffected."""
    f = OIDC_RS_KEY_FILE
    if not f or not os.path.exists(f):
        return None
    try:
        with open(f) as fh:
            j = json.load(fh)
        n, e, d = int(j["n"]), int(j["e"]), int(j["d"])
        return {"n": n, "e": e, "d": d} if n.bit_length() >= 2048 else None
    except Exception:
        return None


RSA_KEY = _load_rsa_key()


def _load_rsa_old_keys():
    """Load retired RS public keys (kid -> {n,e}) for the JWKS overlap window.
    Parses AUTHGW_OIDC_RS_OLD_KEYS = `kid:/path.json[,;kid2:/path2.json]`. Only
    n,e are needed (public half) — d is ignored even if present, since these keys
    never sign. Silently skips any pair that can't be read/parsed (a dropped old
    key just means tokens already issued under it stop validating early, the safe
    failure direction). Empty/unset => {} (single-key, unchanged)."""
    out = {}
    raw = OIDC_RS_OLD_KEYS.strip()
    if not raw:
        return out
    for pair in re.split(r"[;,]", raw):
        pair = pair.strip()
        if ":" not in pair:
            continue
        kid, path = pair.split(":", 1)
        kid, path = kid.strip(), path.strip()
        if not kid or not path or kid == OIDC_RS_KID or not os.path.exists(path):
            continue
        try:
            with open(path) as fh:
                j = json.load(fh)
            n, e = int(j["n"]), int(j["e"])
            if n.bit_length() >= 2048:
                out[kid] = {"n": n, "e": e}
        except Exception:
            continue
    return out


RSA_OLD_KEYS = _load_rsa_old_keys()
# SHA-256 DigestInfo prefix for EMSA-PKCS1-v1_5 (RFC 8017 §9.2).
_SHA256_DIGESTINFO = bytes.fromhex("3031300d060960864801650304020105000420")


def _jwt_rs256(payload):
    """Compact RS256 JWS over `payload`, signed with RSA_KEY using pure-stdlib
    RSASSA-PKCS1-v1_5 (sign = pow(EM, d, n)). Returns None if no key is loaded."""
    if not RSA_KEY:
        return None
    n, d = RSA_KEY["n"], RSA_KEY["d"]
    seg = lambda o: _b64e(json.dumps(o, separators=(",", ":")).encode())
    signing_input = f'{seg({"alg": "RS256", "typ": "JWT", "kid": OIDC_RS_KID})}.{seg(payload)}'
    digest = hashlib.sha256(signing_input.encode()).digest()
    t = _SHA256_DIGESTINFO + digest
    k = (n.bit_length() + 7) // 8
    em = b"\x00\x01" + b"\xff" * (k - len(t) - 3) + b"\x00" + t
    sig = pow(int.from_bytes(em, "big"), d, n).to_bytes(k, "big")
    return f"{signing_input}.{_b64e(sig)}"


def _rsa_jwks():
    """Public JWKS for the RS realm (RFC 7517). Returns a LIST that may hold the
    current signing key PLUS any retired keys still inside their overlap window
    (AUTHGW_OIDC_RS_OLD_KEYS), so relying parties validate id_tokens across a
    rotation. The current key is always FIRST. Empty if no signing key is loaded
    (RS realm inert)."""
    b = lambda i: _b64e(i.to_bytes((i.bit_length() + 7) // 8, "big"))
    keys = []
    if RSA_KEY:
        keys.append({"kty": "RSA", "use": "sig", "alg": "RS256",
                     "kid": OIDC_RS_KID, "n": b(RSA_KEY["n"]), "e": b(RSA_KEY["e"])})
    for kid, k in RSA_OLD_KEYS.items():
        keys.append({"kty": "RSA", "use": "sig", "alg": "RS256",
                     "kid": kid, "n": b(k["n"]), "e": b(k["e"])})
    return {"keys": keys}


def sign_session(localpart):
    exp = int(time.time()) + SESSION_TTL
    # Embed the current global epoch as a 3rd payload field so a later epoch bump
    # invalidates this cookie. A Matrix localpart cannot contain '|'
    # ([a-z0-9._=/-]), so rsplit("|", 2) parses unambiguously.
    epoch = _session_epoch()
    payload = f"{localpart}|{exp}|{epoch}".encode()
    sig = hmac.new(SECRET, payload, hashlib.sha256).digest()
    return f"{_b64e(payload)}.{_b64e(sig)}"


def verify_session(token):
    """Return localpart if the cookie is valid + unexpired + epoch-current, else None."""
    try:
        p_b64, s_b64 = token.split(".", 1)
        payload = _b64d(p_b64)
        sig = _b64d(s_b64)
    except Exception:
        return None
    expect = hmac.new(SECRET, payload, hashlib.sha256).digest()
    if not hmac.compare_digest(sig, expect):
        return None
    try:
        # New cookies are localpart|exp|epoch (3 fields); older cookies are
        # localpart|exp (2 fields). Parse from the RIGHT so a localpart containing
        # no '|' is unambiguous either way, and treat a 2-field cookie as epoch 0
        # (stays valid until the first epoch bump). rsplit(limit=2) yields
        # [localpart, exp, epoch] or [localpart, exp]; we normalise both.
        parts = payload.decode().rsplit("|", 2)
        if len(parts) == 3:
            localpart, exp, epoch_s = parts
            tok_epoch = int(epoch_s)
        else:  # legacy 2-field cookie
            localpart, exp = payload.decode().rsplit("|", 1)
            tok_epoch = 0
    except Exception:
        return None
    if int(exp) < int(time.time()):
        return None
    # reject cookies minted before the latest global logout.
    if tok_epoch < _session_epoch():
        return None
    return localpart


# ---- Matrix credential validation -----------------------------------------
def matrix_login(username, password):
    """Validate creds. Return localpart on success, None on failure.

    Pins device_id so repeated logins reuse one device; logs the token out
    immediately afterwards so no device/token accumulates."""
    username = username.strip()
    # accept either a bare localpart or a full @user:server MXID
    if username.startswith("@"):
        username = username[1:].split(":", 1)[0]
    if not username:
        return None
    device_id = f"authgw-{username}"
    body = json.dumps({
        "type": "m.login.password",
        "identifier": {"type": "m.id.user", "user": username},
        "password": password,
        "device_id": device_id,
        "initial_device_display_name": "matrix-auth-gw",
    }).encode()
    req = urllib.request.Request(
        f"{HS_API}/login", data=body,
        headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as r:
            resp = json.loads(r.read())
    except urllib.error.HTTPError:
        return None          # 403 M_FORBIDDEN = bad creds
    except Exception as e:
        sys.stderr.write(f"authgw: HS login error: {e}\n")
        return None
    token = resp.get("access_token")
    user_id = resp.get("user_id", "")
    if not token:
        return None
    localpart = user_id[1:].split(":", 1)[0] if user_id.startswith("@") else username
    # best-effort logout so we don't leave a live device/token behind
    try:
        lo = urllib.request.Request(
            f"{HS_API}/logout", data=b"{}",
            headers={"Authorization": f"Bearer {token}",
                     "Content-Type": "application/json"}, method="POST")
        urllib.request.urlopen(lo, timeout=HTTP_TIMEOUT).read()
    except Exception as e:
        sys.stderr.write(f"authgw: logout cleanup failed (non-fatal): {e}\n")
    return localpart


# ---- helpers ---------------------------------------------------------------
def safe_next(raw):
    """Only allow same-site relative paths; reject //evil and absolute URLs."""
    if not raw:
        return "/"
    raw = urllib.parse.unquote(raw)
    if not raw.startswith("/") or raw.startswith("//") or raw.startswith("/\\"):
        return "/"
    return raw


LOGIN_HTML = """<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Sign in &middot; {brand}</title>
<style>
 body{{font-family:system-ui,sans-serif;background:#1e1e2e;color:#cdd6f4;
   display:flex;min-height:100vh;align-items:center;justify-content:center;margin:0}}
 .card{{background:#181825;padding:2rem 2.25rem;border-radius:12px;width:320px;
   box-shadow:0 8px 30px rgba(0,0,0,.4)}}
 h1{{font-size:1.15rem;margin:0 0 .25rem}} p.sub{{margin:.1rem 0 1.25rem;font-size:.8rem;color:#9399b2}}
 label{{display:block;font-size:.78rem;margin:.6rem 0 .2rem;color:#a6adc8}}
 input{{width:100%;box-sizing:border-box;padding:.55rem .65rem;border-radius:7px;
   border:1px solid #313244;background:#11111b;color:#cdd6f4;font-size:.95rem}}
 button{{width:100%;margin-top:1.1rem;padding:.6rem;border:0;border-radius:7px;
   background:#89b4fa;color:#11111b;font-weight:600;font-size:.95rem;cursor:pointer}}
 .err{{background:#f38ba8;color:#11111b;padding:.5rem .65rem;border-radius:7px;
   font-size:.82rem;margin-bottom:.5rem}}
</style></head><body><div class="card">
<h1>Sign in to {brand}</h1>
<p class="sub">Use your Matrix username &amp; password.</p>
{err}
<form method="post" action="{prefix}/login">
 <input type="hidden" name="next" value="{next}">
 <input type="hidden" name="csrf" value="{csrf}">
 <label for="u">Username</label>
 <input id="u" name="username" autocapitalize="none" autocorrect="off"
   spellcheck="false" autofocus required>
 <label for="p">Password</label>
 <input id="p" name="password" type="password" required>
 <button type="submit">Sign in</button>
</form></div></body></html>"""


class Handler(BaseHTTPRequestHandler):
    server_version = "matrix-auth-gw"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("authgw %s - %s\n" % (self.address_string(), fmt % args))

    # -- cookie utils
    def _get_cookie(self, name):
        raw = self.headers.get("Cookie", "")
        for part in raw.split(";"):
            if "=" in part:
                k, v = part.strip().split("=", 1)
                if k == name:
                    return v
        return None

    def _cookie(self):
        return self._get_cookie(COOKIE_NAME)

    def _client_ip(self):
        """Real visitor IP from the proxy headers (set by the /authgw/* Caddy
        blocks), falling back to the socket peer (127.0.0.1 on loopback)."""
        xri = (self.headers.get("X-Real-IP") or "").strip()
        if xri:
            return xri
        xff = (self.headers.get("X-Forwarded-For") or "").strip()
        if xff:
            return xff.split(",")[0].strip()
        return self.client_address[0]

    def _send(self, code, body=b"", ctype="text/html; charset=utf-8", extra=None):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra or []):
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _brand(self, next_path=None):
        # The login-page brand is a single operator-configured string
        # (AUTHGW_BRAND). next_path is accepted for signature compatibility but
        # no longer drives per-client branding (the product ships one brand).
        return BRAND

    def _render_login(self, code, next_path, error=""):
        err_html = f'<div class="err">{html.escape(error)}</div>' if error else ""
        # Mint a fresh CSRF token on EVERY render (including failure re-renders
        # from do_POST), so the retry POST always carries a matching cookie+field.
        csrf = secrets.token_urlsafe(24)
        page = LOGIN_HTML.format(prefix=PREFIX, next=html.escape(next_path, quote=True),
                                 err=err_html, brand=html.escape(self._brand(next_path)),
                                 csrf=html.escape(csrf, quote=True))
        self._send(code, page, extra=[self._csrf_cookie(csrf)])

    def _csrf_cookie(self, token):
        attrs = [f"{CSRF_COOKIE}={token}", f"Path={PREFIX}", "HttpOnly",
                 "Secure", "SameSite=Lax", f"Max-Age={CSRF_TTL}"]
        return ("Set-Cookie", "; ".join(attrs))

    def _set_cookie(self, value, max_age):
        attrs = [f"{COOKIE_NAME}={value}", "Path=/", "HttpOnly", "Secure", "SameSite=Lax"]
        if COOKIE_DOMAIN:
            attrs.append(f"Domain={COOKIE_DOMAIN}")
        if max_age is not None:
            attrs.append(f"Max-Age={max_age}")
        return ("Set-Cookie", "; ".join(attrs))

    def _path(self):
        return urllib.parse.urlsplit(self.path)

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        u = self._path()
        path, qs = u.path, urllib.parse.parse_qs(u.query)
        if OIDC_ENABLED and path.startswith(f"{PREFIX}/oidc-rs/"):
            return self._oidc_rs_get(path, qs)
        if OIDC_ENABLED and path.startswith(f"{PREFIX}/oidc/"):
            return self._oidc_get(path, qs)
        if path == f"{PREFIX}/health":
            return self._send(200, "ok", "text/plain; charset=utf-8")
        if path == f"{PREFIX}/verify":
            # forward_auth target: Caddy sends original path in X-Forwarded-Uri
            tok = self._cookie()
            localpart = verify_session(tok) if tok else None
            if localpart:
                extra = [("Remote-User", localpart)]
                # A landing portal can read this via a same-origin fetch to reveal
                # admin-only UI for operators. This is a UI hint, NOT an authz
                # boundary — admin endpoints enforce their own auth, and no
                # forward_auth consumer copies this header.
                if localpart in OIDC_ADMINS:
                    extra.append(("Remote-Admin", "1"))
                return self._send(200, b"", "text/plain; charset=utf-8", extra=extra)
            orig = self.headers.get("X-Forwarded-Uri", "/")
            loc = f"{PREFIX}/login?next=" + urllib.parse.quote(safe_next(orig))
            return self._send(302, b"", extra=[("Location", loc)])
        if path == f"{PREFIX}/logout":
            loc = f"{PREFIX}/login"
            return self._send(302, b"", extra=[("Location", loc),
                              self._set_cookie("deleted", 0)])
        if path == f"{PREFIX}/login":
            nxt = safe_next(qs.get("next", ["/"])[0])
            return self._render_login(200, nxt)
        return self._send(404, "not found", "text/plain; charset=utf-8")

    # -- OIDC IdP endpoints (HS256 realm) ------------------------------------
    def _oidc_get(self, path, qs):
        sub = path[len(f"{PREFIX}/oidc/"):]
        if sub == ".well-known/openid-configuration":
            return self._send(200, json.dumps(_oidc_discovery()), "application/json")
        if sub == "jwks":
            return self._send(200, json.dumps({"keys": []}), "application/json")
        if sub == "authorize":
            return self._oidc_authorize(qs)
        if sub == "userinfo":
            return self._oidc_userinfo()
        return self._send(404, "not found", "text/plain; charset=utf-8")

    # -- RS256 OIDC realm (go-oidc clients): discovery + JWKS ONLY. authorize,
    #    userinfo and token are shared with the HS256 realm above (the token
    #    handler RS256-signs when the client_id is in OIDC_RS_CLIENTS).
    def _oidc_rs_get(self, path, qs):
        sub = path[len(f"{PREFIX}/oidc-rs/"):]
        if sub == ".well-known/openid-configuration":
            return self._send(200, json.dumps(_oidc_discovery_rs()), "application/json")
        if sub == "jwks":
            return self._send(200, json.dumps(_rsa_jwks()), "application/json")
        return self._send(404, "not found", "text/plain; charset=utf-8")

    def _oidc_authorize(self, qs):
        if not OIDC_CLIENTS:
            return self._send(503, "oidc not configured", "text/plain; charset=utf-8")
        g = lambda k: qs.get(k, [""])[0]
        client_id, redirect_uri = g("client_id"), g("redirect_uri")
        state, nonce, rtype = g("state"), g("nonce"), g("response_type")
        if client_id not in OIDC_CLIENTS:
            return self._send(400, "invalid client_id", "text/plain; charset=utf-8")
        if redirect_uri not in OIDC_REDIRECT_URIS:
            return self._send(400, "invalid redirect_uri", "text/plain; charset=utf-8")
        if rtype != "code":
            return self._send(400, "unsupported response_type", "text/plain; charset=utf-8")
        # Require a valid matrix-gw session; otherwise bounce to the login form
        # with next=<this authorize URL> so the user lands right back here.
        tok = self._cookie()
        localpart = verify_session(tok) if tok else None
        if not localpart:
            loc = f"{PREFIX}/login?next=" + urllib.parse.quote(safe_next(self.path))
            return self._send(302, b"", extra=[("Location", loc)])
        code = secrets.token_urlsafe(32)
        now = int(time.time())
        with _oidc_lock:
            _oidc_purge(now)
            _oidc_codes[code] = {
                "client_id": client_id,
                "localpart": localpart,
                "sub": f"@{localpart}:{SERVER_NAME}",
                "email": canonical_email(localpart),
                "preferred_username": canonical_localpart(localpart),
                "roles": ["user"] + (["admin"] if localpart in OIDC_ADMINS else []),
                "nonce": nonce,
                "redirect_uri": redirect_uri,
                "exp": now + OIDC_CODE_TTL,
            }
        sep = "&" if "?" in redirect_uri else "?"
        loc = redirect_uri + sep + urllib.parse.urlencode({"code": code, "state": state})
        return self._send(302, b"", extra=[("Location", loc)])

    def _oidc_userinfo(self):
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Bearer "):
            return self._send(401, "missing bearer", "text/plain; charset=utf-8")
        now = int(time.time())
        with _oidc_lock:
            _oidc_purge(now)
            rec = _oidc_tokens.get(auth[7:].strip())
        if not rec:
            return self._send(401, "invalid token", "text/plain; charset=utf-8")
        return self._send(200, json.dumps({
            "sub": rec["sub"], "email": rec["email"],
            "preferred_username": rec["preferred_username"],
        }), "application/json")

    def _oidc_token(self):
        # The token endpoint is designed to be reached only over loopback (Caddy
        # should 404 it publicly). Should a future/forgotten vhost ever re-expose
        # it, throttle here too so it can't become an unthrottled client-secret
        # oracle / log-flood vector. Uses the same per-IP limiter as
        # /authgw/login; loopback (the legit S2S path) shares the global bucket
        # and is effectively unthrottled for real use.
        if not _rate_allow(self._client_ip()):
            self.log_message("rate-limited oidc/token from %s", self._client_ip())
            return self._send(429, json.dumps({"error": "temporarily_unavailable",
                "error_description": "rate limited"}), "application/json")
        length = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(length) if length else b""
        form = urllib.parse.parse_qs(raw.decode("utf-8", "replace"))
        g = lambda k: form.get(k, [""])[0]
        client_id, client_secret = g("client_id"), g("client_secret")
        grant, code, redirect_uri = g("grant_type"), g("code"), g("redirect_uri")
        # client auth: client_secret_post (body) or client_secret_basic (header)
        if not client_id or not client_secret:
            ah = self.headers.get("Authorization", "")
            if ah.startswith("Basic "):
                try:
                    client_id, client_secret = base64.b64decode(
                        ah[6:]).decode().split(":", 1)
                except Exception:
                    pass
        expected_secret = OIDC_CLIENTS.get(client_id)
        ok_client = bool(expected_secret) and hmac.compare_digest(
            client_secret, expected_secret)
        if not ok_client:
            return self._send(401, json.dumps({"error": "invalid_client"}), "application/json")
        if grant != "authorization_code":
            return self._send(400, json.dumps({"error": "unsupported_grant_type"}), "application/json")
        now = int(time.time())
        with _oidc_lock:
            _oidc_purge(now)
            rec = _oidc_codes.pop(code, None)
        if not rec or rec["exp"] < now:
            return self._send(400, json.dumps({"error": "invalid_grant"}), "application/json")
        # the code is bound to the client that requested it — a client may not
        # redeem another client's code even with valid creds of its own.
        if rec.get("client_id") != client_id:
            return self._send(400, json.dumps(
                {"error": "invalid_grant", "error_description": "client mismatch"}),
                "application/json")
        # redirect_uri check is UNCONDITIONAL (RFC 6749 §4.1.3): the token request
        # MUST present the same redirect_uri bound to the code at authorize time.
        if redirect_uri != rec["redirect_uri"]:
            return self._send(400, json.dumps(
                {"error": "invalid_grant", "error_description": "redirect_uri mismatch"}),
                "application/json")
        exp = now + OIDC_TOKEN_TTL
        # Per-client id_token signing. RS clients (go-oidc) get an RS256 token
        # whose `iss` is the loopback RS issuer (so go-oidc's issuer-match + JWKS
        # signature checks pass); every other client gets an HS256 token signed
        # with its own secret.
        is_rs = client_id in OIDC_RS_CLIENTS
        claims = {
            "iss": OIDC_RS_ISSUER if is_rs else OIDC_PUBLIC_BASE,
            "sub": rec["sub"], "aud": client_id,
            "exp": exp, "iat": now, "email": rec["email"], "email_verified": True,
            "preferred_username": rec["preferred_username"],
            "name": rec["preferred_username"], "nonce": rec["nonce"],
            "roles": rec.get("roles", ["user"]),
        }
        if is_rs:
            id_token = _jwt_rs256(claims)
            if id_token is None:
                return self._send(500, json.dumps({"error": "server_error",
                    "error_description": "rs256 key unavailable"}), "application/json")
        else:
            id_token = _jwt_hs256(claims, expected_secret)
        access_token = secrets.token_urlsafe(32)
        with _oidc_lock:
            _oidc_tokens[access_token] = {
                "sub": rec["sub"], "email": rec["email"],
                "preferred_username": rec["preferred_username"], "exp": exp,
            }
        resp = {
            "access_token": access_token, "token_type": "Bearer",
            "expires_in": OIDC_TOKEN_TTL, "id_token": id_token,
            "scope": "openid email profile",
        }
        return self._send(200, json.dumps(resp), "application/json")

    def do_POST(self):
        u = self._path()
        if OIDC_ENABLED and u.path == f"{PREFIX}/oidc/token":
            return self._oidc_token()
        if u.path != f"{PREFIX}/login":
            return self._send(404, "not found", "text/plain; charset=utf-8")
        # Read the (tiny) login body up-front so every early-return below still
        # drains the socket — avoids HTTP/1.1 keep-alive desync. Cap the read so
        # a bogus Content-Length can't make us buffer unbounded data.
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length > 65536:
            self.close_connection = True
            return self._send(413, "payload too large", "text/plain; charset=utf-8")
        raw = self.rfile.read(length) if length else b""
        form = urllib.parse.parse_qs(raw.decode("utf-8", "replace"))
        nxt = safe_next(form.get("next", ["/"])[0])
        # login-CSRF defence #1: verify the request ORIGIN. Browsers always attach
        # Origin on a cross-site POST and a page cannot forge/suppress ANOTHER
        # site's Origin, so a TRUSTED Origin proves this POST came from one of our
        # own login pages (genuine same-origin) — that alone defeats login-CSRF. A
        # FOREIGN Origin is a hard reject. When Origin is absent (older clients /
        # privacy strippers) fall back to Referer, then to the cookie (#2).
        host = (self.headers.get("Host") or "").split(":")[0]
        def _trusted(o):
            return bool(o) and (o in PUBLIC_ORIGINS or o == f"https://{host}")
        origin = self.headers.get("Origin")
        same_origin = False
        if origin:
            if not _trusted(origin):
                return self._send(403, "bad origin", "text/plain; charset=utf-8")
            same_origin = True
        else:
            ro = urllib.parse.urlsplit(self.headers.get("Referer", ""))
            ref_origin = f"https://{ro.hostname}" if ro.hostname else ""
            if ref_origin and not _trusted(ref_origin):
                return self._send(403, "bad referer", "text/plain; charset=utf-8")
            same_origin = bool(ref_origin)
        # login-CSRF defence #2: double-submit cookie — ENFORCED only when we could
        # NOT confirm same-origin above (no reliable Origin/Referer). When same
        # origin is already proven, a missing/stale cookie (expired Max-Age=1h,
        # back-forward-cache, cookie-blocking) must NOT lock out a genuine user;
        # defence #1 already defeats cross-site forgery. The cookie is still minted
        # on every render and remains the no-Origin/Referer fallback below.
        if not same_origin:
            form_csrf = form.get("csrf", [""])[0]
            cookie_csrf = self._get_cookie(CSRF_COOKIE) or ""
            if (not form_csrf or not cookie_csrf
                    or not hmac.compare_digest(form_csrf, cookie_csrf)):
                return self._render_login(403, nxt, "Your sign-in form expired. Please try again.")
        # per-IP rate-limit (defense-in-depth; the homeserver also limits /login).
        # Checked after the cheap CSRF/Origin gates so only legit-shaped requests
        # consume a slot, and before the network round-trip to the homeserver.
        ip = self._client_ip()
        if not _rate_allow(ip):
            self.log_message("rate-limited login from %s", ip)
            return self._send(429, "Too many attempts. Wait a minute and retry.",
                              "text/plain; charset=utf-8")
        username = (form.get("username", [""])[0]).strip()
        password = form.get("password", [""])[0]
        if not username or not password:
            return self._render_login(400, nxt, "Enter username and password.")
        localpart = matrix_login(username, password)
        if not localpart:
            return self._render_login(401, nxt, "Invalid username or password.")
        cookie = sign_session(localpart)
        return self._send(302, b"", extra=[("Location", nxt),
                          self._set_cookie(cookie, SESSION_TTL)])


def main():
    srv = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler)
    sys.stderr.write(f"matrix-auth-gw listening on {LISTEN_HOST}:{LISTEN_PORT} "
                     f"(HS={HS_API}, server_name={SERVER_NAME})\n")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
