"""tests/test_panel_sites.py — unit tests for admin/app.py's Sites (Pocket
Pages) panel surface, per SPEC-SITES-PANEL.md §17.

Import strategy: admin/app.py reads all of its configuration from os.environ
at import time, so this module points every seam (DATA_DIR, POCKET_ROOT, the
POCKET_* dirs) at a throwaway fixture tree BEFORE importing it, then restores
os.environ so the other test modules' subprocess environments are untouched
(the app has already captured everything into module globals by then). Flask
may be absent in a bare checkout (the panel installs its own venv on-phone via
70-install-admin.sh) — the whole module skips cleanly in that case; CI installs
flask + segno so nothing skips there.

Deliberately NOT here: full deploy/rollback/delete flows through the real
pipeline — those are covered by the arm64 E2E (and were exercised end-to-end
by a laptop integration smoke during M2 validation). These tests pin the pure
logic: the regex + reserved-list duplication contracts, the CSRF header check,
the argv helpers, upload-budget enforcement, and the ENABLE gate.

⚠ Werkzeug's test client CANNOT send a mismatched Content-Length: its
EnvironBuilder recomputes CL from the real body, and Client.open(dict)
re-normalizes via EnvironBuilder.from_environ. The budget tests therefore
drive the WSGI app directly with a hand-built environ (run_wsgi_app).
"""
import io
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import pytest

flask = pytest.importorskip("flask")
from werkzeug.test import create_environ, run_wsgi_app  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[1]

PW = "unit-test-pw"
CSRF = "unit-test-csrf-token"

# ── fixture tree + seams, then import the app, then restore os.environ ───────
_BASE = Path(tempfile.mkdtemp(prefix="panel-sites-test."))
_DATA = _BASE / "data"
_SITES_ROOT = _BASE / "sites-root"
_STATE = _BASE / "state"
_LOGS = _BASE / "logs"
for _d in (_DATA / "secrets", _SITES_ROOT / ".staging", _STATE, _LOGS):
    _d.mkdir(parents=True)

_ENV_FILE = _BASE / ".env"
_ENV_FILE.write_text(
    "DOMAIN=ci.example.org\n"
    f"DATA_DIR={_DATA}\n"
    "CF_TUNNEL_TOKEN=x\n"
    "ADMIN_PASSWORD=x\n"
)

import binascii  # noqa: E402
import hashlib  # noqa: E402

_salt = os.urandom(16)
# Parameters MUST equal app.scrypt_hash(): n=2^14, r=8, p=1, dklen=32 — the
# dklen matters (hashlib defaults to 64; verify_password compares 32-byte hex).
_hash = hashlib.scrypt(PW.encode(), salt=_salt, n=2 ** 14, r=8, p=1, dklen=32)
(_DATA / "secrets" / "adminweb-password.hash").write_text(
    binascii.hexlify(_salt).decode() + ":" + binascii.hexlify(_hash).decode() + "\n")

_SEAMS = {
    "DATA_DIR": str(_DATA),
    "POCKET_ROOT": str(REPO_ROOT),
    "DOMAIN": "ci.example.org",
    "ENABLE_SITES": "true",
    "POCKET_SITES_ROOT": str(_SITES_ROOT),
    "POCKET_STATE_DIR": str(_STATE),
    "POCKET_LOG_DIR": str(_LOGS),
    "POCKET_ENV": str(_ENV_FILE),
}
_saved = {k: os.environ.get(k) for k in _SEAMS}
os.environ.update(_SEAMS)
sys.path.insert(0, str(REPO_ROOT / "admin"))
try:
    import app as appmod
finally:
    for _k, _v in _saved.items():
        if _v is None:
            os.environ.pop(_k, None)
        else:
            os.environ[_k] = _v


# ── client fixtures ──────────────────────────────────────────────────────────

@pytest.fixture()
def client():
    return appmod.app.test_client()


@pytest.fixture()
def authed(client):
    with client.session_transaction() as s:
        s["auth"] = True
        s["user"] = "admin"
        s["boot_nonce"] = appmod.BOOT_NONCE
        s["csrf"] = CSRF
    return client


def raw_upload(authed_client, name, body, cl):
    """POST /sites/upload at the raw WSGI level with exact CONTENT_LENGTH
    control. cl=None removes the header entirely; else it is the (possibly
    lying) CONTENT_LENGTH string."""
    env = create_environ("/sites/upload", method="POST",
                         query_string=f"name={name}", data=body,
                         content_type="application/octet-stream")
    env["HTTP_X_CSRF_TOKEN"] = CSRF
    env["HTTP_X_ADMIN_PASSWORD"] = PW
    env["HTTP_COOKIE"] = f"session={authed_client.get_cookie('session').value}"
    if cl is None:
        env.pop("CONTENT_LENGTH", None)
    else:
        env["CONTENT_LENGTH"] = cl
    app_iter, status, _headers = run_wsgi_app(appmod.app, env)
    out = b"".join(app_iter)
    if hasattr(app_iter, "close"):
        app_iter.close()
    return int(status.split(" ", 1)[0]), out


def staging_files():
    return sorted(p.name for p in (_SITES_ROOT / ".staging").glob("upload-*"))


# ── duplication contracts (§17: "fails loudly the moment the two drift") ─────

def test_reserved_list_parity_with_pipeline():
    out = subprocess.run(
        ["bash", "-c",
         f'. "{REPO_ROOT}/scripts/sites/reserved-subs.sh" && printf "%s" "$RESERVED_SUBS"'],
        capture_output=True, text=True, check=True).stdout.split()
    assert len(out) == len(set(out)), "reserved-subs.sh contains duplicates"
    assert set(out) == appmod.SITE_RESERVED, (
        "admin/app.py SITE_RESERVED != scripts/sites/reserved-subs.sh RESERVED_SUBS "
        "— the §8 duplication contract requires changing both together")


@pytest.mark.parametrize("name", ["a", "a1", "my-site", "0-0", "x" * 63,
                                  "a" + "b" * 61 + "c"])
def test_site_name_regex_accepts(name):
    assert appmod.SITE_SUB_RE.fullmatch(name)


@pytest.mark.parametrize("name", ["", "-lead", "trail-", "UPPER", "under_score",
                                  "dot.dot", "x" * 64, "a b", "a/b", "a\nb",
                                  "café"])
def test_site_name_regex_rejects(name):
    assert not appmod.SITE_SUB_RE.fullmatch(name)


@pytest.mark.parametrize("job", ["20260717T1200Z-a1b2", "20260717T120003Z-a1b2"])
def test_job_id_regex_accepts_pipeline_shapes(job):
    # {4,6} must tolerate both HHMM and the HHMMSS the pipeline actually mints.
    assert appmod._SITE_JOB_RE.fullmatch(job)


@pytest.mark.parametrize("job", [
    "", "20260717T1200Z-A1B2", "20260717T1200Z-a1b", "20260717T1200Z-a1b2c",
    "../etc/passwd", "20260717T1200Z-a1b2/..", "20260717T1200Z-a1b2;rm",
    "20260717T1200Z-a1b2\n", "20260717t1200z-a1b2",
])
def test_job_id_regex_rejects(job):
    assert not appmod._SITE_JOB_RE.fullmatch(job)


# ── csrf_ok_header (§17) ─────────────────────────────────────────────────────

def test_csrf_header_match():
    with appmod.app.test_request_context(headers={"X-CSRF-Token": "tok"}):
        flask.session["csrf"] = "tok"
        assert appmod.csrf_ok_header()


def test_csrf_header_mismatch():
    with appmod.app.test_request_context(headers={"X-CSRF-Token": "tok"}):
        flask.session["csrf"] = "other"
        assert not appmod.csrf_ok_header()


def test_csrf_header_missing():
    with appmod.app.test_request_context():
        flask.session["csrf"] = "tok"
        assert not appmod.csrf_ok_header()


def test_csrf_header_empty_vs_empty_session():
    # bool(tok) guard: an empty header must NEVER pass, even though
    # compare_digest("", "") would be True against a missing session token.
    with appmod.app.test_request_context(headers={"X-CSRF-Token": ""}):
        assert not appmod.csrf_ok_header()


# ── the argv helpers (§17: shape, no SCRIPTS_OK reads) ───────────────────────

@pytest.fixture()
def fake_scripts(monkeypatch, tmp_path):
    monkeypatch.setattr(appmod, "SCRIPTS", str(tmp_path))
    monkeypatch.setattr(appmod, "LOGS", str(tmp_path / "logs"))
    return tmp_path


def test_run_script_argv_preserves_argv_boundaries(fake_scripts):
    (fake_scripts / "argv-echo.sh").write_text(
        '#!/usr/bin/env bash\nprintf "[%s]" "$@"\nexit 0\n')
    assert "argv-echo.sh" not in appmod.SCRIPTS_OK  # explicit-path, not a key
    rc, out = appmod.run_script_argv("argv-echo.sh", ["a b", "--flag"], timeout=10)
    assert rc == 0
    # an argument containing a space stays ONE argv element (no shell parsing)
    assert "[a b][--flag]" in out


def test_run_script_argv_nonzero_rc_passthrough(fake_scripts):
    (fake_scripts / "fail.sh").write_text("#!/usr/bin/env bash\necho nope\nexit 7\n")
    rc, out = appmod.run_script_argv("fail.sh", [], timeout=10)
    assert rc == 7 and "nope" in out


def test_run_script_argv_timeout(fake_scripts):
    (fake_scripts / "slow.sh").write_text("#!/usr/bin/env bash\nsleep 5\n")
    rc, out = appmod.run_script_argv("slow.sh", [], timeout=1)
    assert rc == -1 and "timed out" in out


def test_run_script_detached_argv_launches_and_logs(fake_scripts):
    marker = fake_scripts / "detached-argv.txt"
    (fake_scripts / "detached.sh").write_text(
        f'#!/usr/bin/env bash\nprintf "[%s]" "$@" > "{marker}"\necho sink-line\n')
    ok, logname = appmod.run_script_detached_argv("detached.sh", ["n1", "--job", "j1"],
                                                  "site-deploy-j1.log")
    assert ok and logname == "site-deploy-j1.log"
    for _ in range(50):
        if marker.exists() and (fake_scripts / "logs" / "adminweb-async.log").exists():
            break
        time.sleep(0.1)
    assert marker.read_text() == "[n1][--job][j1]"
    assert "sink-line" in (fake_scripts / "logs" / "adminweb-async.log").read_text()


# ── upload budget + dispatch (§17, at the WSGI level) ────────────────────────

def test_upload_missing_content_length_411(authed):
    st, _ = raw_upload(authed, "unitsite", b"zz", None)
    assert st == 411
    assert staging_files() == []


def test_upload_over_cap_413(authed):
    st, _ = raw_upload(authed, "unitsite", b"z",
                       str((appmod.SITES_MAX_UPLOAD_MB + 1) * 1024 * 1024))
    assert st == 413
    assert staging_files() == []


def test_upload_lying_content_length_400_and_staging_clean(authed):
    st, _ = raw_upload(authed, "unitsite", b"abc", "10")
    assert st == 400
    assert staging_files() == [], "a truncated upload must unlink its staged file"


def test_upload_dispatch_argv_shape(authed, monkeypatch):
    calls = []

    def fake_detached(base_script, extra_argv, logname):
        calls.append((base_script, list(extra_argv), logname))
        return True, logname

    monkeypatch.setattr(appmod, "run_script_detached_argv", fake_detached)
    body = b"PK\x05\x06" + b"\x00" * 18  # empty-but-valid zip EOCD
    r = authed.post("/sites/upload?name=unitsite", data=body,
                    headers={"X-CSRF-Token": CSRF, "X-Admin-Password": PW,
                             "Content-Type": "application/octet-stream"})
    assert r.status_code == 200
    job = (r.get_json() or {}).get("job", "")
    assert appmod._SITE_JOB_RE.fullmatch(job)
    assert len(calls) == 1
    base_script, argv, logname = calls[0]
    assert base_script == appmod.SITES_DEPLOY_SCRIPT
    assert argv[0] == "unitsite" and argv[2:] == ["--job", job]
    staged = Path(argv[1])
    assert staged.parent == _SITES_ROOT / ".staging"   # server-allocated path
    assert staged.read_bytes() == body
    assert logname == f"site-deploy-{job}.log"
    staged.unlink()


@pytest.mark.parametrize("name,code", [("www", 400), ("Bad_Name", 400)])
def test_upload_rejects_reserved_and_invalid_names(authed, name, code):
    r = authed.post(f"/sites/upload?name={name}", data=b"z",
                    headers={"X-CSRF-Token": CSRF, "X-Admin-Password": PW,
                             "Content-Type": "application/octet-stream"})
    assert r.status_code == code


def test_upload_bad_password_401(authed):
    r = authed.post("/sites/upload?name=unitsite", data=b"z",
                    headers={"X-CSRF-Token": CSRF, "X-Admin-Password": "nope",
                             "Content-Type": "application/octet-stream"})
    assert r.status_code == 401


def test_upload_bad_csrf_403(authed):
    r = authed.post("/sites/upload?name=unitsite", data=b"z",
                    headers={"X-CSRF-Token": "garbage", "X-Admin-Password": PW,
                             "Content-Type": "application/octet-stream"})
    assert r.status_code == 403


def test_max_content_length_backstop_is_set():
    assert appmod.app.config["MAX_CONTENT_LENGTH"] == \
        (appmod.SITES_MAX_UPLOAD_MB + 16) * 1024 * 1024


# ── gates + rendering helpers ────────────────────────────────────────────────

def test_login_required_covers_sites(client):
    r = client.get("/sites")
    assert r.status_code == 302 and "/login" in r.headers.get("Location", "")


def test_enable_gate_404s_every_route(authed, monkeypatch):
    monkeypatch.setitem(appmod.ENABLE, "sites", False)
    routes = [
        ("GET", "/sites"), ("POST", "/sites/upload?name=x"),
        ("GET", "/sites/health.json"),
        ("GET", "/sites/deploy-log/20260717T1200Z-a1b2"),
        ("GET", "/sites/job/20260717T1200Z-a1b2"),
        ("POST", "/sites/x/rollback"), ("GET", "/sites/x/delete"),
        ("GET", "/sites/x/qr.svg"), ("POST", "/sites/rebuild-registry"),
        ("POST", "/sites/apply-vhost"),
    ]
    for method, path in routes:
        r = authed.open(path, method=method)
        assert r.status_code == 404, f"{method} {path} leaked through the gate"


def test_registry_reader_degrades_on_corrupt_file(monkeypatch, tmp_path):
    bad = tmp_path / "reg.json"
    bad.write_text("{not json")
    monkeypatch.setattr(appmod, "SITES_REGISTRY", str(bad))
    assert appmod._read_sites_registry() == {"version": 1, "sites": {}}
    monkeypatch.setattr(appmod, "SITES_REGISTRY", str(tmp_path / "missing.json"))
    assert appmod._read_sites_registry() == {"version": 1, "sites": {}}


def test_updated_ago_never_raises():
    assert appmod._site_updated_ago("garbage") == "garbage"
    assert appmod._site_updated_ago("") == "?"
    assert appmod._site_updated_ago(
        time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())) == "just now"
    assert appmod._site_updated_ago("2020-01-01T00:00:00Z").endswith(" ago")


def test_release_created_parses_and_degrades():
    assert appmod._site_release_created("20260717T120003Z-a1b2") == \
        "2026-07-17 12:00:03 UTC"
    assert appmod._site_release_created("garbage") == "garbage"


def test_qr_is_standalone_namespaced_svg(authed):
    pytest.importorskip("segno")
    r = authed.get("/sites/unitsite/qr.svg")
    assert r.status_code == 200
    assert r.headers["Content-Type"] == "image/svg+xml"
    body = r.get_data(as_text=True)
    assert body.startswith("<?xml") and "xmlns" in body
