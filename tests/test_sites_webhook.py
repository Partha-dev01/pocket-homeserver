"""tests/test_sites_webhook.py — unit tests for Pocket Pages M4 Feature A,
git-push-to-deploy via Forgejo webhooks (SPEC-DIFFERENTIATORS.md §6, §6.8).

Two independent surfaces are covered here, matching the two new scripts/one
admin/app.py edit this feature ships:

  1. admin/app.py's `POST /sites/<name>/webhook/forgejo` (machine-called,
     HMAC-authenticated) and `GET|POST /sites/<name>/webhook` (in-panel secret
     management) routes. Import strategy mirrors tests/test_panel_sites.py's
     fixture-tree + os.environ-seam approach, but loads admin/app.py via
     importlib.util under a DISTINCT module name — tests/test_mcp.py's own
     `_import_pocket_mcp()` pattern — so this file's import can never collide
     with test_panel_sites.py's plain `import app as appmod` in the same
     pytest session (both files would otherwise fight over sys.modules["app"]
     with DIFFERENT env seams). Flask may be absent in a bare checkout — the
     whole module skips cleanly then, same as test_panel_sites.py; CI installs
     flask so nothing skips there.

  2. scripts/sites/webhook-stage.sh as a REAL subprocess (test_pipeline.py's
     style — never sourced or re-implemented in Python). The PD_BASE-under-
     PREFIX seam is test_pipeline.py's own test_deploy_rejects_byo_collision
     technique, extended one level deeper (…/opt/forgejo/data/repositories)
     for the Forgejo repos root this script resolves against. The one test
     that needs a REAL `git archive` executed *through proot-distro* skips
     gracefully when proot-distro (or git) is not on PATH — exactly the same
     laptop-unavailable exemption site-deploy.sh's build_hugo/build_node tiers
     already have (site-deploy.sh:141-145; test_pipeline.py never attempts
     their happy path either) — exercised for real by the arm64 E2E harness
     instead (SPEC-DIFFERENTIATORS.md §13).

Deliberately NOT here: a real Forgejo instance, a real webhook delivery, or
the [webhook] ALLOWED_HOST_LIST app.ini heal — those need the arm64 E2E
harness (§6.8's "Needs the arm64 E2E" section) and are not reachable from a
laptop.
"""
import hashlib
import hmac
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile
from pathlib import Path

import pytest

flask = pytest.importorskip("flask")

REPO_ROOT = Path(__file__).resolve().parents[1]
SITES_DIR = REPO_ROOT / "scripts" / "sites"

HAVE_GIT = shutil.which("git") is not None
HAVE_PROOT_DISTRO = shutil.which("proot-distro") is not None


# ══════════════════════════════════════════════════════════════════════════
# Part 1 — admin/app.py's webhook routes
# ══════════════════════════════════════════════════════════════════════════

def _import_admin_app(module_name, seams):
    """Import admin/app.py under `module_name` with `seams` set in os.environ
    for the duration of the import, then restore os.environ exactly
    (test_panel_sites.py's own pattern) so later test modules' subprocess
    environments are untouched. A distinct module_name keeps this fully
    isolated from test_panel_sites.py's own `app` import — no sys.modules
    collision regardless of pytest's collection order (mirrors
    tests/test_mcp.py's _import_pocket_mcp())."""
    saved = {k: os.environ.get(k) for k in seams}
    os.environ.update(seams)
    try:
        spec = importlib.util.spec_from_file_location(module_name, REPO_ROOT / "admin" / "app.py")
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


PW = "unit-test-pw"

_BASE = Path(tempfile.mkdtemp(prefix="sites-webhook-test."))
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

_salt = os.urandom(16)
_hash = hashlib.scrypt(PW.encode(), salt=_salt, n=2 ** 14, r=8, p=1, dklen=32)
(_DATA / "secrets" / "adminweb-password.hash").write_text(
    binascii.hexlify(_salt).decode() + ":" + binascii.hexlify(_hash).decode() + "\n")

_SEAMS = {
    "DATA_DIR": str(_DATA),
    "POCKET_ROOT": str(REPO_ROOT),
    "DOMAIN": "ci.example.org",
    "ENABLE_SITES": "true",
    "ENABLE_SITES_WEBHOOKS": "true",
    "POCKET_SITES_ROOT": str(_SITES_ROOT),
    "POCKET_STATE_DIR": str(_STATE),
    "POCKET_LOG_DIR": str(_LOGS),
    "POCKET_ENV": str(_ENV_FILE),
}
appmod = _import_admin_app("admin_app_webhook_under_test", _SEAMS)


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
def _reset_webhook_module_state():
    """_SITE_WEBHOOK_COOLDOWN is a module-level dict that would otherwise leak
    timestamps across test functions (and across the whole test session)."""
    appmod._SITE_WEBHOOK_COOLDOWN.clear()
    yield
    appmod._SITE_WEBHOOK_COOLDOWN.clear()


def _provision_secret(name):
    d = Path(appmod.SITES_WEBHOOK_SECRET_DIR)
    d.mkdir(parents=True, exist_ok=True)
    secret = "f" + hashlib.sha256(name.encode()).hexdigest()[:63]  # 64 hex-ish chars, deterministic per name
    (d / f"{name}.secret").write_text(secret + "\n")
    return secret


def _sign(secret, body):
    return hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()


def _push_body(ref="refs/heads/main", full_name="admin/blog", after="a" * 40):
    return json.dumps({"ref": ref, "after": after, "repository": {"full_name": full_name}}).encode()


def _fake_stage_ok(staged="/staged/webhook-x.zip"):
    calls = []

    def fake(base_script, extra_argv, timeout=60):
        calls.append((base_script, list(extra_argv), timeout))
        return 0, staged + "\n"
    return fake, calls


def _fake_deploy_ok():
    calls = []

    def fake(base_script, extra_argv, logname):
        calls.append((base_script, list(extra_argv), logname))
        return True, logname
    return fake, calls


# ── HMAC accept/reject/tamper/missing + Gitea-header fallback (§6.8) ────────

def test_webhook_hmac_correct_secret_accepts(client, monkeypatch):
    secret = _provision_secret("acceptsite")
    fake_stage, stage_calls = _fake_stage_ok()
    fake_deploy, deploy_calls = _fake_deploy_ok()
    monkeypatch.setattr(appmod, "run_script_argv", fake_stage)
    monkeypatch.setattr(appmod, "run_script_detached_argv", fake_deploy)

    body = _push_body()
    r = client.post("/sites/acceptsite/webhook/forgejo", data=body,
                     headers={"X-Forgejo-Signature": _sign(secret, body)})
    assert r.status_code == 200
    job = r.get_json()["job"]
    assert appmod._SITE_JOB_RE.fullmatch(job)
    assert len(stage_calls) == 1 and len(deploy_calls) == 1
    assert stage_calls[0][0] == appmod.SITES_WEBHOOK_STAGE_SCRIPT
    assert stage_calls[0][1] == ["acceptsite", "admin/blog", "a" * 40, "--job", job]
    assert deploy_calls[0][0] == appmod.SITES_DEPLOY_SCRIPT
    assert deploy_calls[0][1] == ["acceptsite", "/staged/webhook-x.zip", "--build", "none", "--job", job]


def test_webhook_hmac_wrong_secret_rejects(client, monkeypatch):
    _provision_secret("wrongsecretsite")
    body = _push_body()
    r = client.post("/sites/wrongsecretsite/webhook/forgejo", data=body,
                     headers={"X-Forgejo-Signature": _sign("not-the-real-secret", body)})
    assert r.status_code == 401


def test_webhook_hmac_tampered_body_rejects(client):
    secret = _provision_secret("tamperedsite")
    body = _push_body()
    sig = _sign(secret, body)
    tampered = _push_body(after="b" * 40)  # signature was computed over the ORIGINAL body
    r = client.post("/sites/tamperedsite/webhook/forgejo", data=tampered,
                     headers={"X-Forgejo-Signature": sig})
    assert r.status_code == 401


def test_webhook_hmac_missing_header_rejects(client):
    _provision_secret("missingheadersite")
    r = client.post("/sites/missingheadersite/webhook/forgejo", data=_push_body())
    assert r.status_code == 401


def test_webhook_hmac_gitea_signature_fallback_accepted(client, monkeypatch):
    secret = _provision_secret("gitealegacysite")
    fake_stage, _ = _fake_stage_ok()
    fake_deploy, deploy_calls = _fake_deploy_ok()
    monkeypatch.setattr(appmod, "run_script_argv", fake_stage)
    monkeypatch.setattr(appmod, "run_script_detached_argv", fake_deploy)

    body = _push_body()
    r = client.post("/sites/gitealegacysite/webhook/forgejo", data=body,
                     headers={"X-Gitea-Signature": _sign(secret, body)})
    assert r.status_code == 200
    assert len(deploy_calls) == 1


def test_webhook_hmac_missing_vs_wrong_header_identical_401(client):
    """§6.6's "no probing oracle" claim, the 401 half: an absent signature
    header and a present-but-wrong one must be indistinguishable."""
    secret = _provision_secret("identical401site")
    body = _push_body()
    r_missing = client.post("/sites/identical401site/webhook/forgejo", data=body)
    r_wrong = client.post("/sites/identical401site/webhook/forgejo", data=body,
                           headers={"X-Forgejo-Signature": _sign(secret + "x", body)})
    assert r_missing.status_code == 401 == r_wrong.status_code
    assert r_missing.get_data() == r_wrong.get_data()


def test_webhook_unknown_site_and_unprovisioned_site_identical_404(client):
    """§6.6's "no probing oracle" claim, the 404 half: a totally made-up site
    name and a valid-shaped name that simply has no webhook secret yet must
    return the SAME status+body — the route never distinguishes "no such
    site" from "site exists but no webhook configured"."""
    r1 = client.post("/sites/totallymadeupname/webhook/forgejo", data=_push_body())
    r2 = client.post("/sites/anotherrealsite/webhook/forgejo", data=_push_body())
    assert r1.status_code == 404 == r2.status_code
    assert r1.get_data() == r2.get_data()


# ── owner/repo regex matrix (traversal/absolute/newline/extra-slash, §6.8) ──

@pytest.mark.parametrize("owner_repo", [
    "admin/blog", "a/b", "a.b-c_d/e.f-g_h", "x" * 100 + "/" + "y" * 100,
])
def test_webhook_owner_repo_regex_accepts(owner_repo):
    assert appmod._WEBHOOK_OWNER_REPO_RE.fullmatch(owner_repo)


@pytest.mark.parametrize("owner_repo", [
    "", "noslash", "a/b/c", "/etc/passwd", "trailing/", "/leading",
    "a/b\nc", "good\n../evil", "../..", "a b/c",
])
def test_webhook_owner_repo_regex_rejects(owner_repo):
    assert not appmod._WEBHOOK_OWNER_REPO_RE.fullmatch(owner_repo)


def test_webhook_payload_bad_full_name_400(client):
    secret = _provision_secret("badpayloadsite")
    body = _push_body(full_name="../../etc/passwd")
    r = client.post("/sites/badpayloadsite/webhook/forgejo", data=body,
                     headers={"X-Forgejo-Signature": _sign(secret, body)})
    assert r.status_code == 400


# ── sha matrix (§6.8) ────────────────────────────────────────────────────────

@pytest.mark.parametrize("sha", ["a" * 40, "0" * 40, "0123456789abcdef" * 2 + "01234567"])
def test_webhook_sha_regex_accepts(sha):
    assert len(sha) == 40
    assert appmod._WEBHOOK_SHA_RE.fullmatch(sha)


@pytest.mark.parametrize("sha", ["a" * 39, "A" * 40, "g" * 40, "-" + "a" * 39, "", "a" * 41])
def test_webhook_sha_regex_rejects(sha):
    assert not appmod._WEBHOOK_SHA_RE.fullmatch(sha)


def test_webhook_payload_bad_sha_400(client):
    secret = _provision_secret("badshasite")
    body = _push_body(after="not-forty-hex-chars")
    r = client.post("/sites/badshasite/webhook/forgejo", data=body,
                     headers={"X-Forgejo-Signature": _sign(secret, body)})
    assert r.status_code == 400


# ── branch filter incl. tags (§6.8) ──────────────────────────────────────────

def test_webhook_branch_default_main_dispatches(client, monkeypatch):
    secret = _provision_secret("mainbranchsite")
    fake_stage, _ = _fake_stage_ok()
    fake_deploy, deploy_calls = _fake_deploy_ok()
    monkeypatch.setattr(appmod, "run_script_argv", fake_stage)
    monkeypatch.setattr(appmod, "run_script_detached_argv", fake_deploy)
    body = _push_body(ref="refs/heads/main")
    r = client.post("/sites/mainbranchsite/webhook/forgejo", data=body,
                     headers={"X-Forgejo-Signature": _sign(secret, body)})
    assert r.status_code == 200
    assert len(deploy_calls) == 1


def test_webhook_branch_feature_branch_skips(client, monkeypatch):
    secret = _provision_secret("featurebranchsite")
    fake_deploy, deploy_calls = _fake_deploy_ok()
    monkeypatch.setattr(appmod, "run_script_detached_argv", fake_deploy)
    body = _push_body(ref="refs/heads/feature-x")
    r = client.post("/sites/featurebranchsite/webhook/forgejo", data=body,
                     headers={"X-Forgejo-Signature": _sign(secret, body)})
    assert r.status_code == 200
    assert r.get_json() == {"skipped": "not the configured branch"}
    assert deploy_calls == []


def test_webhook_branch_tag_push_skips(client, monkeypatch):
    secret = _provision_secret("tagpushsite")
    fake_deploy, deploy_calls = _fake_deploy_ok()
    monkeypatch.setattr(appmod, "run_script_detached_argv", fake_deploy)
    body = _push_body(ref="refs/tags/v1")
    r = client.post("/sites/tagpushsite/webhook/forgejo", data=body,
                     headers={"X-Forgejo-Signature": _sign(secret, body)})
    assert r.status_code == 200
    assert r.get_json() == {"skipped": "not the configured branch"}
    assert deploy_calls == []


def test_webhook_branch_respects_configured_override(client, monkeypatch):
    secret = _provision_secret("prodbranchsite")
    monkeypatch.setattr(appmod, "SITES_WEBHOOK_BRANCH", "prod")
    fake_stage, _ = _fake_stage_ok()
    fake_deploy, deploy_calls = _fake_deploy_ok()
    monkeypatch.setattr(appmod, "run_script_argv", fake_stage)
    monkeypatch.setattr(appmod, "run_script_detached_argv", fake_deploy)

    skipped = client.post("/sites/prodbranchsite/webhook/forgejo", data=_push_body(ref="refs/heads/main"),
                           headers={"X-Forgejo-Signature": _sign(secret, _push_body(ref="refs/heads/main"))})
    assert skipped.get_json() == {"skipped": "not the configured branch"}

    body = _push_body(ref="refs/heads/prod")
    dispatched = client.post("/sites/prodbranchsite/webhook/forgejo", data=body,
                              headers={"X-Forgejo-Signature": _sign(secret, body)})
    assert dispatched.status_code == 200
    assert len(deploy_calls) == 1


# ── cooldown (§6.8: monkeypatched detached helper called exactly once) ──────

def test_webhook_cooldown_second_request_429(client, monkeypatch):
    secret = _provision_secret("cooldownsite")
    fake_stage, _ = _fake_stage_ok()
    fake_deploy, deploy_calls = _fake_deploy_ok()
    monkeypatch.setattr(appmod, "run_script_argv", fake_stage)
    monkeypatch.setattr(appmod, "run_script_detached_argv", fake_deploy)
    headers = {"X-Forgejo-Signature": _sign(secret, _push_body())}

    r1 = client.post("/sites/cooldownsite/webhook/forgejo", data=_push_body(), headers=headers)
    r2 = client.post("/sites/cooldownsite/webhook/forgejo", data=_push_body(), headers=headers)
    assert r1.status_code == 200
    assert r2.status_code == 429
    assert len(deploy_calls) == 1, "the cooldown must stop a SECOND dispatch, not just report one"


def test_webhook_cooldown_is_per_site(client, monkeypatch):
    secret_a = _provision_secret("cooldownsite-a")
    secret_b = _provision_secret("cooldownsite-b")
    fake_stage, _ = _fake_stage_ok()
    fake_deploy, deploy_calls = _fake_deploy_ok()
    monkeypatch.setattr(appmod, "run_script_argv", fake_stage)
    monkeypatch.setattr(appmod, "run_script_detached_argv", fake_deploy)

    body = _push_body()
    ra = client.post("/sites/cooldownsite-a/webhook/forgejo", data=body,
                      headers={"X-Forgejo-Signature": _sign(secret_a, body)})
    rb = client.post("/sites/cooldownsite-b/webhook/forgejo", data=body,
                      headers={"X-Forgejo-Signature": _sign(secret_b, body)})
    assert ra.status_code == 200 and rb.status_code == 200
    assert len(deploy_calls) == 2


# ── stage failure -> 502, deploy never dispatched (§6.7) ────────────────────

def test_webhook_stage_failure_gives_502_no_deploy(client, monkeypatch):
    secret = _provision_secret("stagefailsite")

    def fake_stage_fail(base_script, extra_argv, timeout=60):
        return 1, "git archive failed: bad sha"
    fake_deploy, deploy_calls = _fake_deploy_ok()
    monkeypatch.setattr(appmod, "run_script_argv", fake_stage_fail)
    monkeypatch.setattr(appmod, "run_script_detached_argv", fake_deploy)

    body = _push_body()
    r = client.post("/sites/stagefailsite/webhook/forgejo", data=body,
                     headers={"X-Forgejo-Signature": _sign(secret, body)})
    assert r.status_code == 502
    assert deploy_calls == []


# ── build-tier resolution from the registry (§6.4) ──────────────────────────

def test_webhook_resolves_build_tier_from_registry(client, monkeypatch, tmp_path):
    secret = _provision_secret("hugosite")
    reg_path = tmp_path / "reg.json"
    reg_path.write_text(json.dumps({"version": 1, "sites": {"hugosite": {"build": "hugo"}}}))
    monkeypatch.setattr(appmod, "SITES_REGISTRY", str(reg_path))
    fake_stage, _ = _fake_stage_ok()
    fake_deploy, deploy_calls = _fake_deploy_ok()
    monkeypatch.setattr(appmod, "run_script_argv", fake_stage)
    monkeypatch.setattr(appmod, "run_script_detached_argv", fake_deploy)

    body = _push_body()
    r = client.post("/sites/hugosite/webhook/forgejo", data=body,
                     headers={"X-Forgejo-Signature": _sign(secret, body)})
    assert r.status_code == 200
    assert "--build" in deploy_calls[0][1]
    assert deploy_calls[0][1][deploy_calls[0][1].index("--build") + 1] == "hugo"


# ── ENABLE double-gate (§6.4: 404 unless BOTH sites and sites-webhooks) ──────

def test_webhook_forgejo_route_404_when_sites_disabled(client, monkeypatch):
    _provision_secret("gatesite")
    monkeypatch.setitem(appmod.ENABLE, "sites", False)
    r = client.post("/sites/gatesite/webhook/forgejo", data=_push_body())
    assert r.status_code == 404


def test_webhook_forgejo_route_404_when_sites_webhooks_disabled(client, monkeypatch):
    _provision_secret("gatesite2")
    monkeypatch.setitem(appmod.ENABLE, "sites-webhooks", False)
    r = client.post("/sites/gatesite2/webhook/forgejo", data=_push_body())
    assert r.status_code == 404


def test_webhook_admin_page_404_when_disabled(authed, monkeypatch):
    monkeypatch.setitem(appmod.ENABLE, "sites-webhooks", False)
    assert authed.get("/sites/somesite/webhook").status_code == 404
    assert authed.post("/sites/somesite/webhook").status_code == 404


def test_webhook_forgejo_route_400_on_bad_site_name(client):
    r = client.post("/sites/Bad_Name/webhook/forgejo", data=_push_body())
    assert r.status_code == 400


# ── in-panel secret management page (§6.4) ──────────────────────────────────

def test_webhook_admin_requires_login(client):
    r = client.get("/sites/adminpagesite/webhook")
    assert r.status_code == 302 and "/login" in r.headers.get("Location", "")


def test_webhook_admin_get_shows_not_configured(authed):
    r = authed.get("/sites/freshsite/webhook")
    assert r.status_code == 200
    assert b"not configured yet" in r.data


def test_webhook_admin_generate_shows_secret_once_and_persists(authed, monkeypatch):
    def fake_run_script_argv(base_script, extra_argv, timeout=60):
        assert base_script == appmod.SITES_WEBHOOK_SECRET_SCRIPT
        assert extra_argv == ["generatedsite"]
        return 0, "abc123secret\n"
    monkeypatch.setattr(appmod, "run_script_argv", fake_run_script_argv)

    r = authed.post("/sites/generatedsite/webhook",
                     data={"_csrf": "unit-test-csrf-token", "rotate": "0"})
    assert r.status_code == 200
    assert b"abc123secret" in r.data
    assert b"Shown ONCE" in r.data


def test_webhook_admin_rotate_passes_rotate_flag(authed, monkeypatch):
    calls = []

    def fake_run_script_argv(base_script, extra_argv, timeout=60):
        calls.append(list(extra_argv))
        return 0, "newsecret456\n"
    monkeypatch.setattr(appmod, "run_script_argv", fake_run_script_argv)

    r = authed.post("/sites/rotatesite/webhook",
                     data={"_csrf": "unit-test-csrf-token", "rotate": "1"})
    assert r.status_code == 200
    assert calls == [["rotatesite", "--rotate"]]


def test_webhook_admin_post_requires_csrf(authed):
    r = authed.post("/sites/csrfsite/webhook", data={"rotate": "0"})
    assert r.status_code == 403


def test_webhook_admin_bad_site_name_400(authed):
    r = authed.get("/sites/Bad_Name/webhook")
    assert r.status_code == 400


def test_webhook_admin_reserved_name_400(authed):
    r = authed.get("/sites/admin/webhook")
    assert r.status_code == 400


# ══════════════════════════════════════════════════════════════════════════
# Part 2 — scripts/sites/webhook-stage.sh (real subprocess)
# ══════════════════════════════════════════════════════════════════════════

@pytest.fixture()
def stage_env(tmp_path):
    """Mirrors test_pipeline.py's sites_env fixture, PLUS the PREFIX seam so
    PD_BASE (lib-sites.sh) resolves the Forgejo repositories root under an
    isolated tmp tree instead of the real phone rootfs — the SAME technique
    test_pipeline.py's test_deploy_rejects_byo_collision already uses for the
    identical PD_BASE/PREFIX derivation, one level deeper."""
    sites_root = tmp_path / "sites-root"
    state_dir = tmp_path / "state"
    log_dir = tmp_path / "logs"
    prefix_dir = tmp_path / "prefix"
    sites_root.mkdir()
    state_dir.mkdir()
    log_dir.mkdir()

    repos_root = (prefix_dir / "var" / "lib" / "proot-distro" / "installed-rootfs"
                  / "debian" / "opt" / "forgejo" / "data" / "repositories")
    repos_root.mkdir(parents=True)

    env_file = tmp_path / ".env"
    env_file.write_text(
        "DOMAIN=ci.example.org\n"
        f"DATA_DIR={tmp_path / 'data'}\n"
        "CF_TUNNEL_TOKEN=x\n"
        "ADMIN_PASSWORD=x\n"
    )

    env = dict(os.environ)
    env.update({
        "POCKET_SITES_ROOT": str(sites_root),
        "POCKET_STATE_DIR": str(state_dir),
        "POCKET_LOG_DIR": str(log_dir),
        "POCKET_ENV": str(env_file),
        "PREFIX": str(prefix_dir),
    })
    return {
        "env": env, "tmp_path": tmp_path, "sites_root": sites_root,
        "staging": sites_root / ".staging", "repos_root": repos_root,
    }


def run_stage(args, env, **kwargs):
    cmd = ["bash", str(SITES_DIR / "webhook-stage.sh"), *[str(a) for a in args]]
    kwargs.setdefault("stdin", subprocess.DEVNULL)
    return subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=60, **kwargs)


def make_bare_repo(repos_root, owner, repo):
    bare = repos_root / owner / f"{repo}.git"
    bare.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["git", "init", "--bare", "-q", str(bare)], check=True)
    return bare


def make_bare_repo_with_commit(repos_root, owner, repo,
                                filename="hello.txt", content="hello from the fixture repo\n"):
    """git init --bare + a commit pushed via a work clone in tmp (§6.8's own
    wording). Returns (bare_repo_path, head_sha)."""
    bare = make_bare_repo(repos_root, owner, repo)
    work = bare.parent / f".{repo}-work"
    subprocess.run(["git", "clone", "-q", str(bare), str(work)], check=True)
    (work / filename).write_text(content)
    env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.org",
           "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.org"}
    subprocess.run(["git", "-C", str(work), "add", filename], check=True, env=env)
    subprocess.run(["git", "-C", str(work), "commit", "-q", "-m", "init"], check=True, env=env)
    subprocess.run(["git", "-C", str(work), "push", "-q", "origin", "HEAD"], check=True, env=env)
    sha = subprocess.run(["git", "-C", str(work), "rev-parse", "HEAD"],
                          check=True, capture_output=True, text=True, env=env).stdout.strip()
    return bare, sha


# ── argument count / usage ───────────────────────────────────────────────────

def test_webhook_stage_usage_error_on_too_few_args(stage_env):
    result = run_stage(["onlysite"], stage_env["env"])
    assert result.returncode != 0
    assert "usage:" in (result.stdout + result.stderr)


# ── --job validation ─────────────────────────────────────────────────────────

def test_webhook_stage_rejects_bad_job_id(stage_env):
    result = run_stage(["myblog", "admin/blog", "a" * 40, "--job", "not-a-valid-id"], stage_env["env"])
    assert result.returncode != 0
    assert "invalid --job id" in (result.stdout + result.stderr)


# ── owner/repo: regex layer (rejected before any filesystem touch) ─────────

@pytest.mark.parametrize("owner_repo", [
    "noslash", "a/b/c", "/etc/passwd", "trailing/", "/leading", "a/b\nc", "good\n../evil",
])
def test_webhook_stage_rejects_malformed_owner_repo(stage_env, owner_repo):
    result = run_stage(["myblog", owner_repo, "a" * 40], stage_env["env"])
    assert result.returncode != 0
    assert "invalid owner/repo" in (result.stdout + result.stderr)


# ── owner/repo: containment layer (regex-valid, but resolves outside root) ─

def test_webhook_stage_rejects_owner_repo_traversal_outside_root(stage_env):
    # ".." / ".." passes the regex (both segments contain only '.' chars) but
    # must be caught by realpath-containment, not the regex alone.
    result = run_stage(["myblog", "../..", "a" * 40], stage_env["env"])
    assert result.returncode != 0
    assert "outside the Forgejo repositories root" in (result.stdout + result.stderr)


# ── owner/repo: existence layer ─────────────────────────────────────────────

def test_webhook_stage_rejects_missing_repo(stage_env):
    result = run_stage(["myblog", "admin/doesnotexist", "a" * 40], stage_env["env"])
    assert result.returncode != 0
    assert "no such Forgejo repository" in (result.stdout + result.stderr)


# ── sha matrix ───────────────────────────────────────────────────────────────

@pytest.mark.skipif(not HAVE_GIT, reason="fixture bare-repo creation needs a real git binary")
@pytest.mark.parametrize("sha", ["a" * 39, "A" * 40, "g" * 40, "-" + "a" * 39, "zz"])
def test_webhook_stage_rejects_bad_sha(stage_env, sha):
    make_bare_repo(stage_env["repos_root"], "admin", "blog")
    result = run_stage(["myblog", "admin/blog", sha], stage_env["env"])
    assert result.returncode != 0
    assert "invalid sha" in (result.stdout + result.stderr)


@pytest.mark.skipif(not HAVE_GIT, reason="fixture bare-repo creation needs a real git binary")
def test_webhook_stage_accepts_wellformed_sha_shape(stage_env):
    make_bare_repo(stage_env["repos_root"], "admin", "blog")
    result = run_stage(["myblog", "admin/blog", "a" * 40], stage_env["env"])
    # Never rejected for SHA *shape* — whatever happens next (a real archive
    # attempt, gated on proot-distro) is covered separately below.
    assert "invalid sha" not in (result.stdout + result.stderr)


# ── proot-distro unavailable -> fail-closed, clear reason (real on THIS host) ─

@pytest.mark.skipif(HAVE_PROOT_DISTRO, reason="this assertion only holds when proot-distro is absent")
@pytest.mark.skipif(not HAVE_GIT, reason="fixture bare-repo creation needs a real git binary")
def test_webhook_stage_dies_closed_without_proot_distro(stage_env):
    make_bare_repo(stage_env["repos_root"], "admin", "blog")
    result = run_stage(["myblog", "admin/blog", "a" * 40], stage_env["env"])
    assert result.returncode != 0
    assert "proot-distro userland not available" in (result.stdout + result.stderr)
    assert list(stage_env["staging"].glob("webhook-*.zip")) == []


# ── real archive + content match — needs a real git AND a real proot-distro ─

@pytest.mark.skipif(not HAVE_GIT or not HAVE_PROOT_DISTRO,
                     reason="needs a real git binary AND proot-distro for the userland `git archive` "
                            "step — mirrors site-deploy.sh's hugo/node build tiers, which are ALSO not "
                            "laptop-testable (site-deploy.sh:141-145); exercised by the arm64 E2E harness "
                            "instead (SPEC-DIFFERENTIATORS.md §13)")
def test_webhook_stage_archives_head_commit_content_matches(stage_env):
    bare, sha = make_bare_repo_with_commit(stage_env["repos_root"], "admin", "blog")
    result = run_stage(["myblog", "admin/blog", sha], stage_env["env"])
    assert result.returncode == 0, result.stderr
    staged = Path(result.stdout.strip())
    assert staged.is_file()
    with zipfile.ZipFile(staged) as zf:
        assert zf.read("hello.txt").decode() == "hello from the fixture repo\n"


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v"]))
