# Landing portal (optional)

A clean, attractive **service directory** served by Caddy at your **apex domain**
(`http://${DOMAIN}`). The cards are generated from your `ENABLE_*` flags — one card
per enabled app — so the page always matches what you actually run. It is **off by
default** (`ENABLE_LANDING`) and contains **no bait or decoy content** — it is just
a link directory.

## What it is

- A static HTML page (`scripts/landing/index.html.tmpl`) rendered at install time:
  the brand string + one card per enabled app (Chat is always shown; Bookmarks,
  File Share, Feeds, Notes, Tasks, Search, Dev Tools, Status appear when their
  `ENABLE_*` flag is `true`).
- Served from a dir **inside the userland** (`/opt/landing`) by the core Caddy via
  a drop-in `/etc/caddy/apps/landing.caddy` apex vhost — no process to supervise,
  nothing new listening.
- **Auth-agnostic.** By default the portal is public (a link directory). The vhost
  ships a commented `forward_auth` block so you can gate the whole portal behind
  the optional Matrix-SSO gateway, and an `/authgw/*` proxy so the page's account
  bar can show your sign-in state when the gateway is enabled (it degrades to
  "signed out" when it is not). See [APP_AUTH.md](APP_AUTH.md).

## Enabling it

```sh
# in .env
ENABLE_LANDING=true
LANDING_BRAND="My Home"      # optional; defaults to ${DOMAIN}
```

Then run the installer (`./pocket.sh` → Install, or `bash scripts/install.sh --force`).
It renders the page, drops the apex vhost, and validates the Caddyfile fail-closed
(it does not restart Caddy — pick up the change with `scripts/start-stack.sh --restart`).

`LANDING_BRAND` is shown verbatim in the title/header/footer; it is HTML-escaped at
render time, but keep it plain text.

### Manual Cloudflare step

The portal lives at the **bare apex** (`${DOMAIN}`), so add a Cloudflare Tunnel
public hostname for the apex (CNAME-flattened) → `http://localhost:${CADDY_PORT}`,
alongside your subdomain hostnames. If you also run mail on the apex, the records
coexist (MX/TXT are separate from the tunnel hostname).

## Customizing

- **Brand:** `LANDING_BRAND` in `.env`.
- **Cards:** they are generated from the `ENABLE_*` flags — enable/disable an app
  and re-run with `--force` to add/remove its card.
- **Look or copy:** edit `scripts/landing/index.html.tmpl` (the `__BRAND__` token
  and the single `POCKET_CARDS` marker line are the only substitution points) and
  re-run with `--force`.

When no optional apps are enabled, the grid still shows the Chat card plus a hint to
enable apps in `.env`.
