"""tests/test_safe_extract.py — fixtures for scripts/sites/safe_extract.py.

Exercises the CLI as a subprocess (the same way scripts/sites/site-deploy.sh
will call it) rather than importing it as a library. That's deliberate: the
whole point of this module is its exit-code/stdout/stderr CONTRACT ("REJECT:
<reason>" + exit 2, "OK: ..." + exit 0, exit 1 for I/O problems) — the shell
caller never sees Python internals, so the test should observe exactly what
the shell caller observes. Every fixture zip is built in tmp_path with
`zipfile`/`ZipInfo` directly; nothing here reads or writes outside tmp_path.

SPEC-SITES-PIPELINE.md §12 names this the first test suite in the repo and
requires, at minimum: happy path, traversal, absolute path, backslash name,
symlink entry, entry-count cap, declared-size (ratio) bomb, a lying central
directory caught DURING extraction, and non-empty dest-dir. All covered below.
"""
import os
import stat
import subprocess
import sys
import zipfile

import pytest

SCRIPT = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "scripts", "sites", "safe_extract.py",
)


def run_extract(artifact, dest_dir, *extra_args):
    """Invoke the CLI exactly as site-deploy.sh will, and hand back the
    completed-process object (never raises on a non-zero exit — callers
    assert on .returncode themselves, matching how a shell caller would
    branch on $?)."""
    return subprocess.run(
        [sys.executable, SCRIPT, str(artifact), str(dest_dir), *extra_args],
        capture_output=True, text=True, timeout=30,
    )


def make_zip(path, entries):
    """Build a zip at `path` from a list of (name, data_bytes) or
    (name, data_bytes, mode) tuples. `mode` is a full Unix st_mode (e.g.
    stat.S_IFLNK | 0o777 for a symlink entry); when given, it's packed into
    external_attr's high 16 bits exactly the way a real Unix zip tool would,
    and create_system is forced to 3 (Unix) so the mode bits are meaningful."""
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as zf:
        for entry in entries:
            name, data = entry[0], entry[1]
            mode = entry[2] if len(entry) > 2 else None
            zi = zipfile.ZipInfo(name)
            zi.compress_type = zipfile.ZIP_DEFLATED
            if mode is not None:
                zi.create_system = 3
                zi.external_attr = (mode & 0xFFFF) << 16
            zf.writestr(zi, data)
    return path


def dir_is_empty(path):
    return os.listdir(path) == []


# ---------------------------------------------------------------------------
# happy path
# ---------------------------------------------------------------------------

def test_happy_path_nested_dirs_and_files(tmp_path):
    artifact = make_zip(tmp_path / "site.zip", [
        ("index.html", b"<h1>hello</h1>"),
        ("assets/", b""),
        ("assets/style.css", b"body { color: red; }"),
        ("assets/img/logo.svg", b"<svg></svg>"),
    ])
    dest = tmp_path / "dest"
    dest.mkdir()

    result = run_extract(artifact, dest)

    assert result.returncode == 0, result.stderr
    assert result.stdout.strip().startswith("OK: 3 files, ")
    assert (dest / "index.html").read_bytes() == b"<h1>hello</h1>"
    assert (dest / "assets" / "style.css").read_bytes() == b"body { color: red; }"
    assert (dest / "assets" / "img" / "logo.svg").read_bytes() == b"<svg></svg>"
    # permissions stripped to the fixed policy, zip-stored modes ignored
    assert stat.S_IMODE(os.stat(dest / "index.html").st_mode) == 0o644
    assert stat.S_IMODE(os.stat(dest / "assets").st_mode) == 0o755


def test_happy_path_reports_correct_byte_count(tmp_path):
    payload = b"x" * 12345
    artifact = make_zip(tmp_path / "site.zip", [("a.bin", payload)])
    dest = tmp_path / "dest"
    dest.mkdir()

    result = run_extract(artifact, dest)

    assert result.returncode == 0, result.stderr
    assert f"{len(payload)} bytes" in result.stdout


# ---------------------------------------------------------------------------
# path-safety rejections
# ---------------------------------------------------------------------------

def test_traversal_entry_rejected(tmp_path):
    artifact = make_zip(tmp_path / "evil.zip", [
        ("ok.html", b"fine"),
        ("../evil", b"escape attempt"),
    ])
    dest = tmp_path / "dest"
    dest.mkdir()

    result = run_extract(artifact, dest)

    assert result.returncode == 2
    assert result.stderr.startswith("REJECT:")
    assert dir_is_empty(dest)
    # and nothing escaped to the parent of dest either
    assert not (dest.parent / "evil").exists()


def test_deep_traversal_entry_rejected(tmp_path):
    artifact = make_zip(tmp_path / "evil.zip", [
        ("a/b/../../../etc/cron.d/x", b"escape attempt"),
    ])
    dest = tmp_path / "dest"
    dest.mkdir()

    result = run_extract(artifact, dest)

    assert result.returncode == 2
    assert result.stderr.startswith("REJECT:")
    assert dir_is_empty(dest)


def test_absolute_path_entry_rejected(tmp_path):
    artifact = make_zip(tmp_path / "evil.zip", [("/etc/passwd", b"root:x:0:0")])
    dest = tmp_path / "dest"
    dest.mkdir()

    result = run_extract(artifact, dest)

    assert result.returncode == 2
    assert result.stderr.startswith("REJECT:")
    assert dir_is_empty(dest)
    assert not os.path.exists("/etc/passwd.bak")  # sanity: we never touched real /etc


def test_backslash_name_rejected(tmp_path):
    artifact = make_zip(tmp_path / "evil.zip", [("..\\evil", b"windows-style traversal")])
    dest = tmp_path / "dest"
    dest.mkdir()

    result = run_extract(artifact, dest)

    assert result.returncode == 2
    assert result.stderr.startswith("REJECT:")
    assert dir_is_empty(dest)


def test_drive_letter_entry_rejected(tmp_path):
    artifact = make_zip(tmp_path / "evil.zip", [("C:/Windows/System32/evil.dll", b"x")])
    dest = tmp_path / "dest"
    dest.mkdir()

    result = run_extract(artifact, dest)

    assert result.returncode == 2
    assert result.stderr.startswith("REJECT:")
    assert dir_is_empty(dest)


def test_symlink_entry_rejected(tmp_path):
    artifact = make_zip(tmp_path / "evil.zip", [
        ("ok.html", b"fine"),
        ("link", b"/etc/passwd", stat.S_IFLNK | 0o777),
    ])
    dest = tmp_path / "dest"
    dest.mkdir()

    result = run_extract(artifact, dest)

    assert result.returncode == 2
    assert result.stderr.startswith("REJECT:")
    assert "symlink" in result.stderr.lower()
    assert dir_is_empty(dest)
    # crucially: nothing on disk under dest is an actual symlink
    assert not any(os.path.islink(os.path.join(root, f))
                   for root, _, files in os.walk(dest) for f in files)


def test_non_regular_entry_rejected(tmp_path):
    # a FIFO/device-style mode bit that isn't S_IFREG or S_IFDIR
    artifact = make_zip(tmp_path / "evil.zip", [
        ("weird", b"payload", stat.S_IFIFO | 0o600),
    ])
    dest = tmp_path / "dest"
    dest.mkdir()

    result = run_extract(artifact, dest)

    assert result.returncode == 2
    assert result.stderr.startswith("REJECT:")
    assert dir_is_empty(dest)


# ---------------------------------------------------------------------------
# size / count caps
# ---------------------------------------------------------------------------

def test_entry_count_cap_exceeded(tmp_path):
    entries = [(f"f{i}.txt", b"x") for i in range(50)]
    artifact = make_zip(tmp_path / "many.zip", entries)
    dest = tmp_path / "dest"
    dest.mkdir()

    result = run_extract(artifact, dest, "--max-entries", "10")

    assert result.returncode == 2
    assert result.stderr.startswith("REJECT:")
    assert "entr" in result.stderr.lower()
    assert dir_is_empty(dest)


def test_declared_size_ratio_bomb_rejected(tmp_path):
    # Highly compressible, LEGITIMATE content (no lying needed): 20 MB of a
    # single repeated byte compresses to a few KB, but declares (accurately)
    # 20 MB of uncompressed output — a classic zip-bomb pattern, caught by
    # the ratio cap purely from the DECLARED central-directory metadata,
    # before a single byte is extracted.
    payload = b"\x00" * (20 * 1024 * 1024)
    artifact = make_zip(tmp_path / "bomb.zip", [("bomb.bin", payload)])
    dest = tmp_path / "dest"
    dest.mkdir()

    # cap total uncompressed to 1 MB x ratio 4 = 4 MB, well under the 20 MB bomb
    result = run_extract(artifact, dest, "--max-mb", "1", "--max-ratio", "4")

    assert result.returncode == 2
    assert result.stderr.startswith("REJECT:")
    assert dir_is_empty(dest)


def test_per_file_cap_exceeded(tmp_path):
    payload = b"y" * (2 * 1024 * 1024)   # 2 MiB, legitimate/accurate declared size
    artifact = make_zip(tmp_path / "big.zip", [("big.bin", payload)])
    dest = tmp_path / "dest"
    dest.mkdir()

    result = run_extract(artifact, dest, "--max-file-mb", "1")

    assert result.returncode == 2
    assert result.stderr.startswith("REJECT:")
    assert dir_is_empty(dest)


# ---------------------------------------------------------------------------
# lying central directory — caught DURING extraction, not by the pre-scan
# ---------------------------------------------------------------------------

def test_lying_central_directory_rejected_during_extraction(tmp_path):
    """Craft a member whose declared file_size (in the central directory) is
    tiny — comfortably under every cap, so the phase-1 metadata pre-scan
    passes cleanly — while the real compressed stream actually inflates to
    something much larger. Technique: writestr() computes and records the
    TRUE file_size/CRC first; we then mutate the ZipInfo object still held
    by the open ZipFile's filelist, patching file_size down, before the
    archive is closed and the (now-lying) central directory is serialized.
    On reopen, infolist() reports the small lie, but zf.open(info).read()
    still decompresses the real, large payload underneath — which safe_
    extract.py must detect (as a corrupt/CRC-mismatched entry, since the
    declared CRC no longer matches what the truncated-to-declared-size read
    actually produces) and reject mid-stream, cleaning up whatever partial
    bytes it had already written.
    """
    artifact_path = tmp_path / "lying.zip"
    real_data = b"A" * (2 * 1024 * 1024)   # 2 MiB of real, highly-compressible content
    with zipfile.ZipFile(artifact_path, "w", zipfile.ZIP_DEFLATED) as zf:
        zi = zipfile.ZipInfo("big.txt")
        zi.compress_type = zipfile.ZIP_DEFLATED
        zf.writestr(zi, real_data)   # zi.file_size is now accurately 2 MiB
        assert zi.file_size == len(real_data)
        zi.file_size = 10            # THE LIE: claim only 10 bytes uncompressed
        assert zf.filelist[0] is zi  # same object central-directory serialization will use

    # sanity: the central directory we just wrote really does lie
    with zipfile.ZipFile(artifact_path) as check:
        assert check.infolist()[0].file_size == 10

    dest = tmp_path / "dest"
    dest.mkdir()

    result = run_extract(artifact_path, dest)

    assert result.returncode == 2, (result.stdout, result.stderr)
    assert result.stderr.startswith("REJECT:")
    assert dir_is_empty(dest)


# ---------------------------------------------------------------------------
# dest-dir preconditions
# ---------------------------------------------------------------------------

def test_non_empty_dest_dir_rejected(tmp_path):
    artifact = make_zip(tmp_path / "site.zip", [("index.html", b"hi")])
    dest = tmp_path / "dest"
    dest.mkdir()
    (dest / "preexisting.txt").write_text("do not touch me")

    result = run_extract(artifact, dest)

    assert result.returncode == 2
    assert result.stderr.startswith("REJECT:")
    # the pre-existing file must survive untouched — we must never wipe
    # content we didn't create ourselves
    assert (dest / "preexisting.txt").read_text() == "do not touch me"
    assert os.listdir(dest) == ["preexisting.txt"]


def test_missing_dest_dir_is_io_error(tmp_path):
    artifact = make_zip(tmp_path / "site.zip", [("index.html", b"hi")])
    missing = tmp_path / "does-not-exist"

    result = run_extract(artifact, missing)

    assert result.returncode == 1
    assert not missing.exists()


# ---------------------------------------------------------------------------
# misc
# ---------------------------------------------------------------------------

def test_py_compile_clean():
    import py_compile
    py_compile.compile(SCRIPT, doraise=True)


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-q"]))
