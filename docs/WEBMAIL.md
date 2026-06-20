# Webmail (SnappyMail) — the email subsystem's UI half

Optional, **off by default**. `ENABLE_EMAIL=true` turns on the email subsystem;
this is the **UI half**: [SnappyMail](https://snappymail.eu/) served by php-fpm
inside the Debian userland on a loopback FastCGI pool, fronted by Caddy at
`webmail.${DOMAIN}`. It is the front door to the mailbox (the Maddy mail server,
the other half of `ENABLE_EMAIL`), reached over loopback IMAP/SMTP — nothing
ever leaves the host in cleartext.

Installed by `scripts/steps/86-install-webmail.sh` (self-gates on
`ENABLE_EMAIL`).

## What it gives you

- A full webmail client at `webmail.${DOMAIN}`, pinned to the single mailbox
  domain `mail.${DOMAIN}` (the bundled public providers — gmail/outlook/… — are
  removed, so it only ever talks to your own mailbox).
- The data folder lives **outside** the webroot (`/opt/snappymail-data`, set by
  `include.php`) on the large volume (`${DATA_DIR}/snappymail`), so a userland
  rebuild keeps your mail config.
- **Optional Matrix SSO** (only when `ENABLE_AUTH_GATEWAY=true`): a "Sign in with
  OIDC" button on the login screen runs an OIDC front-door against the
  Matrix-auth gateway; the gateway hands back the mailbox address plus a
  server-managed per-user IMAP password the user never sees, and the plugin does
  a normal IMAP login with it. New mailboxes are JIT-provisioned on first login
  and get a one-time welcome email.
- **Optional native admin panel** (`ENABLE_WEBMAIL_ADMIN=true`): SnappyMail's own
  admin UI, **host-locked** to a separate `webmail-admin.${DOMAIN}` vhost that
  fails closed unless it arrives through Cloudflare Access.

## Auth model

The auth boundary is **SnappyMail's own IMAP login** (no stacked Caddy
`forward_auth` cookie gate — SnappyMail is a SPA and a 302-to-login gate breaks
SPAs, the Pingvin/Linkding lesson). SSO, when enabled, is offered **in-app**
(the OIDC button), not via a Caddy gate.

## Configuration (`.env`)

```sh
ENABLE_EMAIL=false           # the whole email subsystem (mail server + this UI)
SNAPPYMAIL_FPM_PORT=9092     # loopback php-fpm pool port
MAIL_IMAP_PORT=9143          # the Maddy IMAP listener (loopback; set in the mail-server half)
MAIL_SUBMISSION_PORT=9587    # the Maddy outbound submission listener (loopback)
ENABLE_WEBMAIL_ADMIN=false   # SnappyMail native admin panel on webmail-admin.${DOMAIN}
# Advanced overrides (sensible defaults derived from DOMAIN):
# SNAPPYMAIL_OIDC_CLIENT_ID, SNAPPYMAIL_OIDC_AUTHORIZE_URL,
# SNAPPYMAIL_OIDC_TOKEN_URL, SNAPPYMAIL_OIDC_REDIRECT_URI, SNAPPYMAIL_BRAND,
# SNAPPYMAIL_WELCOME_FROM, SNAPPYMAIL_VERSION / _URL / _SHA256
```

## The auth-gateway `snappymail` OIDC client

When SSO is on, the gateway needs a `snappymail` OIDC client whose **token
response is extended** with two extra fields the plugin consumes:

- `email` = `<localpart>@mail.${DOMAIN}` (the mailbox address)
- `imap_password` = the server-managed per-user IMAP password, derived as
  `hex(HMAC-SHA256(IMAP_HMAC_KEY, canonical_localpart))` (64 hex chars) — the JIT
  mailbox provisioner creates the Maddy account with the byte-identical value, so
  Maddy's `pass_table` verifies it (Maddy has no OAUTHBEARER). It is returned
  **only** over the loopback, client-secret-gated `/token` exchange, never to the
  browser.

The `IMAP_HMAC_KEY` is **owned by the auth gateway**: `scripts/steps/60-install-auth-gw.sh`
generates `${DATA_DIR}/auth-gw/mail-imap-secret.key` (0600) and the gateway is its
only reader — so there is exactly one key, with no cross-component duplication. The
gateway's mail extension (`OIDC_MAIL_CLIENTS` / `imap_password()` in
`scripts/gateway/matrix-auth-gw.py`) is inert until the install step registers the
`snappymail` client; both the gateway extension and the SnappyMail plugin's
secret-handling are **security-critical** and maintainer-written + verified.

## Upgrading

Bump `SNAPPYMAIL_VERSION` + regenerate `SNAPPYMAIL_SHA256`
(`curl -fsSL "$SNAPPYMAIL_URL" | sha256sum`) and re-run the install step. The
plugin and any application.ini customizations must be **re-applied on upgrade**
(SnappyMail can rewrite config on a fresh extract) — re-running the step does
this fail-closed.
