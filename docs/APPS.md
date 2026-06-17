# Optional apps

Beyond the Matrix homeserver and Element, pocket-homeserver can install a suite
of self-hosted web apps. They are all **optional** and **off by default**. You
turn each one on with its `ENABLE_<APP>` flag in `.env` (the [`setup.sh`](../setup.sh)
wizard asks about each), then run the installer — every enabled app installs its
backend and drops a Caddy vhost, and the edge comes up already aware of it.

```bash
# in .env (or via ./setup.sh)
ENABLE_LINKDING=true
# then:
./scripts/install.sh
```

| App | Hostname | What it is | Served as | Persistent data |
|---|---|---|---|---|
| **Linkding** | `links.${DOMAIN}` | bookmarks | Django + gunicorn | `${DATA_DIR}/linkding` |
| **Pingvin Share** | `share.${DOMAIN}` | file sharing | NestJS API + Next.js UI | `${DATA_DIR}/pingvin` |
| **FreshRSS** | `rss.${DOMAIN}` | RSS / Atom reader | PHP + php-fpm | `${DATA_DIR}/freshrss` |
| **Memos** | `notes.${DOMAIN}` | notes / quick capture | single Go binary | `${DATA_DIR}/memos` |
| **Vikunja** | `tasks.${DOMAIN}` | tasks / kanban / GTD | single Go binary (API+UI) | `${DATA_DIR}/vikunja` |
| **SearXNG** | `search.${DOMAIN}` | private metasearch | Python (Flask) + uWSGI | none (stateless) |
| **IT-Tools** | `tools.${DOMAIN}` | client-side dev toolbox | static site | none (client-side) |
| **Gatus** | `status.${DOMAIN}` | uptime / health dashboard | single Go binary | config only |

## How they all work (the common pattern)

Every app follows the same model, so once you understand one you understand all:

- **Loopback only.** The backend binds `127.0.0.1` (or `${CADDY_BIND}`); it is
  never exposed directly. The core Caddy reverse-proxies the public hostname to
  it, and Cloudflare Tunnel is the only ingress.
- **Self-contained vhost.** Each installer writes `/etc/caddy/apps/<app>.caddy`
  inside the userland (the core Caddyfile imports `/etc/caddy/apps/*.caddy`) and
  runs `caddy validate` fail-closed, so a bad vhost never takes the edge down.
- **Data on the large volume.** Anything that must survive a rootfs rebuild
  (databases, uploads, secrets) lives under `${DATA_DIR}/<app>` and is
  bind-mounted into the userland — so wiping/reinstalling Debian keeps your data.
- **Pinned + verified downloads.** Binaries and source tarballs are pinned to an
  exact version and checked against a `sha256` fail-closed (see
  [SECURITY.md](SECURITY.md)).
- **Supervised + idempotent.** Each long-running app runs under the same
  supervisor as the core stack (restarted on crash, survives reboot), and every
  installer is safe to re-run.

## How they're protected

By default the public hostname is gated at the edge by **Cloudflare Access**, and
apps that have their own login keep it (registration is disabled — you create the
first account, not the public). Optionally you can put the **Matrix-SSO gateway**
in front instead, for one login across all your apps. Both are explained in
**[APP_AUTH.md](APP_AUTH.md)** — each app's vhost ships a commented `forward_auth`
block showing exactly where the gateway hooks in.

---

## Linkding — bookmarks (`links.${DOMAIN}`)

A self-hosted bookmark manager. Built from the pinned upstream git tag into a
Python virtualenv inside the userland and served with gunicorn.

- **Login:** Linkding's own Django login. The installer creates an initial
  superuser from `ADMIN_USER` / `ADMIN_PASSWORD`; public sign-up is off.
- **Data:** `${DATA_DIR}/linkding` (SQLite DB, the Django `SECRET_KEY`, cached
  favicons/previews). The persisted secret key means sessions survive restarts.

## Pingvin Share — file sharing (`share.${DOMAIN}`)

Share files via expiring links. A NestJS backend (`127.0.0.1:8080`) plus a
Next.js frontend (`127.0.0.1:3333`); Caddy fronts both and splits `/api/*` to the
backend.

- **Login:** Pingvin's own accounts; self-registration is off and the hostname is
  additionally gated at the edge.
- **Data:** uploaded files live under `${DATA_DIR}/pingvin/uploads`.
- ⚠ **First run is very slow** — two `npm install`s plus a Next.js and a Nest
  build on a phone can take 15–40+ minutes. It is the heaviest step in the whole
  stack; the build caps the V8 heap so it can't OOM-kill the live stack. Re-runs
  skip the build.
- ⚠ **Loopback-bind hardening:** upstream's backend defaults to `0.0.0.0` (all
  interfaces, i.e. LAN-exposed). The installer patches it to bind loopback,
  fail-closed — keep that patch on upgrades.

## FreshRSS — RSS / Atom reader (`rss.${DOMAIN}`)

A PHP feed reader. The pinned source tarball is installed to `/opt/freshrss` and
served by a dedicated php-fpm pool via Caddy's `php_fastcgi`.

- **Login:** FreshRSS's native form login (`auth_type=form`); open registration
  and anonymous access are off. The installer creates an initial admin from
  `ADMIN_USER` / `ADMIN_PASSWORD` (idempotent) — change the password after first
  login.
- **Data:** `${DATA_DIR}/freshrss` (SQLite DB, config, feed cache). Upgrades keep
  the existing `data/` dir.

## Memos — notes / quick capture (`notes.${DOMAIN}`)

A lightweight note / micro-blog app. A single static Go binary at `/opt/memos`,
supervised on `127.0.0.1:9110`.

- **Login:** Memos' own accounts. ⚠ **Disable open registration** in Memos'
  settings right after you create your first user (it ships registration *on*) —
  see the installer's closing notes.
- **Data:** `${DATA_DIR}/memos` (SQLite DB + uploads); survives a rootfs rebuild.

## Vikunja — tasks / kanban / GTD (`tasks.${DOMAIN}`)

A task manager. The pinned arm64 *"-full"* build bundles the REST API and the Vue
frontend in one binary at `/opt/vikunja`.

- **Login:** Vikunja's native login; registration is off and local login is on,
  so new accounts are created by an admin from inside Vikunja. Service/JWT secrets
  are persisted under `${DATA_DIR}/secrets` so users aren't logged out on restart.
- **Data:** `${DATA_DIR}/vikunja` (SQLite DB + attachments). **Back this up
  before upgrading**, then bump the version + sha256 and re-run.

## SearXNG — private metasearch (`search.${DOMAIN}`)

A privacy-respecting metasearch front-end that queries other engines and returns
aggregated results — it stores no search history and has no user accounts. Built
from source into a venv inside the userland and served via uWSGI.

- **Login:** none of its own — protect the hostname with Cloudflare Access (or the
  SSO gateway) so only your people can use it.
- ⚠ **First run compiles native wheels** (a C toolchain is installed), so it is
  slower than a binary drop-in. Re-runs skip the build.

## IT-Tools — developer toolbox (`tools.${DOMAIN}`)

A large collection of client-side utilities (encoders, converters, generators,
formatters, crypto helpers, …). The prebuilt release is served as a **static
site** by Caddy — there is no backend.

- **Login:** none (it's static). To require a login, gate the whole site with the
  optional Matrix-SSO `forward_auth` block (commented in its vhost) or Cloudflare
  Access.
- The installer self-hosts the figlet fonts so the ASCII-art tool works without a
  third-party CDN (a same-origin correctness fix).

## Gatus — uptime / health dashboard (`status.${DOMAIN}`)

A status page that probes your services and shows their health/history. Built
from source on-device (a pinned Go toolchain compiles the pinned tag), then run in
the userland behind the core Caddy.

- **Login:** the status page has no app-level login by design — decide whether to
  expose it publicly or gate it at the edge.
- ⚠ **First run is slow** — downloading the Go toolchain and compiling on a phone
  can take 10+ minutes. Re-runs skip the build.

---

## Enabling, disabling, and upgrading

- **Enable:** set `ENABLE_<APP>=true` in `.env`, then `./scripts/install.sh`. The
  app installs and its vhost is loaded on the next edge (re)start.
- **Disable:** set the flag to `false`. The installer simply won't (re)install or
  start it; remove its `/etc/caddy/apps/<app>.caddy` and stop its supervisor to
  take the live one down.
- **Upgrade:** bump the app's pinned version **and** its `sha256` in its installer
  (never invent a hash — see [SECURITY.md](SECURITY.md)), **back up its
  `${DATA_DIR}/<app>` data first**, then re-run the installer. Data persists on
  the large volume across the upgrade.

## See also

- [APP_AUTH.md](APP_AUTH.md) — Cloudflare Access vs the optional Matrix-SSO gateway.
- [MATRIX_AUTH_GW.md](MATRIX_AUTH_GW.md) — the single sign-on gateway in depth.
- [ADMIN.md](ADMIN.md) — health, restarts, and logs for every app from the panel.
- [SECURITY.md](SECURITY.md) — the pinning / verification model and threat model.
