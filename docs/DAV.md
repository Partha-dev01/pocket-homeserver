# Radicale — calendar & contacts (CalDAV / CardDAV) (`dav.${DOMAIN}`)

Radicale is a small, pure-Python CalDAV/CardDAV/tasks server. It lets you sync your
calendars, contacts, and to-dos across DAVx5 (Android), Thunderbird, and
iOS/macOS — from your phone. It is **optional and OFF by default** — enable it with
`ENABLE_RADICALE=true`.

## How it installs

`scripts/apps/radicale.sh` creates a dedicated **Python venv on ext4** in the
userland and installs the pinned Radicale (`RADICALE_VERSION`, a pure-Python wheel)
plus **bcrypt**. bcrypt is installed with `--only-binary=:all:` so it can only come
from a **prebuilt aarch64 wheel** — it can **never** trigger a Rust compile on the
phone. If no wheel resolves, the install **fails closed** (it does not fall back to
compiling). It runs on loopback `127.0.0.1:5232`; Caddy fronts the edge.

> **bcrypt fallback:** if a future Python/libc combo has no bcrypt wheel, the
> documented manual fallback is `argon2-cffi` (`htpasswd_encryption = argon2`),
> which also ships aarch64 wheels — switch deliberately, never auto-compile.

## Auth model — service token, NOT the login gate (load-bearing)

CalDAV/CardDAV clients send **HTTP Basic** credentials and **cannot** follow an
interactive 302-to-login. So **do not** put `dav.${DOMAIN}` behind the Cloudflare
Access login policy or the Matrix-SSO `forward_auth` gateway — that breaks every
DAV client. Instead:

- Auth is **Radicale's own bcrypt `htpasswd`**, with `rights = owner_only` (each
  user sees only their own collections).
- In the Cloudflare dashboard, add a **Service Auth (service-token) exemption** for
  `dav.${DOMAIN}` (operator-side; this repo wires nothing for it — see
  [APP_AUTH.md](APP_AUTH.md)).

The vhost is **root-mounted** so Radicale answers `/.well-known/caldav` and
`/.well-known/carddav` itself (the 302s that drive client auto-discovery), with
`flush_interval -1` so chunked CalDAV `REPORT` responses stream. `hosts` is forced
to `127.0.0.1:5232` and **asserted** fail-closed (it refuses to start on a public
bind).

The initial user is seeded from `ADMIN_USER`/`ADMIN_PASSWORD` (bcrypt hash; the
plaintext is fed **off-argv** via the environment, never on a command line) into a
`0600` htpasswd. Add more users with bcrypt entries (`htpasswd -B`) or via the admin
panel.

## Connecting a client (and the QR connect-card)

- **Base URL:** `https://dav.${DOMAIN}/<user>/`
- **Auto-discovery (DAVx5):** `https://dav.${DOMAIN}/`

If the web admin panel is enabled, it has a **`/dav` "connect device" card** that
renders the base URL plus a **scannable QR** (built with the pure-Python `segno`
lib). **The QR carries only the public URL + username — never your password.** You
still type your password in the client.

- **DAVx5 (Android):** Add account → "Login with URL and user name" → scan the QR or
  paste the auto-discovery URL → enter your password.
- **iOS / macOS / Thunderbird:** add a CalDAV account *and* a CardDAV account using
  the base URL above, your username, and your password.

## Storage (collection root MUST be ext4 — load-bearing)

Radicale's `multifilesystem` backend stores each calendar/addressbook as flat
`.ics`/`.vcf` files. The collection root **must** be on **ext4** — we keep it at
`$HOME/.pocket/radicale` (bind-mounted to `/opt/radicale/var`). The install
**refuses to start** if that path resolves onto the exFAT SD card, because exFAT/FUSE:

- has **no rename-over-existing** → Radicale's atomic `.Radicale.tmp-*` → `os.replace`
  writes break or corrupt;
- has **no `fcntl`/`flock`** → `.Radicale.lock` concurrency safety is lost;
- has **2 s mtime granularity + no reliable fsync** → the `.Radicale.cache`
  sync-token correctness silently breaks (clients miss or re-do syncs);
- has **no unix permissions** → calendar/contact data would be world-readable.

**Backups:** `tar` the ext4 collection dir and copy the **tarball** to the SD card —
never sync the live `.ics` tree onto exFAT. After any upgrade, run
`radicale --verify-storage`.

## Upgrades

Bump `RADICALE_VERSION` in `config/versions.env` and re-run
`scripts/install.sh --force` (or `scripts/apps/radicale.sh`). Radicale is pinned
exactly because the password-hashing-library default can shift between minors;
re-run `radicale --verify-storage` afterward.

## Resource & Risk

| Dimension | Assessment |
|---|---|
| **RAM (idle)** | ~30–45 MB (one Python process, no DB engine). Negligible. |
| **RAM (peak)** | Modest; spikes only on large `REPORT`/sync over big collections. `max_connections = 8` caps it. |
| **CPU / LMK / thermal** | Low — a single lightweight long-lived process, no background indexing. Well below the envelope that ruled out Nextcloud. |
| **Storage** | Tiny (flat `.ics`/`.vcf` on ext4). The SD card only ever holds cold backup tarballs. |
| **Dependency risk** | The one native dep is **bcrypt** — installed from a prebuilt aarch64 wheel, fail-closed (never compiles). |
| **Auth boundary** | ⚠️ DAV clients need a **CF Access service-token exemption** — never the interactive gate. |
| **CF tunnel ~100 MB cap** | A non-issue (calendar/contact items are KB-sized). |

## Enabling

```ini
# .env
ENABLE_RADICALE=true
```

Then `./pocket.sh` → Install, and in the Cloudflare dashboard add the public
hostname **and** the service-token exemption for `dav.${DOMAIN}`. To disable: set
`ENABLE_RADICALE=false` and stop the service.

## See also

- [APP_AUTH.md](APP_AUTH.md) — the service-token vs login-gate distinction.
- [ADMIN.md](ADMIN.md) — the `/dav` connect-card in the web admin panel.
- [SECURITY.md](SECURITY.md) — the loopback-only edge model.
- [BACKUPS.md](BACKUPS.md) — backing up the collection tree.
