"""tests/test_sites_analytics.py — unit tests for Pocket Pages M4 Feature D,
analytics-lite (SPEC-DIFFERENTIATORS.md §9, §9.6, AD-10/11/12).

scripts/sites/analytics.py is pure stdlib and tested directly (parse/iter/
aggregate); the panel route is exercised through the Flask test client with
the module imported under a distinct name (test_sites_webhook.py's pattern).

NOT here (arm64 E2E, §9.6): the real Caddy `log` block writing real JSON at
the pinned binary, per-site attribution from live traffic, and rotation
behavior — the fixtures below are shaped exactly like the field subset
honeypot-watcher.py:469-507 already proves against production output.
"""
import gzip
import hashlib
import importlib.util
import json
import os
import sys
import tempfile
import time
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]

_spec = importlib.util.spec_from_file_location(
    "analytics_under_test", REPO_ROOT / "scripts" / "sites" / "analytics.py")
an = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(an)


def _line(host="blog.ci.example.org", uri="/", status=200, ip="203.0.113.7",
          cf_ip=None, size=1234, **extra):
    d = {"ts": time.time(), "status": status, "size": size,
         "request": {"host": host, "uri": uri, "method": "GET",
                     "client_ip": ip, "remote_ip": ip,
                     "headers": {"User-Agent": ["UA"]}}}
    if cf_ip:
        d["request"]["headers"]["Cf-Connecting-IP"] = [cf_ip]
    d.update(extra)
    return json.dumps(d)


# ── parse_line (honeypot-watcher parity) ────────────────────────────────────

def test_parse_line_valid():
    ev = an.parse_line(_line(cf_ip="198.51.100.4"))
    assert ev["host"] == "blog.ci.example.org" and ev["status"] == 200
    assert ev["ip"] == "198.51.100.4"          # Cf-Connecting-IP preferred


def test_parse_line_fallback_client_ip():
    assert an.parse_line(_line())["ip"] == "203.0.113.7"


def test_parse_line_malformed_and_non_request():
    assert an.parse_line("{not json") is None
    assert an.parse_line(json.dumps({"msg": "startup"})) is None
    assert an.parse_line(json.dumps({"request": {"host": "x"}})) is None  # no uri


# ── iter_log_lines: rotation, gz, corruption, retention ─────────────────────

def test_iter_log_lines_gz_and_corrupt(tmp_path):
    (tmp_path / "sites-access.log").write_text(_line() + "\n")
    with gzip.open(tmp_path / "sites-access-1.log.gz", "wt") as f:
        f.write(_line(uri="/old") + "\n")
    (tmp_path / "sites-access-2.log.gz").write_bytes(b"\x1f\x8b garbage")
    lines = list(an.iter_log_lines(str(tmp_path), 30))
    assert len(lines) == 2                     # corrupt gz skipped, not fatal


def test_iter_log_lines_retention_by_mtime(tmp_path):
    old = tmp_path / "sites-access-1.log"
    old.write_text(_line(uri="/ancient") + "\n")
    stale = time.time() - 40 * 86400
    os.utime(old, (stale, stale))
    (tmp_path / "sites-access.log").write_text(_line(uri="/fresh") + "\n")
    lines = list(an.iter_log_lines(str(tmp_path), 30))
    assert len(lines) == 1 and "/fresh" in lines[0]


# ── aggregate ───────────────────────────────────────────────────────────────

def test_aggregate_buckets_by_site_and_skips_foreign_hosts():
    lines = [
        _line(host="blog.ci.example.org", uri="/a"),
        _line(host="blog.ci.example.org", uri="/a", status=404),
        _line(host="docs.ci.example.org", uri="/b"),
        _line(host="evil.other.example", uri="/x"),         # foreign domain
        _line(host="Bad_Label.ci.example.org", uri="/x"),   # invalid label
        _line(host="blog.ci.example.org:8443", uri="/a"),   # port stripped
    ]
    agg = an.aggregate(lines, "ci.example.org")
    assert set(agg["sites"]) == {"blog", "docs"}
    blog = agg["sites"]["blog"]
    assert blog["requests"] == 3
    assert blog["status_2xx"] == 2 and blog["status_4xx"] == 1


def test_aggregate_top_paths_sorted_and_query_stripped():
    # The query string is where accidental PII lands — prove it never reaches
    # the aggregate (the marker word stands in for a credential/search term).
    lines = [_line(uri="/a?q=findme-marker")] * 3 + [_line(uri="/b")]
    agg = an.aggregate(lines, "ci.example.org")
    top = agg["sites"]["blog"]["top_paths"]
    assert top[0] == ["/a", 3] or top[0] == ("/a", 3)
    assert "findme-marker" not in json.dumps(agg)


def test_aggregate_unique_visitors_truncated_set():
    lines = [
        _line(cf_ip="203.0.113.5"), _line(cf_ip="203.0.113.99"),  # same /24
        _line(cf_ip="198.51.100.1"),                               # another
    ]
    agg = an.aggregate(lines, "ci.example.org")
    assert agg["sites"]["blog"]["approx_unique_visitors"] == 2
    # AD-12: no full OR truncated address appears in the aggregate output.
    flat = json.dumps(agg)
    for needle in ("203.0.113.5", "203.0.113.99", "198.51.100.1",
                   "203.0.113.0", "198.51.100.0"):
        assert needle not in flat


def test_aggregate_bytes_hint_tolerates_missing_size():
    lines = [_line(size=100), _line(size=None)]
    agg = an.aggregate(lines, "ci.example.org")
    assert agg["sites"]["blog"]["bytes_hint"] == 100


def test_aggregate_max_lines_truncation_signaled():
    lines = [_line() for _ in range(10)]
    agg = an.aggregate(lines, "ci.example.org", max_lines=5)
    assert agg["truncated"] is True
    assert agg["sites"]["blog"]["requests"] == 5


# ── panel route ─────────────────────────────────────────────────────────────

flask = pytest.importorskip("flask")


def _import_admin_app(module_name, seams):
    saved = {k: os.environ.get(k) for k in seams}
    os.environ.update(seams)
    try:
        spec = importlib.util.spec_from_file_location(
            module_name, REPO_ROOT / "admin" / "app.py")
        mod = importlib.util.module_from_spec(spec)
        sys.modules[module_name] = mod
        spec.loader.exec_module(mod)
        return mod
    finally:
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


_BASE = Path(tempfile.mkdtemp(prefix="sites-analytics-test."))
_DATA = _BASE / "data"
_LOGS = _BASE / "logs"
for _d in (_DATA / "secrets", _LOGS):
    _d.mkdir(parents=True)
_ENV_FILE = _BASE / ".env"
_ENV_FILE.write_text("DOMAIN=ci.example.org\n")

import binascii  # noqa: E402

_salt = os.urandom(16)
_hash = hashlib.scrypt(b"unit-test-pw", salt=_salt, n=2 ** 14, r=8, p=1, dklen=32)
(_DATA / "secrets" / "adminweb-password.hash").write_text(
    binascii.hexlify(_salt).decode() + ":" + binascii.hexlify(_hash).decode() + "\n")

(_LOGS / "sites-access.log").write_text(
    "\n".join([_line(uri="/hello"), _line(uri="/hello", status=404)]) + "\n")

_SEAMS = {
    "DATA_DIR": str(_DATA),
    "POCKET_ROOT": str(REPO_ROOT),
    "DOMAIN": "ci.example.org",
    "ENABLE_SITES": "true",
    "ENABLE_SITES_ANALYTICS": "true",
    "POCKET_LOG_DIR": str(_LOGS),
    "POCKET_ENV": str(_ENV_FILE),
}
appmod = _import_admin_app("admin_app_analytics_under_test", _SEAMS)


@pytest.fixture()
def authed():
    c = appmod.app.test_client()
    with c.session_transaction() as s:
        s["auth"] = True
        s["user"] = "admin"
        s["boot_nonce"] = appmod.BOOT_NONCE
    return c


def test_analytics_page_renders_stats(authed):
    r = authed.get("/sites/blog/analytics")
    assert r.status_code == 200
    html = r.get_data(as_text=True)
    assert "/hello" in html and "analytics" in html


def test_analytics_unknown_site_renders_empty_state(authed):
    r = authed.get("/sites/nosuchsite/analytics")
    assert r.status_code == 200
    assert "No traffic recorded" in r.get_data(as_text=True)


def test_analytics_requires_login():
    c = appmod.app.test_client()
    assert c.get("/sites/blog/analytics").status_code in (302, 401, 403)


def test_analytics_cache_is_shared():
    first = appmod._sites_analytics_cached()
    assert appmod._sites_analytics_cached() is first


_OFF = dict(_SEAMS)
_OFF["ENABLE_SITES_ANALYTICS"] = "false"
appmod_off = _import_admin_app("admin_app_analytics_off_under_test", _OFF)


def test_analytics_disabled_404():
    c = appmod_off.app.test_client()
    with c.session_transaction() as s:
        s["auth"] = True
        s["user"] = "admin"
        s["boot_nonce"] = appmod_off.BOOT_NONCE
    assert c.get("/sites/blog/analytics").status_code == 404
