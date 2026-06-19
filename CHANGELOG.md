# Changelog

All notable changes to pocket-homeserver are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Scripted restore + credential rotation** (`scripts/ops/`). A real
  `restore.sh` rebuilds the userland rootfs and the conduwuit DB from the
  `backup-all.sh` / `backup-db.sh` snapshots — **dry-run by default** (prints the
  plan; only acts on `--confirm=ERASE-AND-RESTORE`), verifies the `.sha256`
  sidecars fail-closed, rejects zip-slip members, decrypts `.age` archives with
  `BACKUP_AGE_IDENTITY`, and renames the old rootfs aside as a one-`mv` rollback.
  Four new rotation scripts join the existing admin-password / registration-token
  ones: `rotate-tunnel-token.sh` (Cloudflare Tunnel token, read off-argv + atomic
  `0600` `.env` rewrite), `rotate-authgw-rs.sh` (two-phase, kid-overlap RS256 OIDC
  signing-key rotation, gated `ENABLE_AUTH_GATEWAY`), `rotate-adminbot-token.sh`
  (optional Matrix admin-bot token, gated `ENABLE_ADMINBOT`), and `rotate-all.sh`
  (orchestrates them independently). All wired into `./pocket.sh` (a new *Rotate
  credentials* menu + *Restore* in *Backups & restore*); see
  `docs/RESTORE_AND_ROTATION.md`.
- **Optional privacy & media filters** (`ENABLE_USER_FILTER` / `ENABLE_MEDIA_FILTER`,
  both off by default) — two small Termux-native loopback proxies in front of the
  Matrix homeserver. `user-filter` hides chosen MXIDs (listed in
  `${DATA_DIR}/secrets/private-users.txt`, re-read live) from the user-directory
  search; `media-filter` sets a `Content-Type` from magic bytes on media the
  homeserver leaves untyped, so native mobile clients render thumbnails / link
  previews. Both fail open, bind loopback only, and are supervised like the rest
  of the stack. `render-config.sh` weaves the matching Caddy routes into the chat
  vhost **only** when a filter is enabled (a disabled filter is never routed to a
  dead port). New install step `scripts/steps/78-install-filters.sh`; see
  `docs/FILTERS.md`.

## [0.1.2] - 2026-06-19

### Added

- **Scheduled backup daemon** (`scripts/ops/backup-daemon.sh`, opt-in via
  `ENABLE_BACKUP_DAEMON`): a supervised daily-wake loop that snapshots the Matrix
  DB weekly (Sunday, UTC) and the full rootfs monthly (the 1st, UTC), applies
  retention, and can ping an optional heartbeat URL (`BACKUP_DAEMON_HC_URL`).
  Wired into `start-stack.sh`, `./pocket.sh`, the admin panel health list, and
  `docs/BACKUPS.md`.
- **Optional honeypot / scanner-detection** (`ENABLE_HONEYPOT`, default off) — a
  native watcher (`scripts/steps/77-install-honeypot.sh` supervises
  `scripts/honeypot/honeypot-watcher.py`) that tails the Caddy access log, flags
  high-confidence scanner probes (`/.env`, `/.git`, `wp-login.php`, `phpMyAdmin`,
  …) by the real client IP, and writes a JSONL ledger. **No inbound listener, no
  Caddy change — zero new attack surface. Alert-only by default.** The web admin
  panel gains a **Security** console (`/honeypot`): ledger overview, filterable
  hits, per-IP drill-down, passive enrichment (RDAP / reverse-DNS / optional
  offline geo / threat-intel links), an abuse-report draft, and a confirm-gated
  DEFENSIVE write console (Cloudflare IP Access Rules on your OWN edge + a local
  safelist). Matrix alerts and Cloudflare edge blocking are **opt-in** via `0600`
  files under `${DATA_DIR}/secrets` (blocking is triple-gated: mode file + opt-in
  marker + a CF token over-scope self-check). Optional offline geo/ASN enrichment
  via the DB-IP lite datasets. Documented in `docs/HONEYPOT.md`.
- **Harmonized the optional Matrix-SSO `forward_auth` recipe** across all eight
  app vhosts, so enabling the gateway is copy-paste-correct instead of a redirect
  loop.

### Fixed

- Removed the dead `ENABLE_ELEMENT` flag. Element is part of the core stack
  (always installed, baked into the core Caddyfile), but it was declared in
  `.env.example` and prompted for by `setup.sh` as if optional while nothing
  consumed the flag — so disabling it silently did nothing. The wizard no longer
  implies Element is optional.
- The admin panel now has a `freshrss-refresh` restart button and health-proc
  entry, symmetric with `linkding-tasks`.
- Documentation/comment accuracy: clarified that the honeypot watcher's `--reap`
  rule-pruning is not auto-scheduled, and corrected two stale internal references
  (the watcher's install-step name and `ops/restart.sh`'s known-services list).

## [0.1.1] - 2026-06-19

### Added

- **Interactive control panel (`./pocket.sh`)** — a single menu-driven TUI that
  drives the whole lifecycle: configure, install / bring up, status, per-service
  restart, backups, logs, and the panic stop. No flags to remember; each item
  just runs the underlying script. Dependency-free (works in Termux and over SSH).
- **Resumable, status-aware installs** — `scripts/install.sh` now records each
  completed step and skips it on the next run, so re-runs are fast and an
  interrupted install resumes where it stopped. New `--status` (what's installed +
  what's running), `--force` (redo everything), and `--reset` (clear the markers).
  Step markers use filesystem-safe names (the data volume is often exFAT).
- **Reboot survival + self-heal watchdog as an install step**
  (`scripts/steps/75-install-boot.sh`, gated by `ENABLE_BOOT`, default on): a
  **Termux:Boot** launcher that brings the whole stack back up on boot (wake-lock,
  stale-pidfile wipe, idempotent bring-up), and a **JobScheduler** watchdog
  (`scripts/watchdog.sh`, ~15 min, persisted) that revives any service Android's
  low-memory killer takes down. Fail-soft when the Termux:Boot / Termux:API addons
  aren't present yet.

### Changed

- **`scripts/start-stack.sh` now brings the whole stack up**, not just the core:
  it re-supervises every installed app/service from the launch command recorded at
  install time, so one command (or a plain re-run of the installer) restores
  everything after a reboot. Recovery from a hard panic is correspondingly simpler.

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
