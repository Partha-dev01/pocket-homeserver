"""tests/test_mcp.py — unit tests for scripts/mcp/pocket-mcp.py's M3 additions
(SPEC-MCP-COMPLETION.md §12): the `sites` tool group, the parity tools (doctor/
metrics/problems/audit/restart-stack/rotate-backups/offsite-push/user mgmt),
and the widened ENABLE/ALLOWED_LOGS config surface.

Import strategy mirrors tests/test_panel_sites.py: build a throwaway fixture
tree, point every POCKET_*/ENABLE_*/MCP_* seam at it via os.environ, import the
server module, then restore os.environ so other test modules' subprocess
environments are untouched. The module filename is hyphenated
(scripts/mcp/pocket-mcp.py), so a plain `import` can't reach it — this file
uses importlib.util.spec_from_file_location instead (AD-10 also means `mcp`
may be absent in a bare checkout; the whole module skips cleanly then).

Deliberately NOT here: full deploy/rollback/delete flows through the real
pipeline, or anything touching a live continuwuity admin room — those need the
arm64 E2E harness (§12's second section) and are not reachable from a laptop.
These tests pin the pure logic: closed-world validation, the confirm-binding
contract (AD-4), the detached-launch allowlist (AD-2), the metrics/problems
summarization, and the three-way reserved-list duplication contract (AD-3).
"""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import pytest

mcp = pytest.importorskip("mcp")

REPO_ROOT = Path(__file__).resolve().parents[1]


def _import_pocket_mcp(module_name, seams):
    """Import scripts/mcp/pocket-mcp.py under `module_name` with `seams` set in
    os.environ for the duration of the import, then restore os.environ exactly
    (test_panel_sites.py's own pattern) so later test modules' subprocess
    environments are untouched. A distinct module_name per call keeps this
    fully isolated from any other test file's own module cache — no
    sys.modules collision, regardless of pytest's collection order."""
    saved = {k: os.environ.get(k) for k in seams}
    os.environ.update(seams)
    try:
        spec = importlib.util.spec_from_file_location(
            module_name, REPO_ROOT / "scripts" / "mcp" / "pocket-mcp.py")
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


# ── fixture tree + seams, then import the module (ALL gates on) ──────────────
_BASE = Path(tempfile.mkdtemp(prefix="mcp-test."))
_DATA = _BASE / "data"
_SITES_ROOT = _BASE / "sites-root"
_STATE = _BASE / "state"
_LOGS = _BASE / "logs"
_METRICS_DIR = _BASE / "metrics"
for _d in (_DATA / "secrets", _SITES_ROOT / ".staging", _STATE, _LOGS, _METRICS_DIR):
    _d.mkdir(parents=True)

_SEAMS = {
    "DATA_DIR": str(_DATA),
    "POCKET_ROOT": str(REPO_ROOT),
    "DOMAIN": "ci.example.org",
    "POCKET_STATE_DIR": str(_STATE),
    "POCKET_LOG_DIR": str(_LOGS),
    "POCKET_SITES_ROOT": str(_SITES_ROOT),
    "POCKET_METRICS_LOG": str(_METRICS_DIR / "metrics.jsonl"),
    "ENABLE_MCP": "true",
    "ENABLE_SITES": "true",
    "ENABLE_USER_ADMIN": "true",
    "ENABLE_METRICS": "true",
    "ENABLE_OFFSITE_BACKUP": "true",
    "MCP_ALLOW_OPERATE": "true",
    "MCP_ALLOW_DANGER": "true",
}
mcpmod = _import_pocket_mcp("pocket_mcp_under_test", _SEAMS)


# ── three-way reserved-list duplication contract (AD-3) ──────────────────────

def test_site_reserved_three_way_parity():
    """lib-sites.sh's RESERVED_SUBS (the shell source), admin/app.py's
    SITE_RESERVED (M2's copy), and pocket-mcp.py's own SITE_RESERVED (M3's
    copy, this file) must all agree — AD-3's duplication contract needs a
    THREE-way check, not the panel's existing two-way one
    (tests/test_panel_sites.py:136-144)."""
    flask = pytest.importorskip("flask")  # admin/app.py needs it to import
    del flask

    bash_out = subprocess.run(
        ["bash", "-c",
         f'. "{REPO_ROOT}/scripts/sites/reserved-subs.sh" && printf "%s" "$RESERVED_SUBS"'],
        capture_output=True, text=True, check=True).stdout.split()
    assert len(bash_out) == len(set(bash_out)), "reserved-subs.sh contains duplicates"
    bash_set = set(bash_out)

    # admin/app.py is imported under ITS OWN module name + its own fixture
    # dirs, so this can never collide with tests/test_panel_sites.py's own
    # "app" import (which binds SECRETS/PASSWORD_FILE to a DIFFERENT fixture
    # tree) regardless of pytest's collection order.
    panel_base = Path(tempfile.mkdtemp(prefix="mcp-test-panel-parity."))
    (panel_base / "data" / "secrets").mkdir(parents=True)
    # admin/app.py's own import-time _sanity() check requires this file to
    # EXIST (content is irrelevant — this test never logs in).
    (panel_base / "data" / "secrets" / "adminweb-password.hash").write_text("x:x\n")
    panel_seams = {
        "DATA_DIR": str(panel_base / "data"),
        "POCKET_ROOT": str(REPO_ROOT),
        "DOMAIN": "ci.example.org",
        "ENABLE_SITES": "true",
        "POCKET_STATE_DIR": str(panel_base / "state"),
        "POCKET_LOG_DIR": str(panel_base / "logs"),
    }
    saved = {k: os.environ.get(k) for k in panel_seams}
    os.environ.update(panel_seams)
    try:
        aspec = importlib.util.spec_from_file_location(
            "pocket_admin_app_for_parity_check", REPO_ROOT / "admin" / "app.py")
        appmod = importlib.util.module_from_spec(aspec)
        aspec.loader.exec_module(appmod)
    finally:
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    assert bash_set == mcpmod.SITE_RESERVED, (
        "pocket-mcp.py SITE_RESERVED != reserved-subs.sh RESERVED_SUBS")
    assert bash_set == appmod.SITE_RESERVED, (
        "admin/app.py SITE_RESERVED != reserved-subs.sh RESERVED_SUBS")
    assert mcpmod.SITE_RESERVED == appmod.SITE_RESERVED, (
        "pocket-mcp.py SITE_RESERVED != admin/app.py SITE_RESERVED")


@pytest.mark.parametrize("name", ["a", "a1", "my-site", "0-0", "x" * 63])
def test_site_sub_re_accepts(name):
    assert mcpmod.SITE_SUB_RE.fullmatch(name)


@pytest.mark.parametrize("name", ["", "-lead", "trail-", "UPPER", "under_score",
                                  "dot.dot", "x" * 64, "a b", "a/b", "a\nb"])
def test_site_sub_re_rejects(name):
    assert not mcpmod.SITE_SUB_RE.fullmatch(name)


# ── _valid_user_target (§7.8, verbatim port of admin/app.py:3695-3696) ───────

@pytest.mark.parametrize("val", ["alice", "a1", "a.b_c=d-e", "a" * 64])
def test_valid_user_target_accepts_localpart(val):
    assert mcpmod._valid_user_target(val, allow_mxid=False) == val


@pytest.mark.parametrize("val", ["", "Alice", "a b", "a/b", "a" * 65,
                                  "@alice:ci.example.org"])
def test_valid_user_target_rejects_bad_localpart(val):
    with pytest.raises(ValueError):
        mcpmod._valid_user_target(val, allow_mxid=False)


def test_valid_user_target_accepts_mxid_when_allowed():
    v = "@alice:ci.example.org"
    assert mcpmod._valid_user_target(v, allow_mxid=True) == v


def test_valid_user_target_rejects_mxid_when_not_allowed():
    with pytest.raises(ValueError):
        mcpmod._valid_user_target("@alice:ci.example.org", allow_mxid=False)


@pytest.mark.parametrize("val", ["", "@bad", "alice; rm -rf /",
                                  # a genuinely EMBEDDED newline (not just a
                                  # trailing one — _valid_user_target's own
                                  # .strip() intentionally tolerates leading/
                                  # trailing whitespace, matching the rest of
                                  # this file's argument-validation convention,
                                  # e.g. pocket_restart_service's `.strip()`)
                                  "@alice:ci.example.org\nrm -rf /",
                                  "@alice:ci.example.org; rm"])
def test_valid_user_target_rejects_metacharacters_even_with_mxid_allowed(val):
    with pytest.raises(ValueError):
        mcpmod._valid_user_target(val, allow_mxid=True)


# ── pocket_site_deploy staging-containment (pure-function test, §12) ─────────

def test_site_deploy_staging_containment(monkeypatch):
    calls = []

    def fake_detached(*a, **k):
        calls.append((a, k))
        return True

    monkeypatch.setattr(mcpmod, "_run_ops_detached", fake_detached)
    monkeypatch.setattr(mcpmod, "_new_job_id", lambda: "20260717T120000Z-aaaa")

    # inside .staging/ — accepted, reaches the detached launch.
    inside = Path(mcpmod.SITES_STAGING) / "ok-artifact"
    inside.mkdir(parents=True, exist_ok=True)
    result = mcpmod.pocket_site_deploy("containtest", str(inside))
    assert "job=20260717T120000Z-aaaa" in result
    assert len(calls) == 1
    assert calls[0][0][0] == "sites/site-deploy.sh"

    # a path that resolves OUTSIDE .staging/ via '..' — rejected before launch.
    calls.clear()
    outside = Path(mcpmod.SITES_STAGING) / ".." / "escaped"
    with pytest.raises(ValueError, match="must resolve inside"):
        mcpmod.pocket_site_deploy("containtest", str(outside))
    assert calls == []

    # a path that does not exist at all, even inside staging — rejected.
    with pytest.raises(ValueError, match="does not exist"):
        mcpmod.pocket_site_deploy("containtest", str(Path(mcpmod.SITES_STAGING) / "nope"))
    assert calls == []


def test_site_deploy_rejects_invalid_or_reserved_name(monkeypatch):
    monkeypatch.setattr(mcpmod, "_run_ops_detached", lambda *a, **k: True)
    with pytest.raises(ValueError):
        mcpmod.pocket_site_deploy("www", str(Path(mcpmod.SITES_STAGING)))
    with pytest.raises(ValueError):
        mcpmod.pocket_site_deploy("Bad_Name", str(Path(mcpmod.SITES_STAGING)))


def test_site_deploy_rejects_bad_build_value(monkeypatch):
    monkeypatch.setattr(mcpmod, "_run_ops_detached", lambda *a, **k: True)
    art = Path(mcpmod.SITES_STAGING) / "buildtest-art"
    art.mkdir(parents=True, exist_ok=True)
    with pytest.raises(ValueError, match="build must be one of"):
        mcpmod.pocket_site_deploy("buildtest", str(art), build="php")


# ── pocket_site_status: race window + traversal (§12) ────────────────────────

def test_site_status_job_present_returns_state_and_log_tail():
    job = "20260717T120000Z-bbbb"
    (Path(mcpmod.STATE) / f"site-job-{job}.json").write_text(
        json.dumps({"job": job, "state": "done", "site": "okname"}))
    (Path(mcpmod.LOGS) / f"site-deploy-{job}.log").write_text("line1\nline2\n")
    doc = json.loads(mcpmod.pocket_site_status(job))
    assert doc["state"] == "done"
    assert "line1" in doc["log_tail"]


def test_site_status_missing_job_file_reports_running_not_raising():
    job = "20260717T120000Z-cccc"
    doc = json.loads(mcpmod.pocket_site_status(job))
    assert doc["job"] == job
    assert doc["state"] == "running"


@pytest.mark.parametrize("bad", ["", "../etc/passwd", "20260717T1200Z-a1b2/..",
                                  "20260717T1200Z-a1b2;rm",
                                  # a genuinely EMBEDDED newline (not just a
                                  # trailing one — pocket_site_status's own
                                  # `.strip()` intentionally tolerates leading/
                                  # trailing whitespace, matching every other
                                  # closed-world argument check in this file)
                                  "2026\n0717T1200Z-a1b2",
                                  "20260717t1200z-a1b2"])
def test_site_status_rejects_malformed_job_id_before_touching_a_file(bad):
    with pytest.raises(ValueError):
        mcpmod.pocket_site_status(bad)


# ── pocket_sites_list / pocket_site_releases / pocket_site_rollback reads ────

def test_sites_list_degrades_on_missing_registry(monkeypatch, tmp_path):
    monkeypatch.setattr(mcpmod, "SITES_REGISTRY", str(tmp_path / "missing.json"))
    doc = json.loads(mcpmod.pocket_sites_list())
    assert doc == {"version": 1, "sites": {}}


def test_site_releases_unknown_site_raises(monkeypatch, tmp_path):
    reg = tmp_path / "reg.json"
    reg.write_text(json.dumps({"version": 1, "sites": {}}))
    monkeypatch.setattr(mcpmod, "SITES_REGISTRY", str(reg))
    with pytest.raises(ValueError):
        mcpmod.pocket_site_releases("no-such-site-xyz")


def test_site_rollback_rejects_unknown_release(monkeypatch, tmp_path):
    reg = tmp_path / "reg.json"
    reg.write_text(json.dumps({"version": 1, "sites": {
        "rollsite": {"releases": ["20260717T120000Z-aaaa"]}}}))
    monkeypatch.setattr(mcpmod, "SITES_REGISTRY", str(reg))
    with pytest.raises(ValueError):
        mcpmod.pocket_site_rollback("rollsite", "20260717T999999Z-zzzz")


# ── target-bound DANGER confirm (AD-4) ────────────────────────────────────────

def test_site_delete_confirm_mismatch_refused_and_script_never_invoked(monkeypatch, tmp_path):
    reg = tmp_path / "reg.json"
    reg.write_text(json.dumps({"version": 1, "sites": {"delsite": {"releases": []}}}))
    monkeypatch.setattr(mcpmod, "SITES_REGISTRY", str(reg))
    calls = []
    monkeypatch.setattr(mcpmod, "_run_ops", lambda *a, **k: calls.append((a, k)) or (0, "ok"))
    with pytest.raises(ValueError):
        mcpmod.pocket_site_delete("delsite", "wrong-confirm")
    assert calls == [], "the backing script must NEVER be invoked on a confirm mismatch"


def test_site_delete_confirm_match_proceeds(monkeypatch, tmp_path):
    reg = tmp_path / "reg.json"
    reg.write_text(json.dumps({"version": 1, "sites": {"delsite2": {"releases": []}}}))
    monkeypatch.setattr(mcpmod, "SITES_REGISTRY", str(reg))
    calls = []
    monkeypatch.setattr(mcpmod, "_run_ops", lambda *a, **k: calls.append((a, k)) or (0, "deleted"))
    mcpmod.pocket_site_delete("delsite2", "delsite2")
    assert len(calls) == 1
    assert calls[0][0][0] == "sites/site-delete.sh"
    assert calls[0][0][1] == "delsite2"


def test_site_delete_unknown_site_refused_before_confirm_check(monkeypatch, tmp_path):
    reg = tmp_path / "reg.json"
    reg.write_text(json.dumps({"version": 1, "sites": {}}))
    monkeypatch.setattr(mcpmod, "SITES_REGISTRY", str(reg))
    calls = []
    monkeypatch.setattr(mcpmod, "_run_ops", lambda *a, **k: calls.append((a, k)) or (0, "ok"))
    with pytest.raises(ValueError, match="nothing to delete"):
        mcpmod.pocket_site_delete("ghost-site", "ghost-site")
    assert calls == []


def test_user_deactivate_confirm_checked_against_raw_user_not_mxid(monkeypatch):
    """AD-4: confirm is compared against the RAW `user` argument, not the
    validated/expanded target — a caller who typed a bare localpart but
    confirms with the full MXID must be refused, exactly like the panel's own
    pre-expansion comparison (admin/app.py:3817)."""
    calls = []
    monkeypatch.setattr(mcpmod, "_run_ops", lambda *a, **k: calls.append((a, k)) or (0, "ok"))
    with pytest.raises(ValueError):
        mcpmod.pocket_user_deactivate("alice", "@alice:ci.example.org")
    assert calls == []


def test_user_deactivate_confirm_match_proceeds(monkeypatch):
    calls = []
    monkeypatch.setattr(mcpmod, "_run_ops", lambda *a, **k: calls.append((a, k)) or (0, "ok"))
    mcpmod.pocket_user_deactivate("alice", "alice")
    assert len(calls) == 1
    assert calls[0][0][0] == "ops/user-deactivate.sh"
    assert calls[0][0][1] == "alice"


# ── _run_ops_detached: allowlist / escape / successful launch (AD-2) ─────────

@pytest.fixture()
def fake_scripts(monkeypatch, tmp_path):
    monkeypatch.setattr(mcpmod, "SCRIPTS", str(tmp_path))
    monkeypatch.setattr(mcpmod, "LOGS", str(tmp_path / "logs"))
    return tmp_path


def test_run_ops_detached_rejects_non_allowlisted(fake_scripts):
    (fake_scripts / "noop.sh").write_text("#!/usr/bin/env bash\nexit 0\n")
    with pytest.raises(ValueError, match="non-allowlisted"):
        mcpmod._run_ops_detached("noop.sh")


def test_run_ops_detached_rejects_realpath_escape(monkeypatch, fake_scripts):
    monkeypatch.setattr(mcpmod, "_DETACHED_ALLOWLIST", frozenset(("../evil.sh",)))
    with pytest.raises(ValueError, match="escapes"):
        mcpmod._run_ops_detached("../evil.sh")


def test_run_ops_detached_successful_launch_writes_sink(monkeypatch, fake_scripts):
    marker = fake_scripts / "detached-argv.txt"
    (fake_scripts / "noop.sh").write_text(
        f'#!/usr/bin/env bash\nprintf "[%s]" "$@" > "{marker}"\necho sink-line\n')
    monkeypatch.setattr(mcpmod, "_DETACHED_ALLOWLIST", frozenset(("noop.sh",)))
    ok = mcpmod._run_ops_detached("noop.sh", "n1", "--job", "j1")
    assert ok is True
    for _ in range(50):
        if marker.exists() and (fake_scripts / "logs" / "mcp-async.log").exists():
            break
        time.sleep(0.1)
    assert marker.read_text() == "[n1][--job][j1]"
    assert "sink-line" in (fake_scripts / "logs" / "mcp-async.log").read_text()


# ── §14 finding 5: _run_ops now passes stdin=subprocess.DEVNULL explicitly ──

def test_run_ops_passes_stdin_devnull(monkeypatch):
    captured = {}

    class _FakeCompleted:
        returncode = 0
        stdout = ""
        stderr = ""

    def fake_run(cmd, **kwargs):
        captured.update(kwargs)
        return _FakeCompleted()

    monkeypatch.setattr(mcpmod.subprocess, "run", fake_run)
    mcpmod._run_ops("ops/status.sh")
    assert captured.get("stdin") is mcpmod.subprocess.DEVNULL


# ── pocket_metrics: empty ring, synthetic summary, absent fields omitted ────

def test_metrics_empty_ring_file():
    p = Path(mcpmod.METRICS_LOG)
    p.parent.mkdir(parents=True, exist_ok=True)
    if p.exists():
        p.unlink()
    doc = json.loads(mcpmod.pocket_metrics())
    assert doc["samples"] == []
    assert "note" in doc


def test_metrics_synthetic_ring_summary_and_absent_fields_omitted():
    p = Path(mcpmod.METRICS_LOG)
    p.parent.mkdir(parents=True, exist_ok=True)
    recs = [
        {"ts": 1, "cpu": 10, "mem": 40},
        {"ts": 2, "cpu": 20, "mem": 50, "temp": 35},
        {"ts": 3, "cpu": 30},
    ]
    p.write_text("\n".join(json.dumps(r) for r in recs) + "\n")
    doc = json.loads(mcpmod.pocket_metrics(10))
    assert doc["sample_count"] == 3
    assert doc["summary"]["cpu"] == {"current": 30, "min": 10, "avg": 20.0, "max": 30}
    assert doc["summary"]["mem"] == {"current": 50, "min": 40, "avg": 45.0, "max": 50}
    # present in only ONE record — still summarized (never omitted merely for
    # being sparse; only a field ABSENT FROM EVERY record is omitted).
    assert doc["summary"]["temp"] == {"current": 35, "min": 35, "avg": 35.0, "max": 35}
    # absent from every record — must be omitted, not reported as 0.
    for absent in ("swap", "l1", "disk", "batt", "deg"):
        assert absent not in doc["summary"]


def test_metrics_samples_cap_bounded_to_500(monkeypatch, tmp_path):
    p = tmp_path / "metrics.jsonl"
    p.write_text("\n".join(json.dumps({"ts": i, "cpu": 1}) for i in range(600)) + "\n")
    monkeypatch.setattr(mcpmod, "METRICS_LOG", str(p))
    doc = json.loads(mcpmod.pocket_metrics(10000))
    assert doc["sample_count"] == mcpmod._METRICS_MAX_SAMPLES == 500


# ── pocket_problems: buckets + all-green ─────────────────────────────────────

def test_problems_buckets(monkeypatch, tmp_path):
    monkeypatch.setattr(mcpmod, "STATE", str(tmp_path))
    monkeypatch.setattr(mcpmod, "_probe", lambda p: {"name": p["name"], "code": 200,
                                                       "latency_ms": 1, "ok": True, "error": ""})
    (tmp_path / "up-svc.cmd").write_text("true\n")
    (tmp_path / "up-svc.pid").write_text(str(os.getpid()))
    (tmp_path / "down-svc.cmd").write_text("true\n")  # no .pid -> DOWN
    (tmp_path / "degraded-svc.cmd").write_text("true\n")
    (tmp_path / "degraded-svc.pid").write_text(str(os.getpid()))
    (tmp_path / "degraded-svc.degraded").write_text("rc=1 fails=5\n")

    doc = json.loads(mcpmod.pocket_problems())
    assert doc["ok"] is False
    assert doc["down"] == ["down-svc"]
    assert [d["service"] for d in doc["degraded"]] == ["degraded-svc"]
    assert doc["failing_probes"] == []


def test_problems_fully_healthy_is_ok(monkeypatch, tmp_path):
    monkeypatch.setattr(mcpmod, "STATE", str(tmp_path))
    monkeypatch.setattr(mcpmod, "_probe", lambda p: {"name": p["name"], "code": 200,
                                                       "latency_ms": 1, "ok": True, "error": ""})
    (tmp_path / "up-svc.cmd").write_text("true\n")
    (tmp_path / "up-svc.pid").write_text(str(os.getpid()))
    doc = json.loads(mcpmod.pocket_problems())
    assert doc == {"ok": True, "message": "no problems"}


def test_health_smoke_includes_degraded_and_probe_section(monkeypatch, tmp_path):
    monkeypatch.setattr(mcpmod, "STATE", str(tmp_path))
    monkeypatch.setattr(mcpmod, "_probe", lambda p: {"name": p["name"], "code": 200,
                                                       "latency_ms": 1, "ok": True, "error": ""})
    (tmp_path / "deg-svc.cmd").write_text("true\n")
    (tmp_path / "deg-svc.pid").write_text(str(os.getpid()))
    (tmp_path / "deg-svc.degraded").write_text("rc=1 fails=5\n")
    out = mcpmod.pocket_health()
    assert "supervised services up" in out
    assert "DEGRADED deg-svc" in out
    assert "core HTTP probes:" in out


# ── ALLOWED_LOGS widened (AD-8) ───────────────────────────────────────────────

def test_allowed_logs_widened_with_new_basenames():
    for name in ("metrics-sampler.log", "user-filter.log", "media-filter.log",
                 "honeypot-watcher.log", "adminweb-async.log", "mcp-async.log"):
        assert name in mcpmod._DEFAULT_ALLOWED_LOGS
    assert isinstance(mcpmod.ALLOWED_LOGS, (set, frozenset))


# ── ENABLE dict: 4 new keys, correctly read their env var (AD-9) ─────────────

@pytest.mark.parametrize("key,envvar", [
    ("sites", "ENABLE_SITES"),
    ("user-admin", "ENABLE_USER_ADMIN"),
    ("metrics", "ENABLE_METRICS"),
    ("offsite", "ENABLE_OFFSITE_BACKUP"),
])
def test_enable_new_keys_present_and_read_their_env_var(key, envvar):
    assert key in mcpmod.ENABLE
    assert mcpmod.ENABLE[key] is True  # baked in at import time from _SEAMS

    saved = os.environ.get(envvar)
    try:
        os.environ[envvar] = "false"
        assert mcpmod._flag(envvar) is False
        os.environ[envvar] = "true"
        assert mcpmod._flag(envvar) is True
    finally:
        if saved is None:
            os.environ.pop(envvar, None)
        else:
            os.environ[envvar] = saved


# ── registration-time gating: a tool is simply NOT registered when its gate
# is off, mirroring the file's own stated security invariant ─────────────────

def test_gates_off_leaves_m3_gated_tools_unregistered():
    base = Path(tempfile.mkdtemp(prefix="mcp-test-gates-off."))
    (base / "data" / "secrets").mkdir(parents=True)
    seams = {
        "DATA_DIR": str(base / "data"),
        "POCKET_ROOT": str(REPO_ROOT),
        "DOMAIN": "ci.example.org",
        "POCKET_STATE_DIR": str(base / "state"),
        "POCKET_LOG_DIR": str(base / "logs"),
        "POCKET_SITES_ROOT": str(base / "sites-root"),
        "ENABLE_SITES": "false",
        "ENABLE_USER_ADMIN": "false",
        "ENABLE_METRICS": "false",
        "ENABLE_OFFSITE_BACKUP": "false",
        "MCP_ALLOW_OPERATE": "false",
        "MCP_ALLOW_DANGER": "false",
    }
    mod = _import_pocket_mcp("pocket_mcp_gates_off", seams)
    for name in ("pocket_sites_list", "pocket_site_releases", "pocket_site_status",
                 "pocket_site_deploy", "pocket_site_rollback", "pocket_site_delete",
                 "pocket_metrics", "pocket_offsite_push", "pocket_user_create",
                 "pocket_user_reset_password", "pocket_user_suspend",
                 "pocket_user_unsuspend", "pocket_user_deactivate",
                 "pocket_restart_stack", "pocket_rotate_backups"):
        assert not hasattr(mod, name), f"{name} registered despite its gate being off"
    # always-on parity reads stay present regardless of ENABLE/OPERATE/DANGER.
    for name in ("pocket_doctor", "pocket_problems", "pocket_audit_recent",
                 "pocket_health"):
        assert hasattr(mod, name)
