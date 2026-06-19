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

A restore is a manual, deliberate operation (there is no one-click restore — that
keeps a destructive path from being a single mis-click). The shape is:

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

## Scheduling (optional)

These scripts are intended to be invoked from the admin panel or by hand. To run
them automatically, wire [`ops/backup-db.sh`](../scripts/ops/backup-db.sh) (frequent) and [`ops/backup-all.sh`](../scripts/ops/backup-all.sh)
(infrequent) into Termux's `cron`/`at` or a Termux:Boot-launched timer. A scheduled
backup daemon is a planned addition.
