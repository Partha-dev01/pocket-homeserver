# Changelog

All notable changes to pocket-homeserver are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-06-17

First public pre-release. pocket-homeserver turns a spare, unrooted Android phone
into an always-on server — a Matrix homeserver plus a suite of optional
self-hosted web apps — with no root, no public IP, and no hosting bill. It is
productized from a real deployment that has run for ~20 users for months.

### Added

- **Config-driven script framework** — a shared bash library
  (`scripts/lib/common.sh`: logging, `.env` loading + defaults, validation,
  verified downloads, idempotency markers, and a process supervisor that respawns
  crashed services), a single `.env` contract (`.env.example`), a config-template
  renderer, and an ordered, re-runnable orchestrator (`scripts/install.sh`).
- **Core stack** — install + bring-up for the proot Debian userland, the
  Cloudflare Tunnel connector, the Caddy loopback edge, the continuwuity /
  conduwuit Matrix homeserver, and the Element web client.
- **Guided setup wizard** (`setup.sh`) — interviews the operator and writes a
  complete, correctly-quoted `.env` (secrets never echoed, `0600`, existing file
  backed up), then can launch the installer.
- **Eight optional apps**, each on its own subdomain behind the loopback edge:
  Linkding (bookmarks), Pingvin Share (file sharing), FreshRSS (RSS), Memos
  (notes), Vikunja (tasks), SearXNG (metasearch), IT-Tools (dev toolbox), and
  Gatus (status page). All pinned + `sha256`-verified, supervised, idempotent.
- **Optional Matrix-SSO auth gateway** — a small loopback service providing a
  `forward_auth` cookie gate and a dormant-by-default OIDC IdP, for one login
  across the apps using a Matrix username/password.
- **Web admin panel** — a phone-friendly Flask control panel: stack health,
  device stats, logs, per-service restarts, backups, the registration token, and
  a guarded danger zone (scrypt login, signed sessions, CSRF, per-IP lockout, and
  optional Cloudflare Access JWT validation).
- **Operational scripts** (`scripts/ops/`) — database and full-rootfs backups
  with retention rotation and optional `age` encryption; registration-token and
  admin-password rotation; soft/hard panic kill-switches; per-service restart;
  and a status summary.
- **Supply-chain & safety** — every downloaded binary is pinned to an exact
  version and verified against a `sha256` fail-closed; a `leak-scan` pre-push
  guard keeps secrets and deployment-specific data out of the public repo.
- **Documentation** — architecture, security/threat model, a zero-to-running
  setup guide, the optional-apps guide, the app-auth model, the SSO gateway
  runbook, the admin-panel runbook, and the backups/restore guide.

### Known limitations

- **Pre-release.** Interfaces may still change before 1.0.
- The fresh-phone, zero-to-running **end-to-end walkthrough is still being
  hardened** — the scripts are faithfully ported from a working deployment, but a
  clean install on a brand-new phone may hit rough edges. Issues and reports are
  welcome.
- A **scheduled backup daemon** is not included yet (the backup scripts are run
  manually or from the admin panel for now).
- **Reboot survival** (Termux:Boot) and a **watchdog self-heal** are documented
  but not yet bundled as install steps — reboot survival is a short manual step
  for now (see the setup guide), and the watchdog is on the roadmap. The
  per-service supervisor (crash-respawn) does ship.

[0.1.0]: https://github.com/Partha-dev01/pocket-homeserver/releases/tag/v0.1.0
