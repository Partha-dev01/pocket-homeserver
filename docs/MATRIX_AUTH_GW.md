# Matrix-SSO auth gateway (advanced)

`matrix-auth-gw` is an **optional** service that lets your users sign into the
apps with their **Matrix username + password** — a single sign-on tied to their
homeserver account, so you never hand out a second set of credentials.

It is an **advanced add-on**. The default app protection in pocket-homeserver is
**Cloudflare Access at the edge plus each app's own login** (see
[APP_AUTH.md](APP_AUTH.md)); you only need this gateway if you specifically want
Matrix-account SSO. It is off unless you set `ENABLE_AUTH_GATEWAY=true`.

- Source: [`scripts/gateway/matrix-auth-gw.py`](../scripts/gateway/matrix-auth-gw.py) (stdlib only)
- Installer: [`scripts/steps/60-install-auth-gw.sh`](../scripts/steps/60-install-auth-gw.sh)
- Binds `127.0.0.1:${AUTHGW_PORT}` (default `9095`) inside the Debian userland;
  reached only through Caddy. Secrets + state live on the large volume under
  `${DATA_DIR}/auth-gw`.

## What it does

The one process offers two independent integration models:

1. **forward_auth (header SSO) — the model the app vhosts hook into.** Caddy
   asks the gateway to authenticate each request (`/authgw/verify`). A valid
   session returns `200` plus a trusted `Remote-User: <localpart>` header;
   otherwise the gateway returns a `302` to its own login form. This gates *any*
   app — including ones that have no login of their own (SearXNG, IT-Tools,
   Gatus).
2. **OIDC IdP (for apps that speak OIDC natively) — dormant by default.** A
   minimal OpenID Connect provider. It answers `503` until you register at least
   one client, so it has no effect unless you deliberately configure it (see
   *Native OIDC* below).

How credentials are checked: on login the gateway POSTs `m.login.password` to
the homeserver (`/_matrix/client/v3/login`) with a pinned `device_id`, and on
success **immediately logs that token out**, so repeated logins never accumulate
Matrix devices/tokens. There is **no password sync** — the homeserver stores
only hashes; the gateway validates live at each sign-in and the app never sees a
password.

The session is an **HMAC-SHA256-signed cookie** (`authgw_session`;
`HttpOnly; Secure; SameSite=Lax`; lifetime `AUTHGW_TTL`, default 30 days). With
`AUTHGW_COOKIE_DOMAIN=${DOMAIN}` (the default) the cookie is scoped to your apex
domain, so **one Matrix login unlocks every `*.${DOMAIN}` app**. Set it empty for
host-only sessions (each subdomain its own login).

## Enabling it

```bash
# in .env
ENABLE_AUTH_GATEWAY=true
AUTHGW_ADMINS=alice            # localparts to auto-grant admin (optional)

# then
bash scripts/steps/60-install-auth-gw.sh
```

The installer ensures `python3` in the userland, copies the gateway in,
generates the signing secret + an RS256 key (chmod 600, on the large volume),
writes a launcher, and supervises the service. It is idempotent — safe to re-run.

Enabling the gateway **does not gate anything by itself**. You then turn it on
per app, in that app's Caddy vhost (next section).

## Gating an app with forward_auth

Each app install script drops a vhost at `/etc/caddy/apps/<app>.caddy` with a
**commented** `forward_auth` block. To gate that app with the gateway, edit the
vhost so it contains all of the following, in this order, **before** the app's
catch-all `reverse_proxy`/`handle`:

```caddy
http://links.example.com:8443 {
	bind 127.0.0.1

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options nosniff
		X-Frame-Options DENY
		Referrer-Policy strict-origin-when-cross-origin
		-Server
	}

	# 1) The gateway's own endpoints must stay reachable (login form, verify,
	#    logout, OIDC). This MUST precede the gate, or the 302-to-login would
	#    itself be gated into a redirect loop. `X-Real-IP {client_ip}` lets the
	#    gateway rate-limit by the real visitor IP.
	handle /authgw/* {
		reverse_proxy 127.0.0.1:9095 {
			header_up X-Real-IP {client_ip}
		}
	}

	# 2) Strip any client-supplied identity header BEFORE the gate, so a visitor
	#    can never forge `Remote-User`. (A top-level `request_header` runs before
	#    `forward_auth`.)
	request_header -Remote-User

	# 3) The gate. A valid session → 200 + Remote-User → request proceeds; no
	#    session → the gateway's 302 to /authgw/login?next=… is returned.
	forward_auth 127.0.0.1:9095 {
		uri /authgw/verify
		copy_headers Remote-User
	}

	# 4) Everything else → the app backend.
	handle {
		reverse_proxy 127.0.0.1:9090 {
			header_up Host {http.request.host}
			header_up X-Forwarded-Proto https
		}
	}
}
```

Then validate + reload:

```bash
bash scripts/start-stack.sh --restart   # brief ingress outage while cloudflared cycles
```

> **Health endpoints stay public.** If an app vhost exposes an unauthenticated
> `/health` (Linkding does), keep its `handle /health { … }` block **before**
> the `forward_auth` so probes are not bounced to login.

### Header-ordering gotcha (read before editing a gated vhost)

`forward_auth` authenticates the request and then copies trusted identity headers
from the gateway's response onto the upstream request. Two rules keep this safe:

- **Strip client-supplied `Remote-*` before the gate** (step 2 above). Do it with
  a top-level `request_header`, which runs *before* `forward_auth`. `copy_headers`
  also overwrites `Remote-User` on a successful verify, but stripping first is
  belt-and-braces.
- **Never strip the session cookie with a top-level `request_header`.** A
  top-level header edit runs *before* the gate, so removing `Cookie` there would
  strip the very `authgw_session` the gate needs and bounce every authenticated
  user to login. If you want to hide the gateway cookie from the app backend
  (optional defense-in-depth), do it with `header_up -Cookie` *inside* the
  step-4 `reverse_proxy` — i.e. *after* the gate.

Always verify a gate change two ways: an authenticated request (valid session)
still reaches the app, and an unauthenticated one is bounced to login.

## Native OIDC (advanced, optional)

Some apps authenticate via OIDC rather than a trusted proxy header. The gateway
can act as their IdP. This is **dormant** until you register a client; the
default install registers none.

There are two realms because OIDC clients verify id_tokens differently:

| Realm | Path | For clients that… | Examples |
|---|---|---|---|
| HS256 | `/authgw/oidc/` | verify the id_token with the shared `client_secret` (HS256), or read identity from `/userinfo`, or don't verify the signature | Linkding (mozilla-django-oidc), Memos, Pingvin |
| RS256 | `/authgw/oidc-rs/` | require an asymmetric signature verified via the published JWKS, and require `issuer == authurl` (coreos/go-oidc) | Vikunja, Gatus |

**Public-vs-loopback split (important).** A phone usually cannot make an outbound
HTTPS call to its own public edge, and OIDC clients do server-to-server fetches
for discovery/token/userinfo. So discovery advertises **loopback** URLs for
`token`/`userinfo`/`jwks`, and only `authorize` (a browser redirect) is the
**public** `https://…/authgw/oidc/authorize`. Point each app's
`discovery`/`token`/`userinfo` at the loopback `http://127.0.0.1:9095/authgw/…`
and only its `authorize` at the public URL.

**Registering clients.** Put client registrations in
`${DATA_DIR}/auth-gw/oidc-clients.env` (create it `chmod 600`). The launcher
sources this file, so client secrets stay in a file and never reach the process
argv. Recognised variables:

```sh
# Primary client (id + secret).
AUTHGW_OIDC_CLIENT_ID=pingvin
AUTHGW_OIDC_CLIENT_SECRET=<random-secret>
# Extra clients: a ;/,-separated list of id=secret pairs.
AUTHGW_OIDC_EXTRA_CLIENTS=linkding=<secret>;memos=<secret>
# Of the registered clients, which use the RS256 realm (go-oidc clients).
AUTHGW_OIDC_RS_CLIENTS=vikunja,gatus
# The PUBLIC base URL of the authorize endpoint (used as the HS256 `iss`).
AUTHGW_OIDC_PUBLIC_BASE=https://share.example.com/authgw/oidc
# Exact allow-list of each client's redirect_uri (comma-separated).
AUTHGW_OIDC_REDIRECT_URIS=https://share.example.com/api/oauth/callback/oidc,https://links.example.com/oidc/callback/
```

Each HS256 id_token is signed with **that client's own secret**, `aud=client_id`,
and the auth code is bound to its `client_id` (a client cannot redeem another's
code). The `redirect_uri` presented at the token endpoint must exactly match the
one bound at authorize time. Restart the gateway after editing the file
(`bash scripts/steps/60-install-auth-gw.sh` re-supervises it, or restart it
directly — see *Operations*).

Claims: `sub=@localpart:${MATRIX_SERVER_NAME}` (a stable key), `email` and
`preferred_username` derived from a canonicalised localpart (`[a-z0-9._-]`),
`roles=["user"]` (plus `"admin"` for localparts in `AUTHGW_ADMINS`). The email is
synthetic (`<localpart>@${DOMAIN}`) and never mailed.

### RS256 key rotation

The RS256 realm signs with one key (`kid=authgw-rs256`) at
`${DATA_DIR}/auth-gw/authgw-rsa.json`. To rotate it with zero downtime, mint a new
key, keep the old public key published in the JWKS for an overlap window via
`AUTHGW_OIDC_RS_OLD_KEYS=oldkid:/path/to/old-key.json` (set in `oidc-clients.env`),
restart, then drop the old key after the window (longer than `AUTHGW_OIDC_TOKEN_TTL`
plus the clients' JWKS cache). The gateway publishes every key in
`AUTHGW_OIDC_RS_OLD_KEYS` in the JWKS but only ever **signs** with the current key.

## Operations

```bash
# health (from inside the userland)
proot-distro login debian -- python3 -c \
  'import urllib.request; print(urllib.request.urlopen("http://127.0.0.1:9095/authgw/health").read())'

# restart (re-supervises; idempotent)
bash scripts/steps/60-install-auth-gw.sh

# logs
tail "${DATA_DIR}/logs/auth-gw.log"

# GLOBAL logout (invalidate every outstanding session cookie at once) — bump the
# epoch file; takes effect on the next request, NO restart, NO secret rotation:
echo 1 > "${DATA_DIR}/auth-gw/authgw-session-epoch"
```

Adding a user is nothing special: anyone with a Matrix account can sign in, and
header-trusting apps auto-create the local account on first login.

## Security notes

- **Binds loopback only**; the homeserver is reached over loopback; the session
  cookie is HMAC-signed, `HttpOnly`, and `Secure`.
- **Login-CSRF**: an `Origin`/`Referer` allow-list (each gated app's own host is
  trusted automatically; extra origins come from `AUTHGW_PUBLIC_ORIGINS`, which
  the installer fills from your enabled apps) **plus** a double-submit CSRF token
  on the login form.
- **Rate-limit**: `POST /authgw/login` is capped per real client IP
  (`AUTHGW_RATE_MAX`, default 20 / `AUTHGW_RATE_WINDOW`=300 s) → `429`. This relies
  on Caddy setting `X-Real-IP {client_ip}` in the `handle /authgw/*` block.
- **Forged-header bypass is prevented**: client `Remote-*` is stripped before the
  gate and `copy_headers` overwrites it from the verified response.
- **Secrets stay off argv**: the signing/RSA keys are files referenced by path,
  and any OIDC client secrets live in the `oidc-clients.env` file the launcher
  sources — never on the command line / in `/proc/*/cmdline`.

## Configuration reference

| `.env` variable | Default | Meaning |
|---|---|---|
| `ENABLE_AUTH_GATEWAY` | `false` | Master switch for this step. |
| `AUTHGW_PORT` | `9095` | Loopback bind port. |
| `AUTHGW_ADMINS` | *(empty)* | Localparts/MXIDs granted the admin role + `Remote-Admin`. |
| `AUTHGW_COOKIE_DOMAIN` | `${DOMAIN}` | Cookie scope; empty = host-only. |
| `AUTHGW_TTL` | `2592000` | Session lifetime (seconds). |
| `AUTHGW_BRAND` | `${DOMAIN}` | Login-page brand. |

Advanced tunables read from `${DATA_DIR}/auth-gw/oidc-clients.env` (OIDC client
registration) are listed under *Native OIDC* above. Rate-limit / CSRF TTLs
(`AUTHGW_RATE_MAX`, `AUTHGW_RATE_WINDOW`, `AUTHGW_CSRF_TTL`) have sensible
defaults and can be overridden in the launcher if needed.

## See also

- [APP_AUTH.md](APP_AUTH.md) — the default (Cloudflare Access) model + per-app table.
- [SECURITY.md](SECURITY.md) — threat model and trust boundaries.
- [ARCHITECTURE.md](ARCHITECTURE.md) — where the gateway sits in the request flow.
