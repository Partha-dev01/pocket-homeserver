# Changelog

All notable changes to pocket-homeserver are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- **MCP server — hardened secret redaction** (defense-in-depth): the `pocket_logs`
  output and audit redaction now also scrub bare Matrix access/refresh tokens
  (`syt_…` / `syr_…`), PEM private-key blocks, credentials embedded in URLs
  (`scheme://user:pass@host`), and generic `*_TOKEN=` / `*_KEY=` / `*_SECRET=` /
  `*_PASS=` env-style assignments — in addition to the previous auth-header,
  bearer, named-secret, long-hex, and base64 coverage.
- **MCP server — per-caller HTTP rate limiting**: the optional HTTP transport
  keyed its rate limit on the TCP peer, which is always loopback behind Caddy
  (so it was effectively one global bucket). It now keys on the reverse-proxy-set
  client IP (`X-Real-IP` / `Cf-Connecting-IP`, falling back to the peer) so the
  cap is per-caller, and it bounds the limiter's memory under key churn.

### Changed

- **MCP server — docs/behaviour accuracy**: documented that the HTTP transport
  *always* enforces the Cloudflare-Access JWT when a team domain is set (it does
  not honour a `CF_ACCESS_MODE=log` permissive mode); removed the unused
  `CF_ACCESS_MODE` variable. `.env.example`'s `MCP_ALLOWED_LOGS` now matches the
  in-code default (adds `caddy-access.log`, `honeypot.log`, `backup-daemon.log`).
  Marked `docs/MCP_SERVER_SPEC.md` as implemented (shipped in v0.3.0).

## [0.3.0] - 2026-06-20

### Added

- **Optional MCP server** (`ENABLE_MCP`, off by default — advanced) — a
  [Model Context Protocol](https://modelcontextprotocol.io/) adapter so an MCP
  client (Claude Desktop, Claude Code, the claude.ai connector, or any MCP host)
  can observe and operate the stack through a small, audited tool set. It is a
  **thin protocol front door to the already-vetted `scripts/ops/*`** — it adds no
  new privileged operation: every mutating tool is a fixed-argv `subprocess`
  (`shell=False`, no path/command argument; the backing script is allowlisted and
  realpath-contained), a `service` argument is validated against the
  currently-supervised set, and a `log` argument against a fixed allowlist. Built
  on the official `mcp` Python SDK (FastMCP) in its own pinned venv
  (`~/pocket-mcp`), Termux-native. Two transports (`MCP_TRANSPORT`): **stdio over
  SSH** (the recommended default — launched on demand by the client, nothing
  published, the SSH/CF-Access channel is the authentication) and an optional
  **Streamable HTTP** transport on `mcp.${DOMAIN}` that is **fail-closed behind
  three gates** (Caddy `@no_cf_jwt` 403, in-process RS256 Cloudflare-Access JWT
  validation reusing the admin panel's logic, and a `0600` bearer credential
  generated at install and checked with `compare_digest`). Tools are tiered:
  **read** tools are on whenever the server is (status, health, services, redacted
  logs, config, backups, recent honeypot events, Matrix user list, a read-only
  restore-plan describe); the **operate** tier (restart / backup / mint+rotate
  registration token) is behind `MCP_ALLOW_OPERATE`; the **danger** tier (soft/
  hard panic) is behind `MCP_ALLOW_DANGER` **and** a per-call typed confirmation,
  mirroring the admin panel danger zone. Secrets never cross the boundary
  (rotation tools return metadata only; `pocket_logs` is redacted), and every
  `tools/call` is written to the same audit log the admin panel uses. New
  `scripts/steps/87-install-mcp.sh`; see `docs/MCP.md` (how-to) and
  `docs/MCP_SERVER_SPEC.md` (design).

## [0.2.0] - 2026-06-20

Feature-parity release: ports almost all of the private deployment's previously
excluded subsystems into the public repo — every one `ENABLE_*`-gated and **off by
default**, with the operator supplying their own secrets/keys at setup time.

### Added

- **Optional email + webmail** (`ENABLE_EMAIL`, off by default — advanced) — a
  full self-hosted mailbox without a public MX. The [Maddy](https://maddy.email/)
  engine runs in the userland on loopback (IMAP / authenticated inject / outbound
  submission); inbound mail arrives via a **pull pipeline** — a Cloudflare Email
  Worker durably writes each message to R2, and a native stdlib drain
  (`scripts/email/mail-drain.py`, SigV4, ledger-before-inject, content-addressed
  dedupe) pulls and injects it — so SMTP accept never depends on the phone being
  online. Outbound goes through a smarthost (Resend). The UI half is
  [SnappyMail](https://snappymail.eu/) (php-fpm) at `webmail.${DOMAIN}`, pinned to
  your mailbox domain. With the auth gateway on, an in-app **Matrix-SSO** login
  (the `login-matrix-oidc` plugin) signs users in via OIDC and the gateway hands
  back a server-managed per-user IMAP password (`hex(HMAC-SHA256(key, localpart))`,
  returned only over the loopback secret-gated token exchange); new mailboxes are
  JIT-provisioned on first login. You bring your own Cloudflare Email Routing + an
  R2 bucket + a Resend key (secrets in `0600` files, never in `.env` or on argv);
  the installer generates the inject + mailbox passwords and pins Maddy by
  `sha256` (fail-closed until you set it). An optional host-locked SnappyMail admin
  panel (`ENABLE_WEBMAIL_ADMIN`) sits behind Cloudflare Access. New
  `scripts/steps/85-install-email.sh` + `86-install-webmail.sh`; see
  `docs/EMAIL.md` + `docs/WEBMAIL.md`.
- **Optional landing portal** (`ENABLE_LANDING`, off by default) — a clean,
  static service directory served by the core Caddy at your **apex domain**
  (`http://${DOMAIN}`). The page (`scripts/landing/index.html.tmpl`) is rendered
  at install time with **one card per enabled app**, generated from the
  `ENABLE_*` flags + `${DOMAIN}` (Chat always leads) — so it always matches what
  you actually run, with **no bait or decoy content**. No new process: Caddy
  serves the files from inside the userland via an apex
  `/etc/caddy/apps/landing.caddy` drop-in (the install step prints the manual
  apex Cloudflare Tunnel hostname). The portal is public by default; it ships a
  commented `forward_auth` block and an `/authgw/*` proxy so it can be gated
  behind, and show sign-in state from, the optional Matrix-SSO gateway.
  `LANDING_BRAND` (HTML-escaped at render) sets the title. New
  `scripts/steps/84-install-landing.sh`; see `docs/LANDING.md`.
- **Optional operator admin bot** (`ENABLE_ADMINBOT`, off by default) — a
  Termux-native Matrix bot (`scripts/adminbot/bot.py`) that lets **only you**
  drive the stack from a private admin-ops room: `!status`, `!users`,
  `!invite-token`, `!private-list/add/remove`, `!backup-now`, and a confirm-gated
  `!restart-stack`. It obeys exactly one operator MXID (exact match, fail-closed),
  maps each command to a fixed `scripts/ops/*` argv (`subprocess`, no `shell=True`,
  path asserted under `scripts/`), and keeps its token/room/MXID in a `0600`
  `adminbot.env` sourced off-argv. The web admin panel gains a small **admin-bot
  widget** — buttons that POST one allowlisted, read-only `!command` to the ops
  room (destructive ops are excluded). No inbound listener. New
  `scripts/steps/83-install-adminbot.sh`; see `docs/ADMINBOT.md`.
- **Optional sticker picker** (`ENABLE_STICKERS`, off by default) — the
  third-party Maunium stickerpicker widget (AGPL, **fetched at install, not
  vendored**) on its own `stickers.${DOMAIN}` vhost, plus a small Termux-native
  backend (`scripts/sticker/sticker-backend.py`, `127.0.0.1:8451`) that proxies
  media uploads (Element widgets can't upload directly) and an optional Giphy
  search, and an optional DM-import bot. Per-user pack writes are gated by a
  **signed widget-URL identity** (`<mxid>|HMAC-SHA256`, keyed by a generated
  `0600` secret), with a `log`→`enforce` rollout; the signing is byte-identical
  across the backend, the importer, and the install-time openssl registration
  (verified). New `scripts/steps/82-install-stickers.sh`; see `docs/STICKERS.md`.
- **Optional on-phone LLM Matrix bot — exobot** (`ENABLE_EXOBOT`, off by default,
  advanced / BYO). Runs an LLM **on the device** (no cloud, no API key): you supply
  your own llama.cpp `llama-server` build (matching your phone's CPU) + a GGUF
  model, and the bot lazy-loads / idle-unloads it. Fail-closed `EXOBOT_ALLOWED_ROOMS`,
  five interaction modes, and four opt-in engagement daemons (all off). An optional
  Gradio web UI (`EXOBOT_UI`, double-opt-in) is served at `ai.${DOMAIN}` behind a
  lazy-start waker and **must** be protected by Cloudflare Access / the SSO gateway.
  The bot's access token lives in a `0600` `${DATA_DIR}/secrets/exobot.env` sourced
  in-process (never on argv); the installer fail-louds on the BYO binary/model and
  fail-closes until the token is set. New `scripts/steps/81-install-exobot.sh`; see
  `docs/CHATBOTS.md`.
- **Optional cloud-LLM Matrix chat bots** (`ENABLE_CLOUD_BOTS`, off by default) —
  stdlib, Termux-native Matrix `/sync` bots that answer `@`-mentions via any
  OpenAI-compatible endpoint (Groq's free tier, OpenRouter, a local server). No
  inbound listener; loopback to the homeserver + one outbound HTTPS call per
  reply. Run one or more bots, each configured by a `0600`
  `${DATA_DIR}/secrets/cloud-bot-<name>.env` (the install step seeds a template);
  the token + API key stay in that file and are sourced in-process so they never
  reach argv. Fail-closed `ALLOWED_ROOMS`, per-bot RPM/RPD rate limits, a sync
  watchdog, and reasoning-model spoilers. New `scripts/steps/80-install-cloud-bots.sh`;
  see `docs/CHATBOTS.md`.
- **Optional Shizuku network stats in the admin panel.** Android blocks
  `/proc/net/dev` for the Termux app domain, so the panel's network section is
  normally "restricted." If you run [Shizuku](https://shizuku.rikka.app/) and its
  `rish` shell-uid bridge (`~/.shizuku/rish`), the panel now reads per-interface
  RX/TX + live throughput as shell uid and labels it "via Shizuku." Entirely
  optional and best-effort — without Shizuku (the default) it is a no-op, and it
  degrades gracefully when Shizuku's service stops on reboot. See `docs/ADMIN.md`.
- **Optional Matrix bootstrap** (`ENABLE_BOOTSTRAP`, off by default) — idempotent
  helpers (`scripts/bootstrap/*`, run by `scripts/steps/79-install-bootstrap.sh`
  after the stack is up) that seed a fresh server: register/log-in an admin
  account and save a `0600` credentials file; create a hub Space with a few public
  rooms and one private E2EE room; create an admin-only `#announcements` room
  (everyone reads, only the admin posts) and post a one-time welcome; and
  optionally generate + upload avatars (`BOOTSTRAP_AVATARS`, needs Pillow). A
  standalone `mint-invite-token.sh [N]` mints single-use, self-expiring invite
  tokens. The structure (Space/room aliases, names, topics) is an env-driven
  template. The admin password + registration token are read from `0600` files and
  kept off argv; the install hook is fail-soft (warns, never aborts the install).
  See `docs/BOOTSTRAP.md`.
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

[0.3.0]: https://github.com/Partha-dev01/pocket-homeserver/releases/tag/v0.3.0
[0.2.0]: https://github.com/Partha-dev01/pocket-homeserver/releases/tag/v0.2.0
[0.1.0]: https://github.com/Partha-dev01/pocket-homeserver/releases/tag/v0.1.0
