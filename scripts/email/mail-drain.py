#!/usr/bin/env python3
"""mail-drain.py — pure-pull R2 drainer for pocket-homeserver email.

Termux-native, Python stdlib ONLY (no boto3). Pulls inbound mail that the
Cloudflare Email Worker durably wrote to R2 (pending/<sha>.eml), injects each
message into Maddy over loopback SMTP (AUTH), then moves the object to processed/
and deletes the pending one.

Correctness (see docs/EMAIL.md):
  * flock around each pass            -> no two drainers run at once.
  * ledger row inserted BEFORE inject -> a crash mid-inject can't re-inject a dup;
    INSERT OR IGNORE on a UNIQUE sha is the dedupe gate.
  * Copy(processed/)+Delete(pending/) -> a crash between them is safe: the object
    is re-pulled, the ledger already has it 'done', so inject is skipped and the
    move just finishes (content-addressed key = idempotent).
  * backlog alert                     -> if the oldest pending object is older than
    ALERT_DAYS, run $MAIL_ALERT_CMD (and drop a sentinel) so silent loss before the
    pending-prefix lifecycle deletes the object becomes visible.

Config (env; the installer's launcher exports these from 0600 secrets/config files):
  R2_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET
  INJECT_HOST(127.0.0.1) INJECT_PORT(9125) INJECT_USER INJECT_PASS
  INJECT_MAIL_FROM(ingest@${MAIL_DOMAIN}) INJECT_RCPT(inbox@${MAIL_DOMAIN})
  MAIL_DOMAIN MAIL_USERS_FILE MAIL_ADMIN_LOCALPART(admin)
  MADDY_DIR(/opt/maddy) MADDY_CONFIG(/opt/maddy/maddy.conf) PROOT_DISTRO(debian)
  LEDGER_DB LOCKFILE POLL_INTERVAL(180) ALERT_DAYS(3) MAIL_ALERT_CMD(optional)
  USER_AGENT(pocket-mail-drain/1)
  ONESHOT(set to drain once and exit; default loop forever)
"""
import os, re, sys, time, hmac, hashlib, sqlite3, smtplib, subprocess, datetime
import urllib.request, urllib.error, urllib.parse, fcntl, errno
import xml.etree.ElementTree as ET

# ----- config -----
ACCOUNT   = os.environ["R2_ACCOUNT_ID"]
AKID      = os.environ["R2_ACCESS_KEY_ID"]
SECRET    = os.environ["R2_SECRET_ACCESS_KEY"]
BUCKET    = os.environ.get("R2_BUCKET", "pocket-mail-inbound")
HOST      = f"{ACCOUNT}.r2.cloudflarestorage.com"
ENDPOINT  = f"https://{HOST}"
REGION    = "auto"          # R2 SigV4 region
SERVICE   = "s3"

# Mail domain used to build per-user mailbox addresses + the default aliases.
MAIL_DOMAIN = os.environ.get("MAIL_DOMAIN", "mail.example.com")

INJECT_HOST = os.environ.get("INJECT_HOST", "127.0.0.1")
INJECT_PORT = int(os.environ.get("INJECT_PORT", "9125"))
INJECT_USER = os.environ.get("INJECT_USER", "")
INJECT_PASS = os.environ.get("INJECT_PASS", "")
MAIL_FROM   = os.environ.get("INJECT_MAIL_FROM", f"ingest@{MAIL_DOMAIN}")
RCPT        = os.environ.get("INJECT_RCPT", f"inbox@{MAIL_DOMAIN}")

# State lives under the large volume's state dir so it survives a rootfs rebuild.
# DATA_DIR is exported by the launcher; STATE_DIR derives from it (POCKET_STATE_DIR).
DATA_DIR    = os.environ.get("DATA_DIR", os.path.expanduser("~/.pocket"))
STATE_DIR   = os.environ.get("POCKET_STATE_DIR", os.path.join(DATA_DIR, "state"))
# Multi-user inbound routing: deliver each message to <recipient-localpart>@MAIL_DOMAIN
# IF that localpart is provisioned (listed in MAIL_USERS_FILE, optionally seeded by
# the operator); otherwise fall back to the catch-all RCPT (inbox@). The recipient
# comes from the CF Worker, which records message.to in the R2 object's
# customMetadata (x-amz-meta-to on GET) — so no Worker change is needed. The
# localpart is canonicalised consistently so the membership set + the delivered
# mailbox name line up exactly.
USERS_FILE  = os.environ.get("MAIL_USERS_FILE", os.path.join(STATE_DIR, "mail-users.txt"))
# The authoritative "which mailboxes exist" set is Maddy itself: each pass we ask
# `maddy imap-acct list` (in the same proot the server runs in) and union it with
# USERS_FILE. That way a mailbox provisioned out of band routes to its own box with
# no file to keep in sync. Best-effort: any failure falls back to file + catch-all.
MADDY_DIR    = os.environ.get("MADDY_DIR", "/opt/maddy")
MADDY_CONFIG = os.environ.get("MADDY_CONFIG", "/opt/maddy/maddy.conf")
PROOT_DISTRO = os.environ.get("PROOT_DISTRO", "debian")
LEDGER_DB   = os.environ.get("LEDGER_DB", os.path.join(STATE_DIR, "mail-drain-ledger.db"))
# flock() is ENOSYS on an exFAT SD card -> the single-instance lock MUST live on an
# ext4 fs (Termux $TMPDIR / $PREFIX/tmp) or EVERY drain pass self-skips and no mail
# ever drains. The ledger above stays on the large volume (survives a chroot wipe);
# only this ephemeral guard moves to ext4.
_LOCK_DEFAULT = os.path.join(os.environ.get("TMPDIR", "/tmp"), "pocket-mail-drain.lock")
LOCKFILE    = os.environ.get("LOCKFILE", _LOCK_DEFAULT)
ALERT_SENT  = os.path.join(STATE_DIR, "mail-drain-ALERT")
POLL        = int(os.environ.get("POLL_INTERVAL", "180"))
ALERT_DAYS  = float(os.environ.get("ALERT_DAYS", "3"))
ALERT_CMD   = os.environ.get("MAIL_ALERT_CMD", "")
ONESHOT     = bool(os.environ.get("ONESHOT", ""))
UA          = os.environ.get("USER_AGENT", "pocket-mail-drain/1")
EMPTY_SHA   = hashlib.sha256(b"").hexdigest()

S3NS = "{http://s3.amazonaws.com/doc/2006-03-01/}"


def log(*a):
    print(f"[{datetime.datetime.utcnow().isoformat()}Z]", *a, flush=True)


# ----- SigV4 (pure stdlib) -----
def _quote(s, safe):
    return urllib.parse.quote(s, safe=safe)

def _sign(key, msg):
    return hmac.new(key, msg.encode(), hashlib.sha256).digest()

def s3_request(method, key="", query=None, extra_headers=None, expect_body=True):
    """Signed S3 request. `key` is the object key (path-style: /<bucket>/<key>).
    All our calls have an empty body, so the payload hash is the empty-string hash.

    SECURITY: standard AWS SigV4 — canonical request (method, canon path, sorted
    canonical query, sorted canonical headers, signed-header list, payload hash),
    string-to-sign, and the date->region->service->aws4_request signing-key chain.
    The R2 secret access key flows ONLY through the HMAC chain (_sign); it is never
    logged and never placed on argv (it comes from the child env via the launcher).
    """
    query = query or {}
    extra_headers = extra_headers or {}
    now = datetime.datetime.utcnow()
    amzdate = now.strftime("%Y%m%dT%H%M%SZ")
    datestamp = now.strftime("%Y%m%d")

    canon_path = "/" + BUCKET + ("/" + _quote(key, "/~-._") if key else "")
    if not key:
        canon_path = "/" + BUCKET
    # canonical query string: sorted, each key/value RFC3986-encoded
    items = sorted((k, v) for k, v in query.items())
    canon_qs = "&".join(f"{_quote(k,'~-._')}={_quote(str(v),'~-._')}" for k, v in items)

    headers = {
        "host": HOST,
        "x-amz-content-sha256": EMPTY_SHA,
        "x-amz-date": amzdate,
    }
    for k, v in extra_headers.items():
        headers[k.lower()] = v
    signed_names = ";".join(sorted(headers))
    canon_headers = "".join(f"{k}:{headers[k].strip()}\n" for k in sorted(headers))

    canon_req = "\n".join([method, canon_path, canon_qs, canon_headers, signed_names, EMPTY_SHA])
    scope = f"{datestamp}/{REGION}/{SERVICE}/aws4_request"
    sts = "\n".join(["AWS4-HMAC-SHA256", amzdate, scope,
                     hashlib.sha256(canon_req.encode()).hexdigest()])
    kDate = _sign(("AWS4" + SECRET).encode(), datestamp)
    kRegion = _sign(kDate, REGION)
    kService = _sign(kRegion, SERVICE)
    kSigning = _sign(kService, "aws4_request")
    sig = hmac.new(kSigning, sts.encode(), hashlib.sha256).hexdigest()
    auth = (f"AWS4-HMAC-SHA256 Credential={AKID}/{scope}, "
            f"SignedHeaders={signed_names}, Signature={sig}")

    url = ENDPOINT + canon_path + (("?" + canon_qs) if canon_qs else "")
    req = urllib.request.Request(url, method=method)
    req.add_header("Authorization", auth)
    req.add_header("User-Agent", UA)
    for k, v in headers.items():
        if k != "host":
            req.add_header(k, v)
    with urllib.request.urlopen(req, timeout=40) as resp:
        body = resp.read() if expect_body else b""
        # resp.headers (HTTPMessage) is parsed before the body and stays valid after
        # the context closes; .get() is case-insensitive (x-amz-meta-* lookups).
        return resp.status, body, resp.headers


def list_pending():
    """Return [(key, last_modified_epoch), ...] under pending/, paginated."""
    out, tok = [], None
    while True:
        q = {"list-type": "2", "prefix": "pending/", "max-keys": "1000"}
        if tok:
            q["continuation-token"] = tok
        status, body, _ = s3_request("GET", "", query=q)
        root = ET.fromstring(body)
        for c in root.findall(f"{S3NS}Contents"):
            k = c.findtext(f"{S3NS}Key")
            lm = c.findtext(f"{S3NS}LastModified") or ""
            epoch = 0
            try:
                epoch = datetime.datetime.strptime(
                    lm, "%Y-%m-%dT%H:%M:%S.%fZ").replace(
                    tzinfo=datetime.timezone.utc).timestamp()
            except ValueError:
                pass
            if k and k.endswith(".eml"):
                out.append((k, epoch))
        if (root.findtext(f"{S3NS}IsTruncated") or "false") == "true":
            tok = root.findtext(f"{S3NS}NextContinuationToken")
        else:
            break
    return out


def get_object(key):
    """Return (raw_bytes, recipient_address). The recipient is the CF Worker's
    message.to stored in R2 customMetadata (x-amz-meta-to); '' if absent."""
    _, body, hdrs = s3_request("GET", key)
    to = (hdrs.get("x-amz-meta-to") or "").strip()
    return body, to

def copy_object(src_key, dst_key):
    # x-amz-copy-source must be /<bucket>/<key>, URI-encoded. MetadataDirective=COPY
    # so processed/ keeps customMetadata.
    src = "/" + BUCKET + "/" + _quote(src_key, "/~-._")
    s3_request("PUT", dst_key, extra_headers={
        "x-amz-copy-source": src,
        "x-amz-metadata-directive": "COPY",
    }, expect_body=False)

def delete_object(key):
    s3_request("DELETE", key, expect_body=False)


# ----- ledger (sqlite; the dedupe authority) -----
def ledger():
    db = sqlite3.connect(LEDGER_DB, timeout=10)
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("CREATE TABLE IF NOT EXISTS seen "
               "(sha TEXT PRIMARY KEY, status TEXT, ts INTEGER)")
    db.commit()
    return db

def claim(db, sha):
    """Insert <sha> as 'injecting' iff absent. Return True if WE claimed it (must
    inject), False if it already exists in any state (skip inject, just finish move)."""
    cur = db.execute("INSERT OR IGNORE INTO seen(sha,status,ts) VALUES(?, 'injecting', ?)",
                     (sha, int(time.time())))
    db.commit()
    return cur.rowcount == 1

def mark_done(db, sha):
    db.execute("UPDATE seen SET status='done', ts=? WHERE sha=?", (int(time.time()), sha))
    db.commit()

def unclaim(db, sha):
    db.execute("DELETE FROM seen WHERE sha=? AND status='injecting'", (sha,))
    db.commit()


# ----- multi-user routing (recipient localpart -> provisioned mailbox) -----
_CANON_DROP = re.compile(r"[^a-z0-9._-]+")

def canon_localpart(lp):
    """Canonicalise an email localpart (lowercase, drop disallowed chars, collapse
    runs of dots, strip leading/trailing separators). An unparseable localpart
    returns '' so it hits the catch-all."""
    s = _CANON_DROP.sub("", lp.lower())
    return re.sub(r"\.{2,}", ".", s).strip(".-_")

_MADDY_ADDR_RE = re.compile(r"([a-z0-9._+-]+)@" + re.escape(MAIL_DOMAIN), re.I)

def maddy_users():
    """Canonical localparts of the Maddy imapsql accounts that actually exist (the
    authoritative 'which mailboxes can receive' set — an inject-only credential
    like `ingest@` has creds but no mailbox, so it's correctly absent). Runs the
    Maddy CLI inside the same proot the server uses. Best-effort: any failure (proot
    slow/absent, maddy down, timeout) returns an empty set and routing falls back to
    USERS_FILE + the catch-all."""
    try:
        cmd = ["proot-distro", "login", PROOT_DISTRO, "--", "bash", "-lc",
               f"cd {MADDY_DIR} && MADDY_CONFIG={MADDY_CONFIG} ./maddy imap-acct list 2>/dev/null"]
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=30).stdout
    except Exception as e:
        log("maddy_users: imap-acct list failed -", e)
        return set()
    users = set()
    for line in out.splitlines():
        m = _MADDY_ADDR_RE.search(line.strip())
        if m:
            lp = canon_localpart(m.group(1))
            if lp:
                users.add(lp)
    return users

def load_users():
    """Provisioned canonical localparts. Union of the live Maddy account list (the
    source of truth) and the optional USERS_FILE (operator pre-seeding / back-compat).
    Re-read each pass so newly provisioned users route correctly without restarting
    the drain."""
    users = maddy_users()
    try:
        with open(USERS_FILE) as f:
            users |= set(l.strip() for l in f if l.strip())
    except FileNotFoundError:
        pass
    return users

# Role/admin addresses (RFC 2142 + the DMARC rua) all funnel to the admin mailbox,
# so server/admin mail and DMARC aggregate reports land in one place the operator
# controls. Only takes effect if the admin mailbox is actually provisioned (else
# they fall through to the per-user / catch-all path). `admin@` itself routes
# naturally (it's a real account).
ADMIN_LOCALPART = canon_localpart(os.environ.get("MAIL_ADMIN_LOCALPART", "admin"))
ROLE_ALIASES = {canon_localpart(x) for x in
                ("postmaster", "abuse", "hostmaster", "webmaster", "security", "dmarc", "root")}

def route_rcpt(to_addr, users):
    """Original recipient -> provisioned per-user mailbox, else catch-all RCPT (inbox@).
    Role addresses (postmaster@, abuse@, dmarc@, ...) funnel to the admin mailbox when
    it's provisioned."""
    addr = (to_addr or "").strip().lower()
    if "@" in addr:
        lp = canon_localpart(addr.split("@", 1)[0])
        if lp in ROLE_ALIASES and ADMIN_LOCALPART in users:
            return f"{ADMIN_LOCALPART}@{MAIL_DOMAIN}"
        if lp and lp in users:
            return f"{lp}@{MAIL_DOMAIN}"
    return RCPT


# ----- inject over loopback SMTP (AUTH) -----
def inject(raw, rcpt):
    """Inject one raw RFC822 message into Maddy over the loopback inject endpoint.

    SECURITY: SMTP AUTH with the inject credential (INJECT_USER/INJECT_PASS), which
    is read ONLY from the child env (sourced from the 0600 secrets file by the
    launcher — never on argv). STARTTLS is used when the endpoint offers it. A failed
    login or send raises, so the caller leaves the object in pending/ and retries on
    the next pass — a message is never delivered unauthenticated.
    """
    s = smtplib.SMTP(INJECT_HOST, INJECT_PORT, timeout=40)
    try:
        s.ehlo()
        if s.has_extn("starttls"):
            s.starttls(); s.ehlo()
        if INJECT_USER:
            s.login(INJECT_USER, INJECT_PASS)
        s.sendmail(MAIL_FROM, [rcpt], raw)   # raw bytes sent verbatim
        return True
    finally:
        try: s.quit()
        except Exception: pass


# ----- backlog alert -----
def check_backlog(pending):
    if not pending:
        if os.path.exists(ALERT_SENT):
            os.remove(ALERT_SENT)   # cleared
        return
    oldest = min(ep for _, ep in pending if ep) if any(ep for _, ep in pending) else 0
    age_days = (time.time() - oldest) / 86400 if oldest else 0
    if age_days >= ALERT_DAYS and not os.path.exists(ALERT_SENT):
        msg = (f"mail backend backlog: {len(pending)} message(s) stuck in R2 pending/, "
               f"oldest {age_days:.1f}d old.")
        log("ALERT:", msg)
        open(ALERT_SENT, "w").write(msg)
        if ALERT_CMD:
            try:
                subprocess.run(ALERT_CMD, shell=True, env={**os.environ, "MAIL_ALERT_MSG": msg},
                               timeout=30)
            except Exception as e:
                log("alert cmd failed:", e)


# ----- one drain pass (single-instance via flock) -----
def drain_pass():
    lock = open(LOCKFILE, "w")
    have_lock = True
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as e:
        if e.errno == errno.ENOSYS:
            # lock fs doesn't support flock (e.g. exFAT) — the supervisor already
            # guarantees one drainer, so proceed WITHOUT the belt-and-suspenders.
            log("flock unsupported on lock fs (ENOSYS) — proceeding without it")
            have_lock = False
        else:
            log("another drain pass holds the lock — skipping")
            return
    try:
        db = ledger()
        try:
            pending = list_pending()
        except (urllib.error.URLError, urllib.error.HTTPError, ET.ParseError) as e:
            log("LIST failed (offline?):", e); return
        check_backlog(pending)
        users = load_users()
        for key, _ in pending:
            sha = key[len("pending/"):-len(".eml")]
            if claim(db, sha):
                # we own this sha -> must inject
                try:
                    raw, to_addr = get_object(key)
                except Exception as e:
                    log("GET failed for", key, "-", e); unclaim(db, sha); continue
                rcpt = route_rcpt(to_addr, users)
                try:
                    inject(raw, rcpt)
                except Exception as e:
                    log("INJECT failed for", sha, "-", e)
                    unclaim(db, sha)   # leave object in pending/, retry next pass
                    continue
                mark_done(db, sha)
                log("injected", sha, "->", rcpt, f"(to={to_addr or '?'})")
            # whether we just injected or it was already done, finish the R2 move
            try:
                copy_object(key, f"processed/{sha}.eml")
                delete_object(key)
            except Exception as e:
                log("move failed for", sha, "- will retry next pass:", e)
        db.close()
    finally:
        if have_lock:
            fcntl.flock(lock, fcntl.LOCK_UN)
        lock.close()


def main():
    os.makedirs(os.path.dirname(LEDGER_DB), exist_ok=True)
    log(f"mail-drain start bucket={BUCKET} inject={INJECT_HOST}:{INJECT_PORT} poll={POLL}s")
    if ONESHOT:
        drain_pass(); return
    while True:
        try:
            drain_pass()
        except Exception as e:
            log("drain pass error:", e)
        time.sleep(POLL)


if __name__ == "__main__":
    main()
