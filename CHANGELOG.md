# Changelog

All notable changes to pocket-homeserver are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0-pre2] - 2026-07-18

Second staged prerelease of the v1.1.0 "Pocket Pages" line (M2 of 4: the
admin-panel UI + the synced landing portal; the MCP tools and the deploy
integrations follow in pre3/pre4).

### Added
- **Admin panel Sites section** (`/sites`, when `ENABLE_SITES`) — deploy,
  inspect, roll back and delete Pocket Pages sites from the browser: drag-drop
  zip uploads (streamed to disk with a hard cap; CSRF via header + admin
  password re-auth), a live SSE deploy-log tail with polling fallback, per-site
  cards with release history + one-click rollback, async health pills, QR share
  of the live URL, a danger-zone-style 3-stage delete, and registry-rebuild /
  vhost-reapply maintenance buttons. Spec: `docs/specs/SPEC-SITES-PANEL.md`.
- **Landing portal ↔ Pocket Pages sync** — the landing page now shows a
  "your sites" card grid generated from the sites registry, refreshed
  automatically on every deploy/delete via a new render-only
  `scripts/landing/regen-landing.sh` (the hook `site-deploy.sh` shipped with;
  `site-delete.sh` now calls it too). The installer delegates its page render
  to the same script — one render code path. Registry names are re-validated
  against the DNS-label pattern before they can reach the (public) page.
- **Landing portal teal re-theme** — the portal now uses the admin panel's
  dark teal palette verbatim (hex-for-hex from `admin/app.py`'s dark tokens),
  so the public page and the panel read as one product. Spec:
  `docs/specs/SPEC-LANDING-SYNC.md`.
- **`SITES_SPA_MODE`** — optional global fallback-to-`/index.html` for
  client-side routers across all deployed sites (`try_files` siblings in the
  one wildcard vhost; the dotfile 403 guard is preserved — an existing dotfile
  still 403s). Off by default; docs: `docs/SITES.md`.

### Changed
- **Admin panel gunicorn worker timeout 60 s → 180 s** — a legitimate near-cap
  (`SITES_MAX_UPLOAD_MB`) upload over the Cloudflare Tunnel can take longer
  than the old 60 s worker-silence limit. Off-tunnel uploads (`ssh -L`, local
  Wi-Fi) are meaningfully faster — see `docs/SITES.md`.

### Fixed
- **Panel-wide request-body ceiling (pre-auth DoS)** — the admin panel never
  set Flask's `MAX_CONTENT_LENGTH`, so Werkzeug would buffer an arbitrarily
  large form body into memory before any view code ran — including an
  **unauthenticated** POST to `/login` on a RAM-constrained phone. A global
  ceiling (sized off `SITES_MAX_UPLOAD_MB` + headroom) now backstops every
  route; the upload route additionally enforces its own precise cap
  mid-stream.
- **Landing brand rendering with special characters** — a `LANDING_BRAND`
  containing `&` (e.g. `"A & B"`) was corrupted by the render's awk `gsub`
  replacement-string expansion; the brand is now escaped for both HTML and
  `gsub` before substitution.
- **Landing vhost dotfile guard depth** — the apex portal vhost's dotfile
  matcher only covered root-level dotfiles (`/.*`); it now also blocks them at
  any depth (`*/.*`), matching the sites wildcard vhost. (Defensive: the
  portal root only ever contains repo-generated files.)

## [1.1.0-pre1] - 2026-07-17

First staged prerelease of the v1.1.0 "Pocket Pages" line (M1 of 4: the
pipeline + serving layer; the admin-panel UI, landing sync, MCP tools and the
deploy integrations follow in pre2–pre4).

### Added
- **Pocket Pages (`ENABLE_SITES`)** — Netlify-like static-site hosting on the phone:
  zip/dir deploys through one hardened pipeline (`scripts/sites/`) into immutable
  per-site release trees, published by an atomic symlink swap and served at
  `<site>.${DOMAIN}` by a single wildcard Caddy vhost (deploys never touch Caddy
  config). Instant rollback, retention GC, hardlink-deduped directory redeploys,
  DNS-label + reserved-name validation, zip-slip/zip-bomb-hardened extraction,
  and optional lazily-installed on-phone build tiers (pinned Hugo; Node with a
  global build lock, RAM ceiling and timebox). Spec: `docs/specs/SPEC-SITES-PIPELINE.md`;
  docs: `docs/SITES.md`.
- **First unit-test suite (`tests/`)** — pytest coverage for the extraction
  guards, name validation, atomic swap/rollback, registry and job state; new CI
  gate runs it on every push.

### Fixed
- **Fresh installs on a Debian trixie userland no longer abort at the Caddy
  step.** Trixie's main repo ships caddy 2.6.2, which predates the
  `servers > trusted_proxies` option used by the rendered Caddyfile — apt
  "succeeded" and `caddy validate` then failed, killing the install.
  `30-install-caddy.sh` now enforces a version floor (2.6.3) and escalates to
  the official Cloudsmith caddy repo when the Debian-packaged caddy is missing
  *or* too old. (Found by the arm64 end-to-end harness; bookworm userlands were
  never affected — bookworm has no caddy in main, so they always took the
  Cloudsmith path.)

## [1.0.0] - 2026-06-24

First stable release. pocket-homeserver installs a complete, opt-in personal cloud on
a single unrooted Android phone — Matrix chat, a Cloudflare-tunnelled Caddy edge, and
~30 optional services (files & sync, productivity, calendar & passwords, media, a git
forge, DNS-over-HTTPS, a mesh VPN, and more). Every web service is loopback-bound
behind the tunnel, every embedded database lives on ext4, every module is **OFF by
default**, and every pinned artifact is sha256-verified fail-closed. See the v0.4.0 →
v0.9.1 entries below for the full feature history; this release closes the pre-1.0
audit's remaining coverage gaps. From here, breaking changes follow SemVer.

Readiness work in this release: defence-in-depth on the network binds, a
re-verification of every pinned artifact, and an honest accounting of the one
build-from-fork dependency.

### Security
- The post-start `ss` wildcard backstop — which refuses to leave a service listening on
  a non-loopback address even if its config/env assert is somehow bypassed — now covers
  **every** Go/Node/Rust web listener, not just Forgejo + AdGuard: Navidrome, Vikunja,
  Kavita, Trilium, Audiobookshelf, Pingvin, Gatus, the Syncthing GUI, Vaultwarden, and
  Dufs. This closes the raw-`SYS_BIND` class (the reason Photoview was dropped) for the
  whole stack. The check is a shared, port-scoped `assert_loopback_listener` helper in
  `scripts/lib/common.sh` (Syncthing audits only its loopback GUI port, never its
  intentional P2P sync port); Forgejo's inline copy was refactored onto it.

### Changed
- Pinned-artifact provenance, re-verified for 1.0: all 16 sha256-pinned downloads were
  re-checked against current upstream bytes (published checksums where available —
  Go, memos, filebrowser, syncthing, navidrome, kavita, forgejo, tailscale, adguard,
  trilium — and a fresh download-and-hash for the self-computed ones). Every pin matches.
- The Pingvin install note now states the real reason it builds from
  `smp46/pingvin-share-x`: canonical upstream `stonith404/pingvin-share` is **archived**
  (the author moved to Pocket ID and pointed users at maintained forks), and that fork is
  the active successor. Audited at the pinned tag (`v1.19.0`): no npm pre/post-install
  lifecycle hooks in either `package.json`, stock NestJS/Next dependencies, and the
  `app.listen()` shape the loopback patch targets is intact.

## [0.9.1] - 2026-06-23

Hardening pass from the pre-1.0 multi-agent audit (security + correctness across the
whole tree). All changes are backward-compatible; the SQLite relocation auto-migrates.

### Security
- No cleartext-secret leak path on the public repo: `.gitignore` now also ignores
  `.env.bak*` / `.env.tmp*` (the timestamped + atomic copies `setup.sh` writes), and
  `tools/leak-scan.sh` gained a JWT-shaped backstop pattern.
- The MCP HTTP transport binds loopback only (`127.0.0.1`) with a fail-closed assert —
  it no longer inherits `CADDY_BIND`.
- Admin-panel log redaction now also scrubs S3/R2/SMTP credentials (read from the 0600
  `secrets/*.env` sibling files) and is applied to the `/action` + `/confirm` command
  output, not just `/logs`.
- Kavita + Audiobookshelf: the optional Matrix-SSO `forward_auth` block moved inside the
  catch-all `handle {}` so it can never be hoisted ahead of the OPDS / token-API exemption.
- Syncthing GUI and Vikunja API listeners gained fail-closed loopback asserts.
- Every ext4-vs-exFAT storage guard now resolves the full real path (a symlinked leaf can
  no longer smuggle a SQLite DB onto the exFAT SD).

### Changed
- SQLite databases for Linkding, Memos, Vikunja, and FreshRSS moved to ext4
  (`$HOME/.pocket/<app>`) — exFAT cannot do POSIX locks / atomic rename / durable fsync,
  which corrupts SQLite. An existing data dir on the SD is auto-migrated once (backed up
  first; the original is left in place to remove after verifying).
- `exobot` pins `gradio` to a known version instead of `--upgrade`.
- The metrics sampler now defaults OFF in `setup.sh`, like every other optional module.

### Fixed
- Admin panel: Dufs / FileBrowser / Syncthing now appear in the health + restart wiring,
  the Tailscale restart button resolves, and the restart-button row lists the v0.6–v0.9 apps.

## [0.9.0] - 2026-06-23

Platform leverage & networking. A git forge, a DNS-over-HTTPS resolver, a bring-your-own
reverse-proxy, a userspace mesh VPN, an in-panel app catalog, and an optional
fail2ban-style rate-jail on the honeypot — all opt-in (`ENABLE_*` / `RATE_JAIL_MODE`,
off by default), loopback-bound where they front a service, keeping any
database/index/state on **ext4** (`$HOME/.pocket/<app>`). Two of these speak
native/non-browser protocols and need a Cloudflare Access **service token / path
exemption** rather than the interactive login (git-over-HTTPS, DoH); Tailscale is a
different trust boundary entirely — tailnet traffic bypasses the Cloudflare edge, so the
**tailnet ACL** is its only network gate.

### Added

- **Forgejo** (`ENABLE_FORGEJO`) — a single-binary git forge (repos / issues / PRs /
  releases / package & LFS registry) on `git.${DOMAIN}` (`scripts/apps/forgejo.sh`). A
  sha256-pinned static Go binary from Codeberg. Forces `HTTP_ADDR=127.0.0.1` with a
  config assert **and** a post-start `ss` wildcard check; runs as an unprivileged
  `forgejo` user (it refuses root); `DISABLE_SSH=true`, `DISABLE_REGISTRATION=true`,
  Actions disabled, `INSTALL_LOCK=true`; SQLite WAL + repos on ext4 (refuses the exFAT
  SD); first admin + `SECRET_KEY`/`INTERNAL_TOKEN` generated off-argv to a `0600` file.
  git-over-HTTPS / `/api/v1` / LFS need a CF Access service-token exemption. See
  [docs/FORGEJO.md](docs/FORGEJO.md).
- **AdGuard Home** (`ENABLE_ADGUARD`) — a filtering **DNS-over-HTTPS** resolver on
  `dns.${DOMAIN}` (`scripts/apps/adguard.sh`), sha256-pinned. UI + plain-HTTP DoH
  (`/dns-query`) on `127.0.0.1:9129` (`http.doh.insecure_enabled`, post-v0.107.74); the
  internal resolver on a high loopback port `9130` (never `:53`/`5353`). Config assert +
  a post-start `ss` audit **scoped to AdGuard's own ports**. **Not a LAN `:53` sinkhole**
  — a privileged port a non-root proot can't bind and UDP can't cross the CGNAT tunnel;
  `/dns-query` needs a CF Access path bypass. See [docs/ADGUARD.md](docs/ADGUARD.md).
- **BYO reverse-proxy** (`ENABLE_PROXY_ROUTES`, `PROXY_ROUTES`) — publishes any loopback
  service you already run on its own subdomain (`scripts/apps/proxy-routes.sh`), no
  binary. Parses `sub=127.0.0.1:port` entries into per-route `byo-<sub>.caddy` vhosts;
  **fail-closed loopback-target gate** (only `127.0.0.1`/`::1`/`localhost`), strict
  DNS-label + port regex (injection guard), explicit hostname-collision check, an
  **authoritative stale-route sweep** (a dropped route's vhost is removed on the next
  run), and a single fail-closed `caddy validate`. See
  [docs/PROXY_ROUTES.md](docs/PROXY_ROUTES.md).
- **Tailscale** (`ENABLE_TAILSCALE`) — a sha256-pinned **userspace** mesh VPN
  (`scripts/steps/90-install-tailscale.sh`) that sidesteps CGNAT with no public
  hostname. `--tun=userspace-networking` (no root, no TUN); SOCKS5 + outbound HTTP proxy
  on a loopback-asserted `127.0.0.1:1055`; node key/state on ext4 (refuses the SD); auth
  key off-argv via `--auth-key file:`; `GOMEMLIMIT` cap; fail-closed if no key. ⚠️ The
  tailnet **bypasses** Cloudflare Access + the tunnel — the tailnet ACL is the only
  network gate. See [docs/TAILSCALE.md](docs/TAILSCALE.md).
- **App catalog / module manager** (`ENABLE_APP_CATALOG`) — an optional admin-panel page
  (`/catalog`) to enable + install a module from the browser. Fail-closed: a **fixed
  in-code allow-list** (request value never reaches argv), **password re-auth** + CSRF on
  every install, an `ENABLE_*`-only atomic `0600` `.env` writer, **detached** installs,
  and **secret redaction at the single `/logs` chokepoint** (install scripts load the
  full `.env`). Data deletion stays CLI-only. See [docs/ADMIN.md](docs/ADMIN.md).
- **Honeypot rate-jail** (`RATE_JAIL_MODE`, default `off`) — a fail2ban-style
  **auth-failure-burst** detector added to the honeypot watcher (not a new daemon/
  listener). Counts only `401`/`403`/`429` responses per IP in a sliding window; `alert`
  ledgers + posts a Matrix alert, `enforce` additionally applies a managed-challenge via
  the **same triple-gated** `cf_block` path (so it safely degrades to alert-only without
  the blocking opt-in). Safelist-honoured, bounded per-IP tracking. See
  [docs/HONEYPOT.md](docs/HONEYPOT.md).
- Central pins for Forgejo / Tailscale / AdGuard in `config/versions.env`; `setup.sh`
  "Platform & networking" prompts (incl. a repeatable `PROXY_ROUTES` helper);
  `.env.example`, `scripts/install.sh`, `scripts/ops/restart.sh`, the admin panel
  (ENABLE dict + health rows + per-service restart + `apply-proxy-routes`), and
  `docs/APPS.md` / `docs/APP_AUTH.md` updated.

## [0.8.0] - 2026-06-23

Media tier. Three optional, self-hosted media servers — music, comics/ebooks, and
audiobooks — all opt-in (`ENABLE_*`, off by default), loopback-bound, keeping their
database/index/cache on **ext4** (`$HOME/.pocket/<app>`) while the bulk **library** may
live on the exFAT SD. **Direct-play by default** (no on-the-fly transcoding — the
phone has no usable hardware transcode path; software transcode is the thermal/LMK
heavy path and stays opt-in). Subsonic / OPDS / mobile API paths are reverse-proxied
ahead of the optional auth gate and get a Cloudflare Access **path exemption** (or
service token), since those clients can't complete the interactive login.

A photo gallery was scoped for this tier but is **deferred to the roadmap**: the
candidate (Photoview) ships only a Go server that hardcodes a `0.0.0.0` bind, and no
userland mechanism available on this stack (proot on unrooted Android) can safely force
it to loopback — Go issues `bind()` as a raw syscall that an `LD_PRELOAD` shim cannot
intercept, and `ptrace`/user-namespace/seccomp-notify rewriting is unavailable or
unvalidatable here. See [docs/MEDIA.md](docs/MEDIA.md) for the full rationale.

### Added

- **Navidrome** (`ENABLE_NAVIDROME`) — a music-streaming server with its own web
  player and a Subsonic-compatible API on `music.${DOMAIN}` (`scripts/apps/navidrome.sh`).
  A single static Go binary, sha256-pinned. Forces `ND_ADDRESS=127.0.0.1` (Navidrome
  defaults to `0.0.0.0`) and asserts it; DB + cache on ext4, the music library on the
  SD. The vhost reverse-proxies `/rest/*` (Subsonic) and `/share/*` ahead of the
  optional gate. See [docs/MEDIA.md](docs/MEDIA.md).
- **Kavita** (`ENABLE_KAVITA`) — a manga/comic/ebook server on `books.${DOMAIN}`
  (`scripts/apps/kavita.sh`). A self-contained .NET arm64 build (sha256-pinned, needs
  system `libicu72`). **Pre-seeds** `appsettings.json` with `IpAddresses=127.0.0.1`
  before first start (Kavita defaults to `0.0.0.0,::`) and asserts it; the JWT
  `TokenKey` is generated off-argv. OPDS (`/api/opds/*`) is exempted from the gate.
- **Audiobookshelf** (`ENABLE_AUDIOBOOKSHELF`) — an audiobook/podcast server on
  `audiobooks.${DOMAIN}` (`scripts/apps/audiobookshelf.sh`), **built from source** from
  a pinned git tag (no arm64 release binary; first build is 15–40+ min, like Pingvin).
  Forces `HOST=127.0.0.1` and asserts it; pins the native `ffmpeg` + nunicode SQLite
  extension (`SKIP_BINARIES_CHECK=1`, no first-boot auto-download). The mobile-app API
  paths are exempted from the gate.
- **docs/MEDIA.md** — the three media apps with a per-app **Resource & Risk** section,
  the storage-tier and direct-play rules, the per-app Cloudflare Access exemptions, a
  **photo-gallery roadmap note** (the loopback-bind blocker above), and an honest
  **"why Jellyfin is docs-only"** note (no hardware transcode on a phone; the CF tunnel
  is the wrong pipe for video) with a manual escape hatch.
- Central pins for all three in `config/versions.env`; `setup.sh` prompts (with library
  paths); `.env.example`, `scripts/install.sh`, the admin panel (health rows +
  per-service restart), and `docs/APPS.md` / `docs/APP_AUTH.md` updated.

## [0.7.0] - 2026-06-22

Productivity & security apps. A Bitwarden-compatible password manager, calendar +
contacts (CalDAV/CardDAV), a notes/wiki, and a read-later service — all opt-in
(`ENABLE_*`, off by default), loopback-bound, and keeping their database/index on
**ext4** (`$HOME/.pocket/<app>`), never on the exFAT SD. Clients that speak native
or token auth (Bitwarden apps, CalDAV/CardDAV, the Wallabag API, Trilium's ETAPI/sync)
use a Cloudflare Access **service-token exemption**, not the interactive login gate.

### Added

- **Vaultwarden** (`ENABLE_VAULTWARDEN`) — a Bitwarden-compatible password-manager
  server on `vault.${DOMAIN}` (`scripts/apps/vaultwarden.sh`). Upstream ships **no
  standalone binary**, only Docker images, and a source build is infeasible on a
  phone — so the installer **daemonlessly extracts** the `musl`-static binary +
  version-locked web-vault from the **official** `vaultwarden/server:<ver>-alpine`
  image, pinned by its **arm64 image-manifest digest** (each layer blob is
  sha256-verified against the manifest), then verifies the **extracted binary**
  against a self-derived sha256 (fail-closed). Hardened: `ROCKET_ADDRESS=127.0.0.1`
  (asserted; default is `0.0.0.0`), `SIGNUPS_ALLOWED=false` (asserted), `ADMIN_TOKEN`
  unset (the `/admin` panel disabled), `ENABLE_DB_WAL=true`. The notifications
  WebSocket rides the main port (one `reverse_proxy` line, no `:3012`). DB + WAL +
  JWT keys on ext4. See [docs/VAULT.md](docs/VAULT.md) for the supply-chain trade-off.
- **Radicale** (`ENABLE_RADICALE`) — a CalDAV/CardDAV/tasks server on `dav.${DOMAIN}`
  (`scripts/apps/radicale.sh`). Installed into a Python venv on ext4; **bcrypt is
  installed from a prebuilt aarch64 wheel only** (`--only-binary`, fail-closed — it
  can never compile Rust on the phone). `hosts` forced to `127.0.0.1:5232` and
  asserted; bcrypt `htpasswd` seeded off-argv; `rights = owner_only`. The vhost is
  **root-mounted** so Radicale's built-in `/.well-known/caldav|carddav` discovery
  works, with `flush_interval -1` for streaming `REPORT`s. The collection root is
  **forced to ext4** (the install refuses an SD path — exFAT lacks the
  rename/locks/mtime/perms DAV needs). See [docs/DAV.md](docs/DAV.md).
- **Radicale "connect device" card** in the web admin panel (`/dav`) — renders the
  CalDAV/CardDAV base URL plus a scannable QR (pure-Python `segno`) for DAVx5 /
  Thunderbird / iOS onboarding. **The QR carries only the public URL + username,
  never the password.**
- **Trilium Notes** (`ENABLE_TRILIUM`) — a hierarchical notes/wiki app on
  `wiki.${DOMAIN}` (`scripts/apps/trilium.sh`), from the **official first-party arm64
  SERVER tarball** (bundled Node + a prebuilt `better-sqlite3` — **no node-gyp**),
  sha256-pinned. Forces `TRILIUM_NETWORK_HOST=127.0.0.1` (asserted; default is
  `0.0.0.0`) and runs a **GLIBCXX boot-smoke** (loads `better-sqlite3` up front, fails
  closed on an old `libstdc++`). `document.db` on ext4. Native login ON by default
  (`TRILIUM_NOAUTH=false`); enable `noAuthentication` only behind the SSO gateway.
  See [docs/NOTES.md](docs/NOTES.md).
- **Wallabag** (`ENABLE_WALLABAG`) — a read-later / article saver on `read.${DOMAIN}`
  (`scripts/apps/wallabag.sh`), from the **official bundled tarball** (ships
  `vendor/` — **no composer** on the phone), reusing php-fpm (+ `php-tidy`,
  `php-bcmath`). SQLite on ext4; open registration off; the admin password is fed
  **on stdin** (off-argv). Upgrades **back up the SQLite DB before** running doctrine
  migrations and always `cache:clear --env=prod`. Upstream ships only an MD5, so the
  repo pins its **own computed sha256** fail-closed. See [docs/READLATER.md](docs/READLATER.md).
- **`config/versions.env`** gains the four pins (Wallabag/Trilium sha256, Radicale
  version, and the Vaultwarden tag + arm64 manifest digest + extracted-binary sha256
  + web-vault version).
- **Docs**: `docs/VAULT.md`, `docs/DAV.md`, `docs/NOTES.md`, `docs/READLATER.md`
  (each with a prominent **Resource & Risk** section); `docs/APP_AUTH.md`,
  `docs/APPS.md`, and `README.md` updated for the new apps and the service-token
  auth boundary.

### Changed

- The web admin panel shows health rows + restart buttons for the four new apps
  (and surfaces a `calendar` nav tab when Radicale is enabled). `setup.sh`,
  `install.sh`, `.env.example`, and `ops/restart.sh` learn the new `ENABLE_*` apps.

## [0.6.0] - 2026-06-22

Personal cloud — files & sync. Serve your own files from the phone and sync them
peer-to-peer. Every module is opt-in (`ENABLE_*`, off by default), loopback-bound,
and keeps its secrets in 0600 files (or Syncthing's own config), never in `.env`.

### Added

- **Dufs** (`ENABLE_DUFS`) — a tiny stateless Rust file server (browser UI +
  WebDAV) on `files.${DOMAIN}` (`scripts/apps/dufs.sh`). **Read-only by default.**
  It pins the binary by sha256, forces the listener to `127.0.0.1` (dufs defaults
  to `0.0.0.0`) and **asserts the loopback bind fail-closed** after rendering its
  config, generates a per-deploy HTTP Basic credential (the `$6$` hash goes in the
  0600 config; cleartext only in `${DATA_DIR}/secrets/dufs.env`, never on argv).
- **FileBrowser** (`ENABLE_FILEBROWSER`) — the classic v2 web file manager
  (multi-user accounts + share links, no WebDAV) on `files.${DOMAIN}`
  (`scripts/apps/filebrowser.sh`). Its **BoltDB is pinned to ext4** (never the
  exFAT SD), and the admin is **seeded deterministically** from `.env`
  `ADMIN_USER`/`ADMIN_PASSWORD` off-argv (a pre-hashed bcrypt import) — no
  print-a-random-password-once lockout trap.
- **Mutually exclusive on `files.${DOMAIN}`** — Dufs and FileBrowser share the
  hostname, so enabling both **dies fail-closed**; `./setup.sh` keeps Dufs and
  disables the other if you pick both.
- **Syncthing** (`ENABLE_SYNCTHING`) — peer-to-peer folder sync
  (`scripts/steps/89-install-syncthing.sh`). It **sidesteps the Cloudflare tunnel
  entirely** (so the ~100 MB body cap is irrelevant — the large-data path); its web
  GUI stays **loopback-only** (no public vhost; reach it via
  `ssh -L 8384:127.0.0.1:8384`). The `HOME` (config + cert + **SQLite index DB**)
  is forced to ext4 with a fail-closed assert against an SD path, and a random GUI
  password is set off-argv (`syncthing generate` reads it from stdin, never on the
  command line).
- **`docs/FILES.md`** — the files & sync guide, including the mandated **why-not-
  Nextcloud / why-no-SMB** rationale, the Dufs-vs-FileBrowser chooser, the
  Cloudflare Tunnel **~100 MB upload cap** + workarounds, the WebDAV service-token
  recipe, the ext4-vs-exFAT storage split, the Quantum-fork note, and a Resource &
  Risk section. Cross-linked from `docs/SECURITY.md` (the edge body cap) and
  `docs/APP_AUTH.md` (non-browser clients need a service token).
- Version pins for all three in `config/versions.env` (`DUFS_*`, `FILEBROWSER_*`,
  `SYNCTHING_*`), each sha256-verified fail-closed.

### Fixed

- **`config/versions.env` now actually ships.** The central version/checksum
  manifest (added in 0.4.0) was caught by the `*.env` line in `.gitignore` and was
  never committed, so a fresh clone had no manifest for `common.sh`, `ops/update.sh`,
  `ops/doctor.sh`, and `docs/UPDATING.md` to operate on (installs still worked via
  each step's inline `${VAR:-default}` fallback). It is now un-ignored and tracked —
  public version pins + sha256s only, no secrets.

## [0.5.0] - 2026-06-22

Reliability & ops: see your phone's health over time, get told when something
breaks, get backups off the device, and manage Matrix users from the panel. Every
piece is opt-in (`ENABLE_*`, off by default) and adds no inbound surface.

### Added

- **Observability** — an optional supervised metrics sampler
  (`scripts/ops/metrics-sampler.py`, `ENABLE_METRICS`) records CPU / memory / swap /
  load / disk / temperature / battery + the DEGRADED count once a minute into a
  capped JSONL ring on **ext4**. The admin panel gains a **`/metrics`** page
  (inline-SVG sparklines + a 24h health strip), a DEGRADED-aware **`/problems`**
  view with a loud dashboard banner + nav badge, a **run doctor** button, and a
  **filter + line-count** on the log viewer. See `docs/OBSERVABILITY.md`.
- **Crash-loop alerts** — `./setup.sh` now wires `POCKET_ALERT_CMD` (none / ntfy /
  healthchecks / Matrix). The Matrix channel ships `scripts/ops/alert-matrix.sh`,
  which reads its token from a 0600 file (never `.env`).
- **Off-device encrypted backup** (`ENABLE_OFFSITE_BACKUP`) — push the
  age-**encrypted** archives to any S3-compatible bucket (R2 / B2 / S3 / Wasabi /
  MinIO) via a tiny dependency-free SigV4 client (`scripts/ops/offsite-s3.py` +
  `offsite-push.sh`); no `rclone`/`aws`/`boto3` to install. It **refuses to upload
  plaintext**, mirrors local retention, and is wired into the backup daemon, the
  panel, and `./pocket.sh`. See `docs/BACKUPS.md`.
- **Matrix user management** (`ENABLE_USER_ADMIN`) — a panel **`/users`** page and
  `scripts/ops/user-*.sh` (list / create / reset-password / suspend / unsuspend /
  deactivate / invite) driven through continuwuity's admin command room
  (`scripts/lib/matrix_admin.py`). Each write op needs CSRF + a password re-auth +
  audit; deactivation needs a typed confirm. See `docs/USERS.md`.

### Fixed

- The admin panel launcher (`steps/70-install-admin.sh`) now exports **all** the
  `ENABLE_*` flags (and `MCP_TRANSPORT`) the panel reads — previously the
  cloud-bots / exobot / stickers / adminbot / email / mcp / filter health rows and
  the admin-bot widget never appeared even when those modules were enabled.

## [0.4.0] - 2026-06-22

### Added

- **Central version manifest** `config/versions.env` — every fetched/built
  component's pinned version + `sha256` in one place, sourced by `load_env` after
  `.env` (your `.env` still overrides; each step keeps an inline fallback). Replaces
  ~20 scattered "hand-edit two lines and re-hash" pins.
- **Safe updates** `scripts/ops/update.sh` — **dry-run by default**; on `--confirm`
  it backs up the manifest, snapshots the DB for Matrix, re-runs the install step
  (sha256-verified fail-closed), restarts, watches the service, and **rolls back
  automatically** if it crash-loops. `--list` shows every pin + tier; tier-aware
  (binary / source / app / static / schema). See `docs/UPDATING.md`.
- **Diagnostics** `scripts/ops/doctor.sh` — read-only preflight / self-test:
  required config, exFAT-vs-ext4 storage tiers, the proot userland, Termux:Boot/API
  addons, duplicate ports, loopback reachability, and crash-loop (`DEGRADED`)
  markers. Never prints secret values. Runs advisory at the end of `install.sh` and
  from `./pocket.sh`.
- **Continuous integration** `.github/workflows/ci.yml` — ShellCheck (error level),
  Python `py_compile`, a **blocking `leak-scan` gate**, and an `install --check`
  plan smoke on every push and pull request.
- **Repo governance** — `SECURITY.md` (private vulnerability reporting + the
  security model), GitHub issue forms, a PR checklist, and a versioning / release
  policy in `CONTRIBUTING.md`.
- `./pocket.sh` gains **Update components** and **Doctor / diagnostics** menu items.

### Changed

- Component version pins moved out of the individual install steps into
  `config/versions.env` (the steps' inline `${VAR:-default}` stays as a last-resort
  fallback if the manifest is ever absent).

### Fixed

- `scripts/install.sh --check` now exits `0` on success — it previously inherited a
  non-zero status from its final conditional, which would have failed the CI smoke
  gate on a green run.

## [0.3.3] - 2026-06-22

### Added

- **Crash-loop resilience for every supervised service.** `supervise()` in
  `scripts/lib/common.sh` now respawns with exponential backoff
  (`POCKET_RESPAWN_MIN`..`POCKET_RESPAWN_MAX`, default 5s..300s) instead of a
  fixed 5s, treats a child that stays up `>= POCKET_HEALTHY_SECS` (default 60s) as
  healthy (resets backoff), and after `POCKET_CRASHLOOP_FAILS` (default 5) rapid
  failures raises a machine-readable **DEGRADED** marker and fires an optional
  one-shot alert. A corrupt-DB crash loop can no longer silently hammer storage
  for hours unnoticed.
- **Crash-loop alerting hook** `POCKET_ALERT_CMD` (optional, off by default): a
  shell command run once when any service goes DEGRADED, with
  `$POCKET_ALERT_SERVICE` / `$POCKET_ALERT_RC` / `$POCKET_ALERT_FAILS` in the
  environment (never on argv). Wire it to healthchecks.io, ntfy, Matrix, etc.
- **DEGRADED visibility in the admin panel + `/health`.** Crash-looping services
  show an amber pulsing dot and a "crash-looping" badge instead of flapping green;
  the Matrix row adds a "DB may be corrupt; run `scripts/ops/restore.sh`" hint.
  The marker auto-clears on a healthy run or a manual restart.
- **Configurable Matrix-DB backup cadence** `BACKUP_DB_CADENCE`
  (`daily`|`weekly`|`monthly`), now defaulting to **daily** so an unclean-kill DB
  corruption costs at most ~1 day of data (the DB tar is small; the heavy rootfs
  stays monthly).
- **`docs/RESILIENCE.md`** — the failure modes (unclean-kill RocksDB corruption,
  silent crash loops), what the stack does automatically, alerting setup, and
  recovery via `ops/restore.sh`. Plus an OFF-by-default, documented
  `rocksdb_recovery_mode` block in `config/conduwuit.toml.tmpl`.

## [0.3.2] - 2026-06-20

### Fixed

- **First-user creation now actually works.** The setup wizard wrote a
  `MATRIX_REGISTRATION_TOKEN` to `.env` that nothing consumed (registration is
  baked closed in the homeserver config), and `docs/SETUP.md` told you to register
  with that dead token. Removed the inert `MATRIX_ALLOW_REGISTRATION` /
  `MATRIX_REGISTRATION_TOKEN` / `MATRIX_ALLOW_FEDERATION` vars and rewrote the
  first-user flow around `scripts/ops/rotate-registration-token.sh` (which opens
  token-gated signup and prints a working token) in the wizard and SETUP.md.
- **Landing portal install no longer aborts.** `84-install-landing.sh` only
  substituted `__LANDING_ROOT__`, leaving literal `${DOMAIN}`/`${CADDY_PORT}`/
  `${CADDY_BIND}` in the rendered vhost (the heredoc can't re-expand them) →
  `caddy validate` failed. The renderer now substitutes all of them, and the
  auth-gateway port is templated (`__AUTHGW_PORT__`) instead of hardcoded.
- **Operator admin bot regains its env-dependent commands.** Its launcher sourced
  only the secrets file, so `DATA_DIR`/`POCKET_LOG_DIR`/`MATRIX_SERVER_NAME` were
  empty and `!invite-token`/`!private-list` plus the audit log silently failed.
  The launcher now exports them (matching the exobot launcher).
- **Honeypot SQLite no longer lands on the exFAT SD card** (where its own code
  warns WAL/locking misbehaves). The watcher now points `HP_DB` at an internal
  ext4 path under `$HOME/.pocket` (overridable via `POCKET_HONEYPOT_DB`).
- **Email install no longer 404s on the Maddy download** — the arch string is now
  `aarch64` (upstream's name for arm64), not `arm64`.
- **Setup wizard completeness**: it now prompts for the honeypot and the
  scheduled-backup daemon (previously enableable only by hand-editing `.env`),
  warns that SearXNG / IT-Tools / Gatus have no built-in login and must sit behind
  Cloudflare Access, and writes the full `MCP_ALLOWED_LOGS` list (fixes a drift
  introduced in 0.3.1).
- **No-auth backends are pinned to loopback.** FreshRSS and SnappyMail php-fpm
  pools (and their Caddy upstreams/probes) now bind `127.0.0.1` explicitly instead
  of following `CADDY_BIND`, so they cannot be exposed on the LAN if a user sets
  `CADDY_BIND=0.0.0.0`.
- **exobot UI** is no longer force-supervised on every bring-up (it is managed
  on-demand by the waker), restoring its lazy-start / idle-stop behaviour.

### Changed

- **Docs**: `docs/SETUP.md` now walks through creating one Cloudflare Tunnel
  public hostname per exposed service and protecting them with Cloudflare Access,
  and includes the literal `pkg install git` / `git clone` first steps;
  `docs/SECURITY.md` reflects the shipped (optional) honeypot and email backend;
  `docs/ARCHITECTURE.md` corrects the Matrix hostname to `chat.${DOMAIN}`; the
  README docs index and `scripts/README.md` are refreshed. Added
  `ADMINWEB_SECURE_COOKIE` to `.env.example`.

## [0.3.1] - 2026-06-20

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

[1.0.0]: https://github.com/Partha-dev01/pocket-homeserver/releases/tag/v1.0.0
[0.9.1]: https://github.com/Partha-dev01/pocket-homeserver/releases/tag/v0.9.1
[0.9.0]: https://github.com/Partha-dev01/pocket-homeserver/releases/tag/v0.9.0
[0.8.0]: https://github.com/Partha-dev01/pocket-homeserver/releases/tag/v0.8.0
[0.7.0]: https://github.com/Partha-dev01/pocket-homeserver/releases/tag/v0.7.0
[0.6.0]: https://github.com/Partha-dev01/pocket-homeserver/releases/tag/v0.6.0
[0.5.0]: https://github.com/Partha-dev01/pocket-homeserver/releases/tag/v0.5.0
[0.4.0]: https://github.com/Partha-dev01/pocket-homeserver/releases/tag/v0.4.0
[0.3.3]: https://github.com/Partha-dev01/pocket-homeserver/releases/tag/v0.3.3
[0.3.2]: https://github.com/Partha-dev01/pocket-homeserver/releases/tag/v0.3.2
[0.3.1]: https://github.com/Partha-dev01/pocket-homeserver/releases/tag/v0.3.1
[0.3.0]: https://github.com/Partha-dev01/pocket-homeserver/releases/tag/v0.3.0
[0.2.0]: https://github.com/Partha-dev01/pocket-homeserver/releases/tag/v0.2.0
[0.1.0]: https://github.com/Partha-dev01/pocket-homeserver/releases/tag/v0.1.0
