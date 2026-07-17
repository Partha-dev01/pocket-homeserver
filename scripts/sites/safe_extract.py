#!/usr/bin/env python3
r"""safe_extract.py — hardened, streaming zip extractor for the sites pipeline.

Standalone, Python-stdlib-only helper invoked by scripts/sites/site-deploy.sh
(SPEC-SITES-PIPELINE.md §8) to turn an uploaded static-site artifact (a
`.zip`) into a release directory tree. It is the ONLY code in the `sites`
module that touches attacker-controlled zip *content* (entry names, declared
sizes, compressed bytes) — everything upstream of it (name/release-id
validation, artifact-path allocation) is the shell layer's job; everything
downstream (atomic publish, registry update) only ever sees a directory tree
this script has already certified safe.

CLI:
    python3 safe_extract.py <artifact.zip> <dest-dir> \
        [--max-mb N] [--max-entries N] [--max-ratio N] [--max-file-mb N]

`dest-dir` must already exist and be EMPTY — the caller (site-deploy.sh)
allocates `releases/<id>.tmp/` and hands it to us; this script never invents
or resolves a destination on its own, which keeps "where do the bytes land"
entirely under the trusted shell layer's control.

THREAT MODEL — a zip is one of the more attacker-hostile file formats an
operator can be asked to accept straight from a browser upload: the central
directory (entry names, declared sizes, Unix mode bits) is 100%
attacker-controlled metadata that Python's own `zipfile` module will happily
hand back without opinion. Every field below is treated as hostile until
checked:
  - Entry names could be absolute (`/etc/passwd`), Windows-style
    (`C:\...`, backslashes), or path-traversal (`../../etc/cron.d/x`) —
    rejected by string + PurePosixPath inspection BEFORE any I/O happens
    (see `_safe_relparts`).
  - Entry types could claim to be a symlink (or another special file) via
    the Unix mode bits packed into `external_attr`'s high 16 bits —
    rejected outright. This module never calls `os.symlink`/`os.link` at
    all — every extracted path is either `os.mkdir`'d or `open(..., "wb")`'d
    — so even a missed check here could not itself produce an on-disk
    symlink; we still reject loudly and early rather than rely on that.
  - Declared sizes (total compressed, per-file uncompressed, total
    uncompressed) are all cap-checked against the CENTRAL DIRECTORY before a
    single byte is extracted — a cheap, up-front zip-bomb rejection. But a
    central directory can LIE about `file_size` relative to the real
    compressed stream, so extraction ALSO re-derives its counts from bytes
    actually read off `zf.open()`, independent of what the metadata
    claimed, and aborts + cleans up mid-stream the moment reality disagrees
    with the declaration (see `_CappedWriter` and the `zipfile.BadZipFile`
    handling in `_extract_member` — CPython's own `ZipExtFile` additionally
    never emits more decompressed bytes than the declared `file_size`, so a
    forged-small declaration with a large real payload surfaces as a CRC
    mismatch there rather than as an over-cap write, but either failure
    mode is treated identically: reject and clean up).
  - Extraction targets are re-checked with `os.path.realpath(target)`
    against `realpath(dest-dir)` immediately before every write — defense
    in depth independent of the name-string validation above, in case that
    parsing logic ever has a bug.

Exit codes (the contract site-deploy.sh branches on):
    0  success — stdout: "OK: <n> files, <bytes> bytes"
    1  environment/I/O problem (missing dest-dir, unreadable artifact, disk
       error) — NOT a statement about the artifact's safety.
    2  the artifact violated policy — stderr: "REJECT: <reason>"; anything
       this run had already written under dest-dir is removed, restoring it
       to the empty state the caller handed us (dest-dir itself is never
       removed — the caller owns its lifecycle, only allocates it empty).
"""
import argparse
import os
import re
import shutil
import stat
import sys
import zipfile
from pathlib import PurePosixPath

# ---------- tunables (env fallback per SPEC-SITES-PIPELINE §9) ----------

CHUNK = 1024 * 1024          # stream in 1 MiB chunks; never hold a whole member in RAM.
DIR_MODE = 0o755
FILE_MODE = 0o644
DEFAULT_MAX_ENTRIES = 20000
DEFAULT_MAX_FILE_MB = 512


def _env_int(name, default):
    """Read an int from the environment, falling back to `default` if unset
    OR unparsable — a malformed env var must never crash this script (it
    would fail a deploy for an unrelated typo elsewhere in .env), it should
    just fall back to the safe built-in default."""
    raw = os.environ.get(name)
    if not raw:
        return default
    try:
        return int(raw)
    except ValueError:
        return default


DEFAULT_MAX_MB = _env_int("SITES_MAX_UPLOAD_MB", 200)
DEFAULT_MAX_RATIO = _env_int("SITES_MAX_RATIO", 4)


class _ExtractionAborted(Exception):
    """Raised anywhere during the extraction pass (phase 2) to signal a
    policy violation — path escape, over-cap write, or a tampered/corrupt
    member. Caught once in main(); never an OSError subclass, so it can
    never be mistaken for (or swallowed by) plain I/O-error handling."""


# ---------- entry-name / entry-type policy (phase 1: pure validation) ------

def _safe_relparts(name):
    """Validate a raw zip entry name and return its normalized path
    components (safe to `os.path.join` under dest-dir), or (None, reason) if
    the name violates policy. Every check here runs BEFORE any bytes are
    written (SPEC-SITES-PIPELINE §8) — a rejection at this stage costs us
    nothing on disk.
    """
    if not name:
        return None, "empty entry name"
    if "\x00" in name:
        return None, f"entry name contains a NUL byte: {name!r}"
    if "\\" in name:
        return None, f"entry name contains a backslash (Windows-style separator, invalid in a zip): {name!r}"
    if re.match(r"^[A-Za-z]:", name):
        return None, f"entry name has a drive letter: {name!r}"
    posix = PurePosixPath(name)
    if posix.is_absolute():
        return None, f"entry name is an absolute path: {name!r}"
    # PurePosixPath does NOT collapse '..' (pure paths are never resolved),
    # so an explicit '..' component survives into .parts exactly where an
    # attacker put it — that is what we're checking for here.
    parts = [p for p in posix.parts if p not in ("", ".")]
    if ".." in parts:
        return None, f"entry name contains a '..' path-traversal segment: {name!r}"
    if not parts:
        return None, f"entry name resolves to an empty/root path: {name!r}"
    return parts, None


def _entry_unix_mode(info):
    """High 16 bits of `external_attr` are the Unix st_mode when the archive
    was written by a Unix-aware zip tool (`create_system == 3`); zips
    authored on Windows generally leave this field 0. `stat.S_ISLNK(0)` and
    `stat.S_ISREG(0)` are both False, so checking this unconditionally
    (without branching on create_system) is safe either way — a
    Windows-origin zip simply never trips the symlink/non-regular checks."""
    return (info.external_attr >> 16) & 0xFFFF


def _is_symlink_entry(info):
    return stat.S_ISLNK(_entry_unix_mode(info))


# Unix file-type bits (S_IFMT-masked) that are never acceptable in a static
# site archive: symlinks, device nodes, FIFOs, sockets. Deliberately an
# allowlist-of-bad-types rather than a "must equal S_IFREG/S_IFDIR", because
# many real-world zip writers — INCLUDING Python's own `zipfile.writestr()`
# when handed a plain filename string, which sets external_attr to just
# `0o600 << 16` (permission bits only, no S_IFMT type field at all) — never
# set the S_IFREG type bit on ordinary files. Requiring it would reject
# perfectly ordinary archives; checking for explicitly-bad types does not.
_BAD_TYPE_BITS = (stat.S_IFLNK, stat.S_IFCHR, stat.S_IFBLK, stat.S_IFIFO, stat.S_IFSOCK)


def _is_non_regular_entry(info):
    """Reject device nodes, FIFOs, and sockets masquerading as a zip entry
    (symlinks are also caught here, redundantly with `_is_symlink_entry`
    above — belt-and-suspenders). A type field of 0 means "no Unix type bits
    recorded" (the common case — see `_BAD_TYPE_BITS` above) and is not
    flagged."""
    type_bits = stat.S_IFMT(_entry_unix_mode(info))
    return type_bits in _BAD_TYPE_BITS


def _prevalidate(zf, max_entries, max_file_bytes, ratio_cap_bytes):
    """Phase 1: pure validation over the zip's DECLARED metadata (the
    central directory Python already parsed when it opened the archive).
    Nothing is written to disk in this function — a rejection here leaves
    dest-dir exactly as the caller handed it to us (empty).

    Returns None on success, else a reason string for the 'REJECT: <reason>'
    line.
    """
    infos = zf.infolist()
    if len(infos) > max_entries:
        return f"{len(infos)} entries, over the {max_entries} entry cap (--max-entries)"

    total_declared = 0
    for info in infos:
        _, reason = _safe_relparts(info.filename)
        if reason:
            return reason
        if _is_symlink_entry(info):
            return f"symlink/hardlink entry rejected: {info.filename!r}"
        if _is_non_regular_entry(info):
            return f"non-regular file entry rejected: {info.filename!r}"
        if not info.is_dir():
            if info.file_size > max_file_bytes:
                return (f"entry {info.filename!r} declares {info.file_size} bytes, "
                        f"over the {max_file_bytes} byte per-file cap (--max-file-mb)")
            total_declared += info.file_size
            if total_declared > ratio_cap_bytes:
                return (f"declared uncompressed total ({total_declared} bytes) exceeds the "
                        f"{ratio_cap_bytes} byte ratio cap (--max-ratio x --max-mb) — possible zip bomb")
    return None


# ---------- streaming extraction (phase 2: the authoritative pass) --------

class _CappedWriter:
    """Wraps a destination file object; every write() is counted against
    both the per-file cap and a running grand-total cap shared across the
    whole extraction. This makes shutil.copyfileobj's normal chunked
    read/write loop enforce our caps chunk-by-chunk against bytes ACTUALLY
    produced by decompression, instead of trusting the (attacker-
    controlled) declared file_size in the zip's central directory — the
    "a lying central directory must not bypass the cap" requirement from
    SPEC-SITES-PIPELINE §8."""

    def __init__(self, fh, file_cap, totals, total_cap):
        self._fh = fh
        self._file_cap = file_cap
        self._written = 0
        self._totals = totals   # 1-item list, shared across every writer this run
        self._total_cap = total_cap

    def write(self, chunk):
        self._written += len(chunk)
        self._totals[0] += len(chunk)
        if self._written > self._file_cap:
            raise _ExtractionAborted(
                f"actual extracted bytes ({self._written}) exceeded the "
                f"{self._file_cap} byte per-file cap during streaming (--max-file-mb)")
        if self._totals[0] > self._total_cap:
            raise _ExtractionAborted(
                f"actual extracted total ({self._totals[0]} bytes) exceeded the "
                f"{self._total_cap} byte ratio cap during streaming (--max-ratio) — "
                f"declared sizes did not match reality (zip-bomb pattern)")
        return self._fh.write(chunk)


def _make_dirs(dest_dir, dest_real, parts, created):
    """Create each path component in `parts` (relative to dest_dir) that
    doesn't already exist, mode 0755, tracking every directory WE personally
    create in `created` so a later abort removes exactly what this run
    added — never anything the caller already had. Also re-checks realpath
    containment per component: defense in depth, independent of the
    name-string validation already done in `_safe_relparts` (SPEC-SITES-
    PIPELINE §8)."""
    cur = dest_dir
    for part in parts:
        cur = os.path.join(cur, part)
        cur_real = os.path.realpath(cur)
        if not (cur_real == dest_real or cur_real.startswith(dest_real + os.sep)):
            raise _ExtractionAborted(f"directory path escapes dest-dir after resolution: {cur!r}")
        if not os.path.isdir(cur):
            try:
                os.mkdir(cur, DIR_MODE)
            except FileExistsError as e:
                # A non-directory (regular file) already occupies this path —
                # only possible from an internally-inconsistent/adversarial
                # archive (e.g. entries "a" and "a/b.txt" both present).
                raise _ExtractionAborted(
                    f"path conflict while creating directory {cur!r}: "
                    f"a file already exists where a directory is required") from e
            os.chmod(cur, DIR_MODE)   # force exact bits regardless of umask
            created.append(cur)
    return cur


def _extract_member(zf, info, dest_dir, dest_real, max_file_bytes, ratio_cap_bytes, totals, created):
    """Extract a single, already-name-validated zip member. Returns 1 if a
    file was written, 0 for a directory. Raises _ExtractionAborted on any
    policy violation discovered during the actual write."""
    parts, reason = _safe_relparts(info.filename)
    if reason:
        # Already caught in _prevalidate; re-checked here so this function
        # is safe to call standalone and never trusts phase 1 blindly.
        raise _ExtractionAborted(reason)

    if info.is_dir():
        _make_dirs(dest_dir, dest_real, parts, created)
        return 0

    parent = _make_dirs(dest_dir, dest_real, parts[:-1], created)
    target = os.path.join(parent, parts[-1])

    # Defense in depth: re-derive containment from the filesystem itself
    # (realpath), independent of the string-based parsing above.
    target_real = os.path.realpath(target)
    if not (target_real == dest_real or target_real.startswith(dest_real + os.sep)):
        raise _ExtractionAborted(f"entry escapes dest-dir after path resolution: {info.filename!r}")

    try:
        raw_dst = open(target, "wb")
    except IsADirectoryError as e:
        raise _ExtractionAborted(
            f"path conflict: {info.filename!r} collides with an existing directory") from e

    with raw_dst:
        created.append(target)
        capped = _CappedWriter(raw_dst, max_file_bytes, totals, ratio_cap_bytes)
        with zf.open(info) as src:
            try:
                shutil.copyfileobj(src, capped, CHUNK)
            except zipfile.BadZipFile as e:
                # The declared CRC/size in the central directory didn't match
                # what actually came off the wire — the classic sign of a
                # tampered/lying archive. See the module docstring's THREAT
                # MODEL section: CPython's ZipExtFile clamps decompressed
                # output to the declared file_size, so this CRC check (not
                # _CappedWriter above) is usually what actually catches a
                # "declared small, real payload big" forgery.
                raise _ExtractionAborted(f"corrupt/tampered entry {info.filename!r}: {e}") from e
            except _ExtractionAborted:
                raise
            except OSError:
                # A REAL I/O problem (disk full, permission) — not a statement
                # about the artifact. Bubble to main()'s exit-1 path, which
                # still runs _cleanup().
                raise
            except Exception as e:
                # Anything else out of the decompressor (zlib.error, EOFError
                # on a truncated stream, ...) is hostile/corrupt STREAM DATA,
                # not an environment problem — without this catch it would
                # skip the reject path (and its cleanup) entirely and surface
                # as an unstructured exit-1. Same treatment as BadZipFile.
                raise _ExtractionAborted(f"undecodable entry {info.filename!r}: {e}") from e
    os.chmod(target, FILE_MODE)   # strip whatever mode the zip declared; static sites need no exec bits
    return 1


def _cleanup(created):
    """Undo exactly what THIS run created, in reverse (deepest-first) order,
    so a failed extraction leaves dest-dir back in the empty state the
    caller handed us. Never touches anything that predates this invocation
    — non-empty-dest-dir rejections (nothing created yet) call this with an
    empty list and are a deliberate no-op."""
    for path in reversed(created):
        try:
            if os.path.isdir(path) and not os.path.islink(path):
                os.rmdir(path)
            else:
                os.remove(path)
        except OSError:
            pass   # best-effort: a half-cleaned dest-dir is still safer than crashing in the cleanup path


# ---------- CLI plumbing ----------------------------------------------------

def _fail_reject(reason, created):
    print(f"REJECT: {reason}", file=sys.stderr)
    _cleanup(created)
    sys.exit(2)


def _fail_error(reason):
    print(f"ERROR: {reason}", file=sys.stderr)
    sys.exit(1)


def _parse_args(argv):
    ap = argparse.ArgumentParser(
        prog="safe_extract.py",
        description="Hardened, streaming zip extractor for the sites pipeline (SPEC-SITES-PIPELINE.md §8).")
    ap.add_argument("artifact", help="path to the uploaded .zip artifact")
    ap.add_argument("dest_dir", help="empty, pre-allocated destination directory")
    ap.add_argument("--max-mb", type=int, default=DEFAULT_MAX_MB,
                     help=f"max compressed artifact size in MB (default {DEFAULT_MAX_MB}, "
                          f"env SITES_MAX_UPLOAD_MB)")
    ap.add_argument("--max-entries", type=int, default=DEFAULT_MAX_ENTRIES,
                     help=f"max entry count (default {DEFAULT_MAX_ENTRIES})")
    ap.add_argument("--max-ratio", type=int, default=DEFAULT_MAX_RATIO,
                     help=f"max ratio of total uncompressed to --max-mb (default {DEFAULT_MAX_RATIO}, "
                          f"env SITES_MAX_RATIO)")
    ap.add_argument("--max-file-mb", type=int, default=DEFAULT_MAX_FILE_MB,
                     help=f"max uncompressed size of any single entry in MB (default {DEFAULT_MAX_FILE_MB})")
    return ap.parse_args(argv[1:])


def main(argv):
    args = _parse_args(argv)

    # ---- dest-dir preconditions: cheapest checks first, before we ever
    # touch the (possibly huge or malicious) artifact file. ----
    dest_dir = os.path.abspath(args.dest_dir)
    if not os.path.isdir(dest_dir):
        _fail_error(f"dest-dir does not exist or is not a directory: {args.dest_dir}")
    try:
        existing = os.listdir(dest_dir)
    except OSError as e:
        _fail_error(f"could not read dest-dir: {e}")
    if existing:
        # The pipeline always allocates dest-dir fresh and empty; a non-empty
        # dest-dir means something is wrong upstream (stale tmp dir, reused
        # path) — refuse rather than silently mixing content into it. Nothing
        # was created by us, so cleanup is a no-op (never delete what we
        # didn't create).
        _fail_reject(f"dest-dir is not empty: {args.dest_dir}", created=[])

    artifact = os.path.abspath(args.artifact)
    if not os.path.isfile(artifact):
        _fail_error(f"artifact not found: {args.artifact}")

    max_bytes = args.max_mb * 1024 * 1024
    max_file_bytes = args.max_file_mb * 1024 * 1024
    ratio_cap_bytes = args.max_ratio * max_bytes

    # Cheap size check BEFORE we even attempt to parse it as a zip — a huge
    # garbage/bomb upload shouldn't cost us a central-directory parse.
    try:
        compressed_bytes = os.path.getsize(artifact)
    except OSError as e:
        _fail_error(f"could not stat artifact: {e}")
    if compressed_bytes > max_bytes:
        _fail_reject(
            f"compressed artifact is {compressed_bytes} bytes, over the {max_bytes} byte cap (--max-mb {args.max_mb})",
            created=[])

    try:
        zf = zipfile.ZipFile(artifact)
    except zipfile.BadZipFile as e:
        _fail_reject(f"not a valid zip archive: {e}", created=[])
    except OSError as e:
        _fail_error(f"could not open artifact: {e}")

    with zf:
        reason = _prevalidate(zf, args.max_entries, max_file_bytes, ratio_cap_bytes)
        if reason:
            _fail_reject(reason, created=[])

        # ---- phase 2: stream-extract, re-enforcing caps against bytes
        # actually produced (see module docstring THREAT MODEL). ----
        dest_real = os.path.realpath(dest_dir)
        created = []
        totals = [0]
        file_count = 0
        try:
            for info in zf.infolist():
                file_count += _extract_member(
                    zf, info, dest_dir, dest_real, max_file_bytes, ratio_cap_bytes, totals, created)
        except _ExtractionAborted as e:
            _fail_reject(str(e), created)
        except OSError as e:
            print(f"ERROR: I/O error during extraction: {e}", file=sys.stderr)
            _cleanup(created)
            sys.exit(1)

    print(f"OK: {file_count} files, {totals[0]} bytes")
    sys.exit(0)


if __name__ == "__main__":
    try:
        main(sys.argv)
    except SystemExit:
        raise
    except Exception as e:  # last-resort safety net: the pipeline branches on our exit code,
        # so a raw traceback (implicit exit 1, but noisy/unstructured) is worse than a clean message.
        print(f"ERROR: unexpected failure: {e}", file=sys.stderr)
        sys.exit(1)
