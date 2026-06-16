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

## Why a phone?

A retired phone is a low-power, battery-backed, always-on ARM64 computer with
storage and (optionally) a SIM for connectivity. Paired with a Cloudflare Tunnel
for ingress, it can serve real HTTPS traffic from anywhere without a static IP —
a cheap, resilient, and genuinely practical way to self-host.

## Target layout

```
docs/      architecture, security model, setup guides, findings
scripts/   idempotent install, service, and backup scripts
admin/     the web admin panel
```

## Roadmap

- [ ] Generalize the install scripts from the reference deployment
- [ ] Ship the web admin panel
- [ ] Zero-to-running setup guide for a fresh phone
- [ ] Architecture & security documentation
- [ ] First tagged release

## Status, license, and contributing

Pre-release and under active construction — expect breaking changes. A license
will be chosen before the first public release. Issues and discussion are welcome
once the initial scaffold lands.
