"""tests/test_sites_forms.py — unit tests for Pocket Pages M4 Feature C, the
Netlify-Forms clone (SPEC-DIFFERENTIATORS.md §8, §8.7, corrections C-2/C-3).

Covers scripts/sites/forms_db.py directly (schema/pragmas/truncation/GC) and
admin/app.py's three forms routes through the Flask test client — the app is
imported under a DISTINCT module name with tightened caps as env seams
(test_sites_webhook.py's own _import_admin_app pattern) so limits are
reachable in tests without 64 KB bodies.

NOT here (arm64 E2E, §8.7): the real Caddy @forms matcher beating
file_server, the vhost's SET-only replacement of client-supplied
X-Pocket-Site/X-Pocket-Forms-Gate (C-4: header_up SET replaces; a paired
delete would wipe it), and a real Maddy relay round-trip. The werkzeug test client also
cannot send a missing/mismatched Content-Length (EnvironBuilder recomputes
it), so the 411 branch is exercised at the raw-WSGI layer only in the E2E —
the same limitation test_panel_sites.py already documents for upload CL
negatives.
"""
import hashlib
import importlib.util
import json
import os
import sys
import tempfile
import time
from pathlib import Path

import pytest

flask = pytest.importorskip("flask")

REPO_ROOT = Path(__file__).resolve().parents[1]

# ── forms_db direct (no flask needed beyond the skip above) ─────────────────

_spec = importlib.util.spec_from_file_location(
    "forms_db_under_test", REPO_ROOT / "scripts" / "sites" / "forms_db.py")
forms_db = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(forms_db)


@pytest.mark.parametrize("ip,expect", [
    ("203.0.113.77", "203.0.113.0"),
    ("10.1.2.3", "10.1.2.0"),
    ("2001:db8:abcd:12:34:56:78:9a", "2001:db8:abcd::"),
    ("", ""),
    ("not-an-ip", ""),
])
def test_truncate_ip(ip, expect):
    assert forms_db.truncate_ip(ip) == expect


def test_db_insert_query_spam_filter(tmp_path):
    db = str(tmp_path / "f.db")
    conn = forms_db.connect(db)
    try:
        assert conn.execute("PRAGMA journal_mode").fetchone()[0] == "wal"
        forms_db.insert(conn, "s1", "contact", {"a": "1"}, "203.0.113.0", "UA", spam=False)
        forms_db.insert(conn, "s1", "contact", {"b": "2"}, "203.0.113.0", "UA", spam=True)
        forms_db.insert(conn, "s2", "contact", {"c": "3"}, "", "UA", spam=False)
        rows, total = forms_db.query(conn, "s1")
        assert total == 1 and json.loads(rows[0]["fields_json"]) == {"a": "1"}
        rows, total = forms_db.query(conn, "s1", include_spam=True)
        assert total == 2
        rows, total = forms_db.query(conn, "s2")
        assert total == 1
    finally:
        conn.close()


def test_db_delete_is_site_scoped(tmp_path):
    conn = forms_db.connect(str(tmp_path / "f.db"))
    try:
        id1 = forms_db.insert(conn, "s1", "f", {}, "", "", False)
        id2 = forms_db.insert(conn, "s2", "f", {}, "", "", False)
        # A forged id list naming another site's row deletes nothing of it.
        assert forms_db.delete_ids(conn, "s1", [id1, id2]) == 1
        assert forms_db.query(conn, "s2")[1] == 1
    finally:
        conn.close()


def test_db_gc_retention_and_throttle(tmp_path):
    conn = forms_db.connect(str(tmp_path / "f.db"))
    stamp = str(tmp_path / "gc-stamp")
    try:
        old_id = forms_db.insert(conn, "s1", "f", {"old": "1"}, "", "", False)
        conn.execute("UPDATE submissions SET ts_epoch = ? WHERE id = ?",
                     (int(time.time()) - 200 * 86400, old_id))
        conn.commit()
        forms_db.insert(conn, "s1", "f", {"new": "1"}, "", "", False)
        assert forms_db.gc_due(stamp)          # no stamp yet
        assert forms_db.gc(conn, 180, stamp) == 1
        assert forms_db.query(conn, "s1")[1] == 1
        assert not forms_db.gc_due(stamp)      # freshly stamped -> throttled
        assert forms_db.gc_due(stamp, min_interval_s=0)
    finally:
        conn.close()


# ── the routes ──────────────────────────────────────────────────────────────

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


_BASE = Path(tempfile.mkdtemp(prefix="sites-forms-test."))
_DATA = _BASE / "data"
_STATE = _BASE / "state"
for _d in (_DATA / "secrets", _STATE):
    _d.mkdir(parents=True)
_ENV_FILE = _BASE / ".env"
_ENV_FILE.write_text("DOMAIN=ci.example.org\n")

import binascii  # noqa: E402

_salt = os.urandom(16)
_hash = hashlib.scrypt(b"unit-test-pw", salt=_salt, n=2 ** 14, r=8, p=1, dklen=32)
(_DATA / "secrets" / "adminweb-password.hash").write_text(
    binascii.hexlify(_salt).decode() + ":" + binascii.hexlify(_hash).decode() + "\n")

GATE = "g" * 64
(_STATE / "sites-forms.gate").write_text(GATE + "\n")

_SEAMS = {
    "DATA_DIR": str(_DATA),
    "POCKET_ROOT": str(REPO_ROOT),
    "DOMAIN": "ci.example.org",
    "ENABLE_SITES": "true",
    "ENABLE_SITES_FORMS": "true",
    "POCKET_STATE_DIR": str(_STATE),
    "POCKET_ENV": str(_ENV_FILE),
    # Tightened caps so every limit is reachable with tiny fixtures.
    "SITES_FORMS_MAX_BODY_KB": "1",
    "SITES_FORMS_MAX_FIELDS": "5",
    "SITES_FORMS_MAX_FIELD_LEN": "50",
    "SITES_FORMS_RATE_LIMIT_PER_HOUR": "3",
}
appmod = _import_admin_app("admin_app_forms_under_test", _SEAMS)


@pytest.fixture()
def client():
    return appmod.app.test_client()


@pytest.fixture()
def authed(client):
    with client.session_transaction() as s:
        s["auth"] = True
        s["user"] = "admin"
        s["boot_nonce"] = appmod.BOOT_NONCE
        s["csrf"] = "unit-test-csrf-token"
    return client


@pytest.fixture(autouse=True)
def _fresh_state():
    """Fresh DB + rate-limit dict per test — both are shared module/disk
    state that would otherwise couple test functions."""
    appmod._FORMS_RATE.clear()
    for f in ("sites-forms.db", "sites-forms.db-wal", "sites-forms.db-shm",
              "sites-forms.gc-stamp"):
        try:
            os.unlink(_STATE / f)
        except OSError:
            pass
    yield
    appmod._FORMS_RATE.clear()


def _submit(client, form="contact", data=None, gate=GATE, site="blog", **hdr):
    headers = {}
    if gate is not None:
        headers["X-Pocket-Forms-Gate"] = gate
    if site is not None:
        headers["X-Pocket-Site"] = site
    headers.update(hdr)
    return client.post(f"/__pocket-forms__/submit/{form}",
                       data=data or {"name": "Ada", "msg": "hi"},
                       headers=headers)


def _rows(site, include_spam=True):
    conn = forms_db.connect(str(_STATE / "sites-forms.db"))
    try:
        return forms_db.query(conn, site, include_spam=include_spam)[0]
    finally:
        conn.close()


# C-2 — the gate token is the trust boundary, not the header's mere presence.

def test_submit_without_gate_404(client):
    assert _submit(client, gate=None).status_code == 404


def test_submit_with_wrong_gate_404(client):
    assert _submit(client, gate="x" * 64).status_code == 404
    assert _rows("blog") == []


def test_submit_missing_site_header_404(client):
    assert _submit(client, site=None).status_code == 404


def test_submit_bad_site_label_404(client):
    assert _submit(client, site="Bad_Label!").status_code == 404


def test_submit_bad_form_name_400(client):
    assert _submit(client, form="bad name!").status_code == 400


def test_submit_ok_stores_row(client):
    r = _submit(client)
    assert r.status_code == 200
    rows = _rows("blog")
    assert len(rows) == 1
    row = rows[0]
    assert row["site"] == "blog" and row["form"] == "contact"
    assert json.loads(row["fields_json"]) == {"name": "Ada", "msg": "hi"}
    assert row["spam"] == 0 and row["emailed"] == 0


def test_submit_json_accept_gets_json(client):
    r = _submit(client, **{"Accept": "application/json"})
    assert r.status_code == 200 and r.get_json() == {"ok": True}


# Caps (§8.3): field count / field length / body size.

def test_field_count_cap_413(client):
    data = {f"f{i}": "x" for i in range(6)}
    assert _submit(client, data=data).status_code == 413
    assert _rows("blog") == []


def test_field_length_cap_413(client):
    assert _submit(client, data={"a": "y" * 51}).status_code == 413


def test_body_size_cap_413(client):
    # 1 KiB cap via the seam; a single oversized urlencoded body trips the
    # content_length check before parsing.
    assert _submit(client, data={"a": "z" * 3000}).status_code == 413


# AD-9 — honeypot: stored, tagged, hidden from default view, same response.

def test_honeypot_trip_stored_as_spam_same_response(client):
    r = _submit(client, data={"name": "Bot", "_pocket_hp": "gotcha"})
    assert r.status_code == 200          # no signal to the submitter
    all_rows = _rows("blog")
    assert len(all_rows) == 1 and all_rows[0]["spam"] == 1
    # Bait value never stored (AD-9), only the trip.
    assert "gotcha" not in all_rows[0]["fields_json"]
    assert _rows("blog", include_spam=False) == []


def test_honeypot_empty_value_is_not_spam(client):
    _submit(client, data={"name": "Ada", "_pocket_hp": ""})
    assert _rows("blog", include_spam=False)[0]["spam"] == 0


# Rate limit — fixed window per (site, form, truncated-ip).

def test_rate_limit_429_after_cap(client):
    for _ in range(3):
        assert _submit(client).status_code == 200
    assert _submit(client).status_code == 429
    assert len(_rows("blog")) == 3


def test_rate_limit_keys_are_independent(client):
    for _ in range(3):
        _submit(client)
    # Different form name -> its own window.
    assert _submit(client, form="other").status_code == 200
    # Different (spoofed-ip-derived) key -> its own window.
    assert _submit(client, **{"Cf-Connecting-IP": "198.51.100.9"}).status_code == 200


# C-3 — the visitor IP comes from Cf-Connecting-IP first; truncated at rest.

def test_ip_source_prefers_cf_connecting_ip(client):
    _submit(client, **{"Cf-Connecting-IP": "203.0.113.77"})
    row = _rows("blog")[0]
    assert row["ip_truncated"] == "203.0.113.0"
    # The FULL address never lands anywhere in the row.
    assert "203.0.113.77" not in (row["fields_json"] + (row["ip_truncated"] or "") + (row["ua"] or ""))


def test_ip_truncation_ipv6(client):
    _submit(client, **{"Cf-Connecting-IP": "2001:db8:abcd:12:34:56:78:9a"})
    assert _rows("blog")[0]["ip_truncated"] == "2001:db8:abcd::"


# Inbox + delete (operator side).

def test_inbox_requires_login(client):
    r = client.get("/sites/blog/forms")
    assert r.status_code in (302, 401, 403)


def test_inbox_escapes_field_values(authed):
    _submit(authed, data={"name": "<script>alert(1)</script>"})
    r = authed.get("/sites/blog/forms")
    assert r.status_code == 200
    html = r.get_data(as_text=True)
    assert "<script>alert(1)</script>" not in html
    assert "&lt;script&gt;" in html


def test_delete_selected_and_spam(authed):
    _submit(authed)
    _submit(authed, data={"a": "b", "_pocket_hp": "x"})
    rows = _rows("blog")
    real_id = [r["id"] for r in rows if not r["spam"]][0]
    r = authed.post("/sites/blog/forms/delete",
                    data={"_csrf": "unit-test-csrf-token", "mode": "selected",
                          "id": [str(real_id)]})
    assert r.status_code in (302, 303)
    r = authed.post("/sites/blog/forms/delete",
                    data={"_csrf": "unit-test-csrf-token", "mode": "spam"})
    assert r.status_code in (302, 303)
    assert _rows("blog") == []


def test_delete_requires_csrf(authed):
    r = authed.post("/sites/blog/forms/delete", data={"mode": "spam"})
    assert r.status_code == 403


# Gate-off: the whole surface disappears.

_OFF = dict(_SEAMS)
_OFF["ENABLE_SITES_FORMS"] = "false"
appmod_off = _import_admin_app("admin_app_forms_off_under_test", _OFF)


def test_forms_disabled_all_routes_404():
    c = appmod_off.app.test_client()
    assert c.post("/__pocket-forms__/submit/contact",
                  headers={"X-Pocket-Forms-Gate": GATE, "X-Pocket-Site": "blog"},
                  data={"a": "b"}).status_code == 404
    with c.session_transaction() as s:
        s["auth"] = True
        s["user"] = "admin"
        s["boot_nonce"] = appmod_off.BOOT_NONCE
    assert c.get("/sites/blog/forms").status_code == 404
