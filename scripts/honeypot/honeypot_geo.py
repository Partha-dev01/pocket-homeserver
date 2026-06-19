#!/usr/bin/env python3
"""Offline geo / ASN enrichment for the honeypot watcher (additive, optional).

Stdlib only (native Termux python3; NO pip). A CGNAT phone cannot do live IP-intel
lookups: outbound HTTPS is often firewalled/metered. So all enrichment is computed
OFFLINE from the FREE DB-IP *lite* datasets (CC-BY 4.0):

    https://download.db-ip.com/free/dbip-country-lite-<YYYY-MM>.csv.gz
    https://download.db-ip.com/free/dbip-asn-lite-<YYYY-MM>.csv.gz

  Country CSV : start_ip,end_ip,country_code            (3 cols; CC = ISO-3166-1)
  ASN     CSV : start_ip,end_ip,asn_number,"Org Name"   (4 cols; org may contain ,)

Ranges are given as text IP addresses and cover BOTH IPv4 and IPv6. Each range is
stored as (int(start), int(end), value) using int(ipaddress.ip_address(x)); IPv4
and IPv6 live in SEPARATE sorted lists (sorted by start) so a single bisect on the
range-start array gives O(log n) containment lookup.

pocket-homeserver ships NO geo dataset by default. With no dataset deployed this
module is a strict no-op: load_geo() still returns a db whose lookup() yields {}
for every ip, and nothing ever raises.

PUBLIC API
  load_geo(country_gz_path, asn_gz_path) -> a _GeoDB (lazy build; cached per-path)
  lookup(ip) -> {"country","asn","as_org","hosting"}  or  {} when not found / no DB

DESIGN CONTRACT (so the watcher stays a strict no-op without the dataset):
  * Missing / unreadable files ⇒ load_geo() still returns a _GeoDB whose lookup()
    yields {} for every ip. No exception ever escapes load/lookup.
  * Empty / absent dataset dir ⇒ the watcher should not call load_geo at all, but
    even if it does with bogus paths the result is the same {} no-op.
  * Loading is lazy (first lookup triggers the build) and cached, so importing this
    module is free and a long-running watcher pays the parse cost once.

DB-IP attribution (REQUIRED by the CC-BY 4.0 licence — keep this line):
    IP Geolocation by DB-IP (https://db-ip.com) — used under CC-BY 4.0.
"""
import os
import csv
import gzip
import bisect
import ipaddress
import threading

# ---------------------------------------------------------------------------
# "hosting" / datacenter heuristic. A datacenter/cloud ASN on a *scanner* hit is a
# far stronger signal than a residential one (real humans rarely port-scan from a
# fleet VM). We derive it purely from the AS org name — substring (word-ish) match,
# case-insensitive. Kept intentionally broad-but-conservative: every token below is
# a well-known hosting/cloud/VPS/colo brand or a generic hosting noun. This NEVER
# feeds classification or blocking — it's an advisory flag on the alert/ledger only.
_HOSTING_TOKENS = (
    "amazon", "aws", "google", "microsoft", "azure", "digitalocean", "ovh",
    "hetzner", "linode", "vultr", "leaseweb", "cloudflare", "oracle", "alibaba",
    "tencent", "contabo", "scaleway", "choopa", "datacamp", "m247", "colo",
    "hosting", "server", "vps", "cloud",
)


def _is_hosting(as_org):
    if not as_org:
        return False
    low = as_org.lower()
    return any(tok in low for tok in _HOSTING_TOKENS)


def _ip_to_int(s):
    """int(ipaddress.ip_address(s)) with a (4|6) family tag, or (None, None)."""
    try:
        a = ipaddress.ip_address(s.strip())
    except (ValueError, AttributeError):
        return None, None
    return int(a), a.version


class _GeoDB:
    """Holds the parsed lookup tables. Build is lazy + guarded by a lock so the
    watcher's first lookup builds once; subsequent lookups are pure bisects.

    Per family we keep three parallel arrays (so bisect on `starts` works):
        starts[i]  = range start as int  (ascending, non-overlapping in DB-IP data)
        ends[i]    = range end as int
        vals[i]    = the value tuple for the range
    Country vals = "CC". ASN vals = ("AS####", "Org Name", hosting_bool)."""

    def __init__(self, country_gz_path, asn_gz_path):
        self._country_path = country_gz_path
        self._asn_path = asn_gz_path
        self._lock = threading.Lock()
        self._built = False
        # family -> (starts, ends, vals)
        self._country = {4: ([], [], []), 6: ([], [], [])}
        self._asn = {4: ([], [], []), 6: ([], [], [])}

    # -- build -------------------------------------------------------------
    def _build(self):
        if self._built:
            return
        with self._lock:
            if self._built:               # double-checked under the lock
                return
            self._load_country(self._country_path)
            self._load_asn(self._asn_path)
            # DB-IP ships rows in ascending start order already, but never trust the
            # file — sort each family by start so bisect is correct regardless.
            for tbl in (self._country, self._asn):
                for fam in (4, 6):
                    starts, ends, vals = tbl[fam]
                    if starts:
                        order = sorted(range(len(starts)), key=starts.__getitem__)
                        tbl[fam] = ([starts[i] for i in order],
                                    [ends[i] for i in order],
                                    [vals[i] for i in order])
            self._built = True

    def _load_country(self, path):
        if not path or not os.path.exists(path):
            return
        try:
            with gzip.open(path, "rt", encoding="utf-8", errors="replace",
                           newline="") as fh:
                for row in csv.reader(fh):
                    if len(row) < 3:
                        continue
                    s, fam = _ip_to_int(row[0])
                    if s is None:
                        continue
                    e, _ = _ip_to_int(row[1])
                    if e is None:
                        continue
                    cc = (row[2] or "").strip().upper()
                    if not cc:
                        continue
                    starts, ends, vals = self._country[fam]
                    starts.append(s)
                    ends.append(e)
                    vals.append(cc)
        except (OSError, gzip.BadGzipFile, EOFError):
            # Corrupt / truncated dataset ⇒ leave the country table empty ⇒ {} no-op.
            return

    def _load_asn(self, path):
        if not path or not os.path.exists(path):
            return
        try:
            with gzip.open(path, "rt", encoding="utf-8", errors="replace",
                           newline="") as fh:
                for row in csv.reader(fh):
                    # DB-IP ASN lite: start,end,asn_number,"Org Name". Some legacy
                    # dumps pack it as start,end,"AS#### Org" (3 cols) — support both.
                    if len(row) < 3:
                        continue
                    s, fam = _ip_to_int(row[0])
                    if s is None:
                        continue
                    e, _ = _ip_to_int(row[1])
                    if e is None:
                        continue
                    if len(row) >= 4:
                        num = (row[2] or "").strip()
                        org = (row[3] or "").strip()
                        asn = ("AS" + num) if num and not num.upper().startswith("AS") \
                            else (num or "")
                    else:
                        # 3-col legacy: value = "AS#### Org Name"
                        val = (row[2] or "").strip()
                        parts = val.split(None, 1)
                        asn = parts[0] if parts else ""
                        org = parts[1] if len(parts) > 1 else ""
                        if asn and not asn.upper().startswith("AS"):
                            asn = "AS" + asn
                    starts, ends, vals = self._asn[fam]
                    starts.append(s)
                    ends.append(e)
                    vals.append((asn, org, _is_hosting(org)))
        except (OSError, gzip.BadGzipFile, EOFError):
            return

    # -- query -------------------------------------------------------------
    @staticmethod
    def _find(tbl, ip_int, fam):
        """Return the value for the range containing ip_int, or None."""
        starts, ends, vals = tbl.get(fam, ([], [], []))
        if not starts:
            return None
        # rightmost range whose start <= ip_int
        i = bisect.bisect_right(starts, ip_int) - 1
        if i < 0:
            return None
        if ip_int <= ends[i]:
            return vals[i]
        return None

    def lookup(self, ip):
        """{"country","asn","as_org","hosting"} for ip, or {} if not found / no DB.

        Always returns a dict; never raises. An ip we can't parse, or one with no
        covering range in either table, yields {} (or a partial dict missing the
        absent field) — the watcher treats an empty dict as "no enrichment"."""
        ip_int, fam = _ip_to_int(ip)
        if ip_int is None:
            return {}
        try:
            self._build()
        except Exception:
            return {}
        out = {}
        cc = self._find(self._country, ip_int, fam)
        if cc:
            out["country"] = cc
        asn_val = self._find(self._asn, ip_int, fam)
        if asn_val:
            asn, org, hosting = asn_val
            if asn:
                out["asn"] = asn
            if org:
                out["as_org"] = org
            out["hosting"] = bool(hosting)
        return out


# ---------------------------------------------------------------------------
# Module-level cache: one _GeoDB per (country_path, asn_path) pair. load_geo is the
# only entry point the watcher needs; it's cheap to call repeatedly.
_CACHE = {}
_CACHE_LOCK = threading.Lock()


def load_geo(country_gz_path, asn_gz_path):
    """Return a cached _GeoDB for the given dataset paths (lazy build inside).

    Never raises: if the files are missing the returned db.lookup() simply yields
    {} for everything, so callers can treat 'no dataset' and 'ip not found'
    identically. Pass empty/None paths to get a guaranteed-{} db."""
    key = (country_gz_path or "", asn_gz_path or "")
    db = _CACHE.get(key)
    if db is None:
        with _CACHE_LOCK:
            db = _CACHE.get(key)
            if db is None:
                db = _GeoDB(country_gz_path, asn_gz_path)
                _CACHE[key] = db
    return db


# ---------------------------------------------------------------------------
if __name__ == "__main__":
    # Tiny self-test / smoke harness. Usage:
    #   honeypot_geo.py <country.csv.gz> <asn.csv.gz> [ip ...]
    import sys
    if len(sys.argv) < 3:
        print("usage: honeypot_geo.py <country.csv.gz> <asn.csv.gz> [ip ...]")
        sys.exit(2)
    cpath, apath = sys.argv[1], sys.argv[2]
    ips = sys.argv[3:] or ["8.8.8.8", "1.1.1.1", "9.9.9.9", "2606:4700:4700::1111"]
    db = load_geo(cpath, apath)
    for ip in ips:
        print(f"{ip:40s} -> {db.lookup(ip)}")
