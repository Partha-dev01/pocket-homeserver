# pocket-homeserver

> Turn a spare Android phone into a real, always-on server — a full Matrix chat
> homeserver plus a suite of self-hosted web apps — with **no root, no public IP,
> and no monthly hosting bill**.

`pocket-homeserver` is an open playbook and toolkit for running genuine server
workloads on an ordinary, unrooted Android phone. Software runs in Termux on top
of a proot Debian userland; ingress is handled by a Cloudflare Tunnel, so the
whole thing works from behind CGNAT or mobile data — no port-forwarding, no
exposed IP, no static address required.

It is distilled from a real, hardened deployment that has run a Matrix homeserver
for ~20 users alongside 20+ supporting services on a single mid-range phone for
months: automated backups, self-healing supervision that survives reboots, a web
admin panel, and a documented security review.

> **Status: early — scaffolding.** This repository is being productized from that
> working deployment. The layout and roadmap below are the target; content lands
> incrementally and interfaces will change until the first tagged release.

## What it aims to provide

- **The stack** — a Matrix homeserver (continuwuity / conduwuit) behind Caddy,
  plus optional self-hosted apps (bookmarks, file sharing, RSS, notes, tasks,
  metasearch, webmail, a status page, and more) — all bound to loopback behind a
  single Cloudflare Tunnel.
- **Idempotent install scripts** — numbered, re-runnable, predictable bring-up;
  one "start everything" entrypoint; reboot survival via Termux:Boot.
- **A web admin panel** — health, service controls, and break-glass actions,
  reachable from the phone or over an authenticated tunnel.
- **Backups & recovery** — scheduled database / rootfs snapshots, retention, and a
  tested restore path.
- **Docs & findings** — architecture, the threat model and hardening applied,
  known issues, and a zero-to-running setup guide.

## Quickstart

Once the phone is prepared and you've cloned this repo into Termux (see the full
walkthrough in [docs/SETUP.md](docs/SETUP.md)), it comes down to two commands:

```bash
./setup.sh            # guided wizard: answer a few questions, writes your .env
./scripts/install.sh  # bring the whole stack up (the wizard can launch this too)
```

The wizard never echoes your secrets, writes `.env` with `0600` permissions, and
can generate a Matrix registration token so you can create your first user.

## Why a phone?

A retired phone is a low-power, battery-backed, always-on ARM64 computer with
storage and (optionally) a SIM for connectivity. Paired with a Cloudflare Tunnel
for ingress, it can serve real HTTPS traffic from anywhere without a static IP —
a cheap, resilient, and genuinely practical way to self-host.

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — how it all fits together: layers,
  request flow, components, storage.
- [docs/SECURITY.md](docs/SECURITY.md) — threat model, layered defenses, and an
  operator checklist.
- [docs/SETUP.md](docs/SETUP.md) — zero-to-running setup guide (skeleton; firming
  up as the scripts land).
- [docs/APP_AUTH.md](docs/APP_AUTH.md) — how the optional apps are protected:
  Cloudflare Access (default) and the optional Matrix-SSO gateway.
- [docs/ADMIN.md](docs/ADMIN.md) — the web admin panel: health, controls, backups,
  and the guarded danger zone.
- [docs/BACKUPS.md](docs/BACKUPS.md) — snapshot scripts, retention, encryption, and
  the restore path.

## Target layout

```
docs/      architecture, security model, setup guides, findings
scripts/   idempotent install, service, and backup scripts
admin/     the web admin panel
tools/     repo tooling (e.g. the leak-scan pre-push guard)
```

## Roadmap

- [x] Architecture & security documentation
- [x] Config-driven script framework (library, `.env`, renderer, orchestrator)
- [x] Core stack install + bring-up (userland, cloudflared, Caddy, Matrix, Element)
- [x] Optional-app install scripts (bookmarks, RSS, notes, tasks, file sharing,
  metasearch, dev tools, status) + the app-auth model (Cloudflare Access)
- [x] Optional Matrix-SSO auth gateway (advanced, single sign-on)
- [x] Web admin panel (health, controls, backups, danger zone)
- [x] Backups & recovery — DB + rootfs snapshot scripts, retention, restore (a
  scheduled backup daemon is still to come)
- [x] Guided `setup.sh` wizard + zero-to-running setup guide (fresh-phone
  end-to-end walkthrough still being hardened)
- [ ] First tagged release

## Status, license, and contributing

Pre-release and under active construction — expect breaking changes. Licensed
under the [MIT License](LICENSE). Issues and discussion are welcome once the
initial scaffold lands.
