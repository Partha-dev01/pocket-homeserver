#!/usr/bin/env python3
"""analytics.py — parse-on-demand traffic stats for Pocket Pages sites
(SPEC-DIFFERENTIATORS.md §9, AD-10/AD-11/AD-12).

Reads the ONE shared JSON access log the sites wildcard vhost writes when
ENABLE_SITES_ANALYTICS=true (rendered by scripts/apps/sites.sh), attributing
lines to sites by request.host at read time. No daemon, no derived database,
no persistent state of any kind (AD-10) — the admin panel calls aggregate()
on a cache-miss and keeps the result in its usual TTL dict.

Privacy (AD-12): the approximate-unique-visitor count is the cardinality of a
truncated-IP set built fresh per aggregation pass and discarded with the
call frame — nothing IP-shaped is ever written to disk by this module, which
is stricter than forms' posture (forms persist a truncated abuse key; a page
view is passive, so analytics never needs a per-visitor record at all).

Also runnable standalone:  python3 analytics.py --log-dir D --domain example.com [--site S] [--days N]
"""

import argparse
import glob
import gzip
import ipaddress
import json
import os
import re
import time

# SUB_RE, scripts/sites/lib-sites.sh:43 — a log line whose host does not parse
# to a valid site label (scanner junk, malformed Host headers) is silently
# skipped, never attributed to a site.
SITE_SUB_RE = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")

TOP_PATHS = 20


def parse_line(line):
    """Byte-for-byte the field extraction scripts/honeypot/honeypot-watcher.py
    :469-507 already proves against this repo's production Caddy output —
    duplicated, not imported: scripts/honeypot/ and scripts/sites/ are
    independent, independently-enabled modules and this repo has no shared
    package between app modules (the same accepted trade-off as
    RESERVED_SUBS' three-way copy, SPEC-MCP-COMPLETION AD-3)."""
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

    cf_ip = (_first("Cf-Connecting-IP") or "").strip()
    ip = cf_ip or req.get("client_ip") or req.get("remote_ip") or ""
    return {
        "ip":     ip,
        "host":   req.get("host", ""),
        "uri":    uri,
        "method": req.get("method", ""),
        "status": d.get("status", 0),
        "size":   d.get("size"),
        "log_ts": d.get("ts", 0),
    }


def _truncate_ip(ip):
    """AD-12 — same /24 (v4) / /48 (v6) granularity as forms_db.truncate_ip,
    but the result only ever lives in an in-memory set for one pass."""
    ip = (ip or "").strip()
    if not ip:
        return ""
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return ""
    bits = 24 if addr.version == 4 else 48
    return str(ipaddress.ip_network(f"{addr}/{bits}", strict=False).network_address)


def iter_log_lines(log_dir, retention_days):
    """Yield lines from sites-access.log + its rotated companions (.gz-aware,
    honeypot-watcher's own --scan-history handling), newest-file-last, with
    files older than the retention window skipped by mtime. AD-11: this is a
    SELECTION filter over what rotation physically kept — it cannot
    manufacture history Caddy already rotated away. A corrupt/truncated .gz
    is skipped, never fatal."""
    cutoff = time.time() - retention_days * 86400
    paths = sorted(
        glob.glob(os.path.join(log_dir, "sites-access*.log")) +
        glob.glob(os.path.join(log_dir, "sites-access*.log.gz")),
        key=lambda p: os.path.getmtime(p) if os.path.exists(p) else 0)
    for p in paths:
        try:
            if os.path.getmtime(p) < cutoff:
                continue
            opener = gzip.open if p.endswith(".gz") else open
            with opener(p, "rt", errors="replace") as f:
                yield from f
        except OSError:
            continue
        except EOFError:
            continue


def aggregate(lines, domain, max_lines=200000):
    """Bucket parsed lines per site label. Returns
    {"sites": {label: {...}}, "truncated": bool, "lines_seen": int}."""
    suffix = "." + domain.lower()
    sites = {}
    uniq = {}
    truncated = False
    seen = 0
    for line in lines:
        seen += 1
        if seen > max_lines:
            # Signaled, never silent (§9.5) — the caller renders the partial
            # marker instead of under-reporting quietly.
            truncated = True
            break
        ev = parse_line(line)
        if ev is None:
            continue
        host = (ev["host"] or "").lower().split(":", 1)[0]
        if not host.endswith(suffix):
            continue
        label = host[:-len(suffix)]
        if not SITE_SUB_RE.fullmatch(label):
            continue
        s = sites.setdefault(label, {
            "requests": 0, "status_2xx": 0, "status_3xx": 0,
            "status_4xx": 0, "status_5xx": 0, "bytes_hint": 0,
            "paths": {},
        })
        s["requests"] += 1
        status = ev["status"] or 0
        if 200 <= status < 300:
            s["status_2xx"] += 1
        elif 300 <= status < 400:
            s["status_3xx"] += 1
        elif 400 <= status < 500:
            s["status_4xx"] += 1
        elif status >= 500:
            s["status_5xx"] += 1
        # `size` is NOT independently confirmed against this repo's pinned
        # Caddy (§16) — best-effort, degrades to 0 when absent, never errors.
        if isinstance(ev.get("size"), (int, float)):
            s["bytes_hint"] += int(ev["size"])
        # Path only, query string dropped — a query string is where accidental
        # PII (tokens, search terms, emails) lands (§9.3).
        path = ev["uri"].split("?", 1)[0][:200]
        s["paths"][path] = s["paths"].get(path, 0) + 1
        t = _truncate_ip(ev["ip"])
        if t:
            uniq.setdefault(label, set()).add(t)
    for label, s in sites.items():
        s["top_paths"] = sorted(
            s.pop("paths").items(), key=lambda kv: (-kv[1], kv[0]))[:TOP_PATHS]
        s["approx_unique_visitors"] = len(uniq.get(label, ()))
    # The truncated-IP sets die here with the call frame (AD-12).
    return {"sites": sites, "truncated": truncated, "lines_seen": seen}


def main():
    ap = argparse.ArgumentParser(description="Pocket Pages analytics-lite")
    ap.add_argument("--log-dir", required=True)
    ap.add_argument("--domain", required=True)
    ap.add_argument("--site", default=None)
    ap.add_argument("--days", type=int, default=30)
    ap.add_argument("--max-lines", type=int, default=200000)
    args = ap.parse_args()
    agg = aggregate(iter_log_lines(args.log_dir, args.days), args.domain,
                    max_lines=args.max_lines)
    if args.site:
        agg = {"sites": {args.site: agg["sites"].get(args.site, {})},
               "truncated": agg["truncated"], "lines_seen": agg["lines_seen"]}
    print(json.dumps(agg, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
