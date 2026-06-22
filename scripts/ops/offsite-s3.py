#!/usr/bin/env python3
"""offsite-s3.py — minimal, dependency-free S3-compatible client (AWS SigV4) used
by ops/offsite-push.sh to copy ENCRYPTED backups off the phone.

Subcommands (path-style addressing; works with Cloudflare R2, Backblaze B2's S3
API, AWS S3, Wasabi, MinIO):
    put <localfile> <key>     upload a file (streamed; payload-hash signed)
    head <key>                exit 0 if the object exists, 3 if 404
    delete <key>              delete an object
    list [prefix]             print one key per line

Config comes from the ENVIRONMENT only (ops/offsite-push.sh exports it from a 0600
secrets file — never on argv, never logged):
    S3_ENDPOINT            https://<...>           (HTTPS required)
    S3_BUCKET              bucket name
    S3_REGION              region (default 'auto'; R2 uses 'auto', AWS needs real)
    S3_ACCESS_KEY_ID       access key id
    S3_SECRET_ACCESS_KEY   secret access key

The secret flows ONLY through the HMAC signing chain — it is never placed in a URL,
a header value other than the derived signature, on argv, or in any log line. This
mirrors the proven SigV4 implementation in scripts/email/mail-drain.py.

Generalized from a working deployment; review before running on a fresh phone.
"""
import datetime
import hashlib
import hmac
import os
import re
import sys
import urllib.parse
import urllib.request
import urllib.error

ENDPOINT = (os.environ.get("S3_ENDPOINT") or "").rstrip("/")
BUCKET = os.environ.get("S3_BUCKET") or ""
REGION = os.environ.get("S3_REGION") or "auto"
AKID = os.environ.get("S3_ACCESS_KEY_ID") or ""
SECRET = os.environ.get("S3_SECRET_ACCESS_KEY") or ""
SERVICE = "s3"
UA = "pocket-offsite/1"
EMPTY_SHA = hashlib.sha256(b"").hexdigest()
# S3 single-PUT objects must be < 5 GiB (multipart is intentionally not implemented
# — see docs/BACKUPS.md "offsite"); guard so a too-large file fails loudly.
MAX_PUT = 5 * 1024 * 1024 * 1024


def _die(msg, code=2):
    print(f"offsite-s3: {msg}", file=sys.stderr)
    sys.exit(code)


def _check_cfg():
    if not ENDPOINT.startswith("https://"):
        _die("S3_ENDPOINT must be set and HTTPS")
    for name, val in (("S3_BUCKET", BUCKET), ("S3_ACCESS_KEY_ID", AKID),
                      ("S3_SECRET_ACCESS_KEY", SECRET)):
        if not val:
            _die(f"{name} is not set")


HOST = urllib.parse.urlparse(ENDPOINT).netloc if ENDPOINT else ""


def _quote(s, safe):
    return urllib.parse.quote(s, safe=safe)


def _sign(key, msg):
    return hmac.new(key, msg.encode(), hashlib.sha256).digest()


def _file_sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def _request(method, key="", query=None, payload_sha=EMPTY_SHA,
             extra_headers=None, data=None, data_len=None, expect_body=True):
    """One SigV4-signed S3 request. `payload_sha` is the hex sha256 of the body
    (EMPTY_SHA for bodyless calls)."""
    query = query or {}
    extra_headers = extra_headers or {}
    now = datetime.datetime.utcnow()
    amzdate = now.strftime("%Y%m%dT%H%M%SZ")
    datestamp = now.strftime("%Y%m%d")

    canon_path = "/" + BUCKET + ("/" + _quote(key, "/~-._") if key else "")
    items = sorted((k, v) for k, v in query.items())
    canon_qs = "&".join(f"{_quote(k, '~-._')}={_quote(str(v), '~-._')}" for k, v in items)

    headers = {
        "host": HOST,
        "x-amz-content-sha256": payload_sha,
        "x-amz-date": amzdate,
    }
    for k, v in extra_headers.items():
        headers[k.lower()] = v
    signed_names = ";".join(sorted(headers))
    canon_headers = "".join(f"{k}:{headers[k].strip()}\n" for k in sorted(headers))

    canon_req = "\n".join([method, canon_path, canon_qs, canon_headers,
                           signed_names, payload_sha])
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
    req = urllib.request.Request(url, method=method, data=data)
    req.add_header("Authorization", auth)
    req.add_header("User-Agent", UA)
    if data_len is not None:
        req.add_header("Content-Length", str(data_len))
    for k, v in headers.items():
        if k != "host":
            req.add_header(k, v)
    with urllib.request.urlopen(req, timeout=120) as resp:
        body = resp.read() if expect_body else b""
        return resp.status, body


def cmd_put(localfile, key):
    if not os.path.isfile(localfile):
        _die(f"no such file: {localfile}")
    size = os.path.getsize(localfile)
    if size >= MAX_PUT:
        _die(f"{localfile} is {size} bytes (>= 5 GiB single-PUT limit); "
             f"multipart is not implemented — see docs/BACKUPS.md", code=4)
    sha = _file_sha256(localfile)
    with open(localfile, "rb") as f:
        status, _ = _request("PUT", key, payload_sha=sha, data=f, data_len=size,
                             extra_headers={"content-type": "application/octet-stream"},
                             expect_body=False)
    print(f"put {key} ({size} bytes) -> {status}")
    return 0 if status in (200, 201) else 1


def cmd_head(key):
    try:
        status, _ = _request("HEAD", key, expect_body=False)
        return 0 if status == 200 else 3
    except urllib.error.HTTPError as ex:
        if ex.code == 404:
            return 3
        raise


def cmd_delete(key):
    status, _ = _request("DELETE", key, expect_body=False)
    print(f"delete {key} -> {status}")
    return 0 if status in (200, 204) else 1


def cmd_list(prefix=""):
    query = {"list-type": "2"}
    if prefix:
        query["prefix"] = prefix
    status, body = _request("GET", "", query=query)
    if status != 200:
        _die(f"list failed: HTTP {status}", code=1)
    for m in re.finditer(r"<Key>([^<]+)</Key>", body.decode("utf-8", "replace")):
        print(m.group(1))
    return 0


def main(argv):
    if len(argv) < 2:
        _die("usage: offsite-s3.py {put <file> <key>|head <key>|delete <key>|list [prefix]}")
    _check_cfg()
    op = argv[1]
    try:
        if op == "put" and len(argv) == 4:
            return cmd_put(argv[2], argv[3])
        if op == "head" and len(argv) == 3:
            return cmd_head(argv[2])
        if op == "delete" and len(argv) == 3:
            return cmd_delete(argv[2])
        if op == "list":
            return cmd_list(argv[2] if len(argv) > 2 else "")
    except urllib.error.HTTPError as ex:
        _die(f"HTTP {ex.code} on {op}: {ex.reason}", code=1)
    except urllib.error.URLError as ex:
        _die(f"network error on {op}: {ex.reason}", code=1)
    _die(f"bad usage for '{op}'")


if __name__ == "__main__":
    sys.exit(main(sys.argv))
