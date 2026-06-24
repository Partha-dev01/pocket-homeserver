# Roadmap

This is the feature ledger for pocket-homeserver: everything that has shipped, and
the short list of what is still planned. The project is **feature-complete as of
v1.0.0**; from here, breaking changes follow [SemVer](https://semver.org).

For the per-release detail (dates, commits, fixes), see the
[CHANGELOG](../CHANGELOG.md).

## Shipped

- Architecture & security documentation
- Config-driven script framework (library, `.env`, renderer, orchestrator)
- Core stack install + bring-up (userland, cloudflared, Caddy, Matrix, Element)
- Optional-app install scripts + the app-auth model (Cloudflare Access)
- Optional Matrix-SSO auth gateway (advanced, single sign-on)
- Web admin panel (health, controls, backups, danger zone)
- Backups & recovery — DB + rootfs snapshots, retention, restore
- Guided `setup.sh` wizard + zero-to-running setup guide
- Interactive control panel (`pocket.sh`) + resumable, status-aware installs
- Platform foundation — a central pinned-version manifest (`config/versions.env`), safe component updates with snapshot + verify-healthy + auto-rollback (`pocket update`), a read-only `doctor` preflight, and CI gates (shellcheck / py_compile / leak-scan / install --check) ([docs/UPDATING.md](docs/UPDATING.md))
- Reboot survival + self-heal watchdog as install steps (Termux:Boot + JobScheduler)
- A scheduled backup daemon (optional; weekly DB + monthly rootfs, auto-pruned)
- Optional honeypot / scanner-detection surface (alert-only; admin Security console)
- Optional privacy & media filters (hide accounts from search; fix media content-type)
- Scripted restore + credential rotation (dry-run restore; rotate tunnel/OIDC/admin-bot keys)
- Optional Matrix bootstrap (admin + hub Space/rooms + announcements + invite tokens)
- Optional cloud-LLM Matrix chat bots (OpenAI-compatible; Groq free tier)
- Optional on-phone LLM bot (advanced / BYO llama.cpp + GGUF; optional web UI)
- Optional sticker picker (Maunium widget + upload/Giphy backend + import bot)
- Optional operator admin bot (operator-only Matrix ops bot + panel widget)
- Optional landing portal (apex service directory; cards generated from enabled apps)
- Optional email + webmail (Maddy + R2-drain pipeline + SnappyMail + Matrix-SSO; advanced/BYO)
- Optional MCP server (official MCP SDK; stdio over SSH + optional HTTP behind CF Access; read/operate/danger tiers)
- Observability — metrics sampler + admin sparklines / 24h health strip / problems view + crash-loop alerts
- Off-device encrypted backup (push age-ciphertext to any S3-compatible bucket)
- Matrix user management in the panel (list/create/reset/suspend/deactivate + invite tokens)
- Personal cloud — files & sync (Dufs + WebDAV / FileBrowser accounts / Syncthing P2P; [docs/FILES.md](docs/FILES.md))
- Productivity & security apps — Vaultwarden (password manager) / Radicale (CalDAV/CardDAV + QR connect-card) / Trilium (notes/wiki) / Wallabag (read-later) ([docs/VAULT.md](docs/VAULT.md) · [docs/DAV.md](docs/DAV.md) · [docs/NOTES.md](docs/NOTES.md) · [docs/READLATER.md](docs/READLATER.md))
- Media apps — Navidrome (music/Subsonic) / Kavita (comics/ebooks) / Audiobookshelf (audiobooks/podcasts); Jellyfin docs-only ([docs/MEDIA.md](docs/MEDIA.md))
- Platform & networking — Forgejo (git forge) / AdGuard Home (DoH resolver) / BYO reverse-proxy / Tailscale (userspace mesh VPN) ([docs/FORGEJO.md](docs/FORGEJO.md) · [docs/ADGUARD.md](docs/ADGUARD.md) · [docs/PROXY_ROUTES.md](docs/PROXY_ROUTES.md) · [docs/TAILSCALE.md](docs/TAILSCALE.md))
- In-panel app catalog (enable + install modules from the browser) + optional fail2ban-style rate-jail on the honeypot ([docs/ADMIN.md](docs/ADMIN.md) · [docs/HONEYPOT.md](docs/HONEYPOT.md))
- **v1.0.0 — first stable release** — full pre-1.0 security + correctness audit, a universal post-start loopback backstop on every Go/Node/Rust listener, and a re-verification of every pinned artifact against upstream

## Planned / under consideration

- Photo gallery — on the roadmap (the candidate's Go server hardcodes a `0.0.0.0` bind that can't be safely forced to loopback on this stack; see [docs/MEDIA.md](docs/MEDIA.md))
