# App authentication

How the optional web apps (bookmarks, RSS, notes, tasks, file sharing, search,
dev tools, status) are protected, and how to choose a model. This is reusable
guidance — see [SECURITY.md](SECURITY.md) for the wider threat model.

There are two independent layers, and most apps use both:

1. **The edge gate — Cloudflare Access (the default).** A Cloudflare Zero Trust
   policy on each app's public hostname decides *who is even allowed to reach it*,
   before a request ever touches the tunnel. This is the recommended default for
   every app and the **only** gate for apps that have no login of their own.
2. **The app's own login.** Several apps (Linkding, Vikunja, FreshRSS, Memos,
   Pingvin) have native accounts. That login stays enabled and is a second,
   inner gate — defense in depth behind Cloudflare Access.

An **optional Matrix-SSO gateway** (advanced) can replace per-app logins with a
single sign-on tied to your Matrix account. It is off by default; every app's
generated vhost contains a commented-out hook for it.

## Why an edge gate at all?

Caddy and the apps bind loopback only and are reached exclusively through the
Cloudflare Tunnel — the phone has no inbound ports. But the *public hostname* you
expose through the tunnel is, by default, reachable by anyone on the internet.
Cloudflare Access puts an identity check in front of that hostname at Cloudflare's
edge, so unauthenticated traffic is rejected before it is ever forwarded to your
phone. That keeps an un-authenticated app (SearXNG, IT-Tools, Gatus) from becoming
an open service, and adds a strong outer layer in front of the apps that *do* have
their own login.

## Per-app auth at a glance

| App | Native login? | Default protection | Cloudflare Access |
|---|---|---|---|
| Linkding (bookmarks) | Yes (Django) | CF Access + native login | Recommended |
| Vikunja (tasks) | Yes | CF Access + native login | Recommended |
| FreshRSS (RSS) | Yes (form) | CF Access + native login | Recommended |
| Memos (notes) | Yes | CF Access + native login | Recommended |
| Pingvin (file share) | Yes (accounts) | CF Access + native login | Recommended |
| SearXNG (metasearch) | **No** | **CF Access only** | **Required** |
| IT-Tools (dev tools) | **No** | **CF Access only** | **Required** |
| Gatus (status page) | **No** | **CF Access only** | **Required** |
| Wallabag (read-later) | Yes | CF Access + native login (browser) | Recommended for the browser UI; **service token** for the REST API / mobile app / extension |
| Trilium (notes / wiki) | Yes | CF Access + native login (browser) | Recommended for the browser UI; **service token** for ETAPI + the sync client |
| Radicale (CalDAV/CardDAV) | Yes (Basic) | **native + service-token edge** | **Service token required** — DAV clients can't do the interactive login |
| Vaultwarden (password manager) | Yes (master pw + 2FA) | **native + service-token edge** | **Service token required** — Bitwarden apps can't do the interactive login |
| Navidrome (music) | Yes | CF Access + native login (browser) | Recommended for the UI; **exempt `/rest/*` + `/share/*`** (path bypass or service token) for Subsonic clients |
| Kavita (comics / ebooks) | Yes | CF Access + native login (browser) | Recommended for the UI; **exempt `/api/opds/*`** for OPDS readers (api-key in URL) |
| Audiobookshelf (audiobooks) | Yes | CF Access + native login (browser) | Recommended for the UI; **exempt `/api/*`,`/public/*`,`/feed/*`,`/status`,`/healthcheck`,`/ping`,`/hls/*`** for the mobile apps |
| Forgejo (git forge) | Yes | CF Access + native login (browser) | Recommended for the UI; **service token / path bypass required** for git-over-HTTPS, `/api/v1`, and LFS — those clients can't do the interactive login |
| AdGuard Home (DoH resolver) | Yes (admin UI) | CF Access on the UI + **`/dns-query` path bypass** | UI behind the gate; **`/dns-query` must be exempted** (path bypass or service token) or DoH clients silently fail |
| BYO reverse-proxy (`PROXY_ROUTES`) | depends on the backend | CF Access (per generated hostname) | Recommended per hostname; a token/non-browser backend needs a **service-token exemption**, never `forward_auth` |
| **Tailscale (mesh VPN)** | n/a (network layer) | **Tailnet ACL only** | ⚠️ **No CF edge involved** — the tailnet completely bypasses Cloudflare Access + the tunnel; the **tailnet ACL** is the only network gate (see below) |

For the three apps with no login of their own (SearXNG, IT-Tools, Gatus),
**Cloudflare Access is the only thing standing between the internet and the app** —
do not skip it, or you publish an open metasearch proxy / open tools site / open
status page. For Radicale and Vaultwarden the reverse holds: their hostnames **must
not** sit behind the interactive Access login (it breaks native clients) — give them
a **service-token exemption** instead and rely on the app's own auth (see below).

## Default: Cloudflare Access

Each app install script already tells you the two manual Cloudflare steps it needs.
In the Cloudflare **Zero Trust** dashboard:

1. **Tunnel public hostname.** Tunnels → your tunnel → *Public Hostnames* → *Add*:
   - Subdomain/domain: the app's hostname (e.g. `links.example.com`).
   - Service: `http://localhost:<CADDY_PORT>` (plain HTTP — Caddy serves the
     loopback origin over HTTP and the tunnel terminates public TLS; this matches
     `CADDY_PORT` in your `.env`, default `8443`).
2. **Access application + policy.** Access → *Applications* → *Add an application*
   → *Self-hosted*:
   - Application domain: the same hostname.
   - Add a policy, e.g. *Allow* when **Emails** is one of your trusted addresses
     (or a one-time-PIN / IdP / device-posture rule of your choosing).

Repeat per app hostname. A policy that lists the specific people you trust is the
simplest robust choice; Cloudflare also supports one-time PINs, social/IdP logins,
and service tokens for automation.

> **Non-browser clients (WebDAV, sync, API) cannot do the interactive login.** A
> WebDAV client (e.g. mounting Dufs in Finder / Explorer / `rclone`) cannot follow
> the Access 302-redirect to a login page. To reach such a hostname without a
> browser, attach a **Cloudflare Access service-token** policy to it and have the
> client send `CF-Access-Client-Id` / `CF-Access-Client-Secret` headers. The
> optional Matrix-SSO gateway (below) has **no service-token path**, so it cannot
> front WebDAV at all. See [FILES.md](FILES.md) for the Dufs WebDAV recipe.
>
> The same applies to several v0.7 apps whose clients are **not** browsers:
> **Vaultwarden** (Bitwarden extension/desktop/mobile/CLI — see [VAULT.md](VAULT.md)),
> **Radicale** (CalDAV/CardDAV clients like DAVx5/Thunderbird/iOS — see
> [DAV.md](DAV.md)), **Wallabag's** REST API / mobile app / extension (see
> [READLATER.md](READLATER.md)), and **Trilium's** ETAPI + sync client (see
> [NOTES.md](NOTES.md)). Each needs a **service-token exemption** on its hostname,
> never the interactive login policy.
>
> The **v0.8 media apps** are a milder variant: their *browser UI* sits behind a normal
> Access login, but specific **API paths** used by non-browser clients must be exempted
> (a per-path Access **bypass** is usually easier than a service token, since many
> mobile Subsonic/OPDS apps can't send the `CF-Access-*` headers). Each vhost already
> reverse-proxies those paths ahead of the optional gate; mirror that at the edge —
> **Navidrome** `/rest/*` + `/share/*`, **Kavita** `/api/opds/*`, **Audiobookshelf**
> `/api/*` `/public/*` `/feed/*` `/status` `/healthcheck` `/ping` `/hls/*`. See
> [MEDIA.md](MEDIA.md).
>
> The **v0.9 platform modules** follow the same rule: **Forgejo** needs a service-token
> exemption for git-over-HTTPS / `/api/v1` / LFS (see [FORGEJO.md](FORGEJO.md)), and
> **AdGuard Home** needs a `/dns-query` path bypass or DoH silently breaks (see
> [ADGUARD.md](ADGUARD.md)). The **BYO reverse-proxy** inherits whatever its backend
> needs.

## Tailscale is a different trust boundary entirely

Everything above concerns the **Cloudflare edge** on `*.${DOMAIN}`. **Tailscale**
(optional, `ENABLE_TAILSCALE`) joins the phone to your private tailnet, and tailnet
traffic **does not go through Cloudflare at all** — it bypasses Cloudflare Access and
the tunnel completely. For anything reachable over the tailnet, your **tailnet ACL**
(Tailscale admin console) is the **only** network gate. The default "allow all within
tailnet" means every device on your tailnet can reach this box's loopback services with
no further network auth — **lock the ACL down**. Per-app native logins still apply on
top. See [TAILSCALE.md](TAILSCALE.md).

> Tip: apps that have their own login (the first five above) work fine with *or*
> without Cloudflare Access, but running both is the recommended default — the
> edge gate stops unauthenticated traffic from reaching the app's login form at
> all.

## Advanced (optional): the Matrix-SSO gateway

If you would rather your Matrix users sign in **once** and reach every app without
a separate per-app account, you can run the optional Matrix-SSO gateway. It is a
small loopback service that turns a Matrix login into a session cookie scoped to
your parent domain (and can act as an OIDC identity provider for apps that speak
OIDC). It is **not installed by default**. The full runbook is
[MATRIX_AUTH_GW.md](MATRIX_AUTH_GW.md); the short version:

1. **Enable + install it**: set `ENABLE_AUTH_GATEWAY=true` in `.env` (optionally
   `AUTHGW_ADMINS=<localpart>`), then run `scripts/steps/60-install-auth-gw.sh`.
   It runs on loopback `127.0.0.1:${AUTHGW_PORT}` (default `9095`).
2. **Gate each app** in its `/etc/caddy/apps/<app>.caddy` vhost. Every app's
   generated vhost already contains the `forward_auth` hook commented out; turning
   it on needs **two** blocks, both **before** the app's catch-all
   `reverse_proxy`/`handle`:

   ```caddy
   # (a) keep the gateway's own endpoints reachable (login form / verify / logout)
   handle /authgw/* {
       reverse_proxy 127.0.0.1:9095 {
           header_up X-Real-IP {client_ip}
       }
   }
   # (b) strip any client-supplied identity header before the gate, then gate:
   request_header -Remote-User
   forward_auth 127.0.0.1:9095 {
       uri /authgw/verify
       copy_headers Remote-User
   }
   ```

   Then `bash scripts/start-stack.sh --restart`. See the header-ordering gotcha
   in [MATRIX_AUTH_GW.md](MATRIX_AUTH_GW.md) before editing a gated vhost.
3. **Or use native OIDC** for apps that speak it (Linkding, Vikunja, Memos,
   Pingvin, Gatus): register the client and point the app at the gateway's OIDC
   endpoints instead of `forward_auth` — see *Native OIDC* in the runbook.

### Header-ordering gotcha (read before editing a gated vhost)

`forward_auth` works by asking the gateway to authenticate the request and then
copying trusted identity headers (e.g. `Remote-User`) from the gateway's response
onto the upstream request. Two rules keep this safe and correct:

- **Strip client-supplied `Remote-*` headers before the gate**, so a visitor can
  never forge an identity by sending their own `Remote-User`. Do this with a
  top-level/`handle`-level header strip that runs *before* `forward_auth`.
- **Rewrite upstream headers with `header_up` *inside* `reverse_proxy`** — i.e.
  *after* the gate — not with a top-level `request_header`, which runs before the
  gate and would strip the very cookie the gate needs.

Always verify a gate change two ways: an authenticated request (with a valid
session) still reaches the app, and an unauthenticated one is bounced to login.

## See also

- [SECURITY.md](SECURITY.md) — threat model, trust boundaries, operator checklist.
- [SETUP.md](SETUP.md) — zero-to-running setup, including the Cloudflare Tunnel.
- [ARCHITECTURE.md](ARCHITECTURE.md) — how the edge, Caddy, and the apps fit together.
