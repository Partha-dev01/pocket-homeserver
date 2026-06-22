# Observability & alerts

Two small, optional pieces let you *see* the phone's health over time and get
*told* when something breaks: a metrics sampler that feeds the admin panel's charts,
and a one-shot crash-loop alert. Both are off by default and add no inbound surface.

## Metrics sampler → admin charts

Set `ENABLE_METRICS=true` (in `.env` or via `./setup.sh`) and re-run the installer.
[`scripts/ops/metrics-sampler.py`](../scripts/ops/metrics-sampler.py) is then
supervised like any other service. Once a minute it reads a few cheap, host-side
numbers and appends one compact JSON line to a **capped ring file**:

| Metric | Source |
|---|---|
| CPU busy % | `/proc/stat` deltas |
| memory / swap used % | `/proc/meminfo` |
| load (1m) | `/proc/loadavg` |
| disk used % | `statvfs(DATA_DIR)` |
| temperature | hottest `/sys/class/thermal/thermal_zone*` |
| battery % | `termux-battery-status` (best-effort; needs Termux:API) |
| DEGRADED count | number of `*.degraded` markers (the 24h health strip) |

The [web admin panel](ADMIN.md) reads it on the **`/metrics`** page: inline-SVG
sparklines per metric (current + 24h min/avg/max) and a **24h health strip** (green
when every service was healthy, red when one was crash-looping, grey for gaps).

Tuning (all optional, in `.env`):

```sh
POCKET_METRICS_POLL_S=60     # sample interval (min 5)
POCKET_METRICS_RING=5760     # samples kept (5760 ≈ 4 days @ 60s)
POCKET_METRICS_BATTERY=true  # poll the battery (self-disables if Termux:API absent)
```

### The "Problems" view + doctor button

Independent of the sampler, the panel surfaces trouble loudly:

- a **Problems banner** on the dashboard and a **`problems (N)`** nav tab appear
  the moment any service is crash-looping (`DEGRADED`) or a core service is down;
- the **`/problems`** page lists each unhealthy service with its crash-loop marker,
  a restart button, and a link to its log;
- a **run doctor** button runs [`ops/doctor.sh`](../scripts/ops/doctor.sh) (the
  read-only preflight) right from the dashboard / problems page;
- the **log viewer** (`/logs/<name>`) takes a case-insensitive `filter` and a line
  count, so you can grep a service's log without a shell.

### Storage tier & resource notes

- The ring file lives on **ext4** (`~/.pocket/metrics/metrics.jsonl`), **not** the
  exFAT SD card — the sampler trims it with an atomic `rename`, which exFAT/FUSE
  refuses, and this keeps churn off the removable card. This mirrors how the
  honeypot DB is pinned to ext4. Override with `POCKET_METRICS_LOG` if needed (point
  the panel at the same path).
- Cost is negligible: a handful of file reads once a minute and a < 1 MB ring. It is
  recommended to leave on. It makes **no** network call and opens **no** port.

## Crash-loop alerts (`POCKET_ALERT_CMD`)

Every service is kept alive by the supervisor; after `POCKET_CRASHLOOP_FAILS` rapid
failures it flags the service `DEGRADED` and fires **one** optional alert command
(see [RESILIENCE.md](RESILIENCE.md)). `./setup.sh` wires it for you — pick a channel:

| Channel | What setup writes (`POCKET_ALERT_CMD`) |
|---|---|
| **none** | empty (no alert) |
| **ntfy** | `curl … -d "service $POCKET_ALERT_SERVICE crash-looping (rc=$POCKET_ALERT_RC …)" <topic>` |
| **healthchecks** | `curl … "<your-ping-url>/fail"` |
| **Matrix** | `bash "…/scripts/ops/alert-matrix.sh"` (a tiny helper, below) |

The command runs once via `sh -c` with `$POCKET_ALERT_SERVICE`, `$POCKET_ALERT_RC`,
`$POCKET_ALERT_FAILS` in the environment (never on argv). It must be short and
silent. You can also just set `POCKET_ALERT_CMD` in `.env` by hand to any command.

### Matrix alerts ([`ops/alert-matrix.sh`](../scripts/ops/alert-matrix.sh))

So the Matrix access token never lands in `.env`, the Matrix channel reads a
**0600** file (the same pattern the honeypot uses). Create it after the stack is up:

```sh
# ${DATA_DIR}/secrets/alert-matrix.env   (chmod 600)
ALERT_MATRIX_HS=http://127.0.0.1:8448          # loopback is fine
ALERT_MATRIX_TOKEN=<access token of a bot/admin account already in the room>
ALERT_MATRIX_ROOM=!internalRoomId:your.domain  # internal id, NOT an alias
```

It posts a one-line `m.text` message and is best-effort (short timeout, never blocks
the supervisor). The token flows only in the `Authorization` header.

### Resource & Risk

- Alerts are **fire-and-forget**: stdout/stderr go to `/dev/null` and a stuck
  command is backgrounded, so a broken alert can never wedge the supervisor — but it
  also means you won't see *why* an alert failed. Test your command once by hand.
- A ping URL or ntfy topic is itself a capability — it lives in `.env` (0600), the
  same trust level as `BACKUP_DAEMON_HC_URL`. The Matrix token lives in a separate
  0600 file, never `.env`.
