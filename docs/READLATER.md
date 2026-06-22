# Wallabag — read-later / article saver (`read.${DOMAIN}`)

Wallabag is a self-hosted "read it later" service (like Pocket/Instapaper): save a
web article, Wallabag fetches a clean, readable copy you can read later, tag, and
search. It is **optional and OFF by default** — enable it with `ENABLE_WALLABAG=true`.

## How it installs

Wallabag is a PHP/Symfony app (pure PHP — architecture-independent), so it reuses
the same **php-fpm** machinery as FreshRSS. `scripts/apps/wallabag.sh` downloads the
official **bundled release tarball** (`wallabag-<ver>.tar.gz`), which already ships
`vendor/` — so there is **no `composer install`** on the phone (the heavy step that
helped rule out Nextcloud). It is served on a dedicated loopback php-fpm pool
(`127.0.0.1:9119`) via Caddy's `php_fastcgi`, with the Symfony front controller at
`web/app.php`.

### Checksum note (load-bearing)

Upstream publishes only an **MD5** (on the release blog, not on GitHub). MD5 is
collision-broken, so this repo pins its **own computed sha256** (`WALLABAG_SHA256`
in `config/versions.env`) and verifies fail-closed — the upstream MD5 is only a
courtesy cross-check. To upgrade, download the asset, `sha256sum` it yourself, and
bump the pin.

## Auth model

Wallabag's **browser UI** is a classic server-rendered Symfony app, so it tolerates
the interactive **Cloudflare Access** edge gate **and** the optional Matrix-SSO
`forward_auth` gateway (a commented block in the vhost). Open self-registration is
**disabled** (`fosuser_registration: false`) — an admin creates accounts.

> **The REST API + the official mobile app / browser extension** authenticate with
> **OAuth2 bearer tokens** and **cannot** follow a 302-to-login. To use them, add a
> **CF Access service-token exemption** for `read.${DOMAIN}` (operator-side; this
> repo wires nothing for it — see [APP_AUTH.md](APP_AUTH.md)).

### Admin seeding (off-argv)

On a fresh database the install runs `wallabag:install`, then seeds the admin from
`ADMIN_USER`/`ADMIN_PASSWORD` with the **password fed on stdin** (never on a command
line). If `ADMIN_USER` is not `wallabag`, it also **deactivates** the default
`wallabag` account so its well-known default password can't log in.

## Storage (SQLite on ext4 — load-bearing)

Wallabag uses **SQLite** (so the phone carries no separate DB server). The SQLite
DB + Symfony sessions live on **ext4** at `$HOME/.pocket/wallabag` (bind-mounted to
`/opt/wallabag/data`), never on exFAT — SQLite needs `fsync`, atomic rename, and
locks, and exFAT forbids `:` in filenames. SQLite is a single-user-grade backend
here; for heavy/multi-user use, move to Postgres on a real server.

## Upgrades (Symfony discipline — load-bearing)

Symfony apps are upgrade-fragile. `scripts/apps/wallabag.sh` handles this:

1. On an existing DB it **backs up the `.sqlite` file** (timestamped) **before**
   running `doctrine:migrations:migrate`. SQLite migrations are a project-known weak
   spot and are hard to roll back — the backup is your escape hatch.
2. It always **clears + warms the Symfony prod cache** (`cache:clear --env=prod`)
   after a code swap — a stale prod cache is the classic Wallabag 500/white screen.

Bump `WALLABAG_VERSION` + `WALLABAG_SHA256` together and re-run
`scripts/install.sh --force`. Treat every bump as a deliberate, tested operation.

## Resource & Risk

| Dimension | Assessment |
|---|---|
| **RAM (idle)** | Low — `pm = ondemand` means no resident php-fpm children when idle. |
| **RAM (peak)** | ⚠️ Medium–high: each request boots the full Symfony kernel (~80–150 MB/worker). `memory_limit = 384M`, `pm.max_children = 3`. Large OPML/Pocket **imports and exports** are documented OOM offenders — they are the realistic peak. |
| **CPU / LMK / thermal** | The `cache:clear` warmup and a big import are the CPU-bound moments; steady-state browsing is light. |
| **Storage** | ~250–400 MB extracted Symfony tree + warmed prod cache, all on ext4. Articles (HTML + small images) are stored in the DB/fs — modest. |
| **Checksum** | Upstream ships only MD5; the repo pins its **own sha256** fail-closed. |
| **Upgrade fragility** | ⚠️ The strongest caveat: mandatory `db:migrate` + `cache:clear` each bump, with a **backup-before-migrate**; SQLite migrations are fragile. |
| **Auth boundary** | Browser UI = the login gate is fine; the **REST API / mobile app / extension need a service-token exemption**. |
| **CF tunnel ~100 MB cap** | A huge Pocket/OPML import through the public hostname can hit it — do big imports on loopback/LAN. |
| **Async worker** | Intentionally **OFF** (no RabbitMQ/Redis — a documented OOM/queue footgun). Article fetch (Graby) is synchronous on save; some sites won't parse (a normal condition, not an install bug). |

## Enabling

```ini
# .env
ENABLE_WALLABAG=true
```

Then `./pocket.sh` → Install, add the `read.${DOMAIN}` public hostname (and an
Access policy) in the Cloudflare dashboard, and log in as `ADMIN_USER`. To disable:
set `ENABLE_WALLABAG=false` and stop the service.

## See also

- [APP_AUTH.md](APP_AUTH.md) — browser-gate vs the OAuth-API service-token exemption.
- [SECURITY.md](SECURITY.md) — the loopback-only edge model + the ~100 MB body cap.
- [BACKUPS.md](BACKUPS.md) — the SQLite DB is backed up before every migrate.
- [APPS.md](APPS.md) — the FreshRSS php-fpm sibling pattern.
