# pocket-homeserver

> Turn a spare Android phone into a real, always-on server — a full Matrix chat
> homeserver plus a suite of self-hosted web apps — with **no root, no public IP,
> and no monthly hosting bill**.

`pocket-homeserver` is an open toolkit and playbook for running genuine server
workloads on an ordinary, unrooted Android phone. Everything runs in Termux on a
proot Debian userland; a Cloudflare Tunnel handles ingress, so it works from
behind CGNAT or mobile data with no port-forwarding, no exposed IP, and no static
address. It is productized from a real, hardened deployment that ran a Matrix
homeserver for ~20 users — alongside a stack of supporting apps — on a single
mid-range phone for months.

> **Status: v0.1.0 — pre-release.** All the pieces below have landed. Interfaces
> may still change before 1.0, and the fresh-phone, zero-to-running walkthrough is
> still being hardened — expect some rough edges. See the [changelog](CHANGELOG.md).

## Quickstart

Prepare the phone and clone this repo into Termux (the full walkthrough is in
[docs/SETUP.md](docs/SETUP.md)), then run one command:

```bash
./pocket.sh
```

That opens an interactive menu that drives the whole thing — configure, install,
check status, restart a service, take backups, read logs, and stop the stack.
First run, pick **Configure** (it writes your `.env`), then **Install**. That's it.

Prefer the command line? The menu just runs these, and you can too:

```bash
./setup.sh            # guided wizard → writes a complete, 0600 .env
./scripts/install.sh  # bring the whole stack up (resumable + idempotent)
```

The wizard never echoes your secrets, and it can generate a Matrix registration
token so you can create your first user.

## The control panel (`./pocket.sh`)

A plain text menu — no extra packages, works over SSH and in Termux as-is. Each
item runs a script you could run by hand, so nothing is hidden:

| Menu item | What it does | Underlying command |
|---|---|---|
| **Configure / reconfigure** | guided setup, writes `.env` | `./setup.sh` |
| **Install / bring up the stack** | install + start everything (resumes) | `scripts/install.sh` |
| **Re-run everything (force)** | redo every install step | `scripts/install.sh --force` |
| **Status** | what's installed and what's running | `scripts/install.sh --status` |
| **Restart a service** | restart one service | `scripts/ops/restart.sh <svc>` |
| **Backups** | DB / full snapshots, retention, listing | `scripts/ops/backup-*.sh` |
| **View logs** | tail any service log | — |
| **Stop / panic** | cut public access, or stop everything | `scripts/ops/panic-*.sh` |

## Run it again, any time

The installer **remembers what's already done.** Each step that finishes is
recorded with a marker on your data volume, so:

- **Re-runs are quick** — completed steps are skipped (config rendering and the
  stack bring-up always run, so things actually come up).
- **An interrupted install resumes** exactly where it stopped.
- **One command restores everything** — `scripts/install.sh` (or the menu's
  *Install*) re-supervises the core stack and every installed app, so after a
  reboot you just run it again and the whole stack comes back.
- `scripts/install.sh --status` shows it all; `--force` redoes everything;
  `--reset` forgets the markers. Changed your domain or an app's settings in
  `.env`? Re-run with **force** so the install steps pick it up.

## What you get

- **A Matrix homeserver** (continuwuity / conduwuit) behind Caddy, with the
  Element web client — federation and open registration off by default.
- **Eight optional apps**, each on its own subdomain, all loopback-bound behind
  the single tunnel: bookmarks (Linkding), file sharing (Pingvin Share), RSS
  (FreshRSS), notes (Memos), tasks (Vikunja), metasearch (SearXNG), a developer
  toolbox (IT-Tools), and a status page (Gatus). See [docs/APPS.md](docs/APPS.md).
- **A web admin panel** — health, stats, logs, per-service restarts, backups, and
  a guarded danger zone, reachable over the tunnel. See [docs/ADMIN.md](docs/ADMIN.md).
- **Backups & recovery** — database and full-rootfs snapshot scripts with
  retention, optional `age` encryption, and a documented restore path. See
  [docs/BACKUPS.md](docs/BACKUPS.md).
- **A process supervisor** that respawns crashed services (identity-checked
  pidfiles), and **pinned + `sha256`-verified** downloads throughout.

## How it works

```
 internet → Cloudflare edge → (mutually-authenticated tunnel) → cloudflared
          → Caddy (loopback HTTP edge) → Matrix / the apps (all on 127.0.0.1)
```

The phone never opens an inbound port; it only dials out to Cloudflare, which
terminates public TLS and forwards to a local Caddy that fronts every service on
loopback. Full detail in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Why a phone?

A retired phone is a low-power, battery-backed, always-on ARM64 computer with
storage and (optionally) a SIM. Paired with a Cloudflare Tunnel, it serves real
HTTPS traffic from anywhere without a static IP — a cheap, resilient, genuinely
practical way to self-host.

## Documentation

- [docs/SETUP.md](docs/SETUP.md) — zero-to-running setup guide.
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — layers, request flow, components, storage.
- [docs/SECURITY.md](docs/SECURITY.md) — threat model, layered defenses, operator checklist.
- [docs/APPS.md](docs/APPS.md) — the optional apps: what each is, where its data lives, how to enable/upgrade.
- [docs/APP_AUTH.md](docs/APP_AUTH.md) — how apps are protected: Cloudflare Access (default) and the optional Matrix-SSO gateway.
- [docs/ADMIN.md](docs/ADMIN.md) — the web admin panel.
- [docs/BACKUPS.md](docs/BACKUPS.md) — snapshots, retention, encryption, restore.
- [docs/MATRIX_AUTH_GW.md](docs/MATRIX_AUTH_GW.md) — the optional single sign-on gateway in depth.

## Repository layout

```
pocket.sh    the interactive control panel (start here)
setup.sh     the guided config wizard (writes .env)
.env.example the single config file, documented
scripts/     idempotent install, service, and ops scripts
admin/       the web admin panel
docs/        architecture, security, setup, and per-subsystem guides
tools/       repo tooling (e.g. the leak-scan pre-push guard)
```

## Roadmap

- [x] Architecture & security documentation
- [x] Config-driven script framework (library, `.env`, renderer, orchestrator)
- [x] Core stack install + bring-up (userland, cloudflared, Caddy, Matrix, Element)
- [x] Optional-app install scripts + the app-auth model (Cloudflare Access)
- [x] Optional Matrix-SSO auth gateway (advanced, single sign-on)
- [x] Web admin panel (health, controls, backups, danger zone)
- [x] Backups & recovery — DB + rootfs snapshots, retention, restore
- [x] Guided `setup.sh` wizard + zero-to-running setup guide
- [x] Interactive control panel (`pocket.sh`) + resumable, status-aware installs
- [x] First tagged release (v0.1.0)
- [ ] Reboot-survival as an install step — a Termux:Boot launcher and a
  `JobScheduler` watchdog (manual boot setup is documented for now)
- [ ] A scheduled backup daemon (snapshots run on demand / from the panel today)

## Status, license, and contributing

Pre-release (v0.1.0) and under active construction — expect breaking changes.
Licensed under the [MIT License](LICENSE). Issues, bug reports, and discussion are
welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). Because the repo is public, every
change is scanned for secrets and deployment-specific data by
[`tools/leak-scan.sh`](tools/leak-scan.sh) before it lands.
