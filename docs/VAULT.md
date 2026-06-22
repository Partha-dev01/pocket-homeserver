# Vaultwarden — password manager (`vault.${DOMAIN}`)

Vaultwarden is a lightweight, Bitwarden-compatible password-manager server (Rust).
It works with the official Bitwarden apps and browser extensions, so your vault
lives on your phone instead of someone else's cloud. It is **optional and OFF by
default** — enable it with `ENABLE_VAULTWARDEN=true`.

> **Read the supply-chain note below before enabling.** Vaultwarden is the one app
> in this project that does **not** ship a clean upstream binary; we build it from
> the official Docker image. That trade-off is real and is spelled out here.

## How it installs (supply chain — load-bearing)

Vaultwarden publishes **no standalone binary** — its GitHub releases carry only
Docker images. Building from source is **not viable on a phone** (a cargo release
build peaks at ~4–7 GB RAM and would trip the Android Low-Memory-Killer + thermal
throttle). So `scripts/apps/vaultwarden.sh` does what the upstream wiki documents,
but **without a Docker daemon**:

1. It fetches the **official** `vaultwarden/server:<ver>-alpine` image **arm64
   manifest by its pinned `@sha256` digest** from the Docker registry over HTTPS
   (`VAULTWARDEN_MANIFEST_ARM64` in `config/versions.env`). Pinning by digest makes
   the content tamper-evident.
2. It downloads each layer blob and **verifies the blob's sha256 against the
   manifest** (fail-closed), assembles the root filesystem, and extracts the
   `musl`-static `/vaultwarden` binary + the `/web-vault` static assets.
3. It then verifies the **extracted binary** against a sha256 the maintainer
   derived himself (`VAULTWARDEN_BIN_SHA256`) and checks the **web-vault version**
   (`VAULTWARDEN_WEBVAULT_VERSION`) — the web vault is version-locked to the server.

**What this means for trust:** integrity is rooted at the **official image digest**
plus a **self-derived binary hash** — *not* at an upstream-signed binary checksum
like the other apps (dufs, caddy, cloudflared). That is materially weaker, and it
is disclosed honestly here and in the script header. Every upgrade requires
re-pulling the new image, re-extracting, and **re-deriving both the binary sha256
and the matched web-vault version** (see *Upgrades*).

The `musl`-static binary runs fine on the glibc proot-Debian userland (same as
dufs). It is supervised as a single process on loopback `127.0.0.1:9122`; Caddy
fronts the public edge.

## Auth model — service token, NOT the login gate (load-bearing)

The Bitwarden clients (browser extension, desktop, mobile, CLI) speak Vaultwarden's
**native token API** and **cannot** follow an interactive 302-to-login redirect.

So **do not** put `vault.${DOMAIN}` behind the interactive Cloudflare Access login
policy or the Matrix-SSO `forward_auth` gateway — that would break every native
client (only the web vault in a browser would survive). Instead:

- Security is **Vaultwarden's own master password + 2FA**.
- In the Cloudflare dashboard, add a **Service Auth (service-token) exemption** for
  `vault.${DOMAIN}` so the tunnel does not 302 native clients. This repo wires
  nothing for it (operator-side, same pattern as Dufs WebDAV — see
  [APP_AUTH.md](APP_AUTH.md)).

The install ships hardened, fail-closed:

- `ROCKET_ADDRESS=127.0.0.1` (Vaultwarden **defaults to `0.0.0.0`** — the script
  forces loopback and **asserts** it; it refuses to start otherwise).
- `SIGNUPS_ALLOWED=false` — no open registration (asserted). Set **before** first
  exposure.
- `ADMIN_TOKEN` is **unset** → the `/admin` panel is fully **disabled**. If you ever
  enable it, set an **Argon2id PHC hash** from `vaultwarden hash` (never plaintext)
  and keep it behind the service-token boundary.
- `DOMAIN=https://vault.${DOMAIN}` so 2FA/WebAuthn and absolute links work behind
  the proxy. The notifications **WebSocket is served on the main port** (since
  v1.31.0), so a single Caddy `reverse_proxy` line handles it — no `:3012` rule.

### First account

Because `SIGNUPS_ALLOWED=false`, registration is closed. To create your first
account, either temporarily set `SIGNUPS_ALLOWED=true`, register, then set it back;
or configure SMTP (operator-supplied) and invite yourself. Keep it `false` in
normal operation.

## Storage (everything on ext4 — load-bearing)

All vault state lives on **ext4** in the userland at `$HOME/.pocket/vaultwarden`
(bind-mounted to `/opt/vaultwarden/data`), **never** on the exFAT SD card:

- `db.sqlite3` + `db.sqlite3-wal` + `db.sqlite3-shm` — SQLite WAL needs real
  `fsync`, atomic rename, and unix locks; exFAT/FUSE provides none and would
  **corrupt the vault**.
- `rsa_key.*` — the JWT signing keys.
- `attachments/`, `sends/`, `config.json`, `icon_cache/`.

`ENABLE_DB_WAL=true` is set on **every** start (booting once without it reverts the
journal mode). Keeping the data on `$HOME/.pocket` also means it survives a userland
rootfs rebuild.

## Upgrades (deliberate, not a silent re-run)

1. **Back up the DB first** (admin panel → Backups, or `scripts/ops/backup-db.sh`).
   SQLite schema migrations run automatically on first start of a new binary and
   are **one-way** (no downgrade).
2. Pull the new `vaultwarden/server:<newver>-alpine` image, read its **linux/arm64
   manifest digest**, extract the new binary, `sha256sum` it, and note the new
   `web-vault/version.json`. Bump **all four** pins together in
   `config/versions.env` (`VAULTWARDEN_TAG`, `VAULTWARDEN_MANIFEST_ARM64`,
   `VAULTWARDEN_BIN_SHA256`, `VAULTWARDEN_WEBVAULT_VERSION`) — a stale web-vault
   yields a blank/broken UI.
3. Re-run `scripts/install.sh --force` (or just `scripts/apps/vaultwarden.sh`).

## Resource & Risk

| Dimension | Assessment |
|---|---|
| **RAM (idle)** | ~50–90 MB (one Rust process + SQLite) — among the lightest apps in the stack. |
| **RAM (peak)** | ~150–250 MB during sync/import or many concurrent clients. Comfortable on a mid-range phone. |
| **CPU / LMK / thermal** | Negligible at runtime (event-driven daemon). The heavy cost is the **source build, which we deliberately avoid** — the extract path has zero on-device build cost. |
| **Storage** | ~30–40 MB installed (binary + web-vault on ext4). DB grows slowly; attachments are small. |
| **Supply chain** | ⚠️ The genuine trade-off: **no upstream binary checksum**. Trust is rooted at the official image digest + a self-derived binary hash. Re-derive on every bump. |
| **Upgrade fragility** | Medium: re-extract + re-hash binary AND version-matched web-vault each bump; one-way auto-migrations → back up first. |
| **Auth boundary** | ⚠️ Native clients need a **CF Access service-token exemption** — never the interactive gate. |
| **CF tunnel ~100 MB cap** | A non-issue (vault attachments are tiny); documented for completeness. |

## Enabling

```ini
# .env
ENABLE_VAULTWARDEN=true
```

Then `./pocket.sh` → Install (or `scripts/install.sh`), and in the Cloudflare
dashboard add the public hostname **and** the service-token exemption for
`vault.${DOMAIN}`. To disable: set `ENABLE_VAULTWARDEN=false` and stop it
(`scripts/ops/restart.sh` / `start-stack.sh`).

## See also

- [APP_AUTH.md](APP_AUTH.md) — the service-token vs login-gate distinction.
- [SECURITY.md](SECURITY.md) — the loopback-only edge model + the body-size cap.
- [BACKUPS.md](BACKUPS.md) — DB backups (do one before every upgrade).
- [UPDATING.md](UPDATING.md) — version pins + `scripts/ops/update.sh`.
