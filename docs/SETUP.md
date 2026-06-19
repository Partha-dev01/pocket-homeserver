# Setup guide

> **Status: maturing.** The install scripts have landed, so the configuration
> and bring-up commands below are concrete. A few phone-side preparation steps
> vary by vendor and are described in general terms.

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

> **The easy way.** From step 6 onward you can do everything from one interactive
> menu: run `./pocket.sh` and pick **Configure**, then **Install**. The same menu
> later handles status, restarts, backups, logs, and stopping the stack. The
> numbered steps below explain what each menu item does under the hood — read them
> once, then drive it from the menu.

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
- **Termux:Boot** — runs a launcher on boot; the installer uses it to bring the
  whole stack back up after a reboot (see [Reboot survival](#reboot-survival)).
- **Termux:API** — provides wake-lock and `termux-job-scheduler`, which the
  installer uses for the self-heal watchdog.

Open **Termux:Boot** once after installing it so Android allows it to run at
boot, and install its package inside Termux later with `pkg install termux-api`.

Then update packages and install git inside Termux.

## 3. Install the Debian userland

The server software runs in a Debian userland provided by `proot-distro` (no root
needed). You don't run this by hand — the installer's first steps
([`scripts/steps/00-prereqs.sh`](../scripts/steps/00-prereqs.sh) and
[`10-install-userland.sh`](../scripts/steps/10-install-userland.sh)) install
`proot-distro` and the Debian rootfs at `${ROOTFS_DIR}` for you in step 7.

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

The easy path — run the interactive menu from the repo root and choose
**Configure** (or run the wizard directly):

```bash
./pocket.sh     # menu → Configure   (or:  ./setup.sh)
```

It asks a handful of questions (domain, storage path, tunnel token, admin login,
which apps to enable), then writes a complete `.env` for you — with `0600`
permissions, your secrets never echoed back, and an existing `.env` backed up
first. It can offer to launch the installer when it finishes, and you can re-run
it any time.

Prefer to do it by hand? Copy the template and edit it instead:

```bash
cp .env.example .env
```

Either way, the values you must set before first start:

| Variable | What to put |
|---|---|
| `DOMAIN` | your apex domain (DNS on Cloudflare) |
| `DATA_DIR` | folder on your large volume / SD card |
| `CF_TUNNEL_TOKEN` | the tunnel token from step 4 |
| `ADMIN_USER` / `ADMIN_PASSWORD` | the admin panel login (use a strong password) |

Review the rest (timezone, app toggles, backup retention) and leave the
defaults if unsure. `.env` is gitignored — your secrets stay local.

## 7. Install and start the stack

From the menu, choose **Install / bring up the stack** — or run the installer
directly (the wizard in step 6 can also launch it for you):

```bash
./scripts/install.sh --check   # preview the ordered plan, change nothing
./scripts/install.sh           # run it
```

This brings up, in order: the reverse proxy, the tunnel connector, the Matrix
homeserver, the auth gateway, the admin panel, and any apps you enabled — each
under a supervisor that restarts it if it dies.

The installer **remembers what's already done**: each completed step is recorded
on your data volume and skipped next time, so re-runs are fast and an interrupted
install resumes where it left off. Run it again any time — it's the same command
that brings the whole stack back up after a reboot. `./scripts/install.sh
--status` shows what's installed and running; `--force` redoes everything (use it
after you change `.env`); `--reset` forgets the markers.

## 8. Create your admin user

Registration is token-gated. If you let the wizard generate a registration token
(step 6), it is already in your `.env`:

```bash
grep MATRIX_REGISTRATION_TOKEN .env
```

Open `https://chat.${DOMAIN}`, choose to create an account on your server, and
supply that token when prompted. The first account you create is the server
admin. You can mint or rotate the token later from the admin panel's danger zone.

## 9. Enable the apps you want

In `.env`, flip the `ENABLE_*` toggles for the apps you want (bookmarks, RSS,
notes, tasks, file sharing, metasearch, a developer toolbox, status page), then
re-run the installer. Each enabled app is served on its own subdomain behind the
login gate — see [APPS.md](APPS.md) for what each one is.

## 10. Verify

- Open `https://chat.${DOMAIN}` — Element Web should load and you should be able
  to log in.
- Open the admin panel (`admin.${DOMAIN}`) and confirm services are healthy.
- Confirm the Cloudflare Tunnel shows a healthy connector in the dashboard.

## Reboot survival

Three layers keep the stack up, all installed for you when `ENABLE_BOOT=true`
(the default), by [`scripts/steps/75-install-boot.sh`](../scripts/steps/75-install-boot.sh):

1. **Per-service supervisor** — while Termux runs, each service runs under a
   supervisor that respawns it if it crashes. (Always on; nothing to configure.)
2. **Termux:Boot launcher** — on a full reboot, `~/.termux/boot/00-pocket-homeserver.sh`
   acquires a wake-lock, clears stale pidfiles, and runs the idempotent
   [`start-stack.sh`](../scripts/start-stack.sh), bringing the whole stack (core +
   every installed app) back up. Needs the **Termux:Boot** addon.
3. **Self-heal watchdog** — [`scripts/watchdog.sh`](../scripts/watchdog.sh) is
   registered with Android's **JobScheduler** (~15 min, persisted), re-running the
   same idempotent bring-up so a service the low-memory killer reaps is revived
   without waiting for a reboot. Needs the **Termux:API** addon +
   `pkg install termux-api`.

The install step is **fail-soft**: if an addon isn't present yet it tells you what
to install and carries on — reboot survival works without the watchdog, and you
can re-run the installer once Termux:API is in place to add it.

> **Android FBE note:** Termux:Boot scripts only run after the *first unlock*
> following a reboot (file-based encryption). That one unlock is the only manual
> step; everything else is automatic. Verify with `termux-job-scheduler --pending`
> (the watchdog job) and `tail -f ${POCKET_LOG_DIR}/watchdog.log`.

## Troubleshooting (where to look)

- **Service down?** Check its log under `${POCKET_LOG_DIR}` and let the supervisor
  respawn it; re-running `./scripts/install.sh` is always safe.
- **Site unreachable?** Check the Cloudflare Tunnel connector status first; a
  down connector means the phone-side tunnel isn't running.
- **App returns a login loop or 502?** Check the auth gateway and the reverse
  proxy config for that hostname.

If something stays down, capture the relevant log lines and open an issue.
