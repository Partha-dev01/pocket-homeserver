"""tests/test_pipeline.py — end-to-end tests for the scripts/sites/*.sh pipeline.

Implements the "Laptop smoke" + unit-test intent of SPEC-SITES-PIPELINE.md §12
for the shell entry points (site-deploy/rollback/list/delete/gc.sh). Every
script is exercised as a REAL subprocess — never sourced or re-implemented in
Python — because the whole point of this test suite is to catch a bug in the
actual bash, not in a Python model of what the bash is supposed to do.

Isolation (the documented laptop-test seam, SPEC §3 AD-2 / lib-sites.sh):
  - POCKET_SITES_ROOT points lib-sites.sh's SITES_ROOT at a tmp_path dir, so
    PD_BASE/proot-distro (which do not exist on this laptop) are never
    consulted for file I/O.
  - POCKET_STATE_DIR / POCKET_LOG_DIR isolate job records + logs from the
    ${DATA_DIR}/state,logs a real phone would use.
  - POCKET_ENV points scripts/lib/common.sh's load_env() at a synthetic .env
    (load_env dies without one) with just enough set to satisfy the
    require_var checks these scripts make (DOMAIN, plus DATA_DIR/
    CF_TUNNEL_TOKEN/ADMIN_PASSWORD so a real .env-shaped file is sourced
    cleanly). common.sh also sources the repo's real config/versions.env
    AFTER .env — harmless, it defines unrelated app version pins.

Every subprocess call defaults stdin to DEVNULL (never a tty), which is what
makes the staging-containment test's "non-interactive caller" path exercised
deterministically regardless of how pytest itself happens to be invoked.
"""
import json
import os
import subprocess
import sys
import zipfile
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
SITES_DIR = REPO_ROOT / "scripts" / "sites"
SAFE_EXTRACT_EXISTS = (SITES_DIR / "safe_extract.py").exists()


# ── environment + subprocess plumbing ────────────────────────────────────────

@pytest.fixture()
def sites_env(tmp_path):
    sites_root = tmp_path / "sites-root"
    state_dir = tmp_path / "state"
    log_dir = tmp_path / "logs"
    sites_root.mkdir()
    state_dir.mkdir()
    log_dir.mkdir()

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
    })
    return {
        "env": env,
        "tmp_path": tmp_path,
        "sites_root": sites_root,
        "state_dir": state_dir,
        "log_dir": log_dir,
        "registry": sites_root / ".registry.json",
        "staging": sites_root / ".staging",
    }


def run_script(script, args, env, **kwargs):
    """Run one of scripts/sites/*.sh as a real subprocess. Invoked via `bash
    <path>`, NOT direct execution — this matches how the rest of the repo
    actually runs these scripts (scripts/install.sh:181's `run_step` does
    `bash "$path"`, and every apps/ops/*.sh script except install.sh itself
    ships WITHOUT the executable bit; scripts/sites/*.sh follows that same
    convention). stdin defaults to DEVNULL — deterministically NOT a tty,
    exercising the "non-interactive caller" branch every one of these scripts
    has (staging containment in site-deploy.sh, the --yes requirement in
    site-delete.sh) without relying on however the ambient test runner's own
    stdin happens to be wired up."""
    cmd = ["bash", str(SITES_DIR / script), *[str(a) for a in args]]
    kwargs.setdefault("stdin", subprocess.DEVNULL)
    return subprocess.run(
        cmd, env=env, capture_output=True, text=True, timeout=60, **kwargs
    )


def deploy(sites_env, name, artifact, extra_args=None, extra_env=None):
    args = [name, artifact, *(extra_args or [])]
    env = dict(sites_env["env"])
    if extra_env:
        env.update({k: str(v) for k, v in extra_env.items()})
    return run_script("site-deploy.sh", args, env)


def rollback(sites_env, name, release=None):
    args = [name] + ([release] if release else [])
    return run_script("site-rollback.sh", args, sites_env["env"])


def delete(sites_env, name, extra_args=None):
    args = [name, *(extra_args or [])]
    return run_script("site-delete.sh", args, sites_env["env"])


def site_list(sites_env, extra_args=None):
    return run_script("site-list.sh", extra_args or [], sites_env["env"])


def gc(sites_env, name=None, extra_env=None):
    args = [name] if name else []
    env = dict(sites_env["env"])
    if extra_env:
        env.update({k: str(v) for k, v in extra_env.items()})
    return run_script("site-gc.sh", args, env)


def load_registry(sites_env):
    return json.loads(sites_env["registry"].read_text())


def job_files(sites_env, kind=None):
    files = sorted(sites_env["state_dir"].glob("site-job-*.json"))
    jobs = [json.loads(f.read_text()) for f in files]
    if kind:
        jobs = [j for j in jobs if j["kind"] == kind]
    return jobs


def make_dir_artifact(base, name, index_html="<h1>hello</h1>", extra_files=None):
    d = base / name
    d.mkdir(parents=True, exist_ok=True)
    if index_html is not None:
        (d / "index.html").write_text(index_html)
    for rel, content in (extra_files or {}).items():
        p = d / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content)
    return d


def active_release_id(sites_env, name):
    current = sites_env["sites_root"] / name / "current"
    assert current.is_symlink(), f"{current} is not a symlink"
    target = os.readlink(current)
    assert not target.startswith("/"), f"current symlink target must be RELATIVE (AD-4), got: {target}"
    return Path(target).name


def release_dirs(sites_env, name):
    releases_dir = sites_env["sites_root"] / name / "releases"
    if not releases_dir.is_dir():
        return []
    return sorted(p.name for p in releases_dir.iterdir() if p.is_dir())


# ── name validation (§7) ─────────────────────────────────────────────────────

BAD_NAMES = [
    "Foo",           # uppercase
    "foo.bar",       # dot (not a single DNS label)
    "-foo",          # leading hyphen
    "foo-",          # trailing hyphen
    "a" * 64,        # too long (max 63)
    "",              # empty — argv-shape edge case, handled below separately
]

RESERVED_NAMES = ["chat", "admin", "www", "matrix", "mcp", "sites", "preview"]


@pytest.mark.parametrize("bad_name", [n for n in BAD_NAMES if n])
def test_deploy_rejects_invalid_name(sites_env, bad_name):
    artifact = make_dir_artifact(sites_env["staging"], "art")
    result = deploy(sites_env, bad_name, artifact)
    assert result.returncode != 0
    assert not (sites_env["sites_root"] / bad_name).exists()


@pytest.mark.parametrize("reserved", RESERVED_NAMES)
def test_deploy_rejects_reserved_name(sites_env, reserved):
    artifact = make_dir_artifact(sites_env["staging"], "art")
    result = deploy(sites_env, reserved, artifact)
    assert result.returncode != 0
    assert "reserved" in (result.stdout + result.stderr).lower()
    assert not (sites_env["sites_root"] / reserved).exists()


def test_deploy_accepts_valid_name(sites_env):
    artifact = make_dir_artifact(sites_env["staging"], "art")
    result = deploy(sites_env, "my-site1", artifact)
    assert result.returncode == 0, result.stderr


# ── deploy: dir artifact -> current + registry + job ────────────────────────

def test_deploy_dir_artifact_creates_current_and_registry(sites_env):
    artifact = make_dir_artifact(sites_env["staging"], "art", "<h1>v1</h1>")
    result = deploy(sites_env, "site1", artifact)
    assert result.returncode == 0, result.stderr

    rel = active_release_id(sites_env, "site1")
    current = sites_env["sites_root"] / "site1" / "current"
    assert (current / "index.html").read_text() == "<h1>v1</h1>"

    reg = load_registry(sites_env)
    site = reg["sites"]["site1"]
    assert site["active_release"] == rel
    assert site["releases"] == [rel]
    assert site["build"] == "none"
    assert site["url"] == "https://site1.ci.example.org"

    jobs = job_files(sites_env, kind="deploy")
    assert len(jobs) == 1
    assert jobs[0]["state"] == "done"
    assert jobs[0]["site"] == "site1"
    assert jobs[0]["release"] == rel
    assert jobs[0]["error"] is None

    # meta.json is written too (§4 layout).
    meta = json.loads((sites_env["sites_root"] / "site1" / "meta.json").read_text())
    assert meta["build"] == "none"


def test_second_deploy_creates_new_release_keeps_old(sites_env):
    art1 = make_dir_artifact(sites_env["staging"], "art1", "<h1>v1</h1>")
    r1 = deploy(sites_env, "site1", art1)
    assert r1.returncode == 0, r1.stderr
    rel1 = active_release_id(sites_env, "site1")

    art2 = make_dir_artifact(sites_env["staging"], "art2", "<h1>v2</h1>")
    r2 = deploy(sites_env, "site1", art2)
    assert r2.returncode == 0, r2.stderr
    rel2 = active_release_id(sites_env, "site1")

    assert rel1 != rel2
    current = sites_env["sites_root"] / "site1" / "current"
    assert (current / "index.html").read_text() == "<h1>v2</h1>"

    dirs = release_dirs(sites_env, "site1")
    assert rel1 in dirs and rel2 in dirs
    assert len(dirs) == 2  # both kept, default SITES_KEEP_RELEASES=5

    reg = load_registry(sites_env)
    assert reg["sites"]["site1"]["active_release"] == rel2
    assert set(reg["sites"]["site1"]["releases"]) == {rel1, rel2}


# ── rollback ──────────────────────────────────────────────────────────────

def test_rollback_default_previous_release(sites_env):
    art1 = make_dir_artifact(sites_env["staging"], "art1", "<h1>v1</h1>")
    deploy(sites_env, "site1", art1)
    rel1 = active_release_id(sites_env, "site1")

    art2 = make_dir_artifact(sites_env["staging"], "art2", "<h1>v2</h1>")
    deploy(sites_env, "site1", art2)
    rel2 = active_release_id(sites_env, "site1")
    assert rel1 != rel2

    result = rollback(sites_env, "site1")
    assert result.returncode == 0, result.stderr
    assert active_release_id(sites_env, "site1") == rel1

    current = sites_env["sites_root"] / "site1" / "current"
    assert (current / "index.html").read_text() == "<h1>v1</h1>"

    reg = load_registry(sites_env)
    assert reg["sites"]["site1"]["active_release"] == rel1

    jobs = job_files(sites_env, kind="rollback")
    assert len(jobs) == 1
    assert jobs[0]["state"] == "done"
    assert jobs[0]["release"] == rel1


def test_rollback_explicit_release_id(sites_env):
    art1 = make_dir_artifact(sites_env["staging"], "art1", "<h1>v1</h1>")
    deploy(sites_env, "site1", art1)
    rel1 = active_release_id(sites_env, "site1")

    art2 = make_dir_artifact(sites_env["staging"], "art2", "<h1>v2</h1>")
    deploy(sites_env, "site1", art2)
    rel2 = active_release_id(sites_env, "site1")

    art3 = make_dir_artifact(sites_env["staging"], "art3", "<h1>v3</h1>")
    deploy(sites_env, "site1", art3)
    assert active_release_id(sites_env, "site1") != rel2

    result = rollback(sites_env, "site1", rel2)
    assert result.returncode == 0, result.stderr
    assert active_release_id(sites_env, "site1") == rel2

    # An invalid/unknown release id must be rejected, not silently accepted.
    bad = rollback(sites_env, "site1", "20200101T000000Z-dead")
    assert bad.returncode != 0
    assert active_release_id(sites_env, "site1") == rel2  # unchanged on rejection

    _ = rel1  # kept for readability of the deploy sequence above


# ── GC retention ──────────────────────────────────────────────────────────

def test_gc_retention_keeps_configured_count(sites_env):
    for i in range(7):
        art = make_dir_artifact(sites_env["staging"], f"art{i}", f"<h1>v{i}</h1>")
        result = deploy(sites_env, "gcsite", art, extra_env={"SITES_KEEP_RELEASES": "3"})
        assert result.returncode == 0, result.stderr

    dirs = release_dirs(sites_env, "gcsite")
    assert len(dirs) == 3, dirs

    active = active_release_id(sites_env, "gcsite")
    assert active in dirs  # the active release is always kept

    reg = load_registry(sites_env)
    assert set(reg["sites"]["gcsite"]["releases"]) == set(dirs)


def test_site_gc_standalone_command(sites_env):
    for i in range(4):
        art = make_dir_artifact(sites_env["staging"], f"art{i}", f"<h1>v{i}</h1>")
        deploy(sites_env, "gcsite2", art, extra_env={"SITES_KEEP_RELEASES": "10"})
    assert len(release_dirs(sites_env, "gcsite2")) == 4

    result = gc(sites_env, "gcsite2")
    assert result.returncode == 0, result.stderr
    # keep default (5) >= 4 existing releases -> nothing pruned
    assert len(release_dirs(sites_env, "gcsite2")) == 4

    # unknown site name -> clear failure, not a silent no-op
    bad = gc(sites_env, "does-not-exist")
    assert bad.returncode != 0


# ── delete ────────────────────────────────────────────────────────────────

def test_delete_removes_tree_and_registry(sites_env):
    art = make_dir_artifact(sites_env["staging"], "art", "<h1>v1</h1>")
    deploy(sites_env, "site1", art)
    assert (sites_env["sites_root"] / "site1").exists()

    result = delete(sites_env, "site1", extra_args=["--yes"])
    assert result.returncode == 0, result.stderr

    assert not (sites_env["sites_root"] / "site1").exists()
    reg = load_registry(sites_env)
    assert "site1" not in reg["sites"]

    jobs = job_files(sites_env, kind="delete")
    assert len(jobs) == 1
    assert jobs[0]["state"] == "done"


def test_delete_without_yes_noninteractive_refuses(sites_env):
    art = make_dir_artifact(sites_env["staging"], "art", "<h1>v1</h1>")
    deploy(sites_env, "site1", art)

    result = delete(sites_env, "site1")  # no --yes, stdin is DEVNULL (not a tty)
    assert result.returncode != 0
    # nothing was touched
    assert (sites_env["sites_root"] / "site1").exists()
    reg = load_registry(sites_env)
    assert "site1" in reg["sites"]


# ── deploy failure: no residue, current untouched ────────────────────────

def test_deploy_failure_no_index_html_leaves_current_untouched(sites_env):
    good = make_dir_artifact(sites_env["staging"], "good", "<h1>v1</h1>")
    r1 = deploy(sites_env, "site1", good)
    assert r1.returncode == 0, r1.stderr
    rel1 = active_release_id(sites_env, "site1")
    dirs_before = release_dirs(sites_env, "site1")

    bad = make_dir_artifact(sites_env["staging"], "bad", index_html=None,
                             extra_files={"style.css": "body{}"})
    r2 = deploy(sites_env, "site1", bad)
    assert r2.returncode != 0

    # current must be untouched — still the first, good release.
    assert active_release_id(sites_env, "site1") == rel1

    # no leftover releases/<id>.tmp, and no half-published release promoted.
    releases_dir = sites_env["sites_root"] / "site1" / "releases"
    leftovers = [p.name for p in releases_dir.iterdir() if p.name.endswith(".tmp")]
    assert leftovers == [], f"leftover .tmp release dirs: {leftovers}"
    assert release_dirs(sites_env, "site1") == dirs_before

    jobs = job_files(sites_env, kind="deploy")
    failed = [j for j in jobs if j["state"] == "failed"]
    assert len(failed) == 1
    assert failed[0]["error"]
    assert failed[0]["release"] is None


def test_deploy_allow_no_index_bypasses_sanity_check(sites_env):
    bad = make_dir_artifact(sites_env["staging"], "bad", index_html=None,
                             extra_files={"style.css": "body{}"})
    result = deploy(sites_env, "site1", bad, extra_args=["--allow-no-index"])
    assert result.returncode == 0, result.stderr
    current = sites_env["sites_root"] / "site1" / "current"
    assert (current / "style.css").is_file()


# ── staging containment (§6) ────────────────────────────────────────────────

def test_staging_containment_rejects_path_outside_staging(sites_env):
    outside = make_dir_artifact(sites_env["tmp_path"] / "outside", "art", "<h1>x</h1>")
    result = deploy(sites_env, "site1", outside)  # stdin is DEVNULL -> non-tty path
    assert result.returncode != 0
    assert not (sites_env["sites_root"] / "site1").exists()


def test_staging_containment_accepts_path_inside_staging(sites_env):
    inside = make_dir_artifact(sites_env["staging"], "upload-abc123", "<h1>x</h1>")
    result = deploy(sites_env, "site1", inside)
    assert result.returncode == 0, result.stderr


# ── zip artifact (skipped until safe_extract.py exists) ────────────────────

@pytest.mark.skipif(not SAFE_EXTRACT_EXISTS, reason="scripts/sites/safe_extract.py not present yet")
def test_deploy_zip_artifact(sites_env):
    # Unlike make_dir_artifact (whose Path.mkdir(parents=True) implicitly
    # creates .staging/ too), a zip is a single FILE — .staging/ only exists
    # once a script has called sites_root_init(), so create it ourselves.
    sites_env["staging"].mkdir(parents=True, exist_ok=True)
    zip_path = sites_env["staging"] / "upload-1.zip"
    with zipfile.ZipFile(zip_path, "w") as zf:
        zf.writestr("index.html", "<h1>from zip</h1>")
        zf.writestr("assets/style.css", "body{color:red}")

    result = deploy(sites_env, "zipsite", zip_path)
    assert result.returncode == 0, result.stderr

    current = sites_env["sites_root"] / "zipsite" / "current"
    assert (current / "index.html").read_text() == "<h1>from zip</h1>"
    assert (current / "assets" / "style.css").is_file()

    reg = load_registry(sites_env)
    assert reg["sites"]["zipsite"]["active_release"] == active_release_id(sites_env, "zipsite")


# ── site-list ────────────────────────────────────────────────────────────

def test_site_list_json_and_rebuild(sites_env):
    art = make_dir_artifact(sites_env["staging"], "art", "<h1>v1</h1>")
    deploy(sites_env, "site1", art)

    result = site_list(sites_env, ["--json"])
    assert result.returncode == 0, result.stderr
    data = json.loads(result.stdout)
    assert "site1" in data["sites"]

    human = site_list(sites_env)
    assert human.returncode == 0, human.stderr
    assert "site1" in human.stdout

    # corrupt the registry, then --rebuild must self-heal it from the tree.
    sites_env["registry"].write_text("{not json")
    rebuilt = site_list(sites_env, ["--rebuild", "--json"])
    assert rebuilt.returncode == 0, rebuilt.stderr
    data2 = json.loads(rebuilt.stdout)
    assert data2["sites"]["site1"]["active_release"] == active_release_id(sites_env, "site1")


# ── hardening: whole-string name match (newline-bypass) ────────────────────
# validate_site_name used to grep PER LINE, so a name like "good\n--evil"
# passed because its FIRST line ("good") matched SUB_RE on its own — [[ =~ ]]
# now matches the WHOLE string, so any embedded/trailing newline fails.

def test_deploy_rejects_name_with_embedded_newline(sites_env):
    artifact = make_dir_artifact(sites_env["staging"], "art")
    bad_name = "good\n--evil"
    result = deploy(sites_env, bad_name, artifact)
    assert result.returncode != 0
    assert not (sites_env["sites_root"] / bad_name).exists()
    assert not (sites_env["sites_root"] / "good").exists()


def test_deploy_rejects_name_with_trailing_newline(sites_env):
    artifact = make_dir_artifact(sites_env["staging"], "art")
    bad_name = "good\n"
    result = deploy(sites_env, bad_name, artifact)
    assert result.returncode != 0
    assert not (sites_env["sites_root"] / bad_name).exists()
    assert not (sites_env["sites_root"] / "good").exists()


# ── hardening: --job id validation (site-deploy.sh) ─────────────────────────
# A caller-supplied --job id lands verbatim in state/log file paths, so it
# gets the same whole-string RELEASE_ID_RE gate as a release id, checked
# BEFORE sites_root_init/job_start ever run.

@pytest.mark.parametrize("bad_job", ["../../evil", "20260717T120000Z-XYZ!"])
def test_deploy_rejects_invalid_job_id(sites_env, bad_job):
    artifact = make_dir_artifact(sites_env["staging"], "art")
    result = deploy(sites_env, "site1", artifact, extra_args=["--job", bad_job])
    assert result.returncode != 0
    assert not (sites_env["sites_root"] / "site1").exists()
    # rejected before job_start ever runs -> no state file written anywhere,
    # in particular none at whatever path a "../../evil" id would traverse to.
    assert list(sites_env["state_dir"].glob("*")) == []


def test_deploy_accepts_valid_job_id_and_writes_done_state(sites_env):
    artifact = make_dir_artifact(sites_env["staging"], "art", "<h1>v1</h1>")
    job_id = "20260717T120000Z-ab12"
    result = deploy(sites_env, "site1", artifact, extra_args=["--job", job_id])
    assert result.returncode == 0, result.stderr

    job_file = sites_env["state_dir"] / f"site-job-{job_id}.json"
    assert job_file.is_file()
    doc = json.loads(job_file.read_text())
    assert doc["job"] == job_id
    assert doc["state"] == "done"
    assert doc["site"] == "site1"
    assert doc["error"] is None


# ── hardening: stray *.tmp build-shuffle dirs never look like real releases ─
# _site_releases_sorted/registry_update_site/registry_rebuild all exclude any
# release-dir name containing ".tmp" (both a bare "<id>.tmp" and a build-shuffle
# leftover like "<id>.tmp.out").

def test_stray_build_dirs_excluded_from_registry_and_rollback(sites_env):
    art1 = make_dir_artifact(sites_env["staging"], "art1", "<h1>v1</h1>")
    deploy(sites_env, "site1", art1)
    rel1 = active_release_id(sites_env, "site1")

    # Created chronologically BETWEEN the two real deploys: if this stray were
    # NOT excluded from _site_releases_sorted, a default (no-explicit-id)
    # rollback from rel2 would pick IT instead of the real rel1 (it would sort
    # newer than rel1 but older than rel2).
    releases_dir = sites_env["sites_root"] / "site1" / "releases"
    stray_mid = releases_dir / "20260101T000000Z-dead.tmp.out"
    stray_mid.mkdir(parents=True)

    art2 = make_dir_artifact(sites_env["staging"], "art2", "<h1>v2</h1>")
    deploy(sites_env, "site1", art2)
    rel2 = active_release_id(sites_env, "site1")
    assert rel1 != rel2

    # A second stray, a bare "<id>.tmp", created after the active release.
    stray_after = releases_dir / "20260101T000100Z-beef.tmp"
    stray_after.mkdir(parents=True)

    # --rebuild derives the registry straight from the on-disk tree — exactly
    # the path that must filter ".tmp" entries out.
    rebuilt = site_list(sites_env, ["--rebuild", "--json"])
    assert rebuilt.returncode == 0, rebuilt.stderr
    releases = json.loads(rebuilt.stdout)["sites"]["site1"]["releases"]
    assert set(releases) == {rel1, rel2}
    assert stray_mid.name not in releases
    assert stray_after.name not in releases

    # Default rollback (no explicit release id) must pick the real rel1.
    result = rollback(sites_env, "site1")
    assert result.returncode == 0, result.stderr
    assert active_release_id(sites_env, "site1") == rel1


def test_stray_build_dirs_not_counted_toward_gc_retention(sites_env):
    art1 = make_dir_artifact(sites_env["staging"], "art1", "<h1>v1</h1>")
    deploy(sites_env, "site1", art1, extra_env={"SITES_KEEP_RELEASES": "2"})
    rel1 = active_release_id(sites_env, "site1")

    art2 = make_dir_artifact(sites_env["staging"], "art2", "<h1>v2</h1>")
    deploy(sites_env, "site1", art2, extra_env={"SITES_KEEP_RELEASES": "2"})
    rel2 = active_release_id(sites_env, "site1")
    assert set(release_dirs(sites_env, "site1")) == {rel1, rel2}

    # Two strays created after both real releases. If sites_gc_site counted
    # them as real releases, the inflated total (4 > keep=2) would wrongly
    # evict the non-active real release (rel1) — the active one (rel2) is
    # always kept unconditionally, so rel1's survival is the tell.
    releases_dir = sites_env["sites_root"] / "site1" / "releases"
    (releases_dir / "20260101T000000Z-dead.tmp.out").mkdir(parents=True)
    (releases_dir / "20260101T000100Z-beef.tmp").mkdir(parents=True)

    result = gc(sites_env, "site1", extra_env={"SITES_KEEP_RELEASES": "2"})
    assert result.returncode == 0, result.stderr

    dirs = release_dirs(sites_env, "site1")
    assert rel1 in dirs and rel2 in dirs


# ── hardening: site-gc.sh hard-dies on a non-numeric retention env var ──────

def test_site_gc_rejects_non_numeric_job_retention_days(sites_env):
    result = gc(sites_env, extra_env={"SITES_JOB_RETENTION_DAYS": "abc"})
    assert result.returncode != 0
    assert "SITES_JOB_RETENTION_DAYS" in (result.stdout + result.stderr)


# ── hardening: a non-numeric SITES_KEEP_RELEASES warns + falls back to 5 ───

def test_deploy_tolerates_non_numeric_keep_releases_defaults_to_five(sites_env):
    result = None
    for i in range(7):
        art = make_dir_artifact(sites_env["staging"], f"art{i}", f"<h1>v{i}</h1>")
        result = deploy(sites_env, "banasite", art, extra_env={"SITES_KEEP_RELEASES": "banana"})
        assert result.returncode == 0, result.stderr

    dirs = release_dirs(sites_env, "banasite")
    assert len(dirs) == 5, dirs
    assert "not a whole number" in (result.stdout + result.stderr)


# ── hardening: BYO proxy-route collision check (validate_site_name) ────────

def test_deploy_rejects_byo_collision(sites_env):
    # PD_BASE derives from $PREFIX (lib-sites.sh); PREFIX is otherwise unused
    # anywhere else in the pipeline under test (SITES_ROOT always comes from
    # the POCKET_SITES_ROOT override baked into sites_env, never from
    # PD_BASE — confirmed by reading scripts/lib/common.sh, which never
    # references PREFIX at all), so pointing PREFIX at an isolated tmp dir
    # here has no side effect on anything else this suite exercises.
    prefix_dir = sites_env["tmp_path"] / "prefix"
    caddy_apps = (
        prefix_dir / "var" / "lib" / "proot-distro" / "installed-rootfs"
        / "debian" / "etc" / "caddy" / "apps"
    )
    caddy_apps.mkdir(parents=True)
    (caddy_apps / "byo-mysite.caddy").write_text("# byo route stub\n")

    artifact = make_dir_artifact(sites_env["staging"], "art", "<h1>v1</h1>")

    collide = deploy(sites_env, "mysite", artifact, extra_env={"PREFIX": prefix_dir})
    assert collide.returncode != 0
    assert "byo-mysite.caddy" in (collide.stdout + collide.stderr)
    assert not (sites_env["sites_root"] / "mysite").exists()

    ok_result = deploy(sites_env, "othersite", artifact, extra_env={"PREFIX": prefix_dir})
    assert ok_result.returncode == 0, ok_result.stderr


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v"]))
