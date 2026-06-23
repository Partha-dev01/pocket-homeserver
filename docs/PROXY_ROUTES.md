# BYO reverse proxy (`PROXY_ROUTES`)

An operator-defined, **loopback-only Caddy vhost generator**. It lets you publish a
service you are already running on `127.0.0.1:PORT` inside the Debian userland on its
own subdomain — without writing a dedicated app script. It is the escape hatch for "I
have my own little daemon and want it behind the tunnel like the built-in apps." It
is **optional and OFF by default** — enable it with `ENABLE_PROXY_ROUTES=true`.

## How it installs

**Nothing in the package sense** — there is **no binary to download, no version to
pin, no data, and no secrets**. `scripts/apps/proxy-routes.sh` reads `PROXY_ROUTES`
from `.env`, validates each entry, and writes one Caddy site file per route to
`/etc/caddy/apps/byo-<sub>.caddy` inside the userland. The core Caddyfile already
`import`s `/etc/caddy/apps/*.caddy`, so enabling a route never requires hand-editing
the core config.

## Input format

`PROXY_ROUTES` is a whitespace/newline-separated list of `sub=HOST:PORT` entries,
e.g. `PROXY_ROUTES="grafana=127.0.0.1:3000 uptime=localhost:3001"`. Each becomes
`sub.${DOMAIN}` fronted by the loopback Caddy edge (`http://sub.${DOMAIN}:${CADDY_PORT}`
with `bind ${CADDY_BIND}`), exactly like every shipped app vhost.

## The loopback / off-loopback gate (load-bearing security)

Before writing anything, the generator **REFUSES** — fail-closed, with `die()` — any
route whose target host is not exactly `127.0.0.1` or `::1`. The convenience alias
`localhost` is normalized to `127.0.0.1` and accepted; everything else (a LAN
address, a public IP, a hostname) is rejected. This is deliberate: pointing a public
Cloudflare hostname at an off-loopback address would turn your tunnel into an open
forward-proxy out of your network/account.

The generated `reverse_proxy` upstream is therefore *always* a validated loopback
target, and the listener is the existing `127.0.0.1` Caddy edge — so this module can
never emit a wildcard or off-loopback bind. The subdomain is additionally validated
against a strict DNS-label regex and the port against 1..65535, so a hostile entry
cannot inject Caddyfile directives into the generated block.

## Collision handling

A route's `sub.${DOMAIN}` may not collide with a built-in/reserved hostname (`chat
admin files music books audiobooks read dav wiki vault links share rss notes tasks
search tools status stickers webmail ai mcp git dns`), nor with a site address
already declared by another `/etc/caddy/apps/*.caddy` file, nor with a second route
in the same `PROXY_ROUTES`; any clash dies before writing. Duplicate detection is
done explicitly (an internal reservation set + a grep of existing site addresses),
**not** by relying on `caddy validate`. If the generated port matches a known
internal service port (e.g. 9000 adminweb, 9095 auth-gw, 9120 mcp, 9123 navidrome,
9124 kavita, 9127 audiobookshelf, 9128 forgejo, 8448 matrix, 8443 caddy) it only
**warns** — that is usually a typo about to publish a hostname straight onto an
internal service.

## Removing a route (auto-swept — load-bearing)

To remove a route, **delete its entry from `PROXY_ROUTES` and re-run**. The generator
rewrites the live routes and then runs an **authoritative stale-route sweep**: any
`byo-*.caddy` file in the userland that is **not** in the current `PROXY_ROUTES` is
removed automatically (the sweep touches only the `byo-*` namespace — never another
app's vhost), so a dropped route stops being published with no hand-deletion. If the
stack is already up, reload the edge with `bash scripts/start-stack.sh --restart` for
the change to go live. Setting `PROXY_ROUTES` empty and re-running sweeps **all** BYO
routes away.

## Storage tier

None. No DB/index/WAL/lock/cache/state of any kind. The only files written are the
`byo-<sub>.caddy` site blocks in the userland (ext4). `DATA_DIR` (the exFAT SD) is
never touched.

## Auth model + CF Access

By default each generated vhost is gated only at the Cloudflare edge (a Cloudflare
Access application/policy you add in the dashboard — not wired by this script), and
the proxied backend keeps its own auth. The standard 3-part Matrix-SSO `forward_auth`
block is written **commented out** in each file for opt-in. A backend that speaks a
token / non-browser API (and so cannot follow a 302-to-login) must **not** be put
behind `forward_auth`; give that hostname a Cloudflare Access **service-token**
exemption instead — the same caveat documented for Vaultwarden/Radicale/Forgejo (see
[APP_AUTH.md](APP_AUTH.md)).

## CGNAT interaction

Identical to every other app: ingress is CGNAT → Cloudflare Tunnel →
`http://localhost:${CADDY_PORT}` (the loopback Caddy edge) → the loopback backend.
You must add each subdomain as a Public Hostname in your Cloudflare Tunnel
(`sub.${DOMAIN} -> http://localhost:${CADDY_PORT}`) and an Access policy in the
dashboard. The tunnel's ~100 MB single-request body cap applies to whatever you proxy.

## Resource & Risk

| Dimension | Assessment |
|---|---|
| **RAM / CPU** | Negligible for this module itself — a one-shot generator that exits after writing files and validating once. |
| **Runtime cost** | Entirely whatever backend you point it at (which you run separately). |
| **Storage** | None beyond the small `byo-*.caddy` text files on ext4. |
| **Security boundary** | ⚠️ Fail-closed loopback-target gate is load-bearing — only `127.0.0.1`/`::1`/`localhost` targets are accepted, preventing an open forward-proxy. |
| **Auth boundary** | Token/non-browser backends need a **CF Access service-token exemption**, never `forward_auth`. |
| **Validation** | `caddy validate` runs once; on failure every `byo-*.caddy` written this run is removed (the Caddyfile stays valid). |

## Upgrades / re-pin recipe

Nothing to pin or upgrade. To change routes: edit `PROXY_ROUTES` in `.env`, then
re-run `scripts/install.sh` (or `bash scripts/apps/proxy-routes.sh` directly). The
generator rewrites the `byo-*.caddy` files from the current list, **auto-sweeps any
dropped routes**, and re-validates fail-closed. If the stack is already up, reload
the edge with `bash scripts/start-stack.sh --restart`.

## Enabling

```ini
# .env
ENABLE_PROXY_ROUTES=true
PROXY_ROUTES="grafana=127.0.0.1:3000 uptime=localhost:3001"
```

Then `./pocket.sh` → Install (or `scripts/install.sh`), and in the Cloudflare
dashboard add a Public Hostname + Access policy for each subdomain. To disable: set
`ENABLE_PROXY_ROUTES=false` (and/or empty `PROXY_ROUTES` then re-run to sweep the
generated vhosts).

## See also

- [APP_AUTH.md](APP_AUTH.md) — the service-token vs login-gate distinction.
- [SECURITY.md](SECURITY.md) — the loopback-only edge model + the body-size cap.
- [ARCHITECTURE.md](ARCHITECTURE.md) — how the Caddy edge + tunnel fit together.
