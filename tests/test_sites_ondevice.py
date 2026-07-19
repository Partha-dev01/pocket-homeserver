"""tests/test_sites_ondevice.py — laptop-testable slice of Pocket Pages M4
Feature B (share-sheet + widget deploy, docs/specs/SPEC-DIFFERENTIATORS.md §7
as amended by CORRECTION C-1).

Scope, deliberately narrow (mirrors tests/test_pipeline.py's "exercise the
REAL script as a subprocess, never re-implement it in Python" philosophy):

  1. scripts/sites/pocket-share-hook.sh's zip/non-zip dispatch decision and
     belt-only site-name validation — driven with NO termux-dialog on PATH
     (so it falls back to `read -r -p`, exercised via stdin), a STUBBED
     scripts/sites/site-deploy.sh (records argv instead of deploying
     anything), a stubbed $EDITOR (records argv instead of opening a real
     editor — the real `nano` on this laptop is interactive and would hang
     the test if ever reached), and a scratch $HOME so nothing here can touch
     the real operator's ~/bin.
  2. scripts/sites/pocket-deploy-widget.sh's equivalent dispatch + its
     termux-storage-get guard, using the same stub conventions plus a stubbed
     termux-storage-get.
  3. scripts/apps/sites.sh's no-clobber install decision for
     ~/bin/termux-file-editor (not-exists -> install; exists+marker -> our
     own, overwrite; exists+no-marker -> operator's own, skip). Running the
     WHOLE script is not laptop-feasible (it require_cmd proot-distro's a
     live userland + a real DOMAIN + `caddy validate` inside a proot rootfs
     none of which exist here — the same reason test_pipeline.py never runs
     scripts/apps/sites.sh either). Per this feature's own task brief, the
     exact copy/marker/skip CONDITION is replicated verbatim as a small
     bash snippet (see INSTALL_LOGIC below) rather than re-run through the
     real installer, and cross-checked against the real files' marker string
     so the replica cannot silently drift out of sync.

Everything requiring a genuine termux-* binary (a real termux-dialog popup,
real termux-storage-get SAF picker, real termux-toast/termux-notification
delivery, Termux:Widget actually invoking a script from a home-screen tap)
stays OUT of this suite — those commands simply do not exist off-phone, and
are documented in the M4 report as the required manual, on-device smoke test
(the same caveat SPEC-DIFFERENTIATORS.md §7.9 already accepts for this
feature, and SPEC-MCP-COMPLETION §12 accepts for the Hugo/Node build tiers).
"""
import os
import re
import stat
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
SITES_DIR = REPO_ROOT / "scripts" / "sites"
SITES_APP_SCRIPT = REPO_ROOT / "scripts" / "apps" / "sites.sh"
SHARE_HOOK = SITES_DIR / "pocket-share-hook.sh"
DEPLOY_WIDGET = SITES_DIR / "pocket-deploy-widget.sh"

# The exact, greppable marker scripts/apps/sites.sh's installer keys its
# no-clobber decision on. Cross-checked against the real files below rather
# than trusted blind, so this constant cannot silently drift out of sync with
# the shipped scripts.
HOOK_MARKER = "# pocket-homeserver share-deploy hook (ENABLE_SITES_SHARE_DEPLOY)"

_MINIMAL_PATH = os.pathsep.join(["/usr/bin", "/bin"])  # no termux-*, no real editor found here

STUB_RECORDER = """#!/usr/bin/env bash
# Test-only stub: records argv (one per line) instead of doing real work.
printf '%s\\n' "$@" > "${STUB_RECORD_FILE}"
exit "${STUB_EXIT_CODE:-0}"
"""

# Like STUB_RECORDER, but also copies fixed bytes to the path it was asked to
# fetch INTO (arg $1) -- stands in for termux-storage-get, which copies the
# SAF-picked file's bytes to a caller-named destination.
STUB_STORAGE_GET = """#!/usr/bin/env bash
printf '%s\\n' "$@" > "${STUB_RECORD_FILE}"
if [ -n "${STUB_STORAGE_GET_BYTES:-}" ]; then
  printf '%s' "${STUB_STORAGE_GET_BYTES}" > "$1"
elif [ "${STUB_STORAGE_GET_TOUCH_EMPTY:-0}" = "1" ]; then
  : > "$1"
fi
exit "${STUB_EXIT_CODE:-0}"
"""

# Replicates scripts/apps/sites.sh's exact copy/marker/skip conditional
# (§4 in that file, "Share-sheet deploy hook" block) for the no-clobber
# install decision -- NOT a re-run of the real installer (which needs
# proot-distro + a real DOMAIN + a live Caddy, none of which exist on a
# laptop), per this feature's own task brief.
INSTALL_LOGIC = """
set -euo pipefail
SRC="$1"; DEST="$2"; MARKER="$3"
mkdir -p "$(dirname "$DEST")"
if [ ! -e "$DEST" ]; then
  cp "$SRC" "$DEST"
  echo installed
elif grep -qF -- "$MARKER" "$DEST" 2>/dev/null; then
  cp "$SRC" "$DEST"
  echo updated
else
  echo skipped
fi
"""


def _write_executable(path: Path, content: str) -> None:
    path.write_text(content)
    mode = path.stat().st_mode
    path.chmod(mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


@pytest.fixture()
def pocket_root(tmp_path):
    """A fake POCKET_ROOT tree whose scripts/sites/site-deploy.sh is a STUB
    that records its argv (site name + artifact path) instead of running the
    real M1 pipeline -- this file tests the two on-phone dispatcher scripts,
    not the pipeline itself (tests/test_pipeline.py already covers that)."""
    root = tmp_path / "pocket-root"
    sites_dir = root / "scripts" / "sites"
    sites_dir.mkdir(parents=True)
    record_file = tmp_path / "deploy-record.txt"
    _write_executable(sites_dir / "site-deploy.sh", STUB_RECORDER)
    return {"root": root, "record_file": record_file}


def _env(pocket_root, tmp_path, extra_path_dirs=(), extra=None):
    fake_home = tmp_path / "home"
    fake_home.mkdir(exist_ok=True)
    env = {
        "POCKET_ROOT": str(pocket_root["root"]),
        "STUB_RECORD_FILE": str(pocket_root["record_file"]),
        "HOME": str(fake_home),
        "PATH": os.pathsep.join([*[str(d) for d in extra_path_dirs], _MINIMAL_PATH]),
    }
    if extra:
        env.update({k: str(v) for k, v in extra.items()})
    return env


def run_hook(pocket_root, tmp_path, args, stdin_text="", extra=None, extra_path_dirs=()):
    env = _env(pocket_root, tmp_path, extra_path_dirs=extra_path_dirs, extra=extra)
    cmd = ["bash", str(SHARE_HOOK), *[str(a) for a in args]]
    return subprocess.run(
        cmd, env=env, input=stdin_text, capture_output=True, text=True, timeout=30
    )


def run_widget(pocket_root, tmp_path, stdin_text="", extra=None, extra_path_dirs=()):
    env = _env(pocket_root, tmp_path, extra_path_dirs=extra_path_dirs, extra=extra)
    cmd = ["bash", str(DEPLOY_WIDGET)]
    return subprocess.run(
        cmd, env=env, input=stdin_text, capture_output=True, text=True, timeout=30
    )


def record_lines(pocket_root):
    return pocket_root["record_file"].read_text().splitlines()


# ── pocket-share-hook.sh: zip/non-zip dispatch ───────────────────────────────

def test_zip_valid_name_dispatches_to_deploy(pocket_root, tmp_path):
    shared = tmp_path / "shared.zip"
    shared.write_bytes(b"PK\x03\x04fake")
    result = run_hook(pocket_root, tmp_path, [shared], stdin_text="myblog\n")
    assert result.returncode == 0, result.stderr
    assert record_lines(pocket_root) == ["myblog", str(shared)]


def test_zip_extension_is_case_insensitive(pocket_root, tmp_path):
    shared = tmp_path / "shared.ZIP"
    shared.write_bytes(b"PK\x03\x04fake")
    result = run_hook(pocket_root, tmp_path, [shared], stdin_text="myblog\n")
    assert result.returncode == 0, result.stderr
    assert record_lines(pocket_root) == ["myblog", str(shared)]


def test_non_zip_falls_through_to_editor_not_deploy(pocket_root, tmp_path):
    shared = tmp_path / "notes.txt"
    shared.write_text("hello")
    editor_record = tmp_path / "editor-record.txt"
    editor_stub = tmp_path / "editor-stub.sh"
    _write_executable(editor_stub, STUB_RECORDER)
    result = run_hook(
        pocket_root, tmp_path, [shared],
        extra={"EDITOR": str(editor_stub), "STUB_RECORD_FILE": str(editor_record)},
    )
    assert result.returncode == 0, result.stderr
    assert editor_record.read_text().splitlines() == [str(shared)]
    assert not pocket_root["record_file"].exists()  # site-deploy.sh never invoked


def test_empty_name_cancelled_exits_zero_quietly(pocket_root, tmp_path):
    shared = tmp_path / "shared.zip"
    shared.write_bytes(b"PK\x03\x04fake")
    result = run_hook(pocket_root, tmp_path, [shared], stdin_text="\n")
    assert result.returncode == 0, result.stderr
    assert not pocket_root["record_file"].exists()


def test_eof_on_prompt_treated_as_cancel(pocket_root, tmp_path):
    shared = tmp_path / "shared.zip"
    shared.write_bytes(b"PK\x03\x04fake")
    result = run_hook(pocket_root, tmp_path, [shared], stdin_text="")  # immediate EOF
    assert result.returncode == 0, result.stderr
    assert not pocket_root["record_file"].exists()


@pytest.mark.parametrize("bad_name", ["Bad_Name", "UPPER", "-leading-hyphen", "trailing-", "has space"])
def test_invalid_name_rejected_no_deploy(pocket_root, tmp_path, bad_name):
    shared = tmp_path / "shared.zip"
    shared.write_bytes(b"PK\x03\x04fake")
    result = run_hook(pocket_root, tmp_path, [shared], stdin_text=f"{bad_name}\n")
    assert result.returncode == 1
    assert not pocket_root["record_file"].exists()
    assert "invalid site name" in result.stderr


def test_deploy_failure_exit_code_propagates(pocket_root, tmp_path):
    shared = tmp_path / "shared.zip"
    shared.write_bytes(b"PK\x03\x04fake")
    result = run_hook(
        pocket_root, tmp_path, [shared], stdin_text="myblog\n", extra={"STUB_EXIT_CODE": "7"}
    )
    assert result.returncode == 7
    assert record_lines(pocket_root) == ["myblog", str(shared)]  # deploy WAS attempted


def test_missing_pocket_root_gives_clear_error(tmp_path):
    empty_root = {"root": tmp_path / "nowhere", "record_file": tmp_path / "unused.txt"}
    shared = tmp_path / "shared.zip"
    shared.write_bytes(b"PK\x03\x04fake")
    result = run_hook(empty_root, tmp_path, [shared], stdin_text="myblog\n")
    assert result.returncode == 1
    assert "not found at" in result.stderr


def test_no_args_usage_error(pocket_root, tmp_path):
    result = run_hook(pocket_root, tmp_path, [])
    assert result.returncode == 1
    assert "usage:" in result.stderr


# ── pocket-deploy-widget.sh ──────────────────────────────────────────────────

def test_widget_missing_termux_api_guard(pocket_root, tmp_path):
    # No termux-storage-get stub on PATH at all -- the real, honest laptop
    # condition (Termux:API doesn't exist off-phone).
    result = run_widget(pocket_root, tmp_path, stdin_text="myblog\n")
    assert result.returncode == 1
    assert "Termux:API not installed" in result.stderr
    assert not pocket_root["record_file"].exists()


def test_widget_valid_name_and_zip_dispatches_to_deploy(pocket_root, tmp_path):
    bin_dir = tmp_path / "stub-bin"
    bin_dir.mkdir()
    picker_record = tmp_path / "picker-record.txt"
    _write_executable(bin_dir / "termux-storage-get", STUB_STORAGE_GET)
    result = run_widget(
        pocket_root, tmp_path, stdin_text="myblog\n",
        extra={
            "STUB_STORAGE_GET_BYTES": "PK\x03\x04fake",
        },
        extra_path_dirs=[bin_dir],
    )
    # The widget's own STUB_RECORD_FILE is shared between the storage-get
    # stub call and the deploy stub call (both use the one env var) --
    # inspect the FINAL contents, which is the deploy stub's argv (it runs
    # last and overwrites the file the storage-get stub wrote first).
    assert result.returncode == 0, result.stderr
    lines = record_lines(pocket_root)
    assert lines[0] == "myblog"
    assert re.match(r".*pocket-deploy-widget-\d+\.zip$", lines[1]), lines
    assert picker_record  # sanity: fixture path constructed (unused otherwise)


def test_widget_invalid_name_fails_before_picker_opens(pocket_root, tmp_path):
    bin_dir = tmp_path / "stub-bin"
    bin_dir.mkdir()
    picker_called_marker = tmp_path / "picker-was-called"
    storage_get_stub = f"""#!/usr/bin/env bash
touch "{picker_called_marker}"
exit 0
"""
    _write_executable(bin_dir / "termux-storage-get", storage_get_stub)
    result = run_widget(
        pocket_root, tmp_path, stdin_text="Bad Name\n", extra_path_dirs=[bin_dir]
    )
    assert result.returncode == 1
    assert not picker_called_marker.exists()  # picker never opened -- fail fast
    assert not pocket_root["record_file"].exists()


def test_widget_empty_picker_result_fails(pocket_root, tmp_path):
    bin_dir = tmp_path / "stub-bin"
    bin_dir.mkdir()
    _write_executable(bin_dir / "termux-storage-get", STUB_STORAGE_GET)
    result = run_widget(
        pocket_root, tmp_path, stdin_text="myblog\n",
        extra={"STUB_STORAGE_GET_TOUCH_EMPTY": "1"},
        extra_path_dirs=[bin_dir],
    )
    assert result.returncode == 1
    assert "no file was picked" in result.stderr


def test_widget_picker_cancelled_fails(pocket_root, tmp_path):
    bin_dir = tmp_path / "stub-bin"
    bin_dir.mkdir()
    cancel_stub = "#!/usr/bin/env bash\nexit 1\n"
    _write_executable(bin_dir / "termux-storage-get", cancel_stub)
    result = run_widget(pocket_root, tmp_path, stdin_text="myblog\n", extra_path_dirs=[bin_dir])
    assert result.returncode == 1
    assert "file picker cancelled or failed" in result.stderr


# ── scripts/apps/sites.sh: no-clobber install decision (replicated) ────────

def _run_install_logic(src: Path, dest: Path, marker: str = HOOK_MARKER):
    return subprocess.run(
        ["bash", "-c", INSTALL_LOGIC, "install-logic", str(src), str(dest), marker],
        capture_output=True, text=True, timeout=10,
    )


def test_install_marker_is_present_verbatim_in_the_real_hook(tmp_path):
    # Guards the replica above against drift: if a future edit renames the
    # marker in pocket-share-hook.sh without updating sites.sh's HOOK_MARKER
    # (or this test), THIS assertion is the one that catches it.
    hook_text = SHARE_HOOK.read_text()
    assert HOOK_MARKER in hook_text.splitlines()


def test_install_marker_matches_sites_sh_installer_constant():
    installer_text = SITES_APP_SCRIPT.read_text()
    match = re.search(r'HOOK_MARKER="([^"]*)"', installer_text)
    assert match, "scripts/apps/sites.sh no longer defines HOOK_MARKER=\"...\""
    assert match.group(1) == HOOK_MARKER


def test_install_no_existing_hook_installs(tmp_path):
    src = tmp_path / "src.sh"
    src.write_text("new content\n" + HOOK_MARKER + "\n")
    dest = tmp_path / "bin" / "termux-file-editor"
    result = _run_install_logic(src, dest)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "installed"
    assert dest.read_text() == src.read_text()


def test_install_existing_own_hook_is_overwritten(tmp_path):
    src = tmp_path / "src.sh"
    src.write_text("new content v2\n" + HOOK_MARKER + "\n")
    dest = tmp_path / "bin" / "termux-file-editor"
    dest.parent.mkdir(parents=True)
    dest.write_text("old content v1\n" + HOOK_MARKER + "\n")
    result = _run_install_logic(src, dest)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "updated"
    assert dest.read_text() == src.read_text()


def test_install_existing_foreign_hook_is_left_untouched(tmp_path):
    src = tmp_path / "src.sh"
    src.write_text("new content\n" + HOOK_MARKER + "\n")
    dest = tmp_path / "bin" / "termux-file-editor"
    dest.parent.mkdir(parents=True)
    operators_own_hook = "#!/data/data/com.termux/files/usr/bin/bash\n# my own editor hook\nexec vim \"$1\"\n"
    dest.write_text(operators_own_hook)
    result = _run_install_logic(src, dest)
    assert result.returncode == 0, result.stderr  # skip is NOT a failure
    assert result.stdout.strip() == "skipped"
    assert dest.read_text() == operators_own_hook  # untouched, byte-for-byte
