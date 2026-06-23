# Forgejo — self-hosted git forge (`git.${DOMAIN}`)

Forgejo is a community soft-fork of Gitea: a lightweight, single-binary git forge
(repositories, issues, pull requests, releases, a package/LFS registry, a web code
browser). On pocket-homeserver it serves the browser UI, **git-over-HTTPS**, and the
REST API at `git.${DOMAIN}`, fronted by the loopback Caddy edge and the Cloudflare
Tunnel. It is **optional and OFF by default** — enable it with `ENABLE_FORGEJO=true`.

## How it installs

A single **static Go binary**, fetched as a **raw `linux-arm64` binary** (not a
tarball) from the canonical Codeberg release, pinned by exact version + sha256 and
verified fail-closed via `fetch_verified`:

- `FORGEJO_VER=15.0.3`
- `FORGEJO_SHA256=788ffe2fdbebff177f5bc73d54ef1827ab0d5704813b97cb22590602427e9af4`

It is installed with `install -m 0755` into the userland at `/opt/forgejo/forgejo`
(no extraction step). The only runtime dependency is `git` (ensured in the
userland); no database server is needed (SQLite).

### Runs as an unprivileged user (load-bearing)

Forgejo (like Gitea) **refuses to run as root**. The proot userland logs in as
root, so the script creates a dedicated unprivileged `forgejo` user, pins
`RUN_USER=forgejo` in `app.ini`, chowns the ext4 data bind to it at start, and
launches both the server **and** the admin-create CLI via `su -s /bin/bash forgejo`.

## Loopback / 0.0.0.0 handling (load-bearing)

Forgejo binds whatever `[server] HTTP_ADDR` says. The script pre-seeds `app.ini`
with `HTTP_ADDR=127.0.0.1` + `HTTP_PORT=9128` so it binds **loopback only** — proot
shares the phone's network namespace, so a wildcard bind would expose the forge on
the phone's real Wi-Fi/cellular interfaces (the verified past-outage class on this
stack). Two fail-closed guards back this up:

1. A **config assert** that requires `HTTP_ADDR=127.0.0.1` and rejects any
   `0.0.0.0` / `::` / `*`.
2. A **post-start `ss -ltnH` wildcard check** on `:9128` — if any listener is on a
   wildcard address the script runs `unsupervise forgejo` and `die`s rather than
   leave a LAN-exposed forge running.

Built-in SSH is also disabled (`DISABLE_SSH=true`, `START_SSH_SERVER=false`) — a
CGNAT phone has no public inbound TCP, so HTTPS is the only viable git transport and
leaving the SSH server's default `0.0.0.0:22` listener up would be pointless attack
surface.

## Auth model — service token for git/API, NOT the login gate (load-bearing)

The default front door is **Cloudflare Access** on `git.${DOMAIN}` plus Forgejo's
own native login; open registration is OFF (`DISABLE_REGISTRATION=true` —
invite/admin-only). The optional Matrix-SSO `forward_auth` gate (a commented block
in the vhost) would cover only the browser UI.

**Sharp edge:** `git clone/push https://…`, the REST API (`/api/v1`), and the LFS
batch API send Basic/token auth and **cannot follow a 302-to-login**. So you MUST
give `git.${DOMAIN}` a **Cloudflare Access service-token exemption** (or a path
bypass for the git-http / `/api/v1` / LFS endpoints) — otherwise the interactive
gate breaks every non-browser client while the web UI still works. As defense in
depth, `REVERSE_PROXY_AUTHENTICATION_USER` is left empty so a token client cannot
spoof the gateway login header. This repo wires nothing for the exemption
(operator-side, same pattern as Vaultwarden/Dufs — see [APP_AUTH.md](APP_AUTH.md)).

### First admin

`INSTALL_LOCK=true` disables the web installer, so the first admin is created from
the CLI with `forgejo admin user create --admin --random-password
--must-change-password=false`. The generated password (plus the `SECRET_KEY` and
`INTERNAL_TOKEN`, produced off-argv via `forgejo generate secret`) is stored 0600 at
`${DATA_DIR}/secrets/forgejo.env`. Read `FORGEJO_ADMIN_USER` / `FORGEJO_ADMIN_PASSWORD`
from there, log in, and change the password. Use a Forgejo **access token** as the
git password for HTTPS push/pull.

## Storage (everything on ext4 — load-bearing)

Everything writable lives on **ext4** at `$HOME/.pocket/forgejo` (bind-mounted to
`/opt/forgejo/data`): `forgejo.db` + its `-wal`/`-shm` (SQLite,
`SQLITE_JOURNAL_MODE=WAL`), the git **repositories**, LFS objects, attachments,
avatars, the issue indexer, file sessions, logs, and `app.ini` itself. SQLite WAL
and git's pack writes need real `fsync` + atomic rename + POSIX locks, which the
exFAT SD card cannot provide → corruption — so the script **refuses** to put the
data dir under `DATA_DIR` fail-closed. Forgejo has no read-mostly bulk tier worth
putting on the SD (repos are write-heavy), so nothing lives on the card. Data +
`app.ini` + secrets persist across upgrades and userland rebuilds because they live
on `$HOME/.pocket`.

## CGNAT interaction

No public inbound TCP → git SSH is impossible and is disabled. All git traffic rides
the Cloudflare Tunnel as HTTPS. The tunnel caps a single request body at **~100 MB**:
git-http pushes chunk fine under that, but a single **LFS object > 100 MB** needs
another transport path.

## Upgrades (deliberate, not a silent re-run)

1. **Back up `$HOME/.pocket/forgejo` first** (`scripts/ops/backup-db.sh` covers the
   ext4 `$HOME/.pocket` tree). The DB migrates on first start of a new version and is
   **not auto-reversible**.
2. Bump `FORGEJO_VER` + `FORGEJO_SHA256` **together** in `config/versions.env` (verify
   the per-asset `forgejo-<ver>-linux-arm64.sha256` Codeberg publishes, or
   `sha256sum forgejo-<ver>-linux-arm64`).
3. Re-run `scripts/apps/forgejo.sh` (or `scripts/ops/update.sh forgejo --to <ver>
   --sha256 <hash> --confirm`). The loopback config assert + post-start `ss` wildcard
   check re-apply on every run.

## Resource & Risk

| Dimension | Assessment |
|---|---|
| **RAM (idle)** | ~80–150 MB (a Go binary + SQLite). Light for a full git forge. |
| **RAM / CPU (peak)** | Large initial repo imports and the issue indexer are the main CPU/IO spikes — do big imports while on power. |
| **CI / Actions** | **Disabled** (`[actions] ENABLED=false`). Runners are a thermal / low-memory-killer heavy path on a phone — do not enable them here. |
| **Storage** | Binary ~100 MB; repos + LFS grow **unbounded** over time on ext4 — a quiet long-term growth risk. Watch `$HOME/.pocket/forgejo`. |
| **Auth boundary** | ⚠️ git-HTTP / `/api/v1` / LFS need a **CF Access service-token exemption** — never the interactive gate. |
| **CF tunnel ~100 MB cap** | A single LFS object > 100 MB cannot traverse the tunnel; ordinary pushes chunk fine. |
| **Upgrade fragility** | Medium: one-way auto-migrations → back up first; bump VER + SHA256 together. |

## Enabling

```ini
# .env
ENABLE_FORGEJO=true
```

Then `./pocket.sh` → Install (or `scripts/install.sh`), and in the Cloudflare
dashboard add the public hostname `git.${DOMAIN} -> http://localhost:${CADDY_PORT}`
**and** the service-token exemption for git-http / `/api/v1` / LFS. To disable: set
`ENABLE_FORGEJO=false` and stop it (`scripts/ops/restart.sh` / `start-stack.sh`).

## See also

- [APP_AUTH.md](APP_AUTH.md) — the service-token vs login-gate distinction.
- [SECURITY.md](SECURITY.md) — the loopback-only edge model + the body-size cap.
- [BACKUPS.md](BACKUPS.md) — DB/data backups (do one before every upgrade).
- [UPDATING.md](UPDATING.md) — version pins + `scripts/ops/update.sh`.
