# Setup guide

> **Status: skeleton.** The ordered path below is stable, but exact commands and
> script names are finalized as the install scripts land (Phase 2). Where a
> concrete command isn't published yet, the step says so.

This guide takes a spare Android phone from nothing to a running Matrix
homeserver reachable at `https://chat.${DOMAIN}`. It is written for someone who
has not done this before; every step says *what* you are doing and *why*.

## Prerequisites

- **A spare Android phone** you can leave plugged in. A mid-range phone with
  ~3 GB RAM and a roomy SD card is plenty. No root required.
- **A domain name** whose DNS you can move to Cloudflare.
- **A free Cloudflare account.**
- **Basic terminal comfort** (copy/paste commands, edit a text file).

## Overview

You will: prepare the phone, install a Linux userland on it, create a Cloudflare
Tunnel, fill in one config file, run the installer, create your admin user, and
verify. In order:

1. Prepare the phone
2. Install Termux + add-ons
3. Install the Debian userland
4. Set up Cloudflare (domain + tunnel)
5. Prepare storage
6. Configure `.env`
7. Install and start the stack
8. Create your admin user
9. Enable the apps you want
10. Verify

## 1. Prepare the phone

The phone must keep running the stack in the background indefinitely, so disable
the power features that would kill it:

- Exempt the terminal app from **battery optimization / Doze**.
- Allow **autostart / background activity** for it (wording varies by vendor).
- Grant **storage access** so it can use the SD card.
- Set a **strong screen lock** and confirm **device encryption** is on.

Keep the phone on a charger. (Vendor skins differ; the goal is simply: never let
the OS "clean up" the terminal app.)

## 2. Install Termux + add-ons

Install [Termux](https://termux.dev) and its add-ons **from F-Droid** (not the
Play Store builds, which are outdated and incompatible):

- **Termux** — the terminal environment.
- **Termux:Boot** — re-launches the stack after a reboot.
- **Termux:API** — lets the watchdog use Android's job scheduler to self-heal.

Then update packages and install git inside Termux.

## 3. Install the Debian userland

The server software runs in a Debian userland provided by `proot-distro` (no root
needed). You'll install `proot-distro`, then a Debian rootfs at `${ROOTFS_DIR}`.

> Exact commands land with the install scripts (Phase 2).

## 4. Set up Cloudflare (domain + tunnel)

1. **Add your domain to Cloudflare** and move its nameservers to the two
   Cloudflare nameservers shown. Wait for the zone to go active.
   *If the domain already serves a live site, export its existing DNS records
   first and re-create anything important before flipping nameservers.*
2. **Create a Tunnel:** Cloudflare dashboard → Zero Trust → Networks → Tunnels →
   Create tunnel → connector "Cloudflared". Copy the **tunnel token** (a long
   `eyJ...` string) — this becomes `CF_TUNNEL_TOKEN`.
3. **Add a public hostname** for the tunnel pointing at the local reverse proxy,
   e.g. `chat.${DOMAIN}` → `http://localhost:${CADDY_PORT}`. One hostname per
   subdomain you expose; the reverse proxy handles path routing.

## 5. Prepare storage

Pick the large volume for bulk data (media, backups, logs). On most phones this
is the SD card, mounted at something like `/storage/XXXX-XXXX`. Set `DATA_DIR` to
a folder on it (e.g. `/storage/XXXX-XXXX/pocket-homeserver`).

## 6. Configure `.env`

Copy the template and fill it in:

```bash
cp .env.example .env
```

The values you must set before first start:

| Variable | What to put |
|---|---|
| `DOMAIN` | your apex domain (DNS on Cloudflare) |
| `DATA_DIR` | folder on your large volume / SD card |
| `CF_TUNNEL_TOKEN` | the tunnel token from step 4 |
| `ADMIN_USER` / `ADMIN_PASSWORD` | the admin panel login (use a strong password) |

Review the rest (timezone, app toggles, backup retention) and leave the
defaults if unsure. `.env` is gitignored — your secrets stay local.

## 7. Install and start the stack

Run the installer from the repo root:

```bash
./scripts/install.sh        # placeholder name — finalized with Phase 2
```

This brings up, in order: the reverse proxy, the tunnel connector, the Matrix
homeserver, the auth gateway, the admin panel, and any apps you enabled — each
under a supervisor that restarts it if it dies.

## 8. Create your admin user

Registration is invite/token-gated, so you mint your own first account as admin.

> Exact command lands with Phase 2; conceptually: mint an invite token, then
> create your account through Element Web using that token. The first user
> becomes the server admin.

## 9. Enable the apps you want

In `.env`, flip the `ENABLE_*` toggles for the apps you want (bookmarks, RSS,
notes, tasks, file sharing, metasearch, status page, webmail), then re-run the
installer. Each enabled app is served on its own subdomain behind the login gate.

## 10. Verify

- Open `https://chat.${DOMAIN}` — Element Web should load and you should be able
  to log in.
- Open the admin panel (`admin.${DOMAIN}`) and confirm services are healthy.
- Confirm the Cloudflare Tunnel shows a healthy connector in the dashboard.

## Reboot survival

Termux:Boot re-runs the bring-up after every reboot, and the watchdog re-runs the
idempotent bring-up every ~15 minutes to recover anything Android kills. You
should not need to babysit the phone.

## Troubleshooting (where to look)

- **Service down?** Check its log and let the supervisor/watchdog respawn it.
- **Site unreachable?** Check the Cloudflare Tunnel connector status first; a
  down connector means the phone-side tunnel isn't running.
- **App returns a login loop or 502?** Check the auth gateway and the reverse
  proxy config for that hostname.

A fuller troubleshooting guide ships with the scripts.
