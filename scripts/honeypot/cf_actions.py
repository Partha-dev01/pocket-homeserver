"""Cloudflare IP-Access-Rules CRUD + token scope-check — the shared honeypot edge
layer, factored out so the watcher AND the admin console use byte-identical,
scope-checked Cloudflare logic.

This module performs NO offensive action. The only edge surface it touches is the
operator's OWN Cloudflare account `firewall/access_rules` (challenge/block/unblock
a single source IP, list/delete the honeypot-auto rules) — the same mechanism and
blast radius the watcher uses for opt-in auto-blocking. There is no free-form
target: every call takes a source IP that is already in the operator's own access
log. Blocking is OFF by default and only ever reached after a triple gate
(honeypot.mode + an explicit opt-in marker + the over-scope tripwire below).

Do NOT confuse this with the admin panel's Cloudflare *Access* JWT verification —
that is a different Cloudflare surface (Zero Trust Access), kept entirely separate.

Configuration (set by the importer BEFORE calling, e.g. the watcher does
`cf_actions.CF_ENV = CF_ENV; cf_actions.log = log`):
  * CF_ENV : path to the 0600 cf-honeypot.env (key=value: CF_API_TOKEN, CF_ACCOUNT_ID),
             normally ${DATA_DIR}/secrets/cf-honeypot.env. Read at call time so a
             freshly-provisioned env is picked up without a restart.
  * log    : a callable(msg) for diagnostics. Defaults to a stderr writer so the
             module is usable standalone; importers override it with their own.

stdlib only (native Termux python3; not in the proot, because the watcher tails the
host-side Caddy access log and calls the Cloudflare API directly).
"""
import os
import json
import time
import sys
import urllib.request
import urllib.parse
import urllib.error

# ---- importer-configurable module globals -------------------------------------
# Path to the 0600 cf-honeypot.env (CF_API_TOKEN, CF_ACCOUNT_ID), normally
# ${DATA_DIR}/secrets/cf-honeypot.env. The importer (watcher / admin panel)
# overrides this; the default lets a bare `import cf_actions` still work without
# hardcoding any deployment-specific path.
CF_ENV = os.environ.get("CF_HONEYPOT_ENV", "cf-honeypot.env")

# User-Agent sent on every Cloudflare API call (identifies the honeypot edge layer).
USER_AGENT = "pocket-homeserver-honeypot/1.0"


def log(msg):
    """Default diagnostic sink (stderr). Importers reassign cf_actions.log to route
    these through their own logger so output is identical to the inline original."""
    sys.stderr.write(f"[{time.strftime('%FT%TZ', time.gmtime())}] cf_actions: {msg}\n")
    sys.stderr.flush()


def _load_cf_env():
    """Parse cf-honeypot.env (key=value) → {CF_API_TOKEN, CF_ACCOUNT_ID}.
    Read at block-time so a freshly-provisioned env is picked up without a restart."""
    cfg = {}
    try:
        for ln in open(CF_ENV):
            ln = ln.strip()
            if ln and not ln.startswith("#") and "=" in ln:
                k, v = ln.split("=", 1)
                cfg[k.strip()] = v.strip().strip('"').strip("'")
    except OSError:
        pass
    return cfg


def cf_token_scope_ok(tok, acct):
    """Best-effort startup self-check on the honeypot CF token BEFORE we ever let
    the watcher enter a blocking tier (challenge/block).

    The token in cf-honeypot.env MUST be scoped to exactly
    `Account → Firewall Access Rules → Edit` and nothing else. Cloudflare does not
    expose the calling token's permission *set* directly, so we probe by behaviour:

      1. POSITIVE: `GET /user/tokens/verify` must succeed and report the token
         active/valid (proves it's a real scoped API token, not e.g. a stale or
         global key on the wrong auth header).
      2. NEGATIVE (over-scope tripwire): try a read a *correctly* scoped
         Firewall-Access-Rules-only token must NOT be able to do — list the
         account's zones (`GET /zones?account.id=<acct>`). If that read returns
         ANY zones, the token is broader than it should be → we REFUSE to enable
         blocking. (CF answers 200 with an EMPTY list for a correctly-scoped token
         that lacks Zone:Read, so an empty result == correctly scoped, NOT broad.)

    Returns (ok, reason):
      ok=True  → token verified AND the over-scope tripwire did NOT fire — safe to block.
      ok=False → token broader than expected, or invalid → caller stays alert-only.
    Best-effort: if the verify endpoint itself is unreachable (network/CF down), we
    DO NOT hard-fail — return (True, "verify-unreachable") and let the caller log a
    WARN, because killing alerting over a transient API blip would be worse. The
    over-scope tripwire only downgrades to alert-only when it AFFIRMATIVELY proves
    breadth (a successful broad read), never on a transport error."""
    hdr = {"Authorization": f"Bearer {tok}",
           "User-Agent": USER_AGENT,
           "Content-Type": "application/json"}
    # 1. POSITIVE — token must verify.
    try:
        req = urllib.request.Request(
            "https://api.cloudflare.com/client/v4/user/tokens/verify",
            method="GET", headers=hdr)
        with urllib.request.urlopen(req, timeout=12) as r:
            resp = json.load(r)
        status = ((resp.get("result") or {}).get("status") or "").lower()
        if not (resp.get("success") and status == "active"):
            return (False, f"token not active (status={status or 'unknown'})")
    except urllib.error.HTTPError as e:
        # An explicit auth failure (401/403) is a real, decisive problem.
        if e.code in (401, 403):
            return (False, f"token verify rejected HTTP {e.code}")
        log(f"cf token verify: HTTP {e.code} — treating as unreachable (best-effort)")
        return (True, "verify-unreachable")
    except Exception as e:
        log(f"cf token verify unreachable ({e}) — best-effort, NOT hard-failing")
        return (True, "verify-unreachable")
    # 2. NEGATIVE over-scope tripwire — a Firewall-Access-Rules-only token must not
    #    be able to actually SEE any zones. Cloudflare returns HTTP 200 with an
    #    EMPTY result list (NOT a 403) for a correctly-scoped token lacking
    #    Zone:Read, so we key off whether real zones come back — NOT on `success`
    #    alone (keying on success alone false-rejected a correct token and kept
    #    blocking permanently clamped to alert-only). Over-scoped iff >=1 zone.
    try:
        qs = urllib.parse.urlencode({"account.id": acct, "per_page": 1})
        req = urllib.request.Request(
            f"https://api.cloudflare.com/client/v4/zones?{qs}",
            method="GET", headers=hdr)
        with urllib.request.urlopen(req, timeout=12) as r:
            zresp = json.load(r)
        if zresp.get("success") and (zresp.get("result") or []):
            return (False, "token can list zones — broader than "
                           "'Firewall Access Rules: Edit' (refusing to block)")
    except urllib.error.HTTPError as e:
        # 403/9109-style = correctly DENIED the broad read → exactly what we want.
        return (True, "scoped-ok")
    except Exception as e:
        # Transport blip on the negative probe → don't claim breadth; allow.
        log(f"cf token over-scope probe inconclusive ({e}) — allowing (best-effort)")
        return (True, "probe-inconclusive")
    return (True, "scoped-ok")


def cf_block(ip, tier):
    """Tiered edge action via Cloudflare **IP Access Rules** (free; no WAF custom
    rule / List needed). Gated: no-op (logged) unless cf-honeypot.env supplies a
    token + account id, so mode=alert is provably side-effect-free at the edge.
        tier 'challenge' -> managed_challenge   (humans pass, bots fail; CGNAT-safe)
        tier 'block'     -> block
    A duplicate (IP already actioned) is treated as success. Returns a short
    action tag stored in the ledger (`cf-<mode>:<rule-id|dup>` or `cf-error`)."""
    cfg = _load_cf_env()
    tok, acct = cfg.get("CF_API_TOKEN"), cfg.get("CF_ACCOUNT_ID")
    if not (tok and acct):
        log(f"mode={tier} but {CF_ENV} missing token/account — CF action skipped (alert-only)")
        return "skipped-no-cf-env"
    mode = "managed_challenge" if tier == "challenge" else "block"
    target = "ip6" if ":" in ip else "ip"
    url = (f"https://api.cloudflare.com/client/v4/accounts/{acct}"
           f"/firewall/access_rules/rules")
    data = json.dumps({
        "mode": mode,
        "configuration": {"target": target, "value": ip},
        "notes": f"honeypot-auto {time.strftime('%FT%TZ', time.gmtime())}",
    }).encode()
    req = urllib.request.Request(url, data=data, method="POST", headers={
        "Authorization": f"Bearer {tok}",
        "User-Agent": USER_AGENT,
        "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=12) as r:
            resp = json.load(r)
        if resp.get("success"):
            rid = (resp.get("result") or {}).get("id", "")
            return f"cf-{mode}:{rid}"
        log(f"cf {mode} {ip}: not success — {resp.get('errors')}")
        return "cf-error"
    except urllib.error.HTTPError as e:
        body = e.read().decode()[:200].lower()
        if e.code == 409 or "duplicate" in body or "already" in body:
            return f"cf-{mode}:dup"
        log(f"cf {mode} {ip}: HTTP {e.code} {body}")
        return "cf-error"
    except Exception as e:
        log(f"cf {mode} {ip}: {e}")
        return "cf-error"


def cf_list_rules(tok, acct):
    """List the CF IP Access Rules WE created (notes start 'honeypot-auto'), across
    all pages. Returns a list of {id, ip, notes} dicts. Read-only (GET). Used by
    --reap. The same token scope (Account Firewall Access Rules: Edit) covers GET.
    Returns [] on error (logged) — --reap then reaps nothing rather than guessing."""
    out = []
    page, per_page = 1, 100
    base = (f"https://api.cloudflare.com/client/v4/accounts/{acct}"
            f"/firewall/access_rules/rules")
    while True:
        qs = urllib.parse.urlencode({
            "page": page, "per_page": per_page,
            "notes": "honeypot-auto",            # CF does a contains-match on notes
        })
        req = urllib.request.Request(f"{base}?{qs}", method="GET", headers={
            "Authorization": f"Bearer {tok}",
            "User-Agent": USER_AGENT,
            "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=15) as r:
                resp = json.load(r)
        except Exception as e:
            log(f"cf list rules page {page}: {e}")
            return out
        if not resp.get("success"):
            log(f"cf list rules page {page}: not success — {resp.get('errors')}")
            return out
        results = resp.get("result") or []
        for it in results:
            notes = it.get("notes") or ""
            # belt-and-braces: the notes filter is a contains-match, so re-assert the
            # prefix locally before we ever DELETE — never touch a non-honeypot rule.
            if not notes.startswith("honeypot-auto"):
                continue
            cfg = it.get("configuration") or {}
            out.append({"id": it.get("id", ""),
                        "ip": cfg.get("value", ""),
                        "notes": notes})
        info = resp.get("result_info") or {}
        total_pages = info.get("total_pages") or 1
        if page >= total_pages or not results:
            break
        page += 1
    return out


def cf_delete_rule(tok, acct, rule_id):
    """DELETE one IP Access Rule by id. Returns True on success (or already-gone)."""
    url = (f"https://api.cloudflare.com/client/v4/accounts/{acct}"
           f"/firewall/access_rules/rules/{urllib.parse.quote(rule_id)}")
    req = urllib.request.Request(url, method="DELETE", headers={
        "Authorization": f"Bearer {tok}",
        "User-Agent": USER_AGENT,
        "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            resp = json.load(r)
        return bool(resp.get("success"))
    except urllib.error.HTTPError as e:
        if e.code == 404:                        # already deleted — idempotent OK
            return True
        log(f"cf delete {rule_id}: HTTP {e.code} {e.read().decode()[:200]}")
        return False
    except Exception as e:
        log(f"cf delete {rule_id}: {e}")
        return False


def cf_unblock(tok, acct, ip):
    """Remove every honeypot-auto IP Access Rule that targets `ip`.

    This is the operator's UNDO for cf_block (the admin console's unblock action).
    It is composed entirely from the byte-identical primitives above — cf_list_rules
    (which already filters to notes starting 'honeypot-auto') + cf_delete_rule — and
    re-asserts the 'honeypot-auto' note prefix LOCALLY a second time before each
    DELETE, so it can NEVER remove a rule the honeypot did not create (e.g. an
    operator's own manual block). Only rules whose configuration value EQUALS `ip`
    are touched. Read-then-delete; no rule outside our own honeypot set is in scope.

    Returns (deleted_count, [failed_rule_ids]). A clean unblock = (n, [])."""
    deleted, failed = 0, []
    for r in cf_list_rules(tok, acct):
        if r.get("ip") != ip:
            continue
        if not (r.get("notes") or "").startswith("honeypot-auto"):
            continue                              # belt-and-braces: never our rule
        rid = r.get("id") or ""
        if rid and cf_delete_rule(tok, acct, rid):
            deleted += 1
        elif rid:
            failed.append(rid)
    return deleted, failed
