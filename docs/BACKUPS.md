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
| **Per `BACKUP_DB_CADENCE`** (default `daily`) | [`ops/backup-db.sh`](../scripts/ops/backup-db.sh) — the Matrix DB (your primary user data; small + cheap). `daily` bounds worst-case loss to ≤ 1 day if the DB is ever corrupted by an unclean kill — recommended. Set `weekly` or `monthly` to snapshot less often. |
| **The 1st of each month** | [`ops/backup-all.sh`](../scripts/ops/backup-all.sh) — the heavy full rootfs |
| **Any other day** | nothing — it wakes, logs, and sleeps again |

> Why daily by default? A phone gets rebooted / low-memory-killed often, and an
> unclean kill can corrupt RocksDB. Sparse DB backups then mean large data loss.
> See [RESILIENCE.md](RESILIENCE.md) for the full failure-mode + recovery picture.

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

## Off-device encrypted backup (S3-compatible)

The snapshots above live **on the same phone**. To survive a lost or dead phone,
pocket-homeserver can push the **age-encrypted** archives to any S3-compatible
bucket — Cloudflare R2, Backblaze B2 (S3 API), AWS S3, Wasabi, MinIO.

```sh
ENABLE_OFFSITE_BACKUP=true       # in .env (or pick it in ./setup.sh)
BACKUP_AGE_RECIPIENT=age1…        # REQUIRED — see below
```

Then create a **0600** secrets file (the S3 keys never go in `.env`):

```sh
# ${DATA_DIR}/secrets/offsite.env   (chmod 600)
S3_ENDPOINT=https://<account>.r2.cloudflarestorage.com    # HTTPS required
S3_BUCKET=my-pocket-backups
S3_REGION=auto             # 'auto' for R2; a real region for AWS/B2/Wasabi
S3_ACCESS_KEY_ID=…
S3_SECRET_ACCESS_KEY=…
S3_PREFIX=pocket           # optional folder/prefix inside the bucket
```

The backup daemon runs the push after each retention pass; you can also run it on
demand from the admin panel (**backups → push encrypted backups off-device**),
`./pocket.sh` → *Backups → Push backups off-device*, or directly:

```sh
bash scripts/ops/offsite-push.sh
```

It uploads only the `*.tar.zst.age` archives (+ their `.sha256` sidecars), skips
anything already present (HEAD check), and mirrors local retention to the remote
(keeps the newest `BACKUP_KEEP_DB` / `BACKUP_KEEP_ROOTFS`). The transfer is a small,
dependency-free SigV4 client ([`ops/offsite-s3.py`](../scripts/ops/offsite-s3.py)) —
no `rclone`/`aws`/`boto3` to install or pin. The secret access key flows **only**
through the signing HMAC; it is never put in a URL, a log line, or on argv.

> **Encryption is mandatory for offsite.** `offsite-push.sh` **refuses to run**
> unless `BACKUP_AGE_RECIPIENT` is set — plaintext backups must never leave the
> device. Keep the age **private key off the phone** (it is the only thing that can
> decrypt what you upload).

### Resource & Risk

- **It uploads over your metered SIM** unless the phone is on Wi-Fi. The monthly
  rootfs archive is ~1 GB; the daily DB archive is small. Schedule / cadence is the
  backup daemon's (DB daily, rootfs monthly) — the push only sends what's new.
- **Single-PUT only (objects must be < 5 GiB).** Multipart upload is intentionally
  not implemented (it is a large, hard-to-verify amount of signing code). A larger
  rootfs archive is **skipped with a loud error**, not silently dropped — if yours
  approaches 5 GiB, prune the userland or copy that archive off by hand.
- **Restore is manual from the remote:** download the `.age` (+ `.sha256`) objects
  back into `${BACKUP_DIR}/db` or `/rootfs`, verify, then use the normal
  [restore](RESTORE_AND_ROTATION.md) path. There is no automatic pull-restore.
- **Cost / trust:** you are trusting your object-store provider with ciphertext only
  (age-encrypted), so a bucket compromise leaks nothing usable — but you still pay
  their storage/egress and must keep the bucket's credentials scoped (a
  bucket-scoped key, write+list+delete only).
