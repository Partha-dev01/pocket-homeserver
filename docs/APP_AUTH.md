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

For the three apps with no login of their own, **Cloudflare Access is the only
thing standing between the internet and the app** — do not skip it, or you publish
an open metasearch proxy / open tools site / open status page.

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

> Tip: apps that have their own login (the first five above) work fine with *or*
> without Cloudflare Access, but running both is the recommended default — the
> edge gate stops unauthenticated traffic from reaching the app's login form at
> all.

## Advanced (optional): the Matrix-SSO gateway

If you would rather your Matrix users sign in **once** and reach every app without
a separate per-app account, you can run an optional Matrix-SSO gateway. It is a
small loopback service that turns a Matrix login into a session cookie scoped to
your parent domain (and acts as an OIDC identity provider for apps that speak
OIDC). It is **not installed by default**.

Every app's generated vhost in `/etc/caddy/apps/<app>.caddy` already contains the
hook, commented out:

```caddy
# forward_auth 127.0.0.1:9095 {
#     uri /authgw/verify
#     copy_headers Remote-User
# }
```

To use it you would:

1. Install + enable the gateway (an optional component — `ENABLE_AUTH_GATEWAY` and
   `scripts/steps/60-install-auth-gw.sh`; this is a planned advanced add-on, so
   treat the commented hooks as the integration point until you have it running).
2. Uncomment the `forward_auth` block in the vhost of each app you want gated by
   the gateway (place it **before** the app's `reverse_proxy`/`handle` so an
   unauthenticated request is redirected to login first).
3. For apps that natively support OIDC (Linkding, Vikunja, Memos, Pingvin, Gatus),
   point the app at the gateway's OIDC endpoints instead of using `forward_auth`,
   per that app's docs.

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
