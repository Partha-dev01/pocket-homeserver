# Resilience: crashes, DB corruption, and recovery

A self-hosted server on a spare Android phone runs in a hostile environment for a
database: the OS reboots, Android's low-memory killer (LMK) reaps background
processes, and storage can be slow. This page explains the failure modes that
matter, what pocket-homeserver does about them automatically, and how to recover.

> **Post-mortem in one line.** The failure class this hardening targets: an
> unclean kill of the Matrix homeserver mid-write left RocksDB unable to open (its
> manifest referenced data files that were never durably flushed), so it
> **crash-looped** — and without a backoff or an alert, a crash loop can hammer
> storage for hours, unnoticed, while chat is down.

## The two failure modes

1. **Unclean shutdown → DB corruption.** The Matrix homeserver (continuwuity /
   conduwuit) stores everything in an embedded RocksDB. If the process is killed
   uncleanly (reboot, LMK, power loss) while writing, RocksDB can come back up
   with a manifest that points at SST files that were never fsync'd → it refuses
   to open and exits.
2. **Silent crash loop.** A service that can't start (corrupt DB, bad config,
   missing dependency) exits immediately. A naive supervisor that just respawns it
   every few seconds will do so forever — pinning CPU/IO, growing logs, and
   leaving the service down with **no signal to the operator**.

## What pocket-homeserver does automatically

### 1. Crash-loop backoff + circuit breaker (`scripts/lib/common.sh`)

Every supervised service runs under `supervise()`, which now:

- **Backs off exponentially** on rapid failures (`POCKET_RESPAWN_MIN` → …,
  doubling, capped at `POCKET_RESPAWN_MAX`) instead of a fixed 5 s — so a broken
  service can't hammer storage.
- Treats a child that stays up `≥ POCKET_HEALTHY_SECS` as **healthy**: the
  backoff resets and any degraded flag clears.
- After `POCKET_CRASHLOOP_FAILS` rapid failures it writes a **DEGRADED marker**
  (`${POCKET_STATE_DIR}/<service>.degraded`) and fires the optional one-shot
  alert. It keeps retrying at the capped interval (so it still self-heals if the
  cause clears), but it is now *loud* instead of silent.

| Variable | Default | Meaning |
|---|---|---|
| `POCKET_HEALTHY_SECS` | `60` | child up ≥ this ⇒ healthy (reset backoff) |
| `POCKET_RESPAWN_MIN` | `5` | first respawn delay (s) |
| `POCKET_RESPAWN_MAX` | `300` | backoff cap (s) |
| `POCKET_CRASHLOOP_FAILS` | `5` | rapid failures before DEGRADED + alert |

### 2. Visibility — the DEGRADED state

A crash-looping service can flicker "alive" between respawns, so the up/down probe
alone is unreliable. The DEGRADED marker is the reliable signal and is surfaced:

- **Admin panel** → *stack health*: an amber, pulsing dot and a "⚠ crash-looping"
  badge. For the Matrix service specifically it adds *"DB may be corrupt; run
  scripts/ops/restore.sh"*.
- **`/health` page**: the process row reads `CRASH-LOOPING ⚠`.
- The marker clears automatically on a healthy run or on a manual restart
  (`scripts/ops/restart.sh <service>` / the panel's restart button).

### 3. Optional crash-loop alerting (`POCKET_ALERT_CMD`)

Set a single shell command in `.env`; it runs **once** when any service enters
DEGRADED, with `$POCKET_ALERT_SERVICE`, `$POCKET_ALERT_RC`, `$POCKET_ALERT_FAILS`
in the environment (never on the command line). Wire it to whatever you use:

```sh
# healthchecks.io (fail ping)
POCKET_ALERT_CMD='curl -fsS -m10 https://hc-ping.com/<uuid>/fail'
# ntfy push
POCKET_ALERT_CMD='curl -fsS -m10 -d "pocket: $POCKET_ALERT_SERVICE crash-looping (rc=$POCKET_ALERT_RC)" ntfy.sh/<your-topic>'
```

This is separate from the backup daemon's own heartbeat (`BACKUP_DAEMON_HC_URL`),
which tells you the *phone* is alive and backups are running.

### 4. Bounded data loss — daily DB backups

The scheduled backup daemon (`ENABLE_BACKUP_DAEMON=true`) snapshots the Matrix DB
on `BACKUP_DB_CADENCE` (**default `daily`**) and the heavy full rootfs monthly.
Daily keeps your worst-case loss to ≤ 1 day if the DB is ever corrupted; the DB
tar is small and the homeserver pauses only for the snapshot (tens of seconds).
Retention is `BACKUP_KEEP_DB` (default 3). Backups are consistent — `backup-db.sh`
stops the homeserver via `unsupervise` (whole process group) before the tar, so
there is never a second writer racing the snapshot.

### 5. Optional RocksDB self-recovery (test first)

`config/conduwuit.toml.tmpl` ships a commented, OFF-by-default block for
`rocksdb_recovery_mode` (recover to the last consistent point on open). It is off
because option names vary by continuwuity build and an unknown key fails closed at
startup — cross-check your build's example config and confirm the server still
starts before enabling. See the comments in that file.

## Recovering from a corrupt DB

If the admin panel shows Matrix crash-looping with the corrupt-DB hint (or the
homeserver won't come up and its log shows `No such file ... .sst` / a keypair
panic):

1. **Restore the latest snapshot:** `bash scripts/ops/restore.sh` (dry-run by
   default; see `docs/RESTORE_AND_ROTATION.md`). It stops the stack, preserves the
   current DB aside (it does not delete it), restores the newest backup, and
   restarts.
2. You lose Matrix state since that snapshot — which is why the default cadence is
   daily. The server's signing identity lives in the DB, so restoring a backup
   preserves it; clients generally stay logged in, though devices/keys created
   after the snapshot may need to re-login.
3. Keep the preserved corrupt DB until you're satisfied, then delete it to reclaim
   space.

## Reducing the chance of an unclean kill

- Keep `termux-wake-lock` held and exempt Termux from battery optimization (see
  `docs/SETUP.md`) so Android is less likely to LMK-kill the stack.
- The watchdog (`scripts/watchdog.sh`, if you enabled boot survival) re-runs
  `start-stack.sh` periodically; combined with the backoff above it heals
  transient deaths without hammering a genuinely broken DB.
