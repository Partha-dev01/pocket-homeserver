"""Honeypot SQLite DB — a derived, queryable cache of the JSONL honeypot ledger.

The ledger (the honeypot watcher's JSONL output) stays the single source of truth.
This module ingests it INCREMENTALLY (by a byte-offset bookmark) into a small
SQLite database so the admin console can offer fast server-side filter / sort /
paginate over the hits and a per-IP drill-down — things that re-parsing a growing
JSONL file on every page load cannot do well.

Design / safety:
  * The DB should live on a real (ext4-style) filesystem, NEVER on the exFAT SD
    card — SQLite WAL/locking misbehaves on exFAT. Its path comes from the
    environment (HP_DB, else derived under the deployment's state dir).
  * **The admin panel is the SOLE writer.** The live watcher never opens the DB;
    it only appends to the ledger. So there is exactly one writer process and WAL
    is safe.
  * Ingestion is **idempotent**. Each hit row is keyed by its `ledger_offset` (the
    byte position where its JSON line starts) with a UNIQUE constraint + INSERT OR
    IGNORE, so re-ingesting overlapping ranges can never double-insert. The
    bookmark (`meta.ledger_ingest_offset`) drives incremental reads. ip_state
    aggregates are only bumped when a hit row is *actually* inserted (rowcount==1),
    so totals never double-count.
  * The DB is a pure function of the ledger. If the ledger is ever truncated or
    replaced (size < bookmark), we wipe + rebuild from offset 0 — safe because the
    ledger is authoritative.
  * A trailing partial line (ledger appended-but-not-yet-newline-terminated) is
    left unconsumed; the bookmark only advances past complete `\n`-terminated lines.

stdlib only (native Termux python3; not in the proot). No network, no shell-out.

Configuration (environment, all optional — sensible defaults below):
  * HP_LEDGER : path to the JSONL ledger (default <POCKET_LOG_DIR>/honeypot.log,
                falling back to <DATA_DIR>/logs/honeypot.log).
  * HP_DB     : path to the derived SQLite DB (default <POCKET_STATE_DIR>/honeypot.db,
                falling back to <DATA_DIR>/state/honeypot.db). Override for tests.
"""
import os
import json
import time
import sqlite3
import calendar


def _default_log_dir():
    """Where the watcher writes its JSONL ledger — the deployment's log dir."""
    d = os.environ.get("POCKET_LOG_DIR")
    if d:
        return d
    data = os.environ.get("DATA_DIR")
    if data:
        return os.path.join(data, "logs")
    # Last resort for standalone/test runs: a logs/ dir under the cwd.
    return os.path.join(os.getcwd(), "logs")


def _default_state_dir():
    """Where the derived DB lives — the deployment's state dir (a real FS, not the
    exFAT SD card)."""
    d = os.environ.get("POCKET_STATE_DIR")
    if d:
        return d
    data = os.environ.get("DATA_DIR")
    if data:
        return os.path.join(data, "state")
    return os.path.join(os.getcwd(), "state")


LEDGER = os.environ.get("HP_LEDGER", os.path.join(_default_log_dir(), "honeypot.log"))
# Derived DB on a real filesystem (NOT the exFAT SD). Override with HP_DB for tests.
DB_PATH = os.environ.get("HP_DB", os.path.join(_default_state_dir(), "honeypot.db"))

SCHEMA_VERSION = "1"

_SCHEMA = """
CREATE TABLE IF NOT EXISTS hits (
    id            INTEGER PRIMARY KEY,
    ts            TEXT,
    ts_epoch      INTEGER,
    ip            TEXT,
    host          TEXT,
    uri           TEXT,
    method        TEXT,
    status        TEXT,
    ua            TEXT,
    hit_rule      TEXT,
    mode          TEXT,
    action        TEXT,
    country       TEXT,
    asn           TEXT,
    as_org        TEXT,
    hosting       INTEGER,
    ledger_offset INTEGER UNIQUE
);
CREATE INDEX IF NOT EXISTS ix_hits_epoch   ON hits(ts_epoch);
CREATE INDEX IF NOT EXISTS ix_hits_ip      ON hits(ip, ts_epoch);
CREATE INDEX IF NOT EXISTS ix_hits_rule    ON hits(hit_rule, ts_epoch);
CREATE INDEX IF NOT EXISTS ix_hits_country ON hits(country);

CREATE TABLE IF NOT EXISTS ip_state (
    ip          TEXT PRIMARY KEY,
    first_seen  TEXT,
    last_seen   TEXT,
    last_epoch  INTEGER,
    total_hits  INTEGER,
    rules       TEXT,          -- JSON array
    actioned    TEXT,          -- '' | 'challenge' | 'block' | 'actioned'
    action_ts   TEXT,
    -- write-action columns (nullable so no migration is needed):
    cf_rule_id  TEXT,
    cf_mode     TEXT,
    cf_actor    TEXT,
    safelisted  INTEGER,
    note        TEXT,
    escalation  TEXT,
    country     TEXT,
    asn         TEXT,
    as_org      TEXT,
    hosting     INTEGER,
    updated_at  TEXT
);
CREATE INDEX IF NOT EXISTS ix_ipstate_hits ON ip_state(total_hits);
CREATE INDEX IF NOT EXISTS ix_ipstate_last ON ip_state(last_epoch);

CREATE TABLE IF NOT EXISTS actions (
    id      INTEGER PRIMARY KEY,
    ts      TEXT,
    actor   TEXT,
    action  TEXT,
    ip      TEXT,
    detail  TEXT,              -- JSON
    result  TEXT,
    source  TEXT
);
CREATE INDEX IF NOT EXISTS ix_actions_ip ON actions(ip, ts);

CREATE TABLE IF NOT EXISTS meta (
    k TEXT PRIMARY KEY,
    v TEXT
);
"""


# ---------------------------------------------------------------------------
def connect(db_path=None):
    """Open (creating dirs + schema as needed) and return a configured connection.
    WAL + NORMAL sync + a busy timeout — correct for a single-writer cache."""
    db_path = db_path or DB_PATH
    os.makedirs(os.path.dirname(db_path), exist_ok=True)
    conn = sqlite3.connect(db_path, timeout=10)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    conn.execute("PRAGMA busy_timeout=5000")
    conn.executescript(_SCHEMA)
    if meta_get(conn, "schema_version") is None:
        meta_set(conn, "schema_version", SCHEMA_VERSION)
    conn.commit()
    return conn


def meta_get(conn, k, default=None):
    r = conn.execute("SELECT v FROM meta WHERE k=?", (k,)).fetchone()
    return r["v"] if r else default


def meta_set(conn, k, v):
    conn.execute("INSERT INTO meta(k, v) VALUES(?, ?) "
                 "ON CONFLICT(k) DO UPDATE SET v=excluded.v", (k, str(v)))


def _epoch(ts):
    try:
        return calendar.timegm(time.strptime(ts, "%Y-%m-%dT%H:%M:%SZ"))
    except Exception:
        return 0


def _hosting_val(rec):
    h = rec.get("hosting")
    return None if h is None else (1 if h else 0)


def _count_hits(conn):
    return conn.execute("SELECT COUNT(*) FROM hits").fetchone()[0]


# ---------------------------------------------------------------------------
def _insert_hit(cur, rec, offset):
    """INSERT OR IGNORE one ledger record. Returns True iff a row was added."""
    ts = str(rec.get("ts", ""))
    cur.execute(
        "INSERT OR IGNORE INTO hits "
        "(ts, ts_epoch, ip, host, uri, method, status, ua, hit_rule, mode, action, "
        " country, asn, as_org, hosting, ledger_offset) "
        "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (ts, _epoch(ts), str(rec.get("ip", "")), str(rec.get("host", "")),
         str(rec.get("uri", "")), str(rec.get("method", "")),
         str(rec.get("status", "")), str(rec.get("ua", "")),
         str(rec.get("hit_rule", "")), str(rec.get("mode", "")),
         str(rec.get("action", "")), rec.get("country"), rec.get("asn"),
         rec.get("as_org"), _hosting_val(rec), offset))
    return cur.rowcount == 1


def _actioned_from(action, prev=""):
    """Derive a coarse actioned state from a ledger `action` tag (e.g.
    'cf-managed_challenge:abc' -> 'challenge', 'cf-block:dup' -> 'block')."""
    a = (action or "").lower()
    if not a.startswith("cf-"):
        return prev
    if "block" in a:
        return "block"
    if "challenge" in a:
        return "challenge"
    return prev or "actioned"


def _upsert_ip_state(cur, rec):
    """Fold one hit into the per-IP aggregate. Mirrors the watcher's ip-state
    bookkeeping (first/last seen, total, rule union) and additionally records the
    realized edge action + geo, derived purely from the ledger."""
    ip = str(rec.get("ip", ""))
    if not ip:
        return
    ts = str(rec.get("ts", ""))
    ep = _epoch(ts)
    rule = str(rec.get("hit_rule", ""))
    action = str(rec.get("action", ""))
    hv = _hosting_val(rec)
    row = cur.execute("SELECT * FROM ip_state WHERE ip=?", (ip,)).fetchone()
    if row is None:
        rules = [rule] if rule else []
        cur.execute(
            "INSERT INTO ip_state "
            "(ip, first_seen, last_seen, last_epoch, total_hits, rules, actioned, "
            " action_ts, country, asn, as_org, hosting, updated_at) "
            "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (ip, ts, ts, ep, 1, json.dumps(rules), _actioned_from(action),
             ts if action.lower().startswith("cf-") else "",
             rec.get("country"), rec.get("asn"), rec.get("as_org"), hv, ts))
    else:
        rules = set(json.loads(row["rules"] or "[]"))
        if rule:
            rules.add(rule)
        actioned = _actioned_from(action, row["actioned"] or "")
        action_ts = ts if action.lower().startswith("cf-") else (row["action_ts"] or "")
        cur.execute(
            "UPDATE ip_state SET last_seen=?, last_epoch=?, total_hits=?, rules=?, "
            "actioned=?, action_ts=?, country=COALESCE(?, country), "
            "asn=COALESCE(?, asn), as_org=COALESCE(?, as_org), "
            "hosting=COALESCE(?, hosting), updated_at=? WHERE ip=?",
            (max(row["last_seen"] or "", ts),
             max(int(row["last_epoch"] or 0), ep),
             int(row["total_hits"] or 0) + 1, json.dumps(sorted(rules)),
             actioned, action_ts, rec.get("country"), rec.get("asn"),
             rec.get("as_org"), hv, ts, ip))


def ingest(conn, ledger_path=None):
    """Incrementally ingest new ledger lines since the byte-offset bookmark.
    Returns {ingested, rebuilt, total, size}. Idempotent + crash-safe."""
    ledger_path = ledger_path or LEDGER
    cur = conn.cursor()
    bookmark = int(meta_get(conn, "ledger_ingest_offset", "0") or "0")
    rebuilt = False
    try:
        size = os.path.getsize(ledger_path)
    except OSError:
        return {"ingested": 0, "rebuilt": False, "total": _count_hits(conn),
                "size": 0, "missing": True}

    if size < bookmark:
        # Ledger truncated / rotated / replaced — DB is derived; rebuild clean.
        cur.execute("DELETE FROM hits")
        cur.execute("DELETE FROM ip_state")
        bookmark = 0
        rebuilt = True

    ingested = 0
    if size > bookmark:
        with open(ledger_path, "rb") as f:
            f.seek(bookmark)
            data = f.read()
        last_nl = data.rfind(b"\n")
        if last_nl >= 0:
            consume = data[:last_nl + 1]   # only whole, newline-terminated lines
            pos = bookmark
            for raw in consume.split(b"\n"):
                line_start = pos
                pos += len(raw) + 1        # +1 for the stripped '\n'
                if not raw.strip():
                    continue
                try:
                    rec = json.loads(raw.decode("utf-8", "replace"))
                    if not isinstance(rec, dict):
                        continue
                except Exception:
                    continue               # unparseable line: skip row, consume bytes
                if _insert_hit(cur, rec, line_start):
                    _upsert_ip_state(cur, rec)
                    ingested += 1
            meta_set(conn, "ledger_ingest_offset", str(bookmark + len(consume)))
    conn.commit()
    return {"ingested": ingested, "rebuilt": rebuilt,
            "total": _count_hits(conn), "size": size}


# ---------------------------------------------------------------------------
# Read-only query helpers (server-side filter / sort / paginate via bound SQL).
_ORDER_COLS = {"ts": "ts_epoch", "ts_epoch": "ts_epoch", "ip": "ip",
               "rule": "hit_rule", "hit_rule": "hit_rule", "host": "host",
               "status": "status", "country": "country"}
_DISTINCT_COLS = {"hit_rule", "host", "country", "mode"}


def query_hits(conn, q=None, rule=None, host=None, country=None, ip=None,
               action=None, order="ts", desc=True, limit=100, offset=0):
    """Return (rows, total_matching). All inputs are bound parameters; the only
    interpolated tokens are whitelisted column names."""
    where, params = [], []
    if ip:
        where.append("ip = ?"); params.append(ip)
    if rule:
        where.append("hit_rule = ?"); params.append(rule)
    if host:
        where.append("host = ?"); params.append(host)
    if country:
        where.append("country = ?"); params.append(country)
    if action == "actioned":
        where.append("action LIKE 'cf-%'")
    if q:
        where.append("(ip LIKE ? OR uri LIKE ? OR host LIKE ? OR ua LIKE ? "
                     "OR hit_rule LIKE ?)")
        like = f"%{q}%"
        params += [like] * 5
    wsql = (" WHERE " + " AND ".join(where)) if where else ""
    col = _ORDER_COLS.get(order, "ts_epoch")
    dirn = "DESC" if desc else "ASC"
    total = conn.execute(f"SELECT COUNT(*) FROM hits{wsql}", params).fetchone()[0]
    rows = conn.execute(
        f"SELECT * FROM hits{wsql} ORDER BY {col} {dirn}, id {dirn} "
        f"LIMIT ? OFFSET ?", params + [int(limit), int(offset)]).fetchall()
    return rows, total


def distinct_values(conn, col, limit=40):
    """Top distinct values of a whitelisted column (for filter chips)."""
    if col not in _DISTINCT_COLS:
        return []
    rows = conn.execute(
        f"SELECT {col} AS c, COUNT(*) AS n FROM hits "
        f"WHERE {col} IS NOT NULL AND {col} != '' "
        f"GROUP BY {col} ORDER BY n DESC LIMIT ?", (int(limit),)).fetchall()
    return [(r["c"], r["n"]) for r in rows]


def ip_summary(conn, ip):
    """Per-IP aggregate row (dict) or None. `rules` decoded to a list."""
    r = conn.execute("SELECT * FROM ip_state WHERE ip=?", (ip,)).fetchone()
    if not r:
        return None
    d = dict(r)
    try:
        d["rules"] = json.loads(d.get("rules") or "[]")
    except Exception:
        d["rules"] = []
    return d


def ip_hits(conn, ip, limit=200, offset=0):
    rows, total = query_hits(conn, ip=ip, order="ts", desc=True,
                             limit=limit, offset=offset)
    return rows, total


def top_offenders(conn, limit=10):
    return conn.execute(
        "SELECT * FROM ip_state ORDER BY total_hits DESC LIMIT ?",
        (int(limit),)).fetchall()


def bucket_counts(conn, now_epoch):
    """Hit counts in the trailing 24h / 7d / 30d windows."""
    out = {}
    for label, secs in (("24h", 86400), ("7d", 604800), ("30d", 2592000)):
        out[label] = conn.execute(
            "SELECT COUNT(*) FROM hits WHERE ts_epoch >= ?",
            (int(now_epoch) - secs,)).fetchone()[0]
    return out


def record_action(conn, actor, action, ip, detail=None, result="", source="admin"):
    """Append a write-action audit row (used for challenge/block/etc.)."""
    ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    conn.execute(
        "INSERT INTO actions (ts, actor, action, ip, detail, result, source) "
        "VALUES (?,?,?,?,?,?,?)",
        (ts, actor, action, ip, json.dumps(detail or {}), result, source))
    conn.commit()


def recent_actions(conn, ip=None, limit=50):
    """Most-recent write-action audit rows, newest first (optionally for one IP)."""
    if ip:
        return conn.execute("SELECT * FROM actions WHERE ip=? ORDER BY id DESC "
                            "LIMIT ?", (ip, int(limit))).fetchall()
    return conn.execute("SELECT * FROM actions ORDER BY id DESC LIMIT ?",
                        (int(limit),)).fetchall()


# Columns the console is allowed to write on ip_state. The keys are a fixed
# whitelist (never interpolated from request data); only the VALUES are
# request-derived and they go in as bound parameters. This is what keeps the
# operator console from being able to scribble on, say, total_hits or rules.
_IP_SET_COLS = ("actioned", "action_ts", "cf_rule_id", "cf_mode", "cf_actor",
                "safelisted", "note", "escalation")


def update_ip_state(conn, ip, **fields):
    """Set whitelisted ip_state columns for `ip`, upserting a minimal row if the IP
    has no hits yet (an operator may safelist/annotate proactively). Returns the
    number of columns written (0 = nothing whitelisted was passed)."""
    cols = [(k, fields[k]) for k in _IP_SET_COLS if k in fields]
    if not cols:
        return 0
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    if conn.execute("SELECT 1 FROM ip_state WHERE ip=?", (ip,)).fetchone() is None:
        conn.execute("INSERT INTO ip_state (ip, total_hits, rules, updated_at) "
                     "VALUES (?, 0, '[]', ?)", (ip, now))
    set_sql = ", ".join(f"{k}=?" for k, _ in cols) + ", updated_at=?"
    params = [v for _, v in cols] + [now, ip]
    conn.execute(f"UPDATE ip_state SET {set_sql} WHERE ip=?", params)
    conn.commit()
    return len(cols)


# ---------------------------------------------------------------------------
def _cli():
    import argparse
    ap = argparse.ArgumentParser(description="Honeypot ledger -> SQLite cache.")
    ap.add_argument("--db", default=None, help=f"DB path (default {DB_PATH})")
    ap.add_argument("--ledger", default=None, help=f"ledger path (default {LEDGER})")
    ap.add_argument("--ingest", action="store_true", help="ingest new ledger lines")
    ap.add_argument("--init", action="store_true", help="just create the schema")
    ap.add_argument("--stats", action="store_true", help="print row counts")
    a = ap.parse_args()
    conn = connect(a.db)
    if a.init:
        print(f"schema ready at {a.db or DB_PATH}")
    if a.ingest:
        r = ingest(conn, a.ledger)
        print(f"ingest: +{r['ingested']} rows "
              f"(rebuilt={r['rebuilt']}, total={r['total']}, size={r['size']}B)")
    if a.stats or not (a.ingest or a.init):
        nh = conn.execute("SELECT COUNT(*) FROM hits").fetchone()[0]
        ni = conn.execute("SELECT COUNT(*) FROM ip_state").fetchone()[0]
        na = conn.execute("SELECT COUNT(*) FROM actions").fetchone()[0]
        bm = meta_get(conn, "ledger_ingest_offset", "0")
        print(f"hits={nh} ip_state={ni} actions={na} bookmark={bm}B")
    conn.close()


if __name__ == "__main__":
    _cli()
