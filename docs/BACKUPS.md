# Backups & recovery

pocket-homeserver ships a small set of snapshot scripts under [`scripts/ops/`](../scripts/ops/). They
are exposed as buttons in the [web admin panel](ADMIN.md) and can also be run by
hand. All output lands under `${BACKUP_DIR}` (default `${DATA_DIR}/backups`), with a
`.sha256` integrity sidecar next to every archive.

> These are point-in-time snapshots **on the same device**. For real durability,
> copy `${BACKUP_DIR}` (or the whole `${DATA_DIR}`) off the phone periodically — to
> a laptop, an external drive, or object storage. A backup that only lives on the
> SD card does not survive a lost or dead phone.

## What gets backed up

| Script | Captures | Downtime | Output |
|---|---|---|---|
| [`ops/backup-db.sh`](../scripts/ops/backup-db.sh) | the Matrix homeserver database (conduwuit RocksDB, `/var/lib/conduwuit/db`) | homeserver stopped for the snapshot (tens of seconds) | `${BACKUP_DIR}/db/db-<UTC>.tar.zst` |
| [`ops/backup-all.sh`](../scripts/ops/backup-all.sh) | the **entire** Debian userland rootfs (all installed software + configs + the homeserver DB) | homeserver stopped during the tar; large + slow (~1 GB) | `${BACKUP_DIR}/rootfs/rootfs-<UTC>.tar.zst` |
| [`ops/rotate-backups.sh`](../scripts/ops/rotate-backups.sh) | — (prunes old archives to retention) | none | — |

**Media and app data are deliberately out of scope of these archives.** Matrix
media and every app's data (Linkding, Pingvin, FreshRSS, …) live on the large
volume under `${DATA_DIR}`, *not* inside the rootfs — so they are covered by copying
`${DATA_DIR}` itself. The one nuance: a few apps keep a small SQLite DB *inside* the
rootfs (e.g. Pingvin's), so `backup-all.sh` captures those best-effort while they
keep running; stop those apps first (`scripts/ops/restart.sh` / the panel) if you
need a fully quiescent rootfs snapshot.

## Retention

[`ops/rotate-backups.sh`](../scripts/ops/rotate-backups.sh) keeps the newest **`BACKUP_KEEP_DB`** db snapshots and
**`BACKUP_KEEP_ROOTFS`** rootfs snapshots (defaults `3` and `4`, set in `.env`). It
runs automatically at the end of `backup-db.sh` and `backup-all.sh`, and removes a
pruned archive together with its `.sha256` / `.age` / `.age.sha256` sidecars.

## Optional at-rest encryption (age)

Set `BACKUP_AGE_RECIPIENT` in `.env` to an [age](https://age-encryption.org)
recipient public key and install `age` in Termux (`pkg install age`). Each archive
is then additionally encrypted to `<archive>.age` and the plaintext is removed.

> Keep the matching age **identity (private key) off the phone**. Without it an
> encrypted backup is unrecoverable — that is the point, but it means the key is now
> the single thing you must not lose.

## Restore

The fastest path is the scripted restore,
[`scripts/ops/restore.sh`](../scripts/ops/restore.sh) (also in `./pocket.sh` →
*Backups & restore*). It is **dry-run by default** — with no flags it only prints
the plan — and acts only when you pass the explicit phrase, so a destructive path
is never a single mis-click:

```sh
bash scripts/ops/restore.sh                          # preview the plan (safe)
bash scripts/ops/restore.sh --confirm=ERASE-AND-RESTORE
```

It picks the latest rootfs + DB snapshot (override with `--rootfs=`/`--db=`),
verifies the `.sha256` sidecars fail-closed, rejects zip-slip members, decrypts
`.age` archives using `BACKUP_AGE_IDENTITY` from `.env`, renames the live rootfs
aside as `debian.broken-<UTC>` (a one-`mv` rollback), extracts, and restarts the
stack. See [RESTORE_AND_ROTATION.md](RESTORE_AND_ROTATION.md) for the full
walkthrough (and the credential-rotation scripts).

> The restore stops every supervised service first — including the admin panel if
> it is supervised — so run it from a shell (SSH / `./pocket.sh`), not as an admin
> panel job. It restores the rootfs + the conduwuit DB; app data and Matrix media
> that live on the data volume are recovered by restoring the volume itself.

If you prefer to do it by hand, the equivalent steps are:

1. **Stop the stack** (admin panel → HARD panic, or `scripts/ops/panic-hard.sh`).
2. **Verify integrity:** `sha256sum -c db-<UTC>.tar.zst.sha256` (and decrypt first
   with `age -d -i <identity> -o archive.tar.zst archive.tar.zst.age` if encrypted).
3. **DB restore:** replace `/var/lib/conduwuit/db` inside the userland with the
   archived `db/` directory:
   `proot-distro login debian --bind ${BACKUP_DIR}/db:/pocket-backup -- bash -lc 'cd /var/lib/conduwuit && rm -rf db && tar --zstd -xf /pocket-backup/db-<UTC>.tar.zst'`
4. **Full rootfs restore:** extract `rootfs-<UTC>.tar.zst` over
   `$PREFIX/var/lib/proot-distro/installed-rootfs/debian` (back up the current one
   first). Use this only for whole-userland recovery.
5. **Start the stack:** `scripts/start-stack.sh` — it brings the whole stack back
   up (core plus every installed app, from their recorded launch commands).

## Scheduled backups (the daemon)

Set `ENABLE_BACKUP_DAEMON=true` in `.env` (then run `./pocket.sh` → Install/Re-run,
or `scripts/start-stack.sh`) and pocket-homeserver supervises a small loop that
snapshots automatically — no cron needed. It wakes **once a day** at hour
`BACKUP_DAEMON_HOUR` (UTC, default `4`) and runs whatever is due:

| When (UTC) | Runs |
|---|---|
| **Every Sunday** | [`ops/backup-db.sh`](../scripts/ops/backup-db.sh) — the Matrix DB (your primary user data; cheap, keeps a tight recovery window) |
| **The 1st of each month** | [`ops/backup-db.sh`](../scripts/ops/backup-db.sh) **and** [`ops/backup-all.sh`](../scripts/ops/backup-all.sh) — DB plus the heavy full rootfs |
| **Any other day** | nothing — it wakes, logs, and sleeps again |

[`ops/rotate-backups.sh`](../scripts/ops/rotate-backups.sh) runs at the end of every wake, so retention stays
applied. The daemon (and every backup it forks) runs at idle CPU + best-effort
idle IO priority, so a heavy monthly rootfs tar never starves your live services.

It is a normal supervised service: it is started by `scripts/start-stack.sh` when
the flag is on (and re-supervised on every bring-up / after a reboot), shows up in
`./pocket.sh` → Status and the admin panel's health list, and can be restarted with
`scripts/ops/restart.sh backup-daemon`.

**Optional heartbeat.** Set `BACKUP_DAEMON_HC_URL` to a ping URL (e.g. a
[healthchecks.io](https://healthchecks.io) check). The daemon pings it after a
successful DB backup, or `<url>/fail` when the backup failed, so you get alerted if
the phone goes dark or a snapshot breaks. Empty (the default) = no ping.

**To stop it:** set `ENABLE_BACKUP_DAEMON=false` and re-run `start-stack.sh`
(it then skips + leaves it stopped), or stop it immediately from `./pocket.sh` →
Backups → *Stop the scheduled daemon* (which calls `unsupervise backup-daemon`).

Prefer to drive backups yourself? Leave the flag off and run the scripts on demand
from the admin panel, `./pocket.sh`, or by hand any time.
