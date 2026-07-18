"""tests/test_landing_regen.py — laptop render tests for scripts/landing/regen-landing.sh.

Implements SPEC-LANDING-SYNC.md §10's "laptop render test" via the --print seam
(AD-5): the script is exercised as a REAL subprocess — never sourced or
re-implemented in Python — and --print stops before the only proot-dependent
step (the userland write), so the whole render path runs on a plain Linux
runner with no Termux/Android/proot dependency.

Isolation mirrors tests/test_pipeline.py:
  - POCKET_SITES_ROOT points the registry read at a tmp_path dir (the SAME
    seam lib-sites.sh documents — one fixture convention across M1+M2 suites).
  - POCKET_ENV points load_env() at a synthetic .env with just enough to
    satisfy require_var (DOMAIN plus the usual .env-shaped fields).

Beyond §10's asserts, this file pins the M2 hardening regressions:
  - registry keys are re-filtered against SUB_RE before landing on the PUBLIC
    page (a tampered registry — e.g. a malicious Node build writing inside the
    userland — must not become injected markup),
  - the brand awk-gsub `&` escape (BRAND_HTML always contains `&` once the
    HTML escape fires; unescaped it renders "A & B" as "A __BRAND__amp; B"),
  - the teal re-theme is complete (no blue/purple hex from the old palette),
  - the exec bit on regen-landing.sh (the deploy/delete hook gates on `[ -x ]`
    and silently no-ops forever without it — the repo's one exec-bit
    exception),
  - the SPA vhost block is sibling try_files+file_server, never route-wrapped
    (Caddy sorts `route` before `respond`, so a route wrapper serves dotfiles
    past the wildcard vhost's @dot 403 guard — SPEC-SITES-PANEL §15
    CORRECTION 2026-07-17).
"""
import json
import os
import re
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
REGEN = REPO_ROOT / "scripts" / "landing" / "regen-landing.sh"
SITES_VHOST_TMPL = REPO_ROOT / "scripts" / "sites" / "sites.caddy.tmpl"
SITES_APP_SH = REPO_ROOT / "scripts" / "apps" / "sites.sh"

DOMAIN = "ci.example.org"


# ── environment + subprocess plumbing ────────────────────────────────────────

@pytest.fixture()
def landing_env(tmp_path):
    sites_root = tmp_path / "sites-root"
    sites_root.mkdir()

    env_file = tmp_path / ".env"
    env_file.write_text(
        f"DOMAIN={DOMAIN}\n"
        f"DATA_DIR={tmp_path / 'data'}\n"
        "CF_TUNNEL_TOKEN=x\n"
        "ADMIN_PASSWORD=x\n"
        "ENABLE_LANDING=true\n"
        "ENABLE_SITES=true\n"
        "ENABLE_LINKDING=true\n"
    )

    env = dict(os.environ)
    env.update({
        "POCKET_SITES_ROOT": str(sites_root),
        "POCKET_ENV": str(env_file),
    })
    return {
        "env": env,
        "env_file": env_file,
        "sites_root": sites_root,
        "registry": sites_root / ".registry.json",
    }


def write_registry(landing_env, names):
    landing_env["registry"].write_text(json.dumps({
        "version": 1,
        "sites": {n: {"releases": [], "active_release": ""} for n in names},
    }))


def render(landing_env):
    """Run regen-landing.sh --print as a real subprocess; return the result."""
    return subprocess.run(
        ["bash", str(REGEN), "--print"],
        env=landing_env["env"],
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        timeout=60,
    )


def set_env_var(landing_env, key, value):
    lines = [
        ln for ln in landing_env["env_file"].read_text().splitlines()
        if not ln.startswith(f"{key}=")
    ]
    lines.append(f"{key}={value}")
    landing_env["env_file"].write_text("\n".join(lines) + "\n")


# ── §10: the happy path ──────────────────────────────────────────────────────

def test_sites_section_renders_from_registry(landing_env):
    write_registry(landing_env, ["blog", "docs"])
    r = render(landing_env)
    assert r.returncode == 0, r.stderr
    assert 'class="card site"' in r.stdout
    assert f"blog.{DOMAIN}" in r.stdout
    assert f"docs.{DOMAIN}" in r.stdout
    # app-card logic is untouched: chat is core, linkding was enabled above
    assert f"chat.{DOMAIN}" in r.stdout
    assert f"links.{DOMAIN}" in r.stdout


def test_no_standalone_marker_lines_survive(landing_env):
    # The rendered page legitimately mentions the marker names in comment
    # PROSE (the template documents its own tokens) — only a STANDALONE
    # marker line means the substitution failed.
    write_registry(landing_env, ["blog"])
    r = render(landing_env)
    assert r.returncode == 0, r.stderr
    for marker in ("POCKET_CARDS", "POCKET_SITES_SECTION"):
        assert not re.search(rf"^[ \t]*{marker}[ \t]*$", r.stdout, re.M), marker
    assert "__BRAND__" not in r.stdout


def test_print_mode_needs_no_proot(landing_env):
    # --print exits before require_cmd proot-distro — the whole point of the
    # laptop seam. If this ever regresses, the run fails on any machine
    # without proot-distro (i.e. every CI runner).
    write_registry(landing_env, ["blog"])
    r = render(landing_env)
    assert r.returncode == 0, r.stderr
    assert "proot-distro" not in r.stderr


# ── §10: the section vanishes cleanly ────────────────────────────────────────

def test_sites_disabled_renders_no_section(landing_env):
    write_registry(landing_env, ["blog"])
    set_env_var(landing_env, "ENABLE_SITES", "false")
    r = render(landing_env)
    assert r.returncode == 0, r.stderr
    assert 'class="card site"' not in r.stdout


def test_missing_registry_renders_no_section(landing_env):
    r = render(landing_env)  # no .registry.json written at all
    assert r.returncode == 0, r.stderr
    assert 'class="card site"' not in r.stdout


def test_corrupt_registry_is_not_fatal(landing_env):
    landing_env["registry"].write_text("{ not json")
    r = render(landing_env)
    assert r.returncode == 0, r.stderr
    assert 'class="card site"' not in r.stdout


def test_empty_registry_renders_no_section(landing_env):
    write_registry(landing_env, [])
    r = render(landing_env)
    assert r.returncode == 0, r.stderr
    assert 'class="card site"' not in r.stdout


def test_landing_disabled_is_a_silent_noop(landing_env):
    write_registry(landing_env, ["blog"])
    set_env_var(landing_env, "ENABLE_LANDING", "false")
    r = render(landing_env)
    assert r.returncode == 0, r.stderr
    assert "<html" not in r.stdout


# ── hardening: hostile registry keys never reach the public page ─────────────

def test_hostile_registry_keys_are_filtered(landing_env):
    write_registry(landing_env, [
        "goodsite",
        "<script>alert(1)</script>",      # markup injection
        "Bad_Name",                        # uppercase + underscore
        "-leadinghyphen",
        "a" * 64,                          # over the 63-char DNS label cap
    ])
    r = render(landing_env)
    assert r.returncode == 0, r.stderr
    assert f"goodsite.{DOMAIN}" in r.stdout
    assert "alert(1)" not in r.stdout
    assert "Bad_Name" not in r.stdout
    assert "-leadinghyphen" not in r.stdout
    assert "a" * 64 not in r.stdout


# ── hardening: brand escaping (HTML + awk-gsub `&`) ──────────────────────────

def test_brand_html_and_gsub_escape(landing_env):
    write_registry(landing_env, ["blog"])
    set_env_var(landing_env, "LANDING_BRAND", '"Bob & Alice <3"')
    r = render(landing_env)
    assert r.returncode == 0, r.stderr
    assert "Bob &amp; Alice &lt;3" in r.stdout
    # the gsub `&`-expansion bug rendered "A & B" as "A __BRAND__amp; B"
    assert "__BRAND__" not in r.stdout


# ── hardening: theme + hook-gate regressions ─────────────────────────────────

def test_no_old_palette_hex_survives(landing_env):
    write_registry(landing_env, ["blog"])
    r = render(landing_env)
    assert r.returncode == 0, r.stderr
    for old_hex in ("5f8cff", "8a7cff", "1f4fff", "7a4dff", "8a4dff",
                    "95,90,255", "95,140,255", "138,124,255"):
        assert old_hex not in r.stdout, old_hex


def test_regen_landing_is_executable():
    # site-deploy.sh/site-delete.sh's hook gates on `[ -x ]` and execs the
    # file directly: without the exec bit the hook silently no-ops forever.
    # This is the repo's ONE deliberate exec-bit exception (SPEC §9).
    assert os.access(REGEN, os.X_OK)


def test_spa_block_is_never_route_wrapped():
    # SPEC-SITES-PANEL §15 CORRECTION: a `route { … }` SPA wrapper sorts
    # before `respond`, bypassing the wildcard vhost's @dot 403 dotfile guard
    # (probed on caddy v2.11.4 — it served an existing /assets/.env). Pin the
    # sibling form in both the template's marker contract and the installer.
    tmpl = SITES_VHOST_TMPL.read_text()
    assert re.search(r"^[ \t]*__SPA_TRY_FILES__[ \t]*$", tmpl, re.M)
    installer = SITES_APP_SH.read_text()
    assert "try_files {path} {path}/ /index.html" in installer
    # inspect the actual SPA_BLOCK assignments, not the whole file — the
    # installer's own comment legitimately names the banned `route {` form
    assignments = [ln for ln in installer.splitlines() if "SPA_BLOCK=" in ln]
    assert assignments, "SPA_BLOCK assignments missing from apps/sites.sh"
    assert not any("route" in ln for ln in assignments), assignments
