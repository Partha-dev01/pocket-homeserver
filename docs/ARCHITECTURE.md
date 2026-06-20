# Architecture

How pocket-homeserver fits together: what runs where, how a request reaches a
service, and why each layer exists. This is the high-level map; per-topic detail
lives in [SECURITY.md](SECURITY.md) and [SETUP.md](SETUP.md).

## Overview

pocket-homeserver runs a Matrix homeserver and a set of optional web apps on a
single Android phone, with **no public IP and no inbound ports**. A Cloudflare
Tunnel, opened *outbound* from the phone, is the only ingress: Cloudflare's edge
terminates TLS and forwards each request through the tunnel to a reverse proxy
(Caddy) that listens **only on loopback**. Everything else — the Matrix server,
the apps, the admin panel — also binds to loopback and is reachable only through
Caddy.

Because the phone never accepts an inbound connection, the design works behind
CGNAT, on mobile data, or on any network, with nothing exposed to scan.

## The layers (bottom-up)

### 1. Android host + Termux

The base is an ordinary Android phone running [Termux](https://termux.dev), a
userspace terminal environment. No root is required or used. Two Termux add-ons
support reliability and are recommended:

- **Termux:Boot** re-launches the whole stack after a reboot. The installer wires
  up the launcher for you (`ENABLE_BOOT`); you just install the addon and open it
  once — see [SETUP.md](SETUP.md).
- **Termux:API** exposes Android's `JobScheduler`, which the installer uses to
  register the self-heal watchdog (see *Supervision* below).

### 2. proot Debian userland

Server software (the reverse proxy, the tunnel connector, the Matrix server)
expects a normal Linux filesystem and POSIX semantics. [`proot-distro`](https://github.com/termux/proot-distro)
provides a Debian userland (`${ROOTFS_DIR}`) where a *fake* root user and a real
`/etc`, `/var`, and package manager exist entirely in userspace — no privilege
needed. The Matrix server's embedded database (RocksDB) in particular needs
POSIX file locks and `fsync`, which the Debian-on-ext4 userland provides.

### 3. Caddy reverse proxy (loopback)

[Caddy](https://caddyserver.com) binds `${CADDY_BIND}:${CADDY_PORT}` (default
`127.0.0.1:8443`) inside the userland. It is the single front door behind the
tunnel:

- routes by hostname / path to each backing service,
- serves the Matrix `.well-known` delegation and the static Element Web client,
- applies security headers,
- and serves the apps over plain HTTP on the loopback (the tunnel terminates
  public TLS), gated at the Cloudflare edge by default — with an optional
  Matrix-SSO `forward_auth` gate available per app (see [APP_AUTH.md](APP_AUTH.md)).

### 4. Cloudflare Tunnel + `cloudflared`

`cloudflared` runs in the userland and holds one outbound tunnel to Cloudflare's
edge. TLS is terminated at the edge; the origin hop is local loopback. The only
secret this layer needs is the tunnel token (`CF_TUNNEL_TOKEN`). There is no DNS
A record pointing at the phone — the tunnel the phone itself opened is the only
path in.

### 5. Matrix homeserver (continuwuity / conduwuit)

A lightweight, memory-safe (Rust) Matrix homeserver with a RocksDB backend,
bound to loopback (default `127.0.0.1:8448`). Federation is **off by default**
(single-server, smallest attack surface); registration is invite/token-gated.

### 6. Optional app suite

Each app is independent, binds loopback, sits behind the auth gate, and is
toggled with an `ENABLE_*` flag in `.env`. The suite is eight apps — bookmarks,
file sharing, an RSS reader, notes, tasks, a metasearch engine, a developer
toolbox, and a status page (the installers live in
[`scripts/apps/`](../scripts/apps/); see [APPS.md](APPS.md)). Enable only what you
want.

### 7. Web admin panel

A small loopback web panel ([`admin/app.py`](../admin/app.py)) for health, service
control, and break-glass actions, reached through the tunnel behind
authentication (see [ADMIN.md](ADMIN.md)).

### 8. Supervision, backups, and resilience

Termux has no `init`/`systemd`, so resilience is layered, and the installer wires
up all three (`ENABLE_BOOT`, default on — [`scripts/steps/75-install-boot.sh`](../scripts/steps/75-install-boot.sh)):

- **Crash-respawn** — each long-running service runs under a tiny bash supervisor
  loop ([`scripts/lib/common.sh`](../scripts/lib/common.sh)) that respawns it
  within seconds if it exits, with an identity-checked pidfile so a reused PID is
  never mistaken for our service.
- **Reboot survival** — a **Termux:Boot** launcher re-runs the *idempotent*
  bring-up ([`start-stack.sh`](../scripts/start-stack.sh)) on boot, restoring the
  core stack and every installed app (after a wake-lock + a stale-pidfile wipe).
- **Watchdog self-heal** — a periodic job (Android's `JobScheduler`, via
  Termux:API) re-runs the same idempotent bring-up (~15 min, persisted) to recover
  any supervisor the low-memory killer reaps, without waiting for a reboot
  ([`scripts/watchdog.sh`](../scripts/watchdog.sh)).

The boot step is fail-soft: without the Termux:Boot / Termux:API addons it still
installs what it can and tells you what to add.

Backups are produced by the [`scripts/ops/`](../scripts/ops/) scripts — run by
hand or from the admin panel — snapshotting the Matrix database and the userland
to the large volume with retention and optional encryption (see
[BACKUPS.md](BACKUPS.md)). The same `ops/` family also covers recovery and
credential hygiene: a dry-run-by-default `restore.sh` rebuilds the userland + DB
from those snapshots, and a set of `rotate-*.sh` scripts rotate the admin
password, registration token, Cloudflare Tunnel token, the auth-gateway RS256
OIDC key, and the optional admin-bot token (see
[RESTORE_AND_ROTATION.md](RESTORE_AND_ROTATION.md)). An optional scheduled backup daemon
([`scripts/ops/backup-daemon.sh`](../scripts/ops/backup-daemon.sh), gated on
`ENABLE_BACKUP_DAEMON`) can run these automatically — the DB weekly and the full
rootfs monthly (UTC) — supervised like any other service.

## Request flow

```
   Matrix / web client (anywhere)
            │  HTTPS
            ▼
   Cloudflare edge        (TLS termination, WAF, anycast)
            │  tunnel — phone-initiated, outbound only
            ▼
   cloudflared            (inside the Debian userland)
            │  local HTTP
            ▼
   Caddy  ${CADDY_BIND}:${CADDY_PORT}      (reverse proxy + auth gate)
            ├── /_matrix/*              → Matrix homeserver (127.0.0.1:8448)
            ├── /.well-known/matrix/*   → inline JSON delegation
            ├── chat.${DOMAIN}          → Element Web (static bundle)
            ├── links./rss./notes. …    → an app, behind the SSO/forward-auth gate
            └── admin.${DOMAIN}         → admin panel (authenticated)
```

The auth gate is enforced at Caddy: requests to a private app are bounced to the
SSO flow unless they carry a valid session, and client-supplied auth headers are
stripped before the gate so they cannot be forged.

## Component inventory

| Component | Role | Binds (loopback) | Example hostname |
|---|---|---|---|
| Matrix homeserver | chat server (RocksDB) | `127.0.0.1:8448` | `matrix.${DOMAIN}` |
| Caddy | reverse proxy (plain-HTTP loopback origin), static files, security headers | `${CADDY_BIND}:${CADDY_PORT}` | the front door |
| cloudflared | Cloudflare Tunnel connector | outbound only | — |
| Element Web | Matrix web client (static) | served by Caddy | `chat.${DOMAIN}` |
| Auth gateway | SSO / forward-auth for private apps | loopback | — |
| Admin panel | health + service control | loopback | `admin.${DOMAIN}` |
| Bookmarks | optional app | loopback | `links.${DOMAIN}` |
| File sharing | optional app | loopback | `share.${DOMAIN}` |
| RSS reader | optional app | loopback | `rss.${DOMAIN}` |
| Notes | optional app | loopback | `notes.${DOMAIN}` |
| Tasks | optional app | loopback | `tasks.${DOMAIN}` |
| Metasearch | optional app | loopback | `search.${DOMAIN}` |
| Developer tools | optional app | loopback | `tools.${DOMAIN}` |
| Status page | optional app | loopback | `status.${DOMAIN}` |
| Honeypot watcher | optional scanner-detection (tails the Caddy log; alert-only) | native, no listener | — |
| Privacy/media filters | optional proxies in front of Matrix (search privacy; media content-type) | `127.0.0.1:8449` / `:8450` | — |
| Matrix bootstrap | optional one-shot seeding (admin + Space/rooms + announcements + invite tokens); Termux-native, loopback CS/admin API | native, no listener | — |
| Cloud chat bots | optional Matrix `/sync` bots answering @-mentions via an OpenAI-compatible API; loopback to Matrix + one outbound LLM call | native, no listener | — |
| On-phone LLM bot (exobot) | optional on-device bot; subprocess-manages a BYO `llama-server`; loopback to Matrix | native + `127.0.0.1:8081` (llama) | — |
| exobot web UI (optional) | optional Gradio UI in the userland + a native lazy-start waker | `127.0.0.1:9114` / `:9116` | `ai.${DOMAIN}` |
| Sticker picker (optional) | Maunium widget (fetched, AGPL) served by Caddy + a native upload/Giphy backend + import bot | `127.0.0.1:8451` | `stickers.${DOMAIN}` |
| Operator admin bot (optional) | operator-only Matrix ops bot; fixed `scripts/ops/*` command table, loopback to Matrix | native, no listener | — |
| Landing portal (optional) | static apex service directory served by Caddy; cards generated from the enabled apps | served by Caddy | `${DOMAIN}` (apex) |
| Maddy mail engine (optional) | self-hosted mailbox; loopback IMAP / inject / submission, outbound via a smarthost | `127.0.0.1:9143/9125/9587` (in proot) | — |
| Mail drain (optional) | native pull loop: fetches inbound mail from R2 (CF Email Worker) and injects it into Maddy | native, no listener | — |
| Webmail (SnappyMail, optional) | php-fpm webmail UI fronted by Caddy; optional Matrix-SSO login plugin | `127.0.0.1:9092` (php-fpm) | `webmail.${DOMAIN}` |
| MCP server (optional) | audited Model Context Protocol adapter over the existing `scripts/ops/*`; stdio over SSH by default + optional HTTP behind CF Access | stdio (no listener) / `127.0.0.1:9120` (HTTP mode) | `mcp.${DOMAIN}` (HTTP mode) |
| Supervisors | respawn crashed services | — | — |
| Boot launcher + watchdog | restart on reboot + revive killed services | — | — |
| Backup scripts | on-demand DB + userland snapshots | — | — |

Exact ports for the apps are assigned by the install scripts; the rule is simply
that **nothing binds anything but loopback** — a `0.0.0.0` listener from any of
these services is a regression, not a feature.

## Storage layout

Storage is split across tiers because a phone's removable storage usually cannot
do everything the database needs:

1. **App / runtime** — Termux's private storage. Small and hot: the admin panel,
   helper scripts, SSH keys.
2. **Userland + database** — the Debian userland (`${ROOTFS_DIR}`) on internal
   ext4. The Matrix database lives here because RocksDB needs POSIX file locks
   and `fsync`, which removable exFAT storage does not provide.
3. **Large volume** (`${DATA_DIR}`, typically an SD card) — bulk and mostly cold:
   uploaded media blobs, backups, pinned binaries, logs, and state markers. It is
   bound into the userland at runtime.

If your phone has ample internal storage you can collapse tiers 2 and 3; the
split exists to keep a small, fast database on POSIX storage while large media
and backups live on a big, cheap volume.

## Why a phone

A retired phone is a low-power, battery-backed, always-on ARM64 computer with
storage and (optionally) a SIM for connectivity. Paired with a Cloudflare Tunnel
for ingress, it serves real HTTPS traffic from anywhere without a static IP — a
cheap, resilient, and genuinely practical way to self-host.

## Disaster recovery (summary)

The system is built to degrade gracefully:

- **Service crashed** → its supervisor respawns it within seconds.
- **Service killed by the low-memory killer** → the JobScheduler watchdog revives
  it on the next tick (~15 min) without a reboot.
- **Phone rebooted** → the Termux:Boot launcher brings the whole stack back up
  after the first unlock.
- **Database corrupted** → restore from the latest snapshot.
- **Userland gone** → restore the userland snapshot.
- **Phone lost** → restore onto a new phone from the large volume (if it
  survives) or an off-device backup, and re-issue the Cloudflare Tunnel.

Keeping the backup-encryption key **off the device** is what makes the last case
recoverable — see [SECURITY.md](SECURITY.md).
