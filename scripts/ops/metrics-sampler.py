#!/usr/bin/env python3
"""metrics-sampler.py — tiny supervised system-metrics sampler (OPTIONAL).

Samples a handful of cheap, host-side numbers every POCKET_METRICS_POLL_S seconds
and appends ONE compact JSON object per line to a capped JSONL "ring" file. The
web admin panel reads that file to draw inline-SVG sparklines, a 24h health strip,
and a stats history. There is NO inbound listener and NO network call — it only
reads /proc, /sys, statvfs and (best effort) termux-battery-status, so it adds
effectively zero attack surface and negligible load.

Storage tier: the ring file lives on REAL ext4 (POCKET_METRICS_LOG, set by the
install step to ~/.pocket/metrics/metrics.jsonl), NOT on the exFAT SD card — the
same ext4 precedent the honeypot SQLite DB uses. That matters for two reasons:
(1) the periodic trim rewrites the file via a temp+rename, and exFAT/FUSE refuses
rename-over-existing; (2) it keeps churn off the removable card. See docs/OBSERVABILITY.md.

Runs TERMUX-NATIVE (not inside the proot userland): everything it reads is on the
host. It is kept alive by the shared supervisor (scripts/lib/common.sh), so a
crash just respawns and start-stack.sh re-supervises it on every bring-up.

Env (all optional; the install step sets the paths):
  POCKET_METRICS_LOG    ring file path           (default ~/.pocket/metrics/metrics.jsonl)
  POCKET_METRICS_POLL_S sample interval, seconds (default 60, min 5)
  POCKET_METRICS_RING   max lines kept           (default 5760 ≈ 4 days @ 60s)
  POCKET_METRICS_DISK   path to measure free %   (default DATA_DIR, else the ring's fs)
  POCKET_STATE_DIR      where *.degraded markers live (for the health count)
  POCKET_METRICS_BATTERY 'true' to poll battery via termux-battery-status (default true)

Each line is a compact object with short keys to keep the ring tiny:
  ts   epoch seconds (UTC)        cpu  busy %          l1   1-min load average
  mem  memory used %              swap swap used %     disk disk used % (POCKET_METRICS_DISK)
  temp °C (max thermal zone)      batt battery %       deg  count of DEGRADED services
Any field that can't be read this tick is simply omitted.

Generalized from a working deployment; review before running on a fresh phone.
"""

import json
import os
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
RING = os.environ.get("POCKET_METRICS_LOG") or os.path.join(
    HOME, ".pocket", "metrics", "metrics.jsonl"
)
POLL = max(5, int(os.environ.get("POCKET_METRICS_POLL_S") or "60"))
MAX_LINES = max(60, int(os.environ.get("POCKET_METRICS_RING") or "5760"))
DISK_PATH = os.environ.get("POCKET_METRICS_DISK") or os.environ.get("DATA_DIR") or RING
STATE_DIR = os.environ.get("POCKET_STATE_DIR") or ""
BATTERY = (os.environ.get("POCKET_METRICS_BATTERY") or "true").lower() == "true"

# Trim the ring every TRIM_EVERY appends (a full rewrite is cheap but not free).
TRIM_EVERY = 30


def _read(path):
    try:
        with open(path) as fh:
            return fh.read()
    except Exception:
        return ""


def cpu_times():
    """Return (busy, total) jiffies from /proc/stat, or None."""
    line = _read("/proc/stat").split("\n", 1)[0]
    if not line.startswith("cpu "):
        return None
    try:
        parts = [int(x) for x in line.split()[1:]]
    except ValueError:
        return None
    if len(parts) < 4:
        return None
    idle = parts[3] + (parts[4] if len(parts) > 4 else 0)  # idle + iowait
    total = sum(parts)
    return total - idle, total


def mem_pcts():
    """Return (mem_used_pct, swap_used_pct) from /proc/meminfo, or (None, None)."""
    vals = {}
    for ln in _read("/proc/meminfo").splitlines():
        k, _, rest = ln.partition(":")
        try:
            vals[k] = int(rest.split()[0])  # kB
        except (IndexError, ValueError):
            pass
    mem = swap = None
    mt, ma = vals.get("MemTotal"), vals.get("MemAvailable")
    if mt and ma is not None and mt > 0:
        mem = round(100.0 * (1.0 - ma / mt), 1)
    st, sf = vals.get("SwapTotal"), vals.get("SwapFree")
    if st and sf is not None and st > 0:
        swap = round(100.0 * (1.0 - sf / st), 1)
    return mem, swap


def load1():
    try:
        return round(float(_read("/proc/loadavg").split()[0]), 2)
    except (IndexError, ValueError):
        return None


def disk_pct(path):
    try:
        st = os.statvfs(path)
        if st.f_blocks > 0:
            return round(100.0 * (1.0 - st.f_bavail / st.f_blocks), 1)
    except OSError:
        pass
    return None


def temp_c():
    """Max plausible thermal-zone temperature in °C, or None."""
    best = None
    base = "/sys/class/thermal"
    try:
        zones = [z for z in os.listdir(base) if z.startswith("thermal_zone")]
    except OSError:
        return None
    for z in zones:
        raw = _read(os.path.join(base, z, "temp")).strip()
        if not raw:
            continue
        try:
            v = int(raw)
        except ValueError:
            continue
        c = v / 1000.0 if v > 1000 else float(v)  # millidegrees vs degrees
        if 0 < c < 150 and (best is None or c > best):
            best = c
    return round(best, 1) if best is not None else None


_battery_ok = True


def battery_pct():
    """Battery % via termux-battery-status (best effort), or None. Self-disables
    if the Termux:API helper is missing so we never fork it repeatedly for nothing."""
    global _battery_ok
    if not (BATTERY and _battery_ok):
        return None
    try:
        out = subprocess.run(
            ["termux-battery-status"],
            capture_output=True,
            text=True,
            timeout=8,
        )
        if out.returncode != 0 or not out.stdout.strip():
            _battery_ok = False
            return None
        return round(float(json.loads(out.stdout).get("percentage")), 0)
    except FileNotFoundError:
        _battery_ok = False
        return None
    except Exception:
        return None


def degraded_count():
    if not STATE_DIR:
        return None
    try:
        return sum(1 for f in os.listdir(STATE_DIR) if f.endswith(".degraded"))
    except OSError:
        return None


def trim(path, keep):
    """Keep only the last `keep` lines, atomically (ext4: temp + rename)."""
    try:
        with open(path) as fh:
            lines = fh.readlines()
    except OSError:
        return
    if len(lines) <= keep:
        return
    tmp = path + ".tmp"
    try:
        with open(tmp, "w") as fh:
            fh.writelines(lines[-keep:])
        os.replace(tmp, path)  # atomic on ext4
    except OSError:
        try:
            os.remove(tmp)
        except OSError:
            pass


def main():
    os.makedirs(os.path.dirname(RING) or ".", exist_ok=True)
    # Tighten perms where the filesystem honours them (ext4 does; exFAT ignores it).
    try:
        if not os.path.exists(RING):
            open(RING, "a").close()
        os.chmod(RING, 0o600)
    except OSError:
        pass

    prev = cpu_times()
    appends = 0
    # Skip the first interval's CPU so the very first sample isn't a bogus 0/spike.
    time.sleep(min(POLL, 10))

    while True:
        now = int(time.time())
        rec = {"ts": now}

        cur = cpu_times()
        if prev and cur and cur[1] > prev[1]:
            busy_d, total_d = cur[0] - prev[0], cur[1] - prev[1]
            if total_d > 0:
                rec["cpu"] = round(100.0 * busy_d / total_d, 1)
        if cur:
            prev = cur

        mem, swap = mem_pcts()
        if mem is not None:
            rec["mem"] = mem
        if swap is not None:
            rec["swap"] = swap
        v = load1()
        if v is not None:
            rec["l1"] = v
        v = disk_pct(DISK_PATH)
        if v is not None:
            rec["disk"] = v
        v = temp_c()
        if v is not None:
            rec["temp"] = v
        v = battery_pct()
        if v is not None:
            rec["batt"] = v
        v = degraded_count()
        if v is not None:
            rec["deg"] = v

        try:
            with open(RING, "a") as fh:
                fh.write(json.dumps(rec, separators=(",", ":")) + "\n")
        except OSError as ex:
            print(f"metrics-sampler: write failed: {ex}", file=sys.stderr)

        appends += 1
        if appends % TRIM_EVERY == 0:
            trim(RING, MAX_LINES)

        time.sleep(POLL)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
