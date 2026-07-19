#!/usr/bin/env python3
"""pocket-homeserver — optional Model Context Protocol (MCP) server.

A thin, well-typed front door that lets an MCP client (Claude Desktop, Claude
Code, the claude.ai connector, or any other MCP host) observe and operate the
stack through a small, audited, tiered tool set — "show me the stack status",
"tail the Caddy log", "restart linkding", "back up the Matrix DB now".

It is a DUMB PROTOCOL ADAPTER. It introduces zero new privileged operations:
every mutating tool shells out to an already-vetted scripts/ops/* (or
scripts/bootstrap/*) script with a FIXED argv (never a string, never
shell=True), and every read tool reuses the same probes the admin panel runs.
Its security posture mirrors the admin-panel danger-zone and the admin bot.

Like every other optional subsystem here it is ENABLE_MCP=false by default,
fully env-driven, and ships with no operator-specific values. See the design
RFC in docs/MCP_SERVER_SPEC.md and the operator runbook in docs/MCP.md.

Runs Termux-NATIVE (NOT inside the proot userland), like admin/app.py, because
operate/danger tools orchestrate the host: proot restarts, supervisor pidfiles
under POCKET_STATE_DIR, and pgrep of host processes.

SECURITY INVARIANTS (all enforced below):
  - Tiered + gated: read tools always on; operate behind MCP_ALLOW_OPERATE;
    danger behind MCP_ALLOW_DANGER *and* a per-call typed confirm. A gated-off
    tool is simply NOT registered, so tools/list never advertises it.
  - Closed-world arguments: a `service` arg is validated against the supervised
    set; a `log` arg against a fixed allowlist; backing scripts are validated
    against a fixed allowlist + realpath-contained under scripts/; no arg ever
    names an arbitrary path or command, and no input reaches a shell.
  - Secrets never cross the boundary: rotation tools return metadata only;
    pocket_logs output is redacted; pocket_config filters to non-secret keys;
    pocket_matrix_users returns identities only, never tokens.
  - Audited: every tools/call is written via the same audit trail the panel uses
    (admin-audit.log), with the caller identity and redacted args.
  - HTTP transport is fail-closed behind THREE gates: the Caddy @no_cf_jwt 403
    presence gate at the edge, then in-process — a 0600 bearer credential
    (hmac.compare_digest) and RS256 Cloudflare-Access JWT validation (the same
    logic the admin panel uses). A per-session rate limit caps abuse.
  - stdio transport: the SSH/CF-Access channel itself is the authentication;
    nothing is published. ALL diagnostics go to stderr — stdout is the JSON-RPC
    protocol channel and printing to it corrupts the stream.

Generalized from a working deployment; review before running on a fresh phone.
"""
import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
from contextvars import ContextVar

# Force this process to stamp times in UTC, regardless of the device timezone,
# so audit lines are consistent and comparable (mirrors admin/app.py).
os.environ["TZ"] = "UTC"
try:
    time.tzset()
except Exception:
    pass

from mcp.server.fastmcp import FastMCP


# ---------- config (from the environment + the repo .env) ----------
def _load_env_file(path):
    """Parse a `KEY=value` env file into a dict (the same shape admin/app.py's
    _load_env uses, plus: tolerate a leading `export ` and strip one layer of
    matching surrounding quotes). Best-effort; never raises."""
    out = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                if line.startswith("export "):
                    line = line[len("export "):]
                k, v = line.split("=", 1)
                k = k.strip()
                v = v.strip()
                if len(v) >= 2 and v[0] == v[-1] and v[0] in ("'", '"'):
                    v = v[1:-1]
                if k:
                    out[k] = v
    except Exception:
        pass
    return out


# POCKET_ROOT is exported by the installed launcher (steps/87-install-mcp.sh).
# We also parse the repo .env directly so the ENABLE_* map + non-secret config
# are accurate regardless of which keys a launcher happens to export — values in
# the real process environment always win over the file.
_POCKET_ROOT_BOOT = os.environ.get("POCKET_ROOT", "")
_DOTENV = _load_env_file(os.path.join(_POCKET_ROOT_BOOT, ".env")) if _POCKET_ROOT_BOOT else {}


def _env(name, default=""):
    v = os.environ.get(name)
    if v is not None:
        return v
    v = _DOTENV.get(name)
    return v if v is not None else default


def _flag(name):
    return _env(name, "false").strip().lower() == "true"


# Core paths — the SAME keys admin/app.py reads (common.sh semantics).
DATA_DIR    = _env("DATA_DIR")                       # large volume (required)
POCKET_ROOT = _env("POCKET_ROOT")                    # repo root — where scripts/ lives (required)
SCRIPTS     = os.path.join(POCKET_ROOT, "scripts")
SECRETS     = os.path.join(DATA_DIR, "secrets")
STATE       = _env("POCKET_STATE_DIR") or os.path.join(DATA_DIR, "state")
LOGS        = _env("POCKET_LOG_DIR")   or os.path.join(DATA_DIR, "logs")
BACKUP_DIR  = _env("BACKUP_DIR")       or os.path.join(DATA_DIR, "backups")
# Metrics ring written by scripts/ops/metrics-sampler.py. Lives on ext4 (Termux
# $HOME), NOT under DATA_DIR (often exFAT) — mirrors admin/app.py:70-71 exactly
# (the sampler's launcher pins the same default, so both readers agree).
METRICS_LOG = _env("POCKET_METRICS_LOG") or os.path.join(
    os.path.expanduser("~"), ".pocket", "metrics", "metrics.jsonl")

# Pocket Pages (Sites) — Termux-native host-side view of SITES_ROOT inside the
# proot userland (AD-3), the same PD_BASE/SITES_ROOT/SITES_STAGING/SITES_REGISTRY
# derivation admin/app.py:79-83 uses. Sites reads go straight to the registry
# file, never through a subprocess (AD-3) — see _sites_registry() below.
PD_BASE        = os.path.join(_env("PREFIX", "/data/data/com.termux/files/usr"),
                               "var/lib/proot-distro/installed-rootfs")
SITES_ROOT     = _env("POCKET_SITES_ROOT") or os.path.join(PD_BASE, "debian/var/www/sites")
SITES_STAGING  = os.path.join(SITES_ROOT, ".staging")
SITES_REGISTRY = os.path.join(SITES_ROOT, ".registry.json")
# Name/job-id validation — ported verbatim from admin/app.py:2739-2748. This is
# the THIRD hand-maintained mirror of the same reserved list (AD-3): lib-sites.sh's
# RESERVED_SUBS is the first, admin/app.py's SITE_RESERVED the second — tests
# assert three-way parity (§12).
SITE_SUB_RE = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")
SITE_RESERVED = frozenset(
    "chat admin files music books audiobooks read dav wiki vault links share rss notes "
    "tasks search tools status stickers webmail ai mcp git dns "
    "www mail mta smtp imap pop autoconfig autodiscover matrix sites api cdn ns1 ns2 preview".split()
)
# Same shape as the pipeline's RELEASE_ID_RE (lib-sites.sh:49): {4,6} tolerates
# both HHMM and the HHMMSS form new_job_id()/new_release_id() actually mint.
_SITE_JOB_RE = re.compile(r"^[0-9]{8}T[0-9]{4,6}Z-[0-9a-f]{4}$")

# Backing-script roots. Mutating tools shell out to these with a FIXED argv.
OPS         = os.path.join(SCRIPTS, "ops")
BOOTSTRAP   = os.path.join(SCRIPTS, "bootstrap")

# Audit trail — the SAME file the admin panel appends to.
AUDIT_LOG   = os.path.join(LOGS, "admin-audit.log")

# Operator credentials file (0600, written by bootstrap/create-admin.sh). Holds
# the operator's ADMIN_TOKEN used for the read-only Matrix admin queries — read
# from this file at call time, never exported on a launcher line, never returned.
ADMIN_CRED_FILE = os.path.join(SECRETS, "admin-credentials.env")
# Private-users list (the user-directory privacy filter), if present.
PRIVATE_FILE = os.path.join(SECRETS, "private-users.txt")

DOMAIN      = _env("DOMAIN", "localhost")
CADDY_BIND  = _env("CADDY_BIND", "127.0.0.1")
CADDY_PORT  = _env("CADDY_PORT", "8443")
# Loopback port of the admin panel itself — used only by the 3 unconditional
# core HTTP probes (AD-7); mirrors admin/app.py:97's own ADMINWEB_PORT read.
ADMINWEB_PORT = _env("ADMINWEB_PORT", "9000") or "9000"

# Same loopback homeserver the panel's gather_health() / bot widget use.
MATRIX_HS_API = "http://127.0.0.1:8448"

# ── MCP configuration (docs/MCP_SERVER_SPEC.md §11) ──────────────────────────
ENABLE_MCP        = _flag("ENABLE_MCP")
MCP_TRANSPORT     = (_env("MCP_TRANSPORT", "stdio").strip().lower() or "stdio")
MCP_HTTP_HOST     = _env("MCP_HTTP_HOST", "mcp")          # subdomain label → mcp.${DOMAIN}
MCP_HTTP_PORT     = int(_env("MCP_HTTP_PORT", "9120") or "9120")
# The HTTP transport MUST bind the loopback (Caddy fronts the edge); NEVER 0.0.0.0.
# Default to a hardcoded 127.0.0.1 and DO NOT follow CADDY_BIND — the no-auth php-fpm
# pools (freshrss/wallabag/snappymail) take the same stance, so a supported
# `CADDY_BIND=0.0.0.0` (chosen to expose Caddy itself) can never LAN-expose this
# tool-execution endpoint. A non-loopback override is refused fail-closed in
# _serve_http() below.
MCP_HTTP_BIND     = _env("MCP_HTTP_BIND") or "127.0.0.1"
MCP_ALLOW_OPERATE = _flag("MCP_ALLOW_OPERATE")
MCP_ALLOW_DANGER  = _flag("MCP_ALLOW_DANGER")
MCP_LOG_REDACT    = _env("MCP_LOG_REDACT", "true").strip().lower() != "false"

# Bearer credential FILE path (HTTP mode); the file is 0600, generated at install.
# Only the PATH lives in the env — the credential value is never on argv / in .env.
MCP_BEARER_TOKEN_FILE = _env("MCP_BEARER_TOKEN_FILE") or os.path.join(
    SECRETS, "mcp-bearer.cred")

# CF Access knobs reused from the admin panel (no new CF keys). NOTE: unlike the
# admin panel, the HTTP transport ALWAYS enforces JWT validation when a team domain
# is set — it intentionally ignores CF_ACCESS_MODE so a remote tool surface is
# fail-closed (there is no "log-only" permissive mode here).
CF_ACCESS_TEAM_DOMAIN = _env("CF_ACCESS_TEAM_DOMAIN")
CF_ACCESS_AUD         = _env("CF_ACCESS_AUD")
CF_ACCESS_ISSUER      = f"https://{CF_ACCESS_TEAM_DOMAIN}" if CF_ACCESS_TEAM_DOMAIN else ""
CF_ACCESS_CERTS_URL   = f"{CF_ACCESS_ISSUER}/cdn-cgi/access/certs" if CF_ACCESS_ISSUER else ""

# Which optional subsystems are enabled — gates conditional tool registration
# and the non-secret pocket_config view (mirrors admin/app.py's ENABLE map).
ENABLE = {
    "auth-gw":       _flag("ENABLE_AUTH_GATEWAY"),
    "linkding":      _flag("ENABLE_LINKDING"),
    "pingvin":       _flag("ENABLE_PINGVIN"),
    "freshrss":      _flag("ENABLE_FRESHRSS"),
    "memos":         _flag("ENABLE_MEMOS"),
    "vikunja":       _flag("ENABLE_VIKUNJA"),
    "searxng":       _flag("ENABLE_SEARXNG"),
    "ittools":       _flag("ENABLE_ITTOOLS"),
    "gatus":         _flag("ENABLE_GATUS"),
    "backup-daemon": _flag("ENABLE_BACKUP_DAEMON"),
    "honeypot":      _flag("ENABLE_HONEYPOT"),
    "user-filter":   _flag("ENABLE_USER_FILTER"),
    "media-filter":  _flag("ENABLE_MEDIA_FILTER"),
    "cloud-bots":    _flag("ENABLE_CLOUD_BOTS"),
    "exobot":        _flag("ENABLE_EXOBOT"),
    "stickers":      _flag("ENABLE_STICKERS"),
    "adminbot":      _flag("ENABLE_ADMINBOT"),
    "email":         _flag("ENABLE_EMAIL"),
    # AD-9 — four keys admin/app.py's ENABLE dict already carries
    # (admin/app.py:114-154); no new .env key, gate registration only.
    "sites":         _flag("ENABLE_SITES"),
    "user-admin":    _flag("ENABLE_USER_ADMIN"),
    "metrics":       _flag("ENABLE_METRICS"),
    "offsite":       _flag("ENABLE_OFFSITE_BACKUP"),
}

# Default allowlist of log basenames pocket_logs may read. Operators can override
# / extend via MCP_ALLOWED_LOGS (a comma list of BASENAMES — never paths).
_DEFAULT_ALLOWED_LOGS = (
    "caddy.log", "caddy-access.log", "cloudflared.log", "matrix.log",
    "adminweb.log", "auth-gw.log", "honeypot.log", "backup-daemon.log",
    # AD-8 additions — every one an actual file a supervised service or a
    # detached script writes (verified against ${POCKET_LOG_DIR} usage, not
    # guessed). Per-job deploy logs (site-deploy-<job>.log) are deliberately
    # NOT here — dynamic basename, read exclusively via pocket_site_status.
    "metrics-sampler.log", "user-filter.log", "media-filter.log",
    "honeypot-watcher.log", "adminweb-async.log", "mcp-async.log",
)


def _parse_allowed_logs():
    """Build the closed-world set of log basenames pocket_logs may read.

    Always basenames only — os.path.basename() defends against any '/' or '..'
    sneaking in via the env. Read-time path containment is enforced separately."""
    raw = _env("MCP_ALLOWED_LOGS").strip()
    names = [n.strip() for n in raw.split(",")] if raw else list(_DEFAULT_ALLOWED_LOGS)
    return {os.path.basename(n) for n in names if n}


ALLOWED_LOGS = _parse_allowed_logs()

# Default tail length + a hard cap so a client can't ask for an unbounded read.
LOG_TAIL_DEFAULT = 200
LOG_TAIL_MAX     = 2000

# Subprocess timeouts (seconds). Long ops (full backup) get a generous ceiling.
OPS_TIMEOUT_DEFAULT = 600

# The caller identity threaded into the audit log: "ssh" for the stdio transport
# (the SSH channel is the authentication), or the validated Cloudflare-Access
# email for the HTTP transport (set per-request by the auth gate).
_CALLER = ContextVar("mcp_caller", default="ssh")


# ---------- redaction ----------
# Leak-scan-style patterns: strip secret-shaped substrings from any text that
# leaves the server (log tails, captured script output, audited args). Built to
# fail safe — over-redacting a log line is acceptable; leaking a credential is not.
_RE_AUTH_HEADER = re.compile(r'(?i)(authorization\s*[:=]\s*bearer\s+)\S+')
_RE_BEARER      = re.compile(r'(?i)\b(bearer)\s+[A-Za-z0-9._~+/\-]{12,}=*')
_RE_KV_SECRET   = re.compile(
    r'(?i)\b(password|passwd|secret|api[_-]?key|access[_-]?token'
    r'|registration[_-]?token|auth[_-]?token|bot[_-]?token|'
    r'client[_-]?secret)\b(\s*[:=]\s*)\S+')
# Generic env/KV secrets by name convention (e.g. FOO_TOKEN=, DB_PASS=, AWS_SECRET=).
# The leading-`\b` + separator-before-key/pass/cred avoids matching words like
# "monkey"/"keyboard" while still catching real *_KEY=/_PASS= env dumps.
_RE_KV_GENERIC  = re.compile(
    r'(?i)\b(\w*(?:secret|token|passwd|password)\w*'
    r'|\w+[_-](?:key|pass|cred|credential|credentials))(\s*[:=]\s*)\S+')
# Bare Matrix access/refresh tokens (syt_…/syr_…); the underscores break _RE_LONG_B64.
_RE_MATRIX_TOK  = re.compile(r'(?i)\bsy[tr]_[A-Za-z0-9._~+/\-]{10,}=*')
# PEM private-key blocks (any internal line length, multiline).
_RE_PEM_KEY     = re.compile(
    r'(?s)-----BEGIN[^-]*PRIVATE KEY-----.*?-----END[^-]*PRIVATE KEY-----')
# Credentials embedded in a URL: scheme://user:pass@host.
_RE_BASIC_AUTH  = re.compile(r'([A-Za-z][A-Za-z0-9+.\-]*://)[^/\s:@]+:[^/\s@]+@')
_RE_LONG_HEX    = re.compile(r'\b[A-Fa-f0-9]{32,}\b')
_RE_LONG_B64    = re.compile(r'[A-Za-z0-9+/]{40,}={0,2}')


def _redact(text):
    """Redact secret-shaped substrings. Honors MCP_LOG_REDACT (default on).
    Fail-safe by design: over-redacting a log line is acceptable, leaking a
    credential is not. Covers auth headers, bearer/Matrix tokens, KV secrets
    (named + by convention), PEM private keys, in-URL credentials, and long
    hex/base64 runs."""
    if not text:
        return text
    if not MCP_LOG_REDACT:
        return text
    out = _RE_PEM_KEY.sub('<redacted-private-key>', text)
    out = _RE_BASIC_AUTH.sub(r'\1<redacted>@', out)
    out = _RE_AUTH_HEADER.sub(r'\1<redacted>', out)
    out = _RE_BEARER.sub(r'\1 <redacted>', out)
    out = _RE_KV_SECRET.sub(r'\1\2<redacted>', out)
    out = _RE_KV_GENERIC.sub(r'\1\2<redacted>', out)
    out = _RE_MATRIX_TOK.sub('<redacted>', out)
    out = _RE_LONG_HEX.sub('<redacted>', out)
    out = _RE_LONG_B64.sub('<redacted>', out)
    return out


# ---------- audit ----------
def _audit(tool, **kw):
    """Append one JSON audit line for a tools/call, written to the SAME audit file
    as admin/app.py log_audit() (this variant adds source=mcp and omits the ip/ua
    fields). Schema: ts, user, source, action, [args]. The caller identity
    is the per-request _CALLER (CF-Access email for HTTP, "ssh" for stdio). Args
    are REDACTED and a `confirm` value is never recorded. Best-effort — auditing
    never crashes a tool."""
    clean = {}
    for k, v in kw.items():
        if k == "confirm":
            continue
        clean[k] = _redact(v) if isinstance(v, str) else v
    line = {
        "ts":     time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "user":   _CALLER.get(),
        "source": "mcp",
        "action": tool,
    }
    if clean:
        line["args"] = clean
    try:
        os.makedirs(LOGS, exist_ok=True)
        with open(AUDIT_LOG, "a") as f:
            f.write(json.dumps(line) + "\n")
    except Exception:
        pass


# ---------- backing-script runner ----------
# Closed-world allowlist of the ONLY scripts any tool may execute. A bug in a
# caller cannot run an arbitrary path: the name must be in this set AND its
# realpath must resolve under scripts/.
_OPS_ALLOWLIST = frozenset((
    "ops/status.sh",
    "ops/restart.sh",
    "ops/backup-db.sh",
    "ops/backup-all.sh",
    "ops/restore.sh",
    "ops/panic-soft.sh",
    "ops/panic-hard.sh",
    "ops/rotate-registration-token.sh",
    "bootstrap/mint-invite-token.sh",
    # M3 additions — parity tools (§7) + sites sync ops (§5).
    "ops/doctor.sh",
    "ops/rotate-backups.sh",
    "ops/offsite-push.sh",
    "ops/user-create.sh",
    "ops/user-reset-password.sh",
    "ops/user-suspend.sh",
    "ops/user-unsuspend.sh",
    "ops/user-deactivate.sh",
    "start-stack.sh",
    "sites/site-rollback.sh",
    "sites/site-delete.sh",
))


def _run_ops(script_name, *args, timeout=OPS_TIMEOUT_DEFAULT):
    """Run an ALLOWLISTED backing script with a FIXED argv; capture output.

    `script_name` is one of _OPS_ALLOWLIST; `*args` are positional args the tool
    wrapper has ALREADY validated (closed-world — never free-form). Returns
    (returncode, combined_output). NEVER shell=True; the argv is a list."""
    if script_name not in _OPS_ALLOWLIST:
        raise ValueError(f"refusing to run non-allowlisted script {script_name!r}")
    scripts_root = os.path.realpath(SCRIPTS)
    path = os.path.realpath(os.path.join(SCRIPTS, script_name))
    if path != scripts_root and not path.startswith(scripts_root + os.sep):
        raise ValueError("resolved script path escapes the scripts/ tree")
    if not os.path.isfile(path):
        raise FileNotFoundError(f"backing script not found: {script_name}")
    cmd = ["bash", path, *[str(a) for a in args]]
    try:
        # §14 finding 5 — explicit stdin=DEVNULL (was: inherited non-tty stdin).
        # site-deploy.sh's non-interactive staging-containment check (AD-5) is
        # gated on `[ ! -t 0 ]`; this makes that guarantee self-documenting
        # instead of an implicit property of how the server happens to run.
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                            stdin=subprocess.DEVNULL)
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except subprocess.TimeoutExpired:
        return -1, f"timed out after {timeout}s"
    except Exception as ex:
        return -2, str(ex)


# AD-2 — one new detached/async execution primitive, scoped to exactly ONE
# caller (pocket_site_deploy, §5): a site deploy can legitimately run past a
# reasonable tools/call timeout (SITES_BUILD_TIMEOUT defaults to 900s for the
# node build tier), and the sites job-id + status-poll pattern requires
# pocket_site_deploy to return almost immediately with a job id. Every other
# mutating tool in this file stays synchronous via _run_ops (see the spec's
# AD-2 rationale for NOT extending this to pocket_offsite_push/pocket_backup_all
# — neither script has a job-state-file contract to poll against).
_DETACHED_ALLOWLIST = frozenset(("sites/site-deploy.sh",))
_MCP_ASYNC_LOG = "mcp-async.log"  # shared sink for every detached MCP-launched script


def _run_ops_detached(script_name, *args):
    """Launch an ALLOWLISTED backing script DETACHED (subprocess.Popen, not
    run) — for the one mutating tool whose backing script can outlive a
    reasonable tools/call timeout. Output goes to LOGS/mcp-async.log (mirrors
    adminweb's single shared async sink, admin/app.py:2802) — per-JOB progress
    is read back separately from the job's OWN log file (site-deploy-<job>.log),
    never from this shared sink. Returns True/False (launch succeeded), never
    raises."""
    if script_name not in _DETACHED_ALLOWLIST:
        raise ValueError(f"refusing to detach-launch non-allowlisted script {script_name!r}")
    scripts_root = os.path.realpath(SCRIPTS)
    path = os.path.realpath(os.path.join(SCRIPTS, script_name))
    if path != scripts_root and not path.startswith(scripts_root + os.sep):
        raise ValueError("resolved script path escapes the scripts/ tree")
    if not os.path.isfile(path):
        raise FileNotFoundError(f"backing script not found: {script_name}")
    cmd = ["bash", path, *[str(a) for a in args]]
    sink = os.path.join(LOGS, _MCP_ASYNC_LOG)
    try:
        os.makedirs(LOGS, exist_ok=True)
        with open(sink, "ab", buffering=0) as lf:
            subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=lf, stderr=lf,
                              start_new_session=True, close_fds=True)
        return True
    except Exception:
        return False


# ---------- small read helpers (plumbing — no privileged logic) ----------
def _read_file(path, default=""):
    try:
        with open(path) as f:
            return f.read()
    except Exception:
        return default


def _tail_file(path, n, chunk=8192):
    """Return the last `n` lines of a file without slurping the whole thing."""
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            data = b""
            while size > 0 and data.count(b"\n") <= n:
                step = min(chunk, size)
                size -= step
                f.seek(size)
                data = f.read(step) + data
            return b"\n".join(data.splitlines()[-n:]).decode("utf-8", "replace")
    except FileNotFoundError:
        return f"(no such log: {os.path.basename(path)})"
    except Exception as ex:
        return f"(cannot read log: {ex})"


def _supervised_services():
    """The closed-world set of currently-supervised service names, read from
    ${POCKET_STATE_DIR}/*.cmd (one file per supervised service, written by
    common.sh supervise()). This is the allowlist the `service` argument of the
    operate tools is validated against."""
    names = set()
    try:
        for fn in os.listdir(STATE):
            if fn.endswith(".cmd"):
                names.add(fn[:-len(".cmd")])
    except Exception:
        pass
    return names


def _service_live(name):
    """Best-effort liveness for a supervised service via its pidfile (mirrors the
    common.sh supervisor-alive check, minus the cmdline re-verify the panel does)."""
    pidfile = os.path.join(STATE, f"{name}.pid")
    try:
        pid = int(_read_file(pidfile).strip() or "0")
    except Exception:
        return False, 0
    if pid <= 0:
        return False, 0
    try:
        os.kill(pid, 0)
        return True, pid
    except Exception:
        return False, pid


def _degraded_marker(name):
    """If the supervisor has flagged this service as crash-looping, return the
    marker text (service/rc/fails/since); else None. Ported from
    admin/app.py:1062-1072 (_degraded_marker) — written by supervise() in
    scripts/lib/common.sh after POCKET_CRASHLOOP_FAILS rapid restarts. A
    service can pgrep/pidfile-alive momentarily while crash-looping, so this
    marker — not the instantaneous liveness check — is the reliable signal
    (AD-7)."""
    try:
        with open(os.path.join(STATE, f"{name}.degraded"), encoding="utf-8") as fh:
            return fh.read().strip() or None
    except Exception:
        return None


# The 3 unconditional core HTTP probes (AD-7) — ported from the first 3 entries
# of admin/app.py's _build_http_probes() (admin/app.py:849-856), the ones admin
# always runs regardless of which optional apps are enabled. Full per-app probe
# parity is an explicit non-goal for M3 (§13 OQ-2 resolution: bounded scope now,
# a shared probe-module refactor later).
_CORE_HTTP_PROBES = (
    {"name": "conduwuit (local)", "host": "127.0.0.1:8448",
     "path": "/_matrix/client/versions", "expect": 200, "scheme": "http"},
    {"name": "matrix via caddy", "host": f"chat.{DOMAIN}",
     "path": "/_matrix/client/versions", "expect": 200, "scheme": "loopback"},
    {"name": "admin panel", "host": f"127.0.0.1:{ADMINWEB_PORT}",
     "path": "/login", "expect": 200, "scheme": "http"},
)


def _probe(probe, timeout=5):
    """One HTTP liveness probe. Ported from admin/app.py:1011-1046 (_probe_http)
    — same no-follow-redirect behavior (a 30x to a login page proves the vhost
    + its gate are live; letting urlopen follow it would report the login
    page's 200 instead) and the same {code, latency_ms, ok, error} shape, plus
    the probe's own "name" for a caller that fans out over _CORE_HTTP_PROBES."""
    import urllib.error
    if probe["scheme"] == "loopback":
        # Caddy is plain HTTP on loopback (TLS terminates at the CF edge).
        url = f"http://{CADDY_BIND}:{CADDY_PORT}{probe['path']}"
    else:
        url = f"http://{probe['host']}{probe['path']}"
    req = urllib.request.Request(
        url, method="GET",
        headers={"Host": probe["host"], "User-Agent": "pocket-homeserver-mcp-health/1"})

    class _NoFollow(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *a, **k):
            return None

    opener = urllib.request.build_opener(_NoFollow)
    t0 = time.time()
    try:
        with opener.open(req, timeout=timeout) as r:
            code = r.status
    except urllib.error.HTTPError as ex:
        code = ex.code
    except Exception as ex:
        return {"name": probe["name"], "code": 0,
                "latency_ms": int((time.time() - t0) * 1000),
                "ok": False, "error": str(ex)[:80]}
    latency = int((time.time() - t0) * 1000)
    return {"name": probe["name"], "code": code, "latency_ms": latency,
            "ok": code == probe["expect"], "error": ""}


def _sites_registry():
    """Direct file read of .registry.json (AD-3) — no subprocess, no proot
    round-trip. A missing/corrupt registry degrades to an empty site list
    rather than raising. Ported from admin/app.py:2813-2823
    (_read_sites_registry)."""
    try:
        with open(SITES_REGISTRY) as f:
            return json.load(f)
    except Exception:
        return {"version": 1, "sites": {}}


def _new_job_id():
    """Mint a job id in the SAME <UTC-ts>-<4hex> shape lib-sites.sh's
    new_job_id() does (lib-sites.sh:141) — the identical one-liner the panel's
    own upload route already uses (admin/app.py:3131). Minting in Python (not
    parsing it back out of the script's stdout) means pocket_site_deploy can
    return the job id before the detached script has necessarily even started."""
    return time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + "-" + secrets.token_hex(2)


def _matrix_get(path, cred, timeout=10):
    """Read-only Client-Server API GET on the loopback homeserver, using the
    operator's access credential in the Authorization header only (never logged)."""
    req = urllib.request.Request(
        MATRIX_HS_API + path, method="GET",
        headers={"Authorization": f"Bearer {cred}",
                 "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read() or b"{}")


# ---------- Cloudflare Access JWT validation (ported from admin/app.py) ----------
_CFA_JWKS_TTL  = 3600
_CFA_JWKS      = {"keys": {}, "ts": 0.0}
_CFA_JWKS_LOCK = threading.Lock()
_CFA_LEEWAY    = 60
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
                CF_ACCESS_CERTS_URL, headers={"User-Agent": "pocket-homeserver-mcp/1.0"})
            with urllib.request.urlopen(req, timeout=10) as r:
                doc = json.loads(r.read())
            keys = {}
            for k in doc.get("keys", []):
                if k.get("kty") == "RSA" and k.get("n") and k.get("e"):
                    keys[k.get("kid", "")] = (_cfa_b64uint(k["n"]), _cfa_b64uint(k["e"]))
            if keys:
                _CFA_JWKS["keys"], _CFA_JWKS["ts"] = keys, now
        except Exception as ex:
            _audit("cf-access-jwks-fetch-failed", err=str(ex)[:120])
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
        raise ValueError("issuer mismatch")
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


# ============================================================================
# MCP server
# ============================================================================
mcp = FastMCP(
    "pocket-homeserver",
    instructions=(
        "Observe and operate a pocket-homeserver stack through a small, audited, "
        "tiered tool set. Read tools are always available; mutating (operate) and "
        "break-glass (danger) tools are gated by the operator and may be absent. "
        "Every mutating tool wraps an already-vetted ops script — there is no "
        "free-form command execution."
    ),
    host=MCP_HTTP_BIND,        # HTTP transport binds the loopback Caddy fronts
    port=MCP_HTTP_PORT,
    streamable_http_path="/mcp",
    json_response=True,        # request/response tool set — no SSE in v1 (spec §14)
)


# ---------------------------------------------------------------------------
# READ tier — always registered when ENABLE_MCP=true.
# ---------------------------------------------------------------------------
@mcp.tool()
def pocket_status() -> str:
    """Overall stack snapshot: services, uptime, disk, and memory.

    Wraps scripts/ops/status.sh (read-only) and returns its text output."""
    _audit("pocket_status")
    rc, out = _run_ops("ops/status.sh", timeout=60)
    if rc != 0:
        raise RuntimeError(f"status.sh exited {rc}: {_redact(out)[:400]}")
    return _redact(out)


@mcp.tool()
def pocket_health() -> str:
    """Per-service up/DOWN/DEGRADED liveness for every supervised service, plus
    the 3 unconditional core HTTP probes (AD-7: conduwuit direct, matrix via
    Caddy, the admin panel's own /login — full per-app probe parity is a
    non-goal for M3, §13 OQ-2).

    DEGRADED (a *.degraded crash-loop marker under POCKET_STATE_DIR) takes
    precedence over a momentary pidfile hit — mirrors admin/app.py's
    gather_health() (admin/app.py:1099-1103): "a crash-looping service is NOT
    healthy even if pgrep caught it mid-respawn." Backward-compatible with the
    v0.3.0 shape: the header line and the "UP  "/"DOWN" per-service prefixes
    are unchanged; DEGRADED and the probe section are additive."""
    _audit("pocket_health")
    services = sorted(_supervised_services())
    lines = []
    up = 0
    for name in services:
        alive, pid = _service_live(name)
        marker = _degraded_marker(name)
        if marker:
            status = "DEGRADED"
        elif alive:
            status = "UP  "
            up += 1
        else:
            status = "DOWN"
        suffix = f" (pid {pid})" if pid else ""
        if marker:
            suffix += f" — {marker}"
        lines.append(f"{status} {name}{suffix}")
    header = f"{up}/{len(services)} supervised services up"
    out = header + ("\n" + "\n".join(lines) if lines else "")
    probe_lines = []
    for p in _CORE_HTTP_PROBES:
        r = _probe(p)
        probe_lines.append(
            f"{'OK  ' if r['ok'] else 'FAIL'} {p['name']}"
            + (f" (HTTP {r['code']})" if r["code"] else f" ({r['error']})"))
    out += "\n\ncore HTTP probes:\n" + "\n".join(probe_lines)
    return out


@mcp.tool()
def pocket_list_services() -> str:
    """List the supervised services (from POCKET_STATE_DIR/*.cmd) and whether
    each is currently alive. This is the closed-world set that the operate-tier
    `service` argument is validated against."""
    _audit("pocket_list_services")
    services = sorted(_supervised_services())
    if not services:
        return "no supervised services found"
    rows = []
    for name in services:
        alive, _ = _service_live(name)
        rows.append(f"{name}\t{'up' if alive else 'down'}")
    return "\n".join(rows)


@mcp.tool()
def pocket_logs(log: str, lines: int = LOG_TAIL_DEFAULT) -> str:
    """Tail the last N lines of an ALLOWLISTED log file, with secrets redacted.

    `log` must be one of the allowlisted basenames (see MCP_ALLOWED_LOGS);
    `lines` is bounded. Never names an arbitrary path."""
    _audit("pocket_logs", log=log, lines=lines)
    # Closed-world arg check: basename only, must be in the allowlist.
    base = os.path.basename(log)
    if base not in ALLOWED_LOGS:
        raise ValueError(
            f"log {log!r} not allowlisted; allowed: {sorted(ALLOWED_LOGS)}")
    try:
        n = int(lines)
    except (TypeError, ValueError):
        raise ValueError("lines must be an integer")
    n = max(1, min(n, LOG_TAIL_MAX))
    # Path safety: realpath-contain the resolved file UNDER LOGS (defends against
    # any symlink in the log dir), then tail (no full slurp), then redact.
    logs_root = os.path.realpath(LOGS)
    path = os.path.realpath(os.path.join(LOGS, base))
    if path != logs_root and not path.startswith(logs_root + os.sep):
        raise ValueError("resolved log path escapes the log directory")
    return _redact(_tail_file(path, n))


@mcp.tool()
def pocket_config() -> str:
    """Which optional subsystems are enabled and a handful of non-secret config
    values (domain, transport, ports). NEVER returns secrets."""
    _audit("pocket_config")
    # Allowlist-by-construction: only the keys named here are ever returned — all
    # are ENABLE_* flags or known non-secret scalars. Never add a secret key.
    enabled = sorted(k for k, v in ENABLE.items() if v)
    cfg = {
        "domain": DOMAIN,
        "mcp_transport": MCP_TRANSPORT,
        "mcp_allow_operate": MCP_ALLOW_OPERATE,
        "mcp_allow_danger": MCP_ALLOW_DANGER,
        "enabled_subsystems": enabled,
    }
    return json.dumps(cfg, indent=2)


@mcp.tool()
def pocket_backups_list() -> str:
    """List the backup artifacts present in BACKUP_DIR (name / size / mtime).
    Returns metadata only — never the contents of a backup."""
    _audit("pocket_backups_list")
    rows = []
    try:
        for fn in sorted(os.listdir(BACKUP_DIR)):
            full = os.path.join(BACKUP_DIR, fn)
            if not os.path.isfile(full):
                continue
            st = os.stat(full)
            mtime = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(st.st_mtime))
            rows.append(f"{fn}\t{st.st_size} bytes\t{mtime}")
    except FileNotFoundError:
        return f"no backup directory at {BACKUP_DIR}"
    except Exception as ex:
        raise RuntimeError(f"cannot list backups: {ex}")
    return "\n".join(rows) if rows else "no backups present"


@mcp.tool()
def pocket_matrix_users() -> str:
    """Matrix users sharing a room with the operator (read-only), via the
    standard Client-Server API (joined_rooms + joined_members) using the
    operator's access credential. Returns user identities + counts only — NEVER
    tokens. Mirrors the admin bot's `users` command."""
    _audit("pocket_matrix_users")
    cred = _load_env_file(ADMIN_CRED_FILE).get("ADMIN_TOKEN", "").strip()
    if not cred:
        return ("operator credential unavailable — create the operator account "
                "first (scripts/bootstrap/create-admin.sh, needs ENABLE_BOOTSTRAP), "
                "then retry. This tool never returns any credential.")
    admin_mxid = _env("ADMIN_MXID") or _load_env_file(ADMIN_CRED_FILE).get("ADMIN_MXID", "")
    try:
        rooms = _matrix_get("/_matrix/client/v3/joined_rooms", cred).get("joined_rooms", [])
    except Exception as ex:
        return f"could not query the homeserver: {ex}"
    members = {}
    errors = 0
    for rid in rooms:
        try:
            enc = urllib.parse.quote(rid)
            r = _matrix_get(f"/_matrix/client/v3/rooms/{enc}/joined_members", cred)
            for mxid in (r.get("joined") or {}).keys():
                members[mxid] = members.get(mxid, 0) + 1
        except Exception:
            errors += 1
    if not members:
        return f"no users found (scanned {len(rooms)} rooms, {errors} errors)"
    priv = {ln.strip() for ln in _read_file(PRIVATE_FILE).splitlines()
            if ln.strip() and not ln.startswith("#")}
    out = [f"{len(members)} user(s) sharing a room with the operator "
           f"(scanned {len(rooms)} rooms, {errors} errors):"]
    for mxid in sorted(members):
        tags = []
        if admin_mxid and mxid == admin_mxid:
            tags.append("operator")
        if mxid in priv:
            tags.append("private")
        nrooms = members[mxid]
        suffix = f"  [{', '.join(tags)}]" if tags else ""
        out.append(f"  {mxid}  ({nrooms} shared room{'s' if nrooms != 1 else ''}){suffix}")
    out.append("")
    out.append("Note: shows users sharing ≥1 room with the operator (someone who "
               "joined no shared room won't appear). Identities only — never tokens.")
    return "\n".join(out)


# pocket_honeypot_recent — registered ONLY when ENABLE_HONEYPOT, so tools/list
# never advertises a tool the operator hasn't enabled (spec §8.1).
if ENABLE["honeypot"]:
    @mcp.tool()
    def pocket_honeypot_recent(limit: int = 50) -> str:
        """Recent honeypot events from the JSONL ledger (scanner probes by client
        IP). The IPs are already-public attacker data; no secrets are involved.

        Reads ${POCKET_LOG_DIR}/honeypot.log directly, like the admin panel's
        Security console."""
        _audit("pocket_honeypot_recent", limit=limit)
        try:
            n = int(limit)
        except (TypeError, ValueError):
            raise ValueError("limit must be an integer")
        n = max(1, min(n, 500))
        ledger = os.path.join(LOGS, "honeypot.log")
        content = _read_file(ledger, default="")
        out = []
        for ln in content.splitlines()[-n:]:
            try:
                r = json.loads(ln)
            except Exception:
                continue
            out.append({
                "ts": r.get("ts"),
                "ip": r.get("ip"),
                "host": r.get("host"),
                "hit_rule": r.get("hit_rule"),
                "action": r.get("action"),
            })
        if not out:
            return "no honeypot events recorded"
        return json.dumps(out, indent=2)


@mcp.tool()
def pocket_restore_describe() -> str:
    """Describe the restore PLAN without executing anything (dry run).

    Runs scripts/ops/restore.sh in its default dry-run mode (no --confirm), which
    only PRINTS the steps it WOULD take. This tool NEVER performs a restore — the
    destructive path is intentionally not exposed over MCP (spec §8.4)."""
    _audit("pocket_restore_describe")
    # restore.sh is DRY by default: invoked with no flags it prints the plan and
    # exits without touching anything. We pass NO arguments — there is no code
    # path here that could supply --confirm.
    rc, out = _run_ops("ops/restore.sh", timeout=60)
    out = _redact(out)
    return out if out.strip() else f"restore.sh dry-run produced no output (rc={rc})"


@mcp.tool()
def pocket_doctor() -> str:
    """Read-only preflight/self-test (storage tiers, Termux integration, service
    liveness, DEGRADED markers). Never changes anything. Wraps ops/doctor.sh
    (--strict is deliberately never passed — MCP always gets the advisory,
    always-exit-0 report; the exit code is not useful to an MCP client, the
    TEXT is)."""
    _audit("pocket_doctor")
    rc, out = _run_ops("ops/doctor.sh", timeout=60)
    return _redact(out) if out.strip() else f"doctor.sh produced no output (rc={rc})"


_METRICS_MAX_SAMPLES = 500   # fixed cap (§13 OQ-4 resolution) — bound a client
                             # from asking for the whole multi-day ring.

if ENABLE["metrics"]:

    @mcp.tool()
    def pocket_metrics(samples: int = 60) -> str:
        """Recent device/stack metrics (cpu/mem/load/disk/temp/battery/degraded
        count) sampled by ops/metrics-sampler.py. Returns the last `samples`
        JSONL records (bounded) plus a min/avg/max/current summary per field —
        the same numbers admin/app.py's /metrics page cards show
        (admin/app.py:3513-3530), as structured JSON instead of HTML."""
        _audit("pocket_metrics", samples=samples)
        try:
            n = int(samples)
        except (TypeError, ValueError):
            raise ValueError("samples must be an integer")
        n = max(1, min(n, _METRICS_MAX_SAMPLES))
        try:
            with open(METRICS_LOG) as f:
                lines = f.readlines()[-n:]
        except FileNotFoundError:
            return json.dumps({"samples": [], "note": "no metrics recorded yet"}, indent=2)
        recs = []
        for ln in lines:
            try:
                recs.append(json.loads(ln))
            except Exception:
                continue
        fields = ("cpu", "mem", "swap", "l1", "disk", "temp", "batt", "deg")
        summary = {}
        for field in fields:
            vals = [r[field] for r in recs if isinstance(r.get(field), (int, float))]
            if vals:
                summary[field] = {"current": vals[-1], "min": min(vals),
                                   "avg": round(sum(vals) / len(vals), 2), "max": max(vals)}
        return json.dumps({"summary": summary, "sample_count": len(recs),
                            "samples": recs}, indent=2)


@mcp.tool()
def pocket_problems() -> str:
    """Everything currently wrong, and nothing else: crash-looping (DEGRADED)
    services, DOWN services, and failing HTTP probes. Empty result means "all
    green" — mirrors admin/app.py's /problems page (admin/app.py:3626-3686) as
    structured JSON instead of HTML cards."""
    _audit("pocket_problems")
    degraded, down = [], []
    for name in sorted(_supervised_services()):
        marker = _degraded_marker(name)
        if marker:
            degraded.append({"service": name, "detail": marker})
            continue
        alive, _pid = _service_live(name)
        if not alive:
            down.append(name)
    probe_fail = [p for p in (_probe(p) for p in _CORE_HTTP_PROBES) if not p["ok"]]
    if not (degraded or down or probe_fail):
        return json.dumps({"ok": True, "message": "no problems"}, indent=2)
    return json.dumps({"ok": False, "degraded": degraded, "down": down,
                        "failing_probes": probe_fail}, indent=2)


@mcp.tool()
def pocket_audit_recent(limit: int = 50) -> str:
    """Recent audit-log entries from the SAME admin-audit.log both the panel and
    this server append to (_audit(), above) — surfaces BOTH panel-sourced and
    MCP-sourced actions, since it's one shared trail by design. Panel-sourced
    entries carry the operator's own client ip/user-agent (admin/app.py:408-421)
    — that's the operator's own metadata, not a third party's, so it is not
    redacted, only capped."""
    _audit("pocket_audit_recent", limit=limit)
    try:
        n = int(limit)
    except (TypeError, ValueError):
        raise ValueError("limit must be an integer")
    n = max(1, min(n, 500))
    lines = _read_file(AUDIT_LOG, default="").splitlines()[-n:]
    out = []
    for ln in lines:
        try:
            rec = json.loads(ln)
        except Exception:
            continue
        for k, v in list(rec.items()):
            if isinstance(v, str):
                rec[k] = _redact(v)
        out.append(rec)
    return json.dumps(out, indent=2) if out else "no audit entries recorded"


# pocket_sites_list / pocket_site_releases / pocket_site_status — registered
# ONLY when ENABLE["sites"], same pattern as pocket_honeypot_recent above.
# Pure reads: straight to .registry.json / the job state file, never a
# subprocess (AD-3).
if ENABLE["sites"]:

    @mcp.tool()
    def pocket_sites_list() -> str:
        """List every deployed Pocket Pages site with its active release, release
        count, size, and URL. Reads .registry.json directly (AD-3) — the same
        derived-state file the panel's Sites page and `site-list.sh --json` both
        read; a missing/corrupt registry degrades to an empty list rather than
        raising."""
        _audit("pocket_sites_list")
        try:
            with open(SITES_REGISTRY) as f:
                raw = f.read()
            json.loads(raw)  # validate before returning malformed JSON to a client
            return raw
        except Exception:
            return json.dumps({"version": 1, "sites": {}}, indent=2)

    @mcp.tool()
    def pocket_site_releases(site: str) -> str:
        """Release history + metadata for ONE site (created/updated/active_release/
        releases/build/bytes/url), straight from the registry. `site` must be a
        currently-registered site name — closed-world, like the `service` argument
        of pocket_restart_service."""
        _audit("pocket_site_releases", site=site)
        reg = _sites_registry()
        entry = reg.get("sites", {}).get(site)
        if entry is None:
            raise ValueError(
                f"no such site {site!r}; known sites: {sorted(reg.get('sites', {}))}")
        return json.dumps(entry, indent=2)

    @mcp.tool()
    def pocket_site_status(job_id: str) -> str:
        """Poll a site job's state (deploy/rollback/delete). Returns the job
        record (job/kind/site/state/release/started/ended/error) plus a short
        redacted tail of the job's own log, when one exists.

        A job id that doesn't have a state file YET (the brief window between
        pocket_site_deploy returning and the detached process actually calling
        job_start()) reports state="running" rather than raising — mirrors the
        panel's own /sites/job/<id> behavior exactly (admin/app.py:3244-3248)."""
        jid = (job_id or "").strip()
        if not _SITE_JOB_RE.fullmatch(jid):
            raise ValueError(f"invalid job id: {job_id!r}")
        _audit("pocket_site_status", job=jid)
        state_path = os.path.join(STATE, f"site-job-{jid}.json")
        try:
            with open(state_path) as f:
                doc = json.load(f)
        except Exception:
            doc = {"job": jid, "state": "running"}
        log_path = os.path.join(LOGS, f"site-deploy-{jid}.log")
        tail = _tail_file(log_path, 20)
        if not tail.startswith("(no such log") and not tail.startswith("(cannot read log"):
            doc["log_tail"] = _redact(tail)
        return json.dumps(doc, indent=2)


# User-target validation — ported verbatim from admin/app.py:3695-3696, shared
# by both the OPERATE-tier user tools (§7.8) and the DANGER-tier
# pocket_user_deactivate (§7.9), so it is defined unconditionally here rather
# than nested inside either tier's `if` block (same placement pattern as
# _require_confirm below, for the DANGER tier).
_VALID_LOCALPART = re.compile(r"^[a-z0-9][a-z0-9._=-]{0,63}$")
_VALID_MXID = re.compile(r"^@[a-z0-9._=/+-]+:[A-Za-z0-9.:-]+$")


def _valid_user_target(val, allow_mxid):
    v = (val or "").strip()
    if _VALID_LOCALPART.fullmatch(v):
        return v
    if allow_mxid and _VALID_MXID.fullmatch(v):
        return v
    raise ValueError(f"invalid user {val!r} (want a localpart, or @user:server where noted)")


# ---------------------------------------------------------------------------
# OPERATE tier — registered ONLY when MCP_ALLOW_OPERATE=true.
# ---------------------------------------------------------------------------
if MCP_ALLOW_OPERATE:

    @mcp.tool()
    def pocket_restart_service(service: str) -> str:
        """Restart ONE supervised service (re-supervise it from its recorded
        .cmd argv). `service` must be a currently-supervised service name."""
        _audit("pocket_restart_service", service=service)
        svc = (service or "").strip()
        supervised = _supervised_services()
        # Closed-world: the only accepted values are the currently-supervised
        # services, so no caller input reaches ops/restart.sh as a free token.
        if svc not in supervised:
            raise ValueError(
                f"service {service!r} is not a currently-supervised service; "
                f"choose one of: {sorted(supervised)}")
        rc, out = _run_ops("ops/restart.sh", svc, timeout=120)
        if rc != 0:
            raise RuntimeError(f"restart.sh exited {rc}: {_redact(out)[-400:]}")
        return _redact(out) or f"restart issued for {svc}"

    @mcp.tool()
    def pocket_backup_db() -> str:
        """Back up the Matrix database (stop-matrix → tar → restart). Returns the
        artifact metadata from scripts/ops/backup-db.sh."""
        _audit("pocket_backup_db")
        rc, out = _run_ops("ops/backup-db.sh", timeout=OPS_TIMEOUT_DEFAULT)
        if rc != 0:
            raise RuntimeError(f"backup-db.sh exited {rc}: {_redact(out)[-400:]}")
        return _redact(out)

    @mcp.tool()
    def pocket_backup_all() -> str:
        """Full userland-rootfs backup. Returns the artifact metadata from
        scripts/ops/backup-all.sh. This can take a while."""
        _audit("pocket_backup_all")
        rc, out = _run_ops("ops/backup-all.sh", timeout=OPS_TIMEOUT_DEFAULT)
        if rc != 0:
            raise RuntimeError(f"backup-all.sh exited {rc}: {_redact(out)[-400:]}")
        return _redact(out)

    @mcp.tool()
    def pocket_mint_invite_token(count: int = 1) -> str:
        """Mint `count` one-time Matrix invite token(s). The token's purpose is
        to be shared, so it IS returned (unlike rotation tools). Wraps
        scripts/bootstrap/mint-invite-token.sh <N>."""
        _audit("pocket_mint_invite_token", count=count)
        try:
            n = int(count)
        except (TypeError, ValueError):
            raise ValueError("count must be a positive integer")
        if n < 1 or n > 50:
            raise ValueError("count must be between 1 and 50")
        rc, out = _run_ops("bootstrap/mint-invite-token.sh", n, timeout=120)
        if rc != 0:
            raise RuntimeError(f"mint-invite-token.sh exited {rc}: {_redact(out)[-400:]}")
        return out

    @mcp.tool()
    def pocket_rotate_registration_token() -> str:
        """Rotate the Matrix registration token (re-opens token-gated signup with
        a fresh token; the OLD token stops working immediately).

        Returns METADATA ONLY — never the token value (spec §5, §10)."""
        _audit("pocket_rotate_registration_token")
        # The backing script's `-q` flag suppresses its one-time token print
        # entirely; we additionally never return its stdout, so the new token
        # cannot reach the client. The token is persisted 0600 by the script.
        rc, out = _run_ops("ops/rotate-registration-token.sh", "-q", timeout=180)
        if rc != 0:
            raise RuntimeError(
                f"rotate-registration-token.sh exited {rc}: {_redact(out)[-300:]}")
        return ("Registration token rotated. The new token was written (0600) to "
                f"{os.path.join(SECRETS, 'registration-token.txt')} and is "
                "intentionally NOT returned over MCP — reveal it from the admin "
                "panel or that file. The OLD token stopped working immediately.")

    @mcp.tool()
    def pocket_restart_stack() -> str:
        """Restart matrix + Caddy + cloudflared in order (apps untouched). Brief
        (tens of seconds) ingress outage while the tunnel reconnects; fully
        reversible. Wraps start-stack.sh --restart — the SAME script the panel's
        danger-zone 'restart stack' card runs, but classified OPERATE here
        rather than DANGER: its impact (bounded, reversible, apps untouched) is
        the whole-stack analogue of the already-OPERATE pocket_restart_service,
        not of panic-soft/hard's blast radius. The panel's own two-page confirm
        is a touchscreen fat-finger guard, not a statement about severity."""
        _audit("pocket_restart_stack")
        rc, out = _run_ops("start-stack.sh", "--restart", timeout=120)
        if rc != 0:
            raise RuntimeError(f"start-stack.sh --restart exited {rc}: {_redact(out)[-400:]}")
        return _redact(out) or "stack restart issued"

    @mcp.tool()
    def pocket_rotate_backups() -> str:
        """Prune backup snapshots to the configured retention (BACKUP_KEEP_DB /
        BACKUP_KEEP_ROOTFS). Safe to run any time — a no-op when nothing is due.
        Wraps ops/rotate-backups.sh."""
        _audit("pocket_rotate_backups")
        rc, out = _run_ops("ops/rotate-backups.sh", timeout=120)
        if rc != 0:
            raise RuntimeError(f"rotate-backups.sh exited {rc}: {_redact(out)[-400:]}")
        return _redact(out)

    if ENABLE["offsite"]:

        @mcp.tool()
        def pocket_offsite_push() -> str:
            """Push already-ENCRYPTED backups to the configured S3-compatible
            bucket. Self-gated on ENABLE_OFFSITE_BACKUP and refuses (fail-closed)
            if backups aren't age-encrypted (scripts/ops/offsite-push.sh:46-49) —
            the S3 secret never touches this tool's return value. Synchronous
            (AD-2), bounded by OPS_TIMEOUT_DEFAULT."""
            _audit("pocket_offsite_push")
            rc, out = _run_ops("ops/offsite-push.sh", timeout=OPS_TIMEOUT_DEFAULT)
            if rc != 0:
                raise RuntimeError(f"offsite-push.sh exited {rc}: {_redact(out)[-400:]}")
            return _redact(out)

    if ENABLE["user-admin"]:

        @mcp.tool()
        def pocket_user_create(localpart: str) -> str:
            """Create a local Matrix user. The server GENERATES the password and
            returns it in its reply — the tool's return value therefore CAN
            contain a fresh credential (unlike every other tool here); it also
            lands in the admin command room's history (ops/user-create.sh:8,
            docs/USERS.md) regardless of how it was triggered."""
            u = _valid_user_target(localpart, allow_mxid=False)
            _audit("pocket_user_create", localpart=u)
            rc, out = _run_ops("ops/user-create.sh", u, timeout=90)
            if rc != 0:
                raise RuntimeError(f"user-create.sh exited {rc}: {_redact(out)[-400:]}")
            return out   # NOT _redact()'d — see the docstring; the generated password IS the payload

        @mcp.tool()
        def pocket_user_reset_password(localpart: str) -> str:
            """Reset a local user's password; the NEW password is generated and
            returned (same caveat as pocket_user_create)."""
            u = _valid_user_target(localpart, allow_mxid=False)
            _audit("pocket_user_reset_password", localpart=u)
            rc, out = _run_ops("ops/user-reset-password.sh", u, timeout=90)
            if rc != 0:
                raise RuntimeError(f"user-reset-password.sh exited {rc}: {_redact(out)[-400:]}")
            return out

        @mcp.tool()
        def pocket_user_suspend(user: str) -> str:
            """Suspend an account (read-only). Reversible with pocket_user_unsuspend.
            `user` is a localpart or a full @user:server MXID."""
            u = _valid_user_target(user, allow_mxid=True)
            _audit("pocket_user_suspend", user=u)
            rc, out = _run_ops("ops/user-suspend.sh", u, timeout=90)
            if rc != 0:
                raise RuntimeError(f"user-suspend.sh exited {rc}: {_redact(out)[-400:]}")
            return _redact(out) or f"suspended {u}"

        @mcp.tool()
        def pocket_user_unsuspend(user: str) -> str:
            """Lift a suspension."""
            u = _valid_user_target(user, allow_mxid=True)
            _audit("pocket_user_unsuspend", user=u)
            rc, out = _run_ops("ops/user-unsuspend.sh", u, timeout=90)
            if rc != 0:
                raise RuntimeError(f"user-unsuspend.sh exited {rc}: {_redact(out)[-400:]}")
            return _redact(out) or f"unsuspended {u}"

    if ENABLE["sites"]:

        @mcp.tool()
        def pocket_site_deploy(site: str, staged_path: str, build: str = "none") -> str:
            """Deploy an ALREADY-STAGED artifact (a directory or a .zip placed under
            SITES_ROOT/.staging by some other channel — scp/rsync, or the panel's own
            upload) as a new release of `site`. Does NOT accept file content as an
            argument (AD-1) — this tool only points the pipeline at a path.

            Returns immediately with a job id; the deploy runs DETACHED (it can take
            up to SITES_BUILD_TIMEOUT for the hugo/node build tiers) — poll progress
            with pocket_site_status(job_id)."""
            name = (site or "").strip()
            if not SITE_SUB_RE.fullmatch(name) or name in SITE_RESERVED:
                raise ValueError(f"invalid or reserved site name: {site!r}")
            if build not in ("none", "hugo", "node"):
                raise ValueError("build must be one of: none, hugo, node")
            staging_root = os.path.realpath(SITES_STAGING)
            real_path = os.path.realpath(staged_path)
            if real_path != staging_root and not real_path.startswith(staging_root + os.sep):
                raise ValueError(
                    f"staged_path must resolve inside {SITES_STAGING} "
                    f"(stage the artifact there first — MCP never carries file content, AD-1)")
            if not os.path.exists(real_path):
                raise ValueError(f"staged_path does not exist: {staged_path!r}")
            job_id = _new_job_id()
            _audit("pocket_site_deploy", site=name, staged_path=staged_path, build=build, job=job_id)
            ok = _run_ops_detached("sites/site-deploy.sh", name, real_path,
                                    "--build", build, "--job", job_id)
            if not ok:
                raise RuntimeError("could not launch the deploy — see " +
                                    os.path.join(LOGS, _MCP_ASYNC_LOG))
            return (f"deploy started: site={name} build={build} job={job_id} — "
                    f"poll pocket_site_status({job_id!r}) for progress")

        @mcp.tool()
        def pocket_site_rollback(site: str, release: str = "") -> str:
            """Instant pointer-swap rollback for `site` — no rebuild, no copy.
            `release` is optional; empty means "the release immediately before
            the current one" (site-rollback.sh's own default,
            scripts/sites/site-rollback.sh:44-50). Synchronous — a rollback is a
            single rename(2), never worth a detached job."""
            name = (site or "").strip()
            if not SITE_SUB_RE.fullmatch(name):
                raise ValueError(f"invalid site name: {site!r}")
            reg = _sites_registry()
            entry = reg.get("sites", {}).get(name)
            if entry is None:
                raise ValueError(f"no such site {name!r}")
            rel = (release or "").strip()
            if rel and rel not in entry.get("releases", []):
                raise ValueError(f"unknown release {rel!r} for site {name!r}; "
                                  f"known: {entry.get('releases', [])}")
            _audit("pocket_site_rollback", site=name, release=rel or "previous")
            args = [name] + ([rel] if rel else [])
            rc, out = _run_ops("sites/site-rollback.sh", *args, timeout=60)
            if rc != 0:
                raise RuntimeError(f"site-rollback.sh exited {rc}: {_redact(out)[-400:]}")
            return _redact(out) or f"rolled back {name}"


# ---------------------------------------------------------------------------
# DANGER tier — registered ONLY when MCP_ALLOW_DANGER=true, AND each call
# requires a typed confirmation argument (mirrors the admin-panel danger zone).
# ---------------------------------------------------------------------------
def _require_confirm(confirm, phrase):
    """Fail closed unless `confirm` exactly equals `phrase` (constant-time)."""
    if not hmac.compare_digest((confirm or ""), phrase):
        raise ValueError(
            f'refused: pass confirm="{phrase}" exactly to run this break-glass action')


if MCP_ALLOW_DANGER:

    @mcp.tool()
    def pocket_panic_soft(confirm: str) -> str:
        """BREAK-GLASS: drop the Cloudflare tunnel — the server goes dark but is
        recoverable. Requires `confirm` to exactly equal "pocket_panic_soft"."""
        _require_confirm(confirm, "pocket_panic_soft")   # raises before any action
        _audit("pocket_panic_soft", confirmed=True)      # never the raw confirm value
        rc, out = _run_ops("ops/panic-soft.sh", timeout=120)
        if rc != 0:
            raise RuntimeError(f"panic-soft.sh exited {rc}: {_redact(out)[-400:]}")
        return _redact(out) or "panic-soft executed (Cloudflare tunnel dropped)"

    @mcp.tool()
    def pocket_panic_hard(confirm: str) -> str:
        """BREAK-GLASS: stop everything except the admin panel. Requires `confirm`
        to exactly equal "pocket_panic_hard"."""
        _require_confirm(confirm, "pocket_panic_hard")   # raises before any action
        _audit("pocket_panic_hard", confirmed=True)      # never the raw confirm value
        rc, out = _run_ops("ops/panic-hard.sh", timeout=120)
        if rc != 0:
            raise RuntimeError(f"panic-hard.sh exited {rc}: {_redact(out)[-400:]}")
        return _redact(out) or "panic-hard executed (all services stopped except the admin panel)"

    if ENABLE["user-admin"]:

        @mcp.tool()
        def pocket_user_deactivate(user: str, confirm: str) -> str:
            """BREAK-GLASS: deactivate (close) an account — effectively
            irreversible; re-enabling means creating the account again
            (ops/user-deactivate.sh:6-8). Requires `confirm` to exactly equal the
            `user` value passed to THIS call (AD-4) — a direct port of the panel's
            shipped retype-the-exact-id behavior (admin/app.py:3703, :3816-3820),
            not a new design for this tool."""
            u = _valid_user_target(user, allow_mxid=True)
            _require_confirm(confirm, user)   # compares against the RAW argument,
                                               # exactly like admin/app.py:3817
                                               # compares against `val`, pre-expansion
            _audit("pocket_user_deactivate", user=u, confirmed=True)
            rc, out = _run_ops("ops/user-deactivate.sh", u, timeout=90)
            if rc != 0:
                raise RuntimeError(f"user-deactivate.sh exited {rc}: {_redact(out)[-400:]}")
            return _redact(out) or f"deactivated {u}"

    if ENABLE["sites"]:

        @mcp.tool()
        def pocket_site_delete(site: str, confirm: str) -> str:
            """BREAK-GLASS: permanently delete a site and ALL its release history —
            not just the live release. Not reversible. Requires `confirm` to
            exactly equal `site` (AD-4) — the site name itself, not a fixed phrase,
            because this action takes a target and a fixed phrase would authorize
            deleting ANY site."""
            name = (site or "").strip()
            if not SITE_SUB_RE.fullmatch(name):
                raise ValueError(f"invalid site name: {site!r}")
            reg = _sites_registry()
            if name not in reg.get("sites", {}):
                raise ValueError(f"no such site {name!r} — nothing to delete")
            _require_confirm(confirm, name)               # raises before any action
            _audit("pocket_site_delete", site=name, confirmed=True)
            rc, out = _run_ops("sites/site-delete.sh", name, "--yes", timeout=60)
            if rc != 0:
                raise RuntimeError(f"site-delete.sh exited {rc}: {_redact(out)[-400:]}")
            return _redact(out) or f"deleted {name}"


# ---------------------------------------------------------------------------
# Resources (read-only, addressable).
# ---------------------------------------------------------------------------
@mcp.resource("pocket://status")
def status_resource() -> str:
    """The stack status snapshot (same as pocket_status), as a resource."""
    rc, out = _run_ops("ops/status.sh", timeout=60)
    return _redact(out) if out.strip() else f"status.sh produced no output (rc={rc})"


@mcp.resource("pocket://config")
def config_resource() -> str:
    """Enabled subsystems + non-secret config (same as pocket_config)."""
    enabled = sorted(k for k, v in ENABLE.items() if v)
    return json.dumps({
        "domain": DOMAIN,
        "mcp_transport": MCP_TRANSPORT,
        "enabled_subsystems": enabled,
    }, indent=2)


@mcp.resource("pocket://docs/{name}")
def docs_resource(name: str) -> str:
    """Expose this repo's docs/<name>.md so a client can pull a runbook
    (e.g. pocket://docs/BACKUPS). `name` is allowlisted to the actual docs/*.md
    basenames — no path traversal, no arbitrary file read."""
    base = os.path.basename(name)
    if base.endswith(".md"):
        base = base[:-len(".md")]
    docs_dir = os.path.realpath(os.path.join(POCKET_ROOT, "docs"))
    candidate = os.path.realpath(os.path.join(docs_dir, base + ".md"))
    # Path containment: the resolved file must live under docs/ (defends against
    # any symlink, on top of the basename strip which blocks the obvious traversal).
    if not candidate.startswith(docs_dir + os.sep):
        raise ValueError(f"refusing to read outside docs/: {name!r}")
    try:
        available = sorted(f[:-3] for f in os.listdir(docs_dir) if f.endswith(".md"))
    except Exception:
        available = []
    if base not in available:
        raise ValueError(f"unknown doc {name!r}; available: {available}")
    return _read_file(candidate, default=f"(docs/{base}.md is empty)")


@mcp.resource("pocket://sites")
def sites_resource() -> str:
    """The full site registry (same as pocket_sites_list), as a resource."""
    if not ENABLE["sites"]:
        return json.dumps({"version": 1, "sites": {}, "note": "sites module disabled"})
    try:
        with open(SITES_REGISTRY) as f:
            return f.read()
    except Exception:
        return json.dumps({"version": 1, "sites": {}})


@mcp.resource("pocket://metrics")
def metrics_resource() -> str:
    """The last 60 metric samples' summary (same shape as pocket_metrics(60)),
    as a resource — for a client that wants a cheap ambient status check
    without an explicit tool call. The gate check happens BEFORE the
    pocket_metrics(60) reference below is ever reached, so there is no
    NameError risk even though pocket_metrics only exists as a module name
    when ENABLE["metrics"] is true (verified: by the time any resource/tool is
    actually invoked, the whole module has already finished one top-to-bottom
    exec, so if this gate is true, the `if ENABLE["metrics"]:` block that
    defines pocket_metrics already ran)."""
    if not ENABLE["metrics"]:
        return json.dumps({"note": "metrics module disabled"})
    return pocket_metrics(60)   # reuses the tool function directly — same logic, no duplication


# ---------------------------------------------------------------------------
# Prompts (guided scaffolds — spec §9).
# ---------------------------------------------------------------------------
@mcp.prompt()
def triage(service: str) -> str:
    """Walk the model through diagnosing one service."""
    return (
        f"Diagnose the '{service}' service on this pocket-homeserver.\n"
        f"1. Call pocket_health and confirm whether '{service}' is up.\n"
        f"2. Call pocket_list_services to confirm it is supervised.\n"
        f"3. Tail its log with pocket_logs (pick the matching allowlisted log).\n"
        f"4. Summarize the likely cause and, if a restart is warranted and the "
        f"operate tier is enabled, propose pocket_restart_service('{service}') — "
        f"but ask the operator before mutating anything."
    )


@mcp.prompt(title="Health report")
def health_report() -> str:
    """Summarize overall stack health."""
    return (
        "Produce a concise health report for this pocket-homeserver:\n"
        "1. Call pocket_status for the overall snapshot (uptime, disk, memory).\n"
        "2. Call pocket_health for per-service liveness.\n"
        "3. List any services that are DOWN and what they affect.\n"
        "4. Flag anything notable (low disk, high memory) and suggest next steps. "
        "Do not run any mutating tool without explicit operator approval."
    )


@mcp.prompt(title="Deploy report")
def deploy_report(site: str) -> str:
    """Walk the model through summarizing one site's deploy state."""
    return (
        f"Produce a concise deploy report for the Pocket Pages site '{site}' on "
        f"this pocket-homeserver:\n"
        f"1. Call pocket_site_releases('{site}') for its current state (active "
        f"release, build tier, size, URL, release count).\n"
        f"2. If the operator mentions an in-flight or recent job id, call "
        f"pocket_site_status(job_id) and report its state/error.\n"
        f"3. Summarize: is the site live, when was it last deployed, how many "
        f"releases of history exist, and is there anything that looks stuck or "
        f"failed.\n"
        f"4. Do not call pocket_site_deploy, pocket_site_rollback, or "
        f"pocket_site_delete without explicit operator approval — this prompt is "
        f"for reporting, not for acting."
    )


# ---------------------------------------------------------------------------
# HTTP transport — fail-closed pure-ASGI auth gate.
# ---------------------------------------------------------------------------
class _RateLimiter:
    """Tiny per-key sliding-window limiter (the gateway's limiter pattern). `spec`
    looks like "60/min"; defaults to 60/min on any parse problem."""
    def __init__(self, spec):
        self.max, self.window = 60, 60
        try:
            n, per = spec.split("/", 1)
            self.max = max(1, int(n.strip()))
            self.window = {"s": 1, "sec": 1, "second": 1,
                           "m": 60, "min": 60, "minute": 60,
                           "h": 3600, "hour": 3600}.get(per.strip().lower(), 60)
        except Exception:
            pass
        self._hits = {}
        self._lock = threading.Lock()

    def ok(self, key):
        now = time.time()
        with self._lock:
            # Bound memory under key churn (we key on a client-influenced IP):
            # drop buckets whose newest hit has aged out of the window.
            if len(self._hits) > 4096:
                stale = now - self.window
                self._hits = {k: v for k, v in self._hits.items()
                              if v and v[-1] >= stale}
            q = self._hits.setdefault(key, [])
            cutoff = now - self.window
            while q and q[0] < cutoff:
                q.pop(0)
            if len(q) >= self.max:
                return False
            q.append(now)
            return True


_RATE = _RateLimiter(_env("MCP_RATE_LIMIT", "60/min"))


class _AuthGate:
    """Pure-ASGI, fail-closed auth gate for the HTTP transport. On success the
    wrapped app is called UNCHANGED (so any streaming is not buffered); otherwise
    a short JSON error is returned. Order: /healthz exempt → rate-limit → bearer
    (gate 3) → Cloudflare-Access RS256 JWT (gate 2, when configured). The Caddy
    @no_cf_jwt 403 presence gate sits in front of this at the edge."""
    def __init__(self, app, bearer):
        self.app = app
        self.bearer = bearer

    async def __call__(self, scope, receive, send):
        if scope.get("type") != "http":
            return await self.app(scope, receive, send)
        if scope.get("path", "") == "/healthz":
            return await self._respond(send, 200, b"ok", b"text/plain; charset=utf-8")
        headers = {k.decode("latin1").lower(): v.decode("latin1")
                   for k, v in scope.get("headers", [])}
        client = scope.get("client") or ("?", 0)
        peer = client[0] if isinstance(client, (list, tuple)) and client else "?"
        # Behind Caddy every TCP peer is loopback, so keying the limiter on the peer
        # would be a single global bucket. Caddy sets X-Real-IP to its
        # trusted_proxies-validated client_ip, so prefer that for a per-caller cap;
        # fall back to the peer if the header is absent (e.g. a direct local call).
        rl_key = headers.get("x-real-ip") or headers.get("cf-connecting-ip") or peer
        if not _RATE.ok(rl_key):
            return await self._deny(send, 429, "rate limited")
        # Gate 3 — bearer credential (constant-time compare).
        auth = headers.get("authorization", "")
        presented = auth[7:].strip() if auth[:7].lower() == "bearer " else ""
        if not (self.bearer and presented and hmac.compare_digest(presented, self.bearer)):
            return await self._deny(send, 401, "unauthorized")
        # Gate 2 — in-process Cloudflare Access JWT validation (when configured).
        caller = "bearer"
        if CF_ACCESS_TEAM_DOMAIN:
            jwt = headers.get("cf-access-jwt-assertion", "")
            try:
                claims = _cfa_validate(jwt)
            except Exception:
                return await self._deny(send, 403, "forbidden")
            caller = claims.get("email") or claims.get("sub") or "cf-access"
        _CALLER.set(caller)
        return await self.app(scope, receive, send)

    async def _respond(self, send, code, body, content_type):
        await send({"type": "http.response.start", "status": code,
                    "headers": [(b"content-type", content_type),
                                (b"content-length", str(len(body)).encode())]})
        await send({"type": "http.response.body", "body": body})

    async def _deny(self, send, code, msg):
        body = json.dumps({"error": msg}).encode()
        await self._respond(send, code, body, b"application/json")


def _load_bearer():
    return _read_file(MCP_BEARER_TOKEN_FILE).strip()


def _build_http_app():
    """Build the FastMCP Streamable-HTTP ASGI app wrapped in the fail-closed auth
    gate. The gate is the in-process security boundary for the remote transport."""
    app = mcp.streamable_http_app()
    bearer = _load_bearer()
    if not bearer:
        print("[pocket-mcp] FATAL: the HTTP transport requires a bearer credential "
              f"at {MCP_BEARER_TOKEN_FILE}; run scripts/steps/87-install-mcp.sh.",
              file=sys.stderr)
        sys.exit(1)
    return _AuthGate(app, bearer)


def _serve_http():
    """Serve the auth-wrapped ASGI app with uvicorn on the loopback Caddy fronts."""
    import uvicorn
    # Fail-closed: the MCP control surface must never bind a non-loopback address
    # (proot shares the host net ns, so 0.0.0.0 would expose tool-execution on the
    # phone's real Wi-Fi/cell interfaces). Refuse rather than silently LAN-expose.
    if MCP_HTTP_BIND not in ("127.0.0.1", "::1", "localhost"):
        sys.exit(f"[pocket-mcp] refusing to bind the HTTP transport on a non-loopback "
                 f"address ({MCP_HTTP_BIND!r}); set MCP_HTTP_BIND=127.0.0.1 "
                 f"(Caddy fronts the public edge regardless of CADDY_BIND).")
    app = _build_http_app()
    print(f"[pocket-mcp] HTTP transport on {MCP_HTTP_BIND}:{MCP_HTTP_PORT} "
          f"(mcp.{DOMAIN} via Caddy; fail-closed: bearer + Cloudflare Access)",
          file=sys.stderr)
    uvicorn.run(app, host=MCP_HTTP_BIND, port=MCP_HTTP_PORT, log_level="info")


# ---------------------------------------------------------------------------
# Entry point — transport selected by MCP_TRANSPORT (stdio default).
# ---------------------------------------------------------------------------
def main():
    if not ENABLE_MCP:
        # Fail loud on stderr (never stdout — that is the protocol channel).
        print("[pocket-mcp] ENABLE_MCP is not true; refusing to start. Set "
              "ENABLE_MCP=true in .env (see docs/MCP.md).", file=sys.stderr)
        sys.exit(1)
    if not POCKET_ROOT:
        print("[pocket-mcp] POCKET_ROOT is empty; run via the installed launcher "
              "(scripts/steps/87-install-mcp.sh) which sources .env.", file=sys.stderr)
        sys.exit(1)

    transport = MCP_TRANSPORT
    if transport == "stdio":
        # The SDK reads/writes newline-delimited JSON-RPC on stdin/stdout; all our
        # diagnostics go to stderr. The SSH/CF-Access channel is the authentication;
        # the caller identity for the audit log is "ssh" (the _CALLER default).
        _CALLER.set("ssh")
        print("[pocket-mcp] stdio transport (auth = the SSH channel)", file=sys.stderr)
        mcp.run("stdio")
    elif transport in ("http", "both"):
        # stdio and http are deployed as SEPARATE processes: the installer's
        # `pocket-mcp` launcher forces MCP_TRANSPORT=stdio (spawned per client over
        # SSH), and the supervised http launcher forces MCP_TRANSPORT=http. So a
        # single process owns exactly one transport; "both" here serves the HTTP
        # listener (the supervised, long-running one).
        _serve_http()
    else:
        print(f"[pocket-mcp] unknown MCP_TRANSPORT {transport!r} "
              "(want: stdio | http | both)", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
