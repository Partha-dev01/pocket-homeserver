#!/usr/bin/env python3
"""forms_db.py — SQLite store for the Pocket Pages forms endpoint
(SPEC-DIFFERENTIATORS.md §8, AD-4/AD-8/AD-9 + §14's OQ-5 resolution).

Loaded by admin/app.py via importlib (the panel runs as an out-of-tree copy,
so a plain package import can't reach this file; the panel already knows
SCRIPTS and loads this by absolute path). Mirrors honeypot_db.py's shape —
WAL + synchronous=NORMAL + busy_timeout, ext4 only, one writer (the panel's
single mandatory gunicorn worker) — without its ingestion machinery: forms
INSERT one row per public POST, they never tail anything.

Privacy (AD-8): the ONLY address-shaped thing ever written is truncate_ip()'s
coarse /24 (v4) / /48 (v6) network address — the full client IP never reaches
this module at all (the caller truncates first, so a bug here can't leak it).
Retention (OQ-5): gc() deletes rows older than the configured window; the
caller throttles it to at most one sweep per day (gc_due()) so the documented
retention is actually enforced without a cron entry.
"""

import ipaddress
import json
import os
import sqlite3
import time

_SCHEMA = """
CREATE TABLE IF NOT EXISTS submissions (
    id            INTEGER PRIMARY KEY,
    site          TEXT NOT NULL,
    form          TEXT NOT NULL,
    ts            TEXT NOT NULL,
    ts_epoch      INTEGER NOT NULL,
    ip_truncated  TEXT,
    ua            TEXT,
    fields_json   TEXT NOT NULL,
    spam          INTEGER NOT NULL DEFAULT 0,
    emailed       INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS ix_submissions_site ON submissions(site, ts_epoch);
"""


def connect(db_path):
    """Open (creating if needed) the forms DB with the repo's standard
    concurrent-SQLite pragmas (honeypot_db.py:148-153). Caller keeps the
    connection per-use (open/close per request is fine at form-submission
    volume; no pooling)."""
    os.makedirs(os.path.dirname(db_path), exist_ok=True)
    conn = sqlite3.connect(db_path, timeout=10)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    conn.execute("PRAGMA busy_timeout=5000")
    conn.executescript(_SCHEMA)
    return conn


def truncate_ip(ip):
    """Coarse, GDPR-oriented anonymization (AD-8): IPv4 -> /24 network address
    ("203.0.113.0"), IPv6 -> /48 ("2001:db8:1::"). Unparseable/empty -> ""
    (stored as an empty abuse-key rather than failing the submission)."""
    ip = (ip or "").strip()
    if not ip:
        return ""
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return ""
    bits = 24 if addr.version == 4 else 48
    return str(ipaddress.ip_network(f"{addr}/{bits}", strict=False).network_address)


def insert(conn, site, form, fields, ip_truncated, ua, spam):
    """One row per accepted POST. `fields` is an already-capped dict of
    field-name -> value (honeypot field ALREADY removed by the caller —
    AD-9 stores the fact of the trip in `spam`, never the bait value).
    Single INSERT, no multi-statement transaction to half-commit."""
    now = time.time()
    conn.execute(
        "INSERT INTO submissions (site, form, ts, ts_epoch, ip_truncated, ua, fields_json, spam, emailed)"
        " VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0)",
        (site, form,
         time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)), int(now),
         ip_truncated, (ua or "")[:300], json.dumps(fields, ensure_ascii=False),
         1 if spam else 0))
    conn.commit()
    return conn.execute("SELECT last_insert_rowid()").fetchone()[0]


def mark_emailed(conn, row_id):
    conn.execute("UPDATE submissions SET emailed = 1 WHERE id = ?", (row_id,))
    conn.commit()


def query(conn, site, include_spam=False, limit=50, offset=0):
    """Newest-first page of a site's submissions; spam rows are filtered out
    of the default view (AD-9 — stored for audit, hidden from the inbox)."""
    where = "site = ?" if include_spam else "site = ? AND spam = 0"
    rows = conn.execute(
        f"SELECT * FROM submissions WHERE {where} ORDER BY ts_epoch DESC, id DESC"
        " LIMIT ? OFFSET ?", (site, int(limit), int(offset))).fetchall()
    total = conn.execute(
        f"SELECT COUNT(*) FROM submissions WHERE {where}", (site,)).fetchone()[0]
    return rows, total


def delete_ids(conn, site, ids):
    """Prune specific rows — site-scoped so the inbox for one site can never
    delete another site's submissions, even with a forged id list."""
    ids = [int(i) for i in ids]
    if not ids:
        return 0
    q = ",".join("?" * len(ids))
    cur = conn.execute(
        f"DELETE FROM submissions WHERE site = ? AND id IN ({q})", [site] + ids)
    conn.commit()
    return cur.rowcount


def delete_spam(conn, site):
    cur = conn.execute("DELETE FROM submissions WHERE site = ? AND spam = 1", (site,))
    conn.commit()
    return cur.rowcount


# ── retention GC (OQ-5: automatic, throttled by the caller) ──────────────────

def gc_due(state_path, min_interval_s=86400):
    """True when the last sweep (mtime of `state_path`) is older than
    min_interval_s (or has never happened). The caller touches the stamp via
    gc() itself — a plain mtime stamp file, no extra table."""
    try:
        return (time.time() - os.path.getmtime(state_path)) >= min_interval_s
    except OSError:
        return True


def gc(conn, retention_days, state_path):
    """Delete rows older than the retention window and stamp the sweep.
    Retention is a hard privacy bound (AD-8), not housekeeping — which is why
    OQ-5 resolved to automatic rather than operator-remembered."""
    cutoff = int(time.time()) - int(retention_days) * 86400
    cur = conn.execute("DELETE FROM submissions WHERE ts_epoch < ?", (cutoff,))
    conn.commit()
    os.makedirs(os.path.dirname(state_path), exist_ok=True)
    with open(state_path, "w") as f:
        f.write(str(int(time.time())) + "\n")
    return cur.rowcount
