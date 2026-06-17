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
do the heavy lifting for reliability:

- **Termux:Boot** re-launches the whole stack after a reboot.
- **Termux:API** exposes Android's `JobScheduler`, which the watchdog uses to
  recover from the low-memory killer (see *Supervision* below).

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
toggled with an `ENABLE_*` flag in `.env`. The suite includes bookmarks,
file-sharing, an RSS reader, notes, tasks, a metasearch engine, a status page,
and webmail. Enable only what you want.

### 7. Web admin panel

A small loopback web panel (`admin/`) for health, service control, and
break-glass actions, reached through the tunnel behind authentication.

### 8. Supervision, self-healing, and backups

Termux has no `init`/`systemd`, so each long-running service runs under a tiny
bash supervisor loop that respawns it if it exits. Two layers keep the system up
without human intervention:

- A **watchdog** registered with Android's `JobScheduler` re-runs the
  *idempotent* bring-up script every ~15 minutes. This recovers services (and
  their supervisors) killed by Android's low-memory killer, surviving even a full
  Termux app kill.
- **Termux:Boot** runs the bring-up on every reboot.

Scheduled jobs snapshot the Matrix database and the userland to the large volume
(see *Storage* below), with retention and optional encryption.

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
| Status page | optional app | loopback | `status.${DOMAIN}` |
| Webmail | optional app | loopback | `webmail.${DOMAIN}` |
| Supervisors + watchdog | keep services alive | — | — |
| Backup jobs | scheduled DB + userland snapshots | — | — |

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
- **Database corrupted** → restore from the latest snapshot.
- **Userland gone** → restore the userland snapshot.
- **Phone lost** → restore onto a new phone from the large volume (if it
  survives) or an off-device backup, and re-issue the Cloudflare Tunnel.

Keeping the backup-encryption key **off the device** is what makes the last case
recoverable — see [SECURITY.md](SECURITY.md).
