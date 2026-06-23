# AdGuard Home — DoH-over-tunnel resolver (`dns.${DOMAIN}`)

AdGuard Home here is a self-hosted, filtering **DNS-over-HTTPS (DoH)** resolver,
published at `https://dns.${DOMAIN}/dns-query` through the Cloudflare Tunnel. Point a
device's "Private DNS / DoH" setting at that URL and its DNS lookups are resolved and
ad/tracker-filtered by AdGuard Home running on the phone. It also serves a web admin
UI for managing blocklists, viewing the query log, and tuning upstreams. It is
**optional and OFF by default** — enable it with `ENABLE_ADGUARD=true`.

> **Read the scope statement first.** This is a DoH endpoint, **not** a network-wide
> `:53` sinkhole. That is a hard platform limitation, not a config choice.

## Blunt scope — this is NOT a LAN `:53` sinkhole

AdGuard Home here is a **DoH-over-tunnel resolver ONLY**. It **cannot** be the
network-wide ":53 sinkhole" people usually run AdGuard/Pi-hole for:

- **`:53` is a privileged port.** A non-root proot userland cannot bind it.
- **The phone is behind CGNAT and reachable only via the Cloudflare Tunnel, which
  carries HTTP(S) — not raw UDP/53.** Even if something bound `:53` locally, nothing
  outside the phone could reach it over the tunnel.

So there is no "set your router's DNS to the phone" mode. The only thing that works
on this stack is the DoH endpoint, which is exactly what ships. A real network-wide
`:53` sinkhole needs **Tailscale** (an overlay that can carry UDP to a high port on
the phone — see [TAILSCALE.md](TAILSCALE.md)) or a dedicated LAN box.

## How it installs

A single pinned, sha256-verified Go binary (`AdGuardHome_linux_arm64.tar.gz`,
`AGH_VER=0.107.77`, fail-closed `fetch_verified`,
`AGH_SHA256=e095d38e67cd72e0190fbe5f23177c0bdafd35ba83cf387b8147cd70d842b9d2`)
extracted into the userland at `/opt/adguard/AdGuardHome`. No apt package, no Docker.
`apache2-utils` (htpasswd) is installed in the userland **only** to generate the
admin bcrypt hash off-argv. Supervised with `AdGuardHome --no-check-update -c <config>
-w <workdir>` (no phone-home).

## Loopback / 0.0.0.0 / `:53` handling (load-bearing)

proot shares the phone's network namespace, so a wildcard bind would expose the
resolver on the phone's real Wi-Fi/cellular interfaces. Everything is pinned to
loopback and guarded three ways:

- `http.address: 127.0.0.1:9129` — the web UI **and** the plain-HTTP DoH `/dns-query`
  endpoint (see the version note below).
- `dns.bind_hosts: [127.0.0.1]`, `dns.port: 9130` — the internal resolver listener is
  a **high, non-privileged loopback port, never `:53`** (and never `5353`, which
  collides with mDNS on Android).
- **Pre-start config assert**: the rendered yaml is grepped for the exact loopback
  `http.address`, dies on any `0.0.0.0`, and dies if `ADGUARD_DNS_PORT` is `53`.
- **Post-start runtime `ss` audit**: after the service is up, the script enumerates
  TCP + UDP listeners (`ss -ltnH` + `ss -lunH`) and refuses (`unsupervise` + `die`)
  if a **wildcard listener (`0.0.0.0` / `*` / `[::]` / `::`) is bound on either of
  AdGuard's own ports** (`9129`/`9130`). The check is deliberately **scoped to
  AdGuard's ports** — a blanket "die on any wildcard or any `:53`" would false-trip
  on Android's own system listeners, since proot shares the host network namespace.

## Version-critical config note (read on every bump)

`tls.allow_unencrypted_doh` was **removed in v0.107.74**. From v0.107.74 onward (this
pin is v0.107.77), plain-HTTP DoH is enabled with `http.doh.insecure_enabled: true`
and is served on the **same port as `http.address`** (the web-UI port, 9129). There
is therefore **no separate plain-HTTP DoH port** — the UI and `/dns-query` both live
on `127.0.0.1:9129`, and the Caddy exemption proxies `/dns-query` to 9129. The
internal resolver port (`dns.port: 9130`) is unrelated — it is the upstream-facing
listener, not the DoH endpoint. If you bump across the v0.107.74 boundary in either
direction, re-read this note before editing the yaml. The config is seeded with a
complete `users` / `dns` / `schema_version` block so the first-run wizard is
**skipped**. AdGuard **owns** `AdGuardHome.yaml` after first start: the seeded
`schema_version: 28` is auto-migrated forward to the running binary's schema (e.g.
v0.107.77 migrates it to 34) and the yaml is rewritten on first boot — this is
expected and harmless (28 is kept deliberately because AdGuard migrates it forward
correctly; a too-new value with these key shapes could be silently mis-read).

## Auth model + CF Access exemption (load-bearing)

By default `dns.${DOMAIN}` is gated at the Cloudflare edge (Cloudflare Access) and
AdGuard keeps its own admin login (seeded from `ADMIN_USER` / `ADMIN_PASSWORD` as a
bcrypt hash via `htpasswd -niB` over stdin, off-argv). The Caddy vhost
reverse-proxies `/dns-query*` **directly, before the gateable catch-all** (the admin
UI), because DoH clients send a raw DNS wire-format body and **cannot follow a
302-to-login**.

**You MUST add a path-based BYPASS (or service token) for `/dns-query` in your
Cloudflare Access policy** — otherwise DoH clients silently fail while the UI still
works. The optional Matrix-SSO gateway, if uncommented, covers only the admin-UI
handle. This repo wires nothing for the exemption (operator-side — see
[APP_AUTH.md](APP_AUTH.md)).

## Storage (everything on ext4 — load-bearing)

All state — `AdGuardHome.yaml`, the work dir (sessions DB, query log, stats,
downloaded filter lists) — lives on **ext4** at `$HOME/.pocket/adguard`, bind-mounted
to `/opt/adguard/data`. The script **refuses `DATA_DIR` (the exFAT SD) fail-closed**:
those stores need real `fsync` + atomic rename + POSIX locks, which exFAT cannot
provide (the corruption class documented in [RESILIENCE.md](RESILIENCE.md)). A DNS
resolver has no bulk read-mostly data, so nothing is placed on the SD card.

## CGNAT interaction

The phone is on CGNAT; only the Cloudflare Tunnel (HTTP/S) provides inbound
reachability. The tunnel maps `dns.${DOMAIN}` → `http://localhost:${CADDY_PORT}` and
terminates public TLS, so AdGuard speaks plain HTTP internally (hence
`http.doh.insecure_enabled`). Raw UDP/53 DNS cannot traverse the tunnel — which is
precisely why only the DoH endpoint is viable.

## Resource & Risk

| Dimension | Assessment |
|---|---|
| **RAM (idle)** | Tens of MB (a lightweight Go binary). |
| **CPU / thermal** | Negligible — no transcoding/scan workload; far lighter than the media apps or Matrix/conduwuit. |
| **Notable cost** | Periodic blocklist updates + query-log/stats writes; query logging and statistics kept at a conservative 24 h retention. The first blocklist download is a brief one-time spike. |
| **Storage** | Small: config + work dir on ext4; bounded by the 24 h retention. |
| **Scope limit** | ⚠️ **DoH-over-tunnel only — no LAN `:53` sinkhole** (privileged port + UDP can't cross the tunnel). Use Tailscale for a real `:53`. |
| **Auth boundary** | ⚠️ `/dns-query` needs a **CF Access path-exemption / service token** or DNS silently breaks; the UI sits behind the gate. |
| **Upgrade fragility** | Low–medium: re-read the v0.107.74 plain-HTTP-DoH note on any bump across that boundary. |

## Upgrades / re-pin recipe

1. Get the new version's hash from its release `checksums.txt` (or hash a trusted
   tarball: `sha256sum AdGuardHome_linux_arm64.tar.gz`).
2. Bump `AGH_VER` + `AGH_SHA256` **together** in `config/versions.env` (preferred:
   `scripts/ops/update.sh adguard --to <ver> --sha256 <hash> --confirm`).
3. Re-run `scripts/apps/adguard.sh` (or let `update.sh` do it). State on
   `$HOME/.pocket/adguard` persists across upgrades.
4. If crossing the v0.107.74 boundary, verify the plain-HTTP-DoH key in
   `AdGuardHome.yaml` (`http.doh.insecure_enabled` vs the old
   `tls.allow_unencrypted_doh`) before trusting the rendered config.

## Enabling

```ini
# .env
ENABLE_ADGUARD=true
```

Then `./pocket.sh` → Install (or `scripts/install.sh`), and in the Cloudflare
dashboard add the public hostname `dns.${DOMAIN} -> http://localhost:${CADDY_PORT}`
**and** the `/dns-query` path-bypass. To disable: set `ENABLE_ADGUARD=false` and stop
it (`scripts/ops/restart.sh` / `start-stack.sh`).

## See also

- [TAILSCALE.md](TAILSCALE.md) — the overlay you'd need for a real LAN `:53` resolver.
- [APP_AUTH.md](APP_AUTH.md) — the `/dns-query` path-exemption vs login-gate.
- [SECURITY.md](SECURITY.md) — the loopback-only edge model.
- [UPDATING.md](UPDATING.md) — version pins + `scripts/ops/update.sh`.
