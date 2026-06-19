#!/usr/bin/env python3
"""Honeypot / scanner-detection watcher — detect + ledger (+ optional alert/block).

Defensive only. Tails Caddy's JSON access log (which carries the REAL client IP
via the Cloudflare `Cf-Connecting-IP` header — see the Caddy integration note in
docs/HONEYPOT.md) and flags requests to high-confidence scanner paths that NONE of
the real apps in this stack ever serve (`/.env`, `/.git/config`, `/wp-login.php`,
`/phpmyadmin`, …). On a hit it:

  1. appends a JSONL line to the audit ledger  ${POCKET_LOG_DIR}/honeypot.log  (record of record)
  2. (OPTIONAL) posts a Matrix alert — ONLY if the operator created
     ${DATA_DIR}/secrets/honeypot-alert.env with HP_MATRIX_HS + HP_MATRIX_TOKEN +
     HP_MATRIX_ROOM; absent any of those, alerting is silently skipped.
  3. (OPTIONAL, mode != alert) adds the source IP to a Cloudflare IP Access Rule —
     ONLY when triple-gated (see below).

Design notes — see docs/HONEYPOT.md:
  * ZERO Caddy attack surface: we only READ an existing access log. This process
    makes no inbound listener. The internet-facing edge is untouched.
  * The only outbound calls are the OPTIONAL Matrix loopback alert and (block
    tiers) the Cloudflare API. No eval, no shell-out with request data, no SSRF.
  * Tiered response is gated behind ${DATA_DIR}/secrets/honeypot.mode:
        alert      (default) — ledger only, plus the OPTIONAL Matrix alert
        challenge  — + CF Managed Challenge          [needs cf-honeypot.env + opt-in]
        block      — + add IP to CF block rule        [needs cf-honeypot.env + opt-in]
    The blocking tiers are TRIPLE-GATED and OFF by default; see read_mode().
  * Safelist (loopback + Cloudflare ranges built in + an operator file) is checked
    before any action — never alert/block on our own egress or the operator's IPs.

Modes:
  (no args)        live tail — supervised; resumes from persisted offsets (EOF on
                   first run so we never alert on historical traffic), ledgers (and
                   optionally alerts/actions) new hits as they arrive.
  --scan-history   one-shot — scan ALL logs incl. rotated *.gz from the start,
                   write matching hits to the ledger as action="historical" (NO
                   Matrix alerts). Seeds the ledger / audits the past.
  --dry-run        with --scan-history: print a summary of what WOULD be flagged
                   (counts by rule / host / top IPs) and write NOTHING. Used to
                   validate regex precision against real traffic before going live.
  --reap           one-shot — auto-expiry / unban. List the CF IP Access Rules we
                   created (notes start "honeypot-auto"), DELETE those older than
                   HP_REAP_DAYS (default 14), and clear the actioned flag for those
                   IPs in the persistent ip-state. No-op (with a message) if cf env
                   is absent. Meant to run daily from a scheduler/cron.
  --digest [DAYS]  one-shot — aggregate the ledger over the last N days (default 1)
                   and (optionally) post ONE Matrix summary. Always prints to stdout.

stdlib only (native Termux python3; NOT in the proot — it tails the host-side
Caddy log and optionally calls the CF API + the loopback Matrix API). Everything
operator-specific (paths, domain, decoy hosts, alert target) comes from the
environment; the install step (scripts/steps/73-honeypot.sh) wires it.
"""
import sys, os, re, json, time, gzip, glob, html, ipaddress, calendar
import urllib.request, urllib.parse, urllib.error

# ---------------------------------------------------------------------------
# Paths. All env-driven, with defaults derived from the framework's DATA_DIR /
# POCKET_LOG_DIR / POCKET_STATE_DIR (set by scripts/lib/common.sh). There is NO
# hardcoded data path — a deploy that exports those three (as the install step
# does) gets the canonical locations; a bare run falls back to a local .run tree.
DATA_DIR   = os.environ.get("DATA_DIR", "").rstrip("/")
_FALLBACK  = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".run")
_FALLBACK  = os.path.normpath(_FALLBACK)
LOG_DIR    = os.environ.get("POCKET_LOG_DIR") or (f"{DATA_DIR}/logs" if DATA_DIR else f"{_FALLBACK}/logs")
STATE_DIR  = os.environ.get("POCKET_STATE_DIR") or (f"{DATA_DIR}/state" if DATA_DIR else f"{_FALLBACK}/state")
SECRETS_DIR = f"{DATA_DIR}/secrets" if DATA_DIR else f"{_FALLBACK}/secrets"

# The Caddy JSON access log this watcher tails. The integration patch makes Caddy
# emit JSON access logs (with the Cf-Connecting-IP client IP) to this path.
CADDY_LOG = os.environ.get("HONEYPOT_CADDY_LOG", f"{LOG_DIR}/caddy-access.log")
# Glob covering the active access log(s) — single file by default, but a glob is
# honoured so an operator who shards logs per-host still gets all of them tailed.
LOG_GLOB  = os.environ.get("HP_LOG_GLOB", CADDY_LOG)

LEDGER        = os.environ.get("HP_LEDGER",    f"{LOG_DIR}/honeypot.log")
STATE_FILE    = os.environ.get("HP_STATE",     f"{STATE_DIR}/honeypot-offsets.json")
IP_STATE_FILE = os.environ.get("HP_IP_STATE",  f"{STATE_DIR}/honeypot-ip-state.json")
MODE_FILE     = os.environ.get("HP_MODE_FILE", f"{SECRETS_DIR}/honeypot.mode")
SAFELIST_F    = os.environ.get("HP_SAFELIST",  f"{SECRETS_DIR}/honeypot-safelist.txt")
CF_ENV        = os.environ.get("HP_CF_ENV",    f"{SECRETS_DIR}/cf-honeypot.env")
# Operator opt-in marker for the blocking tiers (gate #2 — see read_mode()).
ALLOW_BLOCK_MARKER = os.environ.get("HP_ALLOW_BLOCK_MARKER",
                                    f"{SECRETS_DIR}/honeypot-allow-blocking")
# OPTIONAL Matrix alerting config. If this file exists and supplies all three
# vars, hits post a Matrix alert; otherwise alerting is silently skipped. The
# token is read from this 0600 file, NEVER from argv / a logged variable.
ALERT_ENV  = os.environ.get("HP_ALERT_ENV", f"{SECRETS_DIR}/honeypot-alert.env")

# OPTIONAL offline geo/ASN enrichment (ADDITIVE — never affects classification,
# safelisting, or blocking; purely advisory annotation on the ledger/alert/digest).
# The free DB-IP *lite* datasets (CC-BY 4.0) are dropped into HP_GEO_DIR — see
# scripts/honeypot/geo/README.md. With NO dataset present this is a strict no-op:
# every lookup yields {}, the heavy module (honeypot_geo.py) is never even imported,
# and the ledger record is byte-identical to a geo-less deploy. pocket-homeserver
# ships no dataset, so geo enrichment is dormant until an operator deploys one.
HP_GEO_DIR     = os.environ.get(
    "HP_GEO_DIR",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "geo"))
HP_GEO_COUNTRY = os.environ.get("HP_GEO_COUNTRY", "dbip-country-lite.csv.gz")
HP_GEO_ASN     = os.environ.get("HP_GEO_ASN", "dbip-asn-lite.csv.gz")
_GEO_DB = None          # cached _GeoDB once built (None until first geo_lookup)
_GEO_TRIED = False      # so a missing module/dataset is reported at most once

POLL_SEC       = float(os.environ.get("HP_POLL", "3.0"))
ALERT_COALESCE = float(os.environ.get("HP_ALERT_COALESCE", "600"))  # per-IP alert throttle (s)
STATE_FLUSH    = float(os.environ.get("HP_STATE_FLUSH", "10"))      # min s between offset writes

# The BLOCKING tiers (challenge/block) are gated behind a SEPARATE opt-in from the
# mode file: the operator must deliberately create the 0600 marker file
# ALLOW_BLOCK_MARKER (honeypot-allow-blocking). The mode file may live on a
# filesystem with no enforced perms (e.g. SD/exFAT), so anything with write access
# there could flip it to `block` and feed the watcher traffic to auto-ban arbitrary
# IPs (DoS-by-honeypot). Requiring a SECOND, separate opt-in means a tampered mode
# file ALONE can never enable mass-block.
#
# We read the MARKER FILE directly (not only an env flag): the supervisor re-launches
# this watcher from a recorded argv, NOT its env, after a reboot/respawn, so an
# env-only flag would silently fail to survive a reboot and quietly disable blocking
# for an operator who opted in. The marker file is the durable source of truth; the
# HP_ALLOW_BLOCKING env var is still honored as an alternative opt-in. Default
# (neither present) → mode is clamped to `alert`.
ALLOW_BLOCKING = (
    os.environ.get("HP_ALLOW_BLOCKING", "").lower() in ("1", "true", "yes")
    or os.path.isfile(ALLOW_BLOCK_MARKER)
)

# Set True only after the startup CF-token over-scope self-check passes (or the
# verify endpoint was unreachable = best-effort allow). While False, the blocking
# tiers are clamped to alert even if HP_ALLOW_BLOCKING is set, so an over-scoped
# token can never be used to mass-block. None = check not run yet (e.g.
# --scan-history / --digest, which never block anyway).
_BLOCK_TOKEN_OK = None

# Persistent per-IP state tuning. ESCALATE_HITS: an IP with >= this many lifetime
# hits escalates a `challenge`-mode action to a hard `block` (see handle_hit).
# IP_STATE_CAP: bound the ip-state file (evict oldest last_seen when exceeded).
# REAP_DAYS: --reap deletes honeypot-auto CF rules older than this many days.
ESCALATE_HITS = int(os.environ.get("HP_ESCALATE_HITS", "5"))
IP_STATE_CAP  = int(os.environ.get("HP_IP_STATE_CAP", "5000"))
REAP_DAYS     = int(os.environ.get("HP_REAP_DAYS", "14"))

# ---------------------------------------------------------------------------
# Scanner fingerprints. Each is a high-confidence path probe that NONE of the
# stack's real apps serve. Matched (case-insensitive) against the decoded URL path
# with the query string stripped. Anchored with leading `/` and a `/`-or-end tail
# so a legitimate longer path can't accidentally match. Validate against the live
# access log with --scan-history --dry-run before flipping a new rule live.
#
# DELIBERATELY NOT flagged (real, in-use): /config.json (Element), /.well-known/*
# (Matrix/ACME), /api/* (apps), /static /assets /fonts, /_matrix/*, /authgw/*
# /oidc/* /auth/*, /s /share (Pingvin), /bookmarks /feeds (Linkding), /search
# (SearXNG), /sw.js /manifest.* (PWAs), /health /healthz.
SCANNER_RULES = [
    ("dotenv",      re.compile(r"/\.env(\.[a-z0-9]+)?(/|$)", re.I)),
    ("git",         re.compile(r"/\.git(/|attributes$|ignore$|$)", re.I)),
    ("vcs",         re.compile(r"/\.(svn|hg|bzr)(/|$)", re.I)),
    ("cloud-creds", re.compile(r"/\.(aws|ssh|docker|kube|gnupg|gcloud)(/|$)", re.I)),
    ("dotfile",     re.compile(r"/\.(npmrc|bashrc|bash_history|htpasswd|htaccess|netrc|pgpass|my\.cnf)(/|$)", re.I)),
    ("editor",      re.compile(r"/\.(vscode|idea)(/|$)", re.I)),
    ("dsstore",     re.compile(r"/\.ds_store$", re.I)),
    ("wordpress",   re.compile(r"/(wp-login\.php|wp-admin|wp-content|wp-includes|wp-config\.php(\.[a-z]+)?|xmlrpc\.php|wlwmanifest\.xml|wordpress)(/|$)", re.I)),
    ("phpmyadmin",  re.compile(r"/(phpmyadmin|phpmyadmin2|pma|pma2|myadmin|mysqladmin|dbadmin|adminer(\.php)?|sqladmin)(/|$)", re.I)),
    ("joomla",      re.compile(r"/(administrator|joomla)(/|$)", re.I)),
    ("apache-stat", re.compile(r"/(server-status|server-info)(/|$)", re.I)),
    ("cgi",         re.compile(r"/cgi-bin/", re.I)),
    ("php-rce",     re.compile(r"/(vendor/phpunit|phpunit|eval-stdin\.php|allow_url_include)", re.I)),
    ("java-app",    re.compile(r"/(manager/html|jmx-console|invoker|struts|login\.action|index\.action|api/jsonws|jenkins/|solr/|druid/|actuator)(/|$)", re.I)),
    ("laravel",     re.compile(r"/(_ignition|telescope/|storage/logs/laravel\.log)", re.I)),
    ("exchange",    re.compile(r"/(owa/|ecp/|autodiscover/autodiscover\.xml)", re.I)),
    ("router-iot",  re.compile(r"/(boaform|gponform|setup\.cgi|currentsetting\.htm)", re.I)),
    # The dump/backup KEYWORDS must be a whole filename token (start of the last
    # path segment OR after a `. _ -` separator), not a bare substring, so a
    # legitimately-named asset that merely CONTAINS "backup" (e.g. /nobackup.zip)
    # does NOT match, while /backup.zip, /my-backup.zip and /a/backup.rar still do.
    # The pure-extension anchors (`.sql`, `.sql.gz`, `.sql.zip`) are unambiguous on
    # their own.
    # ⚠ MUST re-run `--scan-history --dry-run` and confirm 0 NEW false-positives
    #   before deploying a change to this rule (see docs/HONEYPOT.md).
    ("db-dump",     re.compile(r"/(?:[^/]*[._/-])?(dump\.sql|backup\.(?:sql|zip|tar\.gz|tgz|rar))$|/[^/]*\.sql(?:\.gz)?$|/[^/]*\.sql\.zip$", re.I)),
    # php-probe — only unambiguous scanner/webshell tokens, each WORD-BOUNDARY
    # anchored: the token must start the last path segment (right after the final
    # `/`) OR follow a `. _ -` separator, so e.g. /foxtrot.php does not trip `fox`
    # while /fox.php and /cmd-shell.php still do. `phpinfo` is its own whole token.
    # ⚠ MUST re-run `--scan-history --dry-run` and confirm 0 NEW false-positives
    #   before deploying a change to this rule (see docs/HONEYPOT.md).
    ("php-probe",   re.compile(r"/(?:[^/]*[._/-])?(phpinfo|shell|cmd|c99|r57|wso|alfa|fox|0x)\.php$", re.I)),
    ("config-leak", re.compile(r"/(web\.config|config\.php\.bak|\.config\.bak|composer\.lock)$", re.I)),
    # log4shell (CVE-2021-44228): the literal JNDI lookup marker in the decoded URI
    # (also catches obfuscated `${jndi:` since classify() tries the decoded form).
    # No real app ever puts `${jndi:` in a path/query.
    ("log4shell",   re.compile(r"\$\{jndi:", re.I)),
    # spring4shell (CVE-2022-22965): the classloader binding-injection marker. No
    # real request carries `class.module.classloader`.
    ("spring4shell", re.compile(r"class\.module\.classloader", re.I)),
    # directory / path traversal: dotdot sequences (raw + percent-encoded) and the
    # classic sensitive-file targets. classify() feeds both raw + url-decoded forms
    # so `..%2f` and `..%252f`→`..%2f` are caught. None of our paths contain `../`.
    ("path-traversal", re.compile(
        r"(\.\./|\.\.%2f|%2e%2e/|%2e%2e%2f|/etc/passwd|/etc/shadow|/win\.ini|/boot\.ini)", re.I)),
    # known appliance / CVE probe paths served NOWHERE (F5/Fortinet/Cisco/Pulse/
    # Liferay/MOVEit/ownCloud-Nextcloud-enum/WP user-enum). Each is a fixed, distinct
    # vendor path — zero overlap with /api, /authgw, /s, /bookmarks, etc.
    ("cve-probe",   re.compile(
        r"/(tmui/|remote/fgt_lang|\+CSCOE\+/|dana-na/|api/jsonws/invoke|moveitisapi|"
        r"human2\.aspx|owncloud/|nextcloud/|wp-json/wp/v2/users)", re.I)),
    # --- bait hooks (inert until a decoy-catchall vhost serves them) ---
    # canary trap — a request to a PLANTED bait path (a fake .env / config / git
    # config / backup deliberately served from the decoy). A hit = a scanner (or a
    # link-unfurler) touched a planted file. ALERT-ONLY (in ALERT_ONLY_RULES below):
    # a planted URL token can be fetched by a well-meaning bot, so never auto-block
    # on the canary path itself — the bad bots ALSO trip /.env etc. and get actioned
    # there. The literal bait paths come from HP_CANARY_PATHS.
    #   (built dynamically below from HP_CANARY_PATHS via classify_event.)
    # cred-replay: classified only when METHOD==POST to a decoy auth path on a decoy
    # host (handled in classify_event, which sees the method). A GET to the decoy
    # login page is just a canary/page view; a POST of credentials to it is
    # unambiguous malice → BLOCK_NOW_RULES → escalates to a hard block.
    #   (built dynamically below from HP_DECOY_AUTH_PATHS via classify_event.)
    #
    # planted bait — paths that exist NOWHERE real, advertised only as honeytrap
    # lures (robots.txt Disallow + a hidden in-app canary link). A hit means a bot
    # scraped robots.txt / followed a hidden link, or someone snooped the page
    # source. Kept LAST so a real scanner path under these prefixes (e.g.
    # /internal-admin/.env) still classifies as the specific blockable rule.
    ("honeytrap",   re.compile(r"/(private-backups|internal-admin)(/|$)", re.I)),
]

# ---------------------------------------------------------------------------
# Bait path config (inert until a decoy-catchall vhost is deployed and serves
# these paths; until then these paths simply never appear in real logs, so adding
# the rules is side-effect-free). Comma-separated env overrides.
#
# HP_CANARY_PATHS — planted bait files served by the decoy. A GET to any of these
#   (on a decoy host) classifies as `canary-token` (alert-only). These are EXACT
#   path prefixes, each advertised nowhere a legitimate user/app would reach.
HP_CANARY_PATHS = tuple(p.strip().lower() for p in os.environ.get(
    "HP_CANARY_PATHS",
    "/.env,/config.json,/.git/config,/backup.sql,/wp-login.php,"
    "/internal-admin/ops-console").split(",") if p.strip())
# HP_DECOY_AUTH_PATHS — the decoy login endpoint(s). A POST here (on a decoy host)
#   = cred-replay (BLOCK_NOW_RULES). A GET to the same path is NOT cred-replay
#   (it's a page view). Default mirrors a common NAS-appliance login form action.
HP_DECOY_AUTH_PATHS = tuple(p.strip().lower() for p in os.environ.get(
    "HP_DECOY_AUTH_PATHS",
    "/webman/login.cgi").split(",") if p.strip())


def _path_matches_any(decoded_path, candidates):
    """True if decoded_path equals or is under any candidate prefix (segment-safe)."""
    dp = decoded_path.lower()
    for c in candidates:
        if dp == c or dp.startswith(c + "/") or dp.startswith(c + "?"):
            return True
    return False

# Rules that are DETECT + ALERT only — never auto-block, even in challenge/block
# mode. Planted bait could conceivably be touched by a well-meaning bot (a search
# verifier, a Matrix/Slack link-unfurler), and we must not challenge/ban a legit
# crawler's IP account-wide. The bad bots that hit bait ALSO hit the passive
# blockable paths (/.env, …), so they still get challenged there. `canary-token`
# (a planted bait FILE fetched on the decoy) joins this set for the same reason.
ALERT_ONLY_RULES = {"honeytrap", "decoy-host", "canary-token"}

# Rules that ALWAYS escalate to a hard `block` (in challenge/block mode), even on
# the first hit and even if mode=="challenge" — unambiguous, intent-revealing
# malice. `cred-replay` is the only member: it fires solely on a POST of credentials
# to the decoy's fake login endpoint, which no benign crawler ever does (unfurlers
# GET, never POST credentials). See handle_hit. NEVER intersect ALERT_ONLY_RULES.
BLOCK_NOW_RULES = {"cred-replay"}

# Decoy hosts: fake subdomains fronting no real service, advertised nowhere — so
# ANY request to one is hostile subdomain enumeration, flagged regardless of path.
# Alert-only (above) so the operator testing the decoy, or a CT-log crawler that
# discovers the subdomain, is never challenged. Configured via HONEYPOT_DECOY_HOSTS
# (comma-separated); DEFAULT EMPTY — no decoy hosts unless the operator sets them.
DECOY_HOSTS = {h.strip().lower() for h in os.environ.get(
    "HONEYPOT_DECOY_HOSTS", "").split(",") if h.strip()}


def log(msg):
    sys.stderr.write(f"[{time.strftime('%FT%TZ', time.gmtime())}] honeypot-watcher: {msg}\n")
    sys.stderr.flush()


def read_mode():
    """alert | challenge | block  (default alert; unknown -> alert).

    The blocking tiers are TRIPLE-GATED. A `challenge`/`block` value in the mode
    file is CLAMPED back to `alert` unless ALL of:
      (1) the mode file says challenge/block (this read), AND
      (2) the operator opt-in marker (honeypot-allow-blocking) exists, or the
          HP_ALLOW_BLOCKING env flag is set (ALLOW_BLOCKING), AND
      (3) the CF-token over-scope self-check has passed (_BLOCK_TOKEN_OK is not
          affirmatively False).
    So a tampered mode file ALONE — or an over-scoped CF token — can never enable
    mass-block. Re-read on a short interval by run_live (cheap hot-reload)."""
    try:
        m = open(MODE_FILE).read().strip().lower()
        m = m if m in ("alert", "challenge", "block") else "alert"
    except OSError:
        m = "alert"
    if m in ("challenge", "block"):
        # gate #2: require the start-script opt-in flag.
        if not ALLOW_BLOCKING:
            return "alert"
        # gate #3: require the CF-token over-scope self-check to have passed.
        # _BLOCK_TOKEN_OK is False only when the check AFFIRMATIVELY proved the
        # token is too broad / invalid; None (not yet run) or True both allow.
        if _BLOCK_TOKEN_OK is False:
            return "alert"
    return m


# Always-safe networks: loopback + the published Cloudflare edge ranges. The real
# attacker IP arrives via Cf-Connecting-IP; when that header is absent (CF's own
# crawlers / Always-Online / health probes) the client IP falls back to the CF edge
# address itself — we must NEVER alert or (in the block tier) block those, or we'd
# ban our own edge and kill the tunnel. Refresh from https://www.cloudflare.com/ips/
# if CF changes ranges. Operator IPs go in the safelist file (one IP/CIDR per line).
DEFAULT_SAFE_CIDRS = [
    "127.0.0.0/8", "::1/128",
    # Cloudflare IPv4
    "173.245.48.0/20", "103.21.244.0/22", "103.22.200.0/22", "103.31.4.0/22",
    "141.101.64.0/18", "108.162.192.0/18", "190.93.240.0/20", "188.114.96.0/20",
    "197.234.240.0/22", "198.41.128.0/17", "162.158.0.0/15", "104.16.0.0/13",
    "104.24.0.0/14", "172.64.0.0/13", "131.0.72.0/22",
    # Cloudflare IPv6
    "2400:cb00::/32", "2606:4700::/32", "2803:f800::/32", "2405:b500::/32",
    "2405:8100::/32", "2a06:98c0::/29", "2c0f:f248::/32",
]


def load_safelist():
    """Return a list of ip_network objects (loopback + Cloudflare + operator file)."""
    nets = []
    for c in DEFAULT_SAFE_CIDRS:
        try:
            nets.append(ipaddress.ip_network(c, strict=False))
        except ValueError:
            pass
    try:
        for ln in open(SAFELIST_F):
            ln = ln.split("#", 1)[0].strip()
            if not ln:
                continue
            try:
                nets.append(ipaddress.ip_network(ln, strict=False))
            except ValueError:
                log(f"safelist: ignoring invalid entry {ln!r}")
    except OSError:
        pass
    return nets


def ip_safelisted(ip, nets):
    """True if ip is empty/unparseable (can't act on it) or inside a safe net."""
    if not ip:
        return True
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return True
    return any(addr in n for n in nets)


# Injection-marker rules whose payload commonly lives in the QUERY STRING or an
# encoded segment, not just the path — for these we additionally scan the FULL uri
# (path?query, raw + decoded). They are literal, high-entropy markers (`${jndi:`,
# `class.module.classloader`, `../`) that no legitimate query carries, so widening
# the scan to the query cannot introduce a path-rule false-positive. The path-only
# rules keep scanning the query-stripped path exactly as before (0-FP preserved).
_FULL_URI_RULES = {"log4shell", "spring4shell", "path-traversal"}


def classify(uri):
    """Return rule name if the request looks like a scanner probe, else None.

    Path-anchored rules match against the query-stripped path (raw + url-decoded).
    Injection-marker rules (_FULL_URI_RULES) ALSO match against the full uri incl.
    the query string. First match wins; rules are ordered so the specific blockable
    fingerprints win over the trailing planted-bait rules."""
    path = uri.split("?", 1)[0].split("#", 1)[0]
    try:
        decoded_path = urllib.parse.unquote(path)
        decoded_uri = urllib.parse.unquote(uri)
    except Exception:
        decoded_path, decoded_uri = path, uri
    for name, rx in SCANNER_RULES:
        if name in _FULL_URI_RULES:
            cands = (path, decoded_path, uri, decoded_uri)
        else:
            cands = (path, decoded_path)
        for cand in cands:
            if rx.search(cand):
                return name
    return None


def classify_event(ev):
    """Event-aware classification (host + method + path). Returns a rule name or None.

    Precedence (most-decisive first), all preserving the 0-FP guarantee:
      1. cred-replay   — METHOD==POST to a decoy auth path (HP_DECOY_AUTH_PATHS) AND
                         the request is on a decoy host. A credential POST to the
                         fake login is unambiguous malice → BLOCK_NOW_RULES.
      2. decoy host    — on a decoy subdomain, ANY hit is hostile enumeration. A hit
                         on a PLANTED bait path → the more specific `canary-token`
                         (alert-only); any other path → `decoy-host` (alert-only).
      3. classify(uri) — on the REAL surface, the path/injection scanner fingerprints
                         ONLY. Canary/cred-replay never fire here, so a real
                         `/config.json` (Element), `/.env` probe, etc. classify
                         precisely — no downgrade, no new FP.

    With HONEYPOT_DECOY_HOSTS empty (the default), DECOY_HOSTS is empty and steps
    1–2 never fire; every result is exactly classify(ev['uri'])."""
    host = (ev.get("host") or "").lower()
    method = (ev.get("method") or "").upper()
    path = ev.get("uri", "").split("?", 1)[0].split("#", 1)[0]
    try:
        decoded_path = urllib.parse.unquote(path)
    except Exception:
        decoded_path = path

    on_decoy = host in DECOY_HOSTS
    if on_decoy:
        # 1. cred-replay: a credential POST to the decoy login endpoint.
        if method == "POST" and _path_matches_any(decoded_path, HP_DECOY_AUTH_PATHS):
            return "cred-replay"
        # 2. canary-token (planted bait file) > generic decoy-host tripwire.
        if _path_matches_any(decoded_path, HP_CANARY_PATHS):
            return "canary-token"
        return "decoy-host"

    # 3. real surface: the path/injection scanner fingerprints only (unchanged).
    return classify(ev.get("uri", ""))


def parse_line(line):
    """Caddy JSON access line -> normalized event dict, or None if not a request.

    The real client IP is taken from the Cf-Connecting-IP request header that Caddy
    logs (set by the integration patch's `log` block), falling back to Caddy's own
    client_ip / remote_ip when the header is absent."""
    try:
        d = json.loads(line)
    except Exception:
        return None
    req = d.get("request")
    if not isinstance(req, dict):
        return None
    uri = req.get("uri", "")
    if not uri:
        return None
    hdrs = req.get("headers") or {}

    def _first(name):
        v = hdrs.get(name)
        if isinstance(v, list) and v:
            return v[0]
        if isinstance(v, str) and v:
            return v
        return ""

    ua = _first("User-Agent")
    # Prefer the Cloudflare-supplied real client IP; fall back to Caddy's view.
    cf_ip = (_first("Cf-Connecting-IP") or "").strip()
    ip = cf_ip or req.get("client_ip") or req.get("remote_ip") or ""
    return {
        "ip":     ip,
        "host":   req.get("host", ""),
        "uri":    uri,
        "method": req.get("method", ""),
        "ua":     ua,
        "status": d.get("status", 0),
        "log_ts": d.get("ts", 0),
    }


def ledger_write(rec):
    try:
        os.makedirs(os.path.dirname(LEDGER), exist_ok=True)
        with open(LEDGER, "a") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    except Exception as e:
        log(f"ledger write failed: {e}")


def geo_lookup(ip):
    """Offline geo/ASN enrichment for `ip`. Returns {"country","asn","as_org",
    "hosting"} (any subset) or {} when the dataset is absent / the ip isn't found /
    anything goes wrong. NEVER raises, NEVER touches classification — purely
    advisory annotation merged into the ledger record.

    No-op contract: if HP_GEO_DIR is empty/unset or neither dataset file is present,
    this returns {} immediately and never imports the geo module, so a deploy
    WITHOUT the dataset is byte-equivalent to a geo-less watcher."""
    global _GEO_DB, _GEO_TRIED
    if not HP_GEO_DIR:
        return {}
    if _GEO_DB is None:
        if _GEO_TRIED:
            return {}
        _GEO_TRIED = True
        country_path = os.path.join(HP_GEO_DIR, HP_GEO_COUNTRY)
        asn_path = os.path.join(HP_GEO_DIR, HP_GEO_ASN)
        # Dataset absent ⇒ stay a strict no-op without importing anything heavy.
        if not (os.path.exists(country_path) or os.path.exists(asn_path)):
            return {}
        # Import the sibling honeypot_geo.py lazily — a geo-less deploy never pays
        # for it, and a failure to import is a silent no-op (advisory only).
        try:
            import importlib.util
            mod_path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                    "honeypot_geo.py")
            spec = importlib.util.spec_from_file_location("honeypot_geo", mod_path)
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            _GEO_DB = mod.load_geo(country_path, asn_path)
            log(f"geo enrichment ENABLED (dir={HP_GEO_DIR})")
        except Exception as e:
            log(f"geo enrichment disabled (load failed: {e})")
            return {}
    try:
        return _GEO_DB.lookup(ip) or {}
    except Exception:
        return {}


# ---------------------------------------------------------------------------
# OPTIONAL Matrix alerting. There is no bundled bot in pocket-homeserver: alerting
# is OFF unless the operator drops a 0600 file at ${DATA_DIR}/secrets/honeypot-alert.env
# supplying ALL of HP_MATRIX_HS (homeserver base URL, e.g. http://127.0.0.1:8448),
# HP_MATRIX_TOKEN (an access token) and HP_MATRIX_ROOM (a room id). The token is
# read from that file at send-time and NEVER placed on argv. Any missing var ⇒
# alerting is silently skipped (ledger-only remains the default behaviour).
def _load_alert_env():
    """Parse honeypot-alert.env (key=value) → {HP_MATRIX_HS, HP_MATRIX_TOKEN,
    HP_MATRIX_ROOM}. Read at send-time so a freshly-provisioned file is picked up
    without a restart. Returns {} if the file is absent/unreadable. Env vars of the
    same name (if exported) take precedence so a wrapper can inject them too."""
    cfg = {}
    try:
        for ln in open(ALERT_ENV):
            ln = ln.strip()
            if ln and not ln.startswith("#") and "=" in ln:
                k, v = ln.split("=", 1)
                cfg[k.strip()] = v.strip().strip('"').strip("'")
    except OSError:
        pass
    for k in ("HP_MATRIX_HS", "HP_MATRIX_TOKEN", "HP_MATRIX_ROOM"):
        ev = os.environ.get(k, "")
        if ev:
            cfg[k] = ev
    return cfg


def _md_alert(rec, ip_count, ent=None):
    """Build the per-IP Matrix alert. `ent` (optional) is the persistent ip-state
    entry — when present we add concise session-correlation context (lifetime hits,
    distinct rules this IP has tripped, first-seen). All attacker-controlled fields
    (uri/ua) stay truncated and go through _md_to_html's escape path; the
    correlation fields (counts, rule names, our own timestamps) are watcher-
    generated, not attacker text, so they're safe."""
    p = rec
    msg = (
        "🍯 **Honeypot hit** — scanner probe detected\n"
        f"**IP:** `{p['ip']}`\n"
        f"**Host:** {p['host']}\n"
        f"**Path:** `{p['uri'][:200]}`\n"
        f"**Method:** {p['method']} → {p['status']}\n"
        f"**Rule:** {p['hit_rule']}\n"
        f"**UA:** {(p['ua'] or '-')[:160]}\n"
        f"**Action:** {p['action']}\n"
    )
    if ent is not None:
        # rule names are watcher-defined identifiers; clamp the list length anyway.
        rules = ", ".join(ent.get("rules", [])[:12]) or "-"
        msg += (
            f"**Seen before:** {ent.get('total_hits', ip_count)} lifetime hit(s), "
            f"rules [{rules}]\n"
            f"**First seen:** {ent.get('first_seen', '-')}\n"
        )
    msg += f"_(≥{ip_count} hit(s) from this IP this run)_"
    return msg


def _md_to_html(md):
    """Tiny, injection-safe markdown -> Matrix HTML: escape everything first, then
    re-introduce a known-safe subset (**bold**, `code`, _italic_, newlines)."""
    out = html.escape(md, quote=False)
    out = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", out)
    out = re.sub(r"`([^`]+?)`", r"<code>\1</code>", out)
    out = re.sub(r"_(.+?)_", r"<em>\1</em>", out)
    return out.replace("\n", "<br>")


def matrix_alert(md_text):
    """Post one Matrix alert if (and only if) honeypot-alert.env supplies all three
    vars. The token is read from the 0600 file here and used solely as the Bearer
    header — never logged, never on argv. Returns True on a 2xx send, else False
    (including the silent-skip case where alerting isn't configured)."""
    cfg = _load_alert_env()
    hs = (cfg.get("HP_MATRIX_HS") or "").rstrip("/")
    token = cfg.get("HP_MATRIX_TOKEN") or ""
    room = cfg.get("HP_MATRIX_ROOM") or ""
    if not (hs and token and room):
        return False
    content = {
        "msgtype": "m.text",
        "body": re.sub(r"[*`_]", "", md_text),
        "format": "org.matrix.custom.html",
        "formatted_body": _md_to_html(md_text),
    }
    txn = str(time.time_ns())
    url = (f"{hs}/_matrix/client/v3/rooms/"
           f"{urllib.parse.quote(room)}/send/m.room.message/{txn}")
    req = urllib.request.Request(
        url, data=json.dumps(content).encode(), method="PUT",
        headers={"Authorization": f"Bearer {token}",
                 "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=8) as r:
            return 200 <= r.status < 300
    except Exception as e:
        log(f"matrix alert failed: {e}")
        return False


# ---------------------------------------------------------------------------
# Cloudflare IP-Access-Rules CRUD + token scope-check.
#
# These live in the sibling cf_actions module (scripts/honeypot/cf_actions.py) so
# the watcher AND the admin panel's honeypot console use byte-identical,
# scope-checked CF logic. We wire this module's CF_ENV + log into cf_actions so its
# diagnostics route through our logger, then re-bind the names locally so the rest
# of this file calls them unchanged.
import cf_actions
cf_actions.CF_ENV = CF_ENV
cf_actions.log = log
_load_cf_env = cf_actions._load_cf_env
cf_token_scope_ok = cf_actions.cf_token_scope_ok
cf_block = cf_actions.cf_block
cf_list_rules = cf_actions.cf_list_rules
cf_delete_rule = cf_actions.cf_delete_rule


# ---------------------------------------------------------------------------
# offset state (live tail): {"files": {path: {"inode": int, "offset": int}}}
def load_state():
    try:
        return json.load(open(STATE_FILE))
    except Exception:
        return {"files": {}}


def save_state(state):
    try:
        os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
        tmp = STATE_FILE + ".tmp"
        json.dump(state, open(tmp, "w"))
        os.replace(tmp, STATE_FILE)
    except Exception as e:
        log(f"state save failed: {e}")


# ---------------------------------------------------------------------------
# Persistent per-IP state: survives restarts, powers escalation +
# session-correlation + the digest. Shape:
#   {"<ip>": {"first_seen": iso, "last_seen": iso, "total_hits": int,
#             "rules": [sorted unique rule names], "actioned": "",
#             "action_ts": iso|""}}
# Bounded at IP_STATE_CAP (evict oldest last_seen). Absent file ⇒ {} ⇒ the watcher
# behaves exactly as before (escalation just never triggers).
def load_ip_state():
    try:
        d = json.load(open(IP_STATE_FILE))
        return d if isinstance(d, dict) else {}
    except Exception:
        return {}


def save_ip_state(ip_state):
    try:
        os.makedirs(os.path.dirname(IP_STATE_FILE), exist_ok=True)
        # bound the file: evict oldest last_seen beyond the cap.
        if len(ip_state) > IP_STATE_CAP:
            ordered = sorted(ip_state.items(),
                             key=lambda kv: kv[1].get("last_seen", ""))
            for ip, _ in ordered[:len(ip_state) - IP_STATE_CAP]:
                ip_state.pop(ip, None)
        tmp = IP_STATE_FILE + ".tmp"
        json.dump(ip_state, open(tmp, "w"))
        os.replace(tmp, IP_STATE_FILE)
    except Exception as e:
        log(f"ip-state save failed: {e}")


def ip_state_update(ip_state, ip, rule, now_iso):
    """Record this hit in the persistent per-IP state; return the updated entry.
    Pure bookkeeping — does NOT decide actions (handle_hit does, using total_hits)."""
    e = ip_state.get(ip)
    if e is None:
        e = {"first_seen": now_iso, "last_seen": now_iso, "total_hits": 0,
             "rules": [], "actioned": "", "action_ts": ""}
        ip_state[ip] = e
    e["last_seen"] = now_iso
    e["total_hits"] = int(e.get("total_hits", 0)) + 1
    if rule not in e["rules"]:
        e["rules"] = sorted(set(e["rules"]) | {rule})
    return e


def handle_hit(ev, mode, safelist, ip_counts, last_alert, blocked, live,
               ip_state=None):
    """Common path for a classified scanner hit. Returns True if it was a hit.
    `blocked` is an ip->action map so we hit the CF API at most once per IP per
    run (CF also rejects dupes; this just avoids the redundant calls).
    `ip_state` (optional) is the persistent per-IP dict — when provided it is
    updated and used for repeat-offender escalation + richer alerts. When omitted
    behaviour is identical (no escalation, plain alert)."""
    # Event-aware classification: decoy-host / cred-replay(POST) / canary-token /
    # the path+injection scanner fingerprints.
    rule = classify_event(ev)
    if not rule:
        return False
    if ip_safelisted(ev["ip"], safelist):
        return False
    ip = ev["ip"]
    ip_counts[ip] = ip_counts.get(ip, 0) + 1
    now_iso = time.strftime("%FT%TZ", time.gmtime())

    # persistent per-IP bookkeeping (powers escalation + correlation + digest).
    ent = ip_state_update(ip_state, ip, rule, now_iso) if ip_state is not None else None

    action = "alerted" if live else "historical"
    if live and mode in ("challenge", "block") and rule not in ALERT_ONLY_RULES:
        # Repeat-offender / cred-replay ESCALATION (challenge/block mode only):
        #   * mode=="block"            -> always a hard block.
        #   * rule in BLOCK_NOW_RULES  -> hard block even on the first hit (cred-replay
        #     is unambiguous malice).
        #   * lifetime total_hits >= HP_ESCALATE_HITS -> a persistent repeat offender;
        #     escalate this IP's `challenge` to a hard `block`.
        #   * otherwise                -> the configured tier (challenge).
        # ALERT_ONLY_RULES are excluded above so they never escalate or block.
        total_hits = ent["total_hits"] if ent is not None else ip_counts[ip]
        escalate = (rule in BLOCK_NOW_RULES) or (total_hits >= ESCALATE_HITS)
        tier = "block" if escalate else mode
        if ip in blocked:
            action = blocked[ip]
        else:
            action = cf_block(ip, tier)
            blocked[ip] = action
        if ent is not None and not str(action).startswith(("skipped", "alerted", "cf-error")):
            # record the realized edge action in persistent state (for --reap + digest).
            ent["actioned"] = "block" if tier == "block" else "challenge"
            ent["action_ts"] = now_iso
    rec = {
        "ts":   now_iso,
        "ip":   ip, "host": ev["host"], "uri": ev["uri"],
        "method": ev["method"], "status": ev["status"], "ua": ev["ua"],
        "hit_rule": rule, "mode": mode, "action": action,
    }
    # ADDITIVE offline geo/ASN enrichment — merge country/asn/as_org/hosting when a
    # dataset is deployed. {} (no dataset / not found) leaves rec unchanged, so a
    # geo-less deploy writes the exact same ledger record as before.
    geo = geo_lookup(ip)
    if geo:
        rec.update(geo)
    ledger_write(rec)
    if live:
        now = time.time()
        if now - last_alert.get(ip, 0) >= ALERT_COALESCE:
            last_alert[ip] = now
            matrix_alert(_md_alert(rec, ip_counts[ip], ent))
    return True


# ---------------------------------------------------------------------------
def run_live():
    global _BLOCK_TOKEN_OK
    # Blocking-tier gating. Report the start-script opt-in flag, and — if a blocking
    # tier is even potentially in play — run the CF-token over-scope self-check ONCE
    # at startup. read_mode() consults both gates, so the watcher silently stays
    # alert-only (never blocks) when either gate is closed.
    if ALLOW_BLOCKING:
        cfg = _load_cf_env()
        tok, acct = cfg.get("CF_API_TOKEN"), cfg.get("CF_ACCOUNT_ID")
        if tok and acct:
            ok, reason = cf_token_scope_ok(tok, acct)
            _BLOCK_TOKEN_OK = ok
            if ok:
                log(f"CF token scope self-check PASSED ({reason}) — blocking tiers permitted")
            else:
                log(f"CF token scope self-check FAILED: {reason} — "
                    f"REFUSING blocking; clamped to alert-only")
        else:
            # No cf env yet → cf_block already no-ops; nothing to block with.
            log("blocking opt-in present but cf-honeypot.env has no token/account — "
                "blocking is inert (alert-only) until provisioned")
    else:
        log(f"blocking tiers DISABLED (no opt-in marker {ALLOW_BLOCK_MARKER}) — "
            "alert-only regardless of honeypot.mode")
    mode = read_mode()
    safelist = load_safelist()
    alerting = bool(_load_alert_env().get("HP_MATRIX_TOKEN")
                    and _load_alert_env().get("HP_MATRIX_ROOM")
                    and _load_alert_env().get("HP_MATRIX_HS"))
    log(f"live tail starting — mode={mode}, glob={LOG_GLOB}, "
        f"ledger={LEDGER}, matrix_alerts={'on' if alerting else 'off (ledger-only)'}")
    state = load_state()
    first_run = not state["files"]
    ip_counts, last_alert, blocked = {}, {}, {}
    ip_state = load_ip_state()          # persistent per-IP (escalation + correlation)
    ip_state_dirty = False
    last_flush = 0.0
    last_mode_check = 0.0
    while True:
        # cheap hot-reload of the mode file every poll-ish
        now = time.time()
        if now - last_mode_check > 5:
            mode = read_mode()
            last_mode_check = now
        for path in sorted(glob.glob(LOG_GLOB)):
            try:
                st = os.stat(path)
            except OSError:
                continue
            fs = state["files"].get(path)
            if fs is None or fs.get("inode") != st.st_ino:
                # new file (first sight or rotated). On the very first watcher run
                # seed at EOF so we don't alert on the whole backlog of history; a
                # mid-run rotation reads the fresh file from the top.
                offset = st.st_size if (first_run and fs is None) else 0
                state["files"][path] = {"inode": st.st_ino, "offset": offset}
                fs = state["files"][path]
            if st.st_size < fs["offset"]:      # truncated
                fs["offset"] = 0
            if st.st_size == fs["offset"]:
                continue
            try:
                with open(path, "rb") as f:
                    f.seek(fs["offset"])
                    while True:
                        raw = f.readline()
                        if not raw:
                            break
                        if not raw.endswith(b"\n"):   # partial trailing line; leave it
                            break
                        fs["offset"] = f.tell()
                        ev = parse_line(raw.decode("utf-8", "replace"))
                        if ev:
                            if handle_hit(ev, mode, safelist, ip_counts, last_alert,
                                          blocked, live=True, ip_state=ip_state):
                                ip_state_dirty = True
            except OSError as e:
                log(f"read {path}: {e}")
        first_run = False
        if now - last_flush > STATE_FLUSH:
            save_state(state)
            if ip_state_dirty:
                save_ip_state(ip_state)
                ip_state_dirty = False
            last_flush = now
        time.sleep(POLL_SEC)


def run_scan_history(dry_run):
    """Scan every log incl. rotated *.gz from the start. Ledger (or, if dry-run,
    just summarize) every scanner hit. No Matrix alerts."""
    safelist = load_safelist()
    paths = sorted(glob.glob(LOG_GLOB) +
                   glob.glob(os.path.join(os.path.dirname(LOG_GLOB), "*.log.gz")))
    by_rule, by_host, by_ip = {}, {}, {}
    total_lines = hits = 0
    for path in paths:
        opener = gzip.open if path.endswith(".gz") else open
        try:
            with opener(path, "rt", encoding="utf-8", errors="replace") as f:
                for line in f:
                    total_lines += 1
                    ev = parse_line(line)
                    if not ev:
                        continue
                    # Use the SAME event-aware classifier as live mode so the dry-run
                    # validation sees decoy-host / cred-replay / canary-token too —
                    # this is the run that must show 0 NEW false-positives before the
                    # new rules go live (see docs/HONEYPOT.md).
                    rule = classify_event(ev)
                    if not rule or ip_safelisted(ev["ip"], safelist):
                        continue
                    hits += 1
                    by_rule[rule] = by_rule.get(rule, 0) + 1
                    by_host[ev["host"]] = by_host.get(ev["host"], 0) + 1
                    by_ip[ev["ip"]] = by_ip.get(ev["ip"], 0) + 1
                    if not dry_run:
                        ledger_write({
                            "ts": time.strftime("%FT%TZ", time.gmtime()),
                            "ip": ev["ip"], "host": ev["host"], "uri": ev["uri"],
                            "method": ev["method"], "status": ev["status"],
                            "ua": ev["ua"], "hit_rule": rule, "mode": "scan",
                            "action": "historical",
                        })
        except OSError as e:
            log(f"scan {path}: {e}")
    print(f"== honeypot --scan-history{' --dry-run' if dry_run else ''} ==")
    print(f"files scanned : {len(paths)}")
    print(f"lines parsed  : {total_lines}")
    print(f"scanner hits  : {hits}  (after safelist)")
    print("by rule       :")
    for k, v in sorted(by_rule.items(), key=lambda x: -x[1]):
        print(f"   {v:6d}  {k}")
    print("by host       :")
    for k, v in sorted(by_host.items(), key=lambda x: -x[1]):
        print(f"   {v:6d}  {k}")
    print(f"unique IPs    : {len(by_ip)}")
    for k, v in sorted(by_ip.items(), key=lambda x: -x[1])[:15]:
        print(f"   {v:6d}  {k}")
    if dry_run:
        print("(dry-run: ledger NOT written)")


# ---------------------------------------------------------------------------
def _parse_note_ts(note):
    """Extract the ISO timestamp the watcher wrote into a CF rule note
    ('honeypot-auto 2026-06-04T12:00:00Z') → epoch seconds, or None if absent."""
    m = re.search(r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})Z?", note or "")
    if not m:
        return None
    try:
        return calendar.timegm(time.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S"))
    except Exception:
        return None


def run_reap():
    """Auto-expiry / unban. DELETE the CF IP Access Rules WE created (notes start
    'honeypot-auto') that are older than HP_REAP_DAYS, and clear the `actioned` flag
    in ip-state for the reaped IPs. No-op (with a clear message) if cf-honeypot.env
    is absent. Read + DELETE only — never creates rules, never touches the safelist.
    Meant to run daily from a scheduler/cron.

    Token scope: Account Firewall Access Rules: Edit (covers GET + DELETE) — the
    same token cf_block already uses."""
    cfg = _load_cf_env()
    tok, acct = cfg.get("CF_API_TOKEN"), cfg.get("CF_ACCOUNT_ID")
    if not (tok and acct):
        print(f"--reap: {CF_ENV} missing CF_API_TOKEN/CF_ACCOUNT_ID — nothing to do "
              f"(no edge rules can have been created). No-op.")
        return
    cutoff = time.time() - REAP_DAYS * 86400
    rules = cf_list_rules(tok, acct)
    kept = deleted = errors = undated = 0
    reaped_ips = set()
    for r in rules:
        ts = _parse_note_ts(r.get("notes"))
        if ts is None:
            undated += 1          # no parseable timestamp → keep (don't guess age)
            kept += 1
            continue
        if ts >= cutoff:
            kept += 1
            continue
        if cf_delete_rule(tok, acct, r["id"]):
            deleted += 1
            if r.get("ip"):
                reaped_ips.add(r["ip"])
        else:
            errors += 1
    # clear the actioned flag for reaped IPs so escalation can re-evaluate fresh.
    if reaped_ips:
        ip_state = load_ip_state()
        changed = False
        for ip in reaped_ips:
            ent = ip_state.get(ip)
            if ent and ent.get("actioned"):
                ent["actioned"] = ""
                ent["action_ts"] = ""
                changed = True
        if changed:
            save_ip_state(ip_state)
    print("== honeypot --reap ==")
    print(f"honeypot-auto rules found : {len(rules)}")
    print(f"older than {REAP_DAYS}d (deleted) : {deleted}")
    print(f"kept (fresh)              : {kept}  (incl. {undated} undated)")
    print(f"delete errors             : {errors}")
    print(f"ip-state actioned cleared : {len(reaped_ips)}")


# ---------------------------------------------------------------------------
def _digest_window_start(days):
    return time.time() - days * 86400


def _ledger_ts_epoch(ts):
    """Ledger 'ts' is the watcher's ISO 'YYYY-MM-DDTHH:MM:SSZ' → epoch, or None."""
    m = re.match(r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})", ts or "")
    if not m:
        return None
    try:
        return calendar.timegm(time.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S"))
    except Exception:
        return None


def run_digest(days):
    """Aggregate the ledger over the last `days` days and (optionally) post ONE
    Matrix summary. Read-only over the ledger + ip-state; no CF calls. Always prints
    the digest to stdout. Injection-safe (reuses _md_to_html escape)."""
    start = _digest_window_start(days)
    total = 0
    uniq_ips = set()
    by_rule, by_host, by_ip = {}, {}, {}
    cf_actions_n = canary_touches = credreplay = 0
    try:
        with open(LEDGER, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except Exception:
                    continue
                ep = _ledger_ts_epoch(rec.get("ts"))
                if ep is None or ep < start:
                    continue
                total += 1
                ip = rec.get("ip", "")
                rule = rec.get("hit_rule", "?")
                host = rec.get("host", "")
                action = str(rec.get("action", ""))
                uniq_ips.add(ip)
                by_rule[rule] = by_rule.get(rule, 0) + 1
                by_host[host] = by_host.get(host, 0) + 1
                by_ip[ip] = by_ip.get(ip, 0) + 1
                if action.startswith("cf-") and not action.endswith("error"):
                    cf_actions_n += 1
                if rule in ("canary-token", "honeytrap", "decoy-host"):
                    canary_touches += 1
                if rule == "cred-replay":
                    credreplay += 1
    except OSError as e:
        log(f"digest: cannot read ledger {LEDGER}: {e}")

    ip_state = load_ip_state()

    # --- stdout report ---
    print(f"== honeypot --digest (last {days}d) ==")
    print(f"total hits   : {total}")
    print(f"unique IPs   : {len(uniq_ips)}")
    print(f"cf actions   : {cf_actions_n}")
    print(f"canary/trap  : {canary_touches}")
    print(f"cred-replay  : {credreplay}")
    print("by rule      :")
    for k, v in sorted(by_rule.items(), key=lambda x: -x[1]):
        print(f"   {v:6d}  {k}")
    print("by host      :")
    for k, v in sorted(by_host.items(), key=lambda x: -x[1]):
        print(f"   {v:6d}  {k}")
    print("top IPs      :")
    top = sorted(by_ip.items(), key=lambda x: -x[1])[:10]
    for ip, v in top:
        ent = ip_state.get(ip) or {}
        print(f"   {v:6d}  {ip}  lifetime={ent.get('total_hits', '?')} "
              f"actioned={ent.get('actioned') or '-'} "
              f"rules={','.join(ent.get('rules', [])) or '-'}")

    # --- Matrix message (one) ---
    if total == 0:
        md = (f"🍯 **Honeypot daily digest** (last {days}d)\n"
              f"_All quiet — 0 scanner hits in the window._")
    else:
        lines = [f"🍯 **Honeypot daily digest** (last {days}d)",
                 f"**Total hits:** {total}  ·  **Unique IPs:** {len(uniq_ips)}",
                 f"**CF actions:** {cf_actions_n}  ·  **canary/trap:** {canary_touches}"
                 f"  ·  **cred-replay:** {credreplay}",
                 "**By rule:** " + (", ".join(
                     f"{k}×{v}" for k, v in sorted(by_rule.items(), key=lambda x: -x[1]))
                     or "-"),
                 "**By host:** " + (", ".join(
                     f"{k}×{v}" for k, v in sorted(by_host.items(), key=lambda x: -x[1])[:8])
                     or "-"),
                 "**Top IPs:**"]
        for ip, v in top:
            ent = ip_state.get(ip) or {}
            rules = ",".join(ent.get("rules", [])[:8]) or "-"
            lines.append(
                f"  · `{ip}` — {v} hit(s); lifetime {ent.get('total_hits', '?')}, "
                f"actioned {ent.get('actioned') or '-'}, rules [{rules}]")
        md = "\n".join(lines)
    if matrix_alert(md):
        print("(digest posted to Matrix room)")
    else:
        print("(digest NOT posted — honeypot-alert.env unset/incomplete or send "
              "failed; the stdout above is the full digest)")


def main():
    args = sys.argv[1:]
    if "--reap" in args:
        run_reap()
    elif "--digest" in args:
        # optional positional DAYS after --digest (default 1).
        days = 1
        i = args.index("--digest")
        if i + 1 < len(args):
            try:
                days = max(1, int(args[i + 1]))
            except ValueError:
                pass
        run_digest(days)
    elif "--scan-history" in args:
        run_scan_history(dry_run=("--dry-run" in args))
    elif "--dry-run" in args:
        run_scan_history(dry_run=True)
    else:
        run_live()


if __name__ == "__main__":
    main()
