# Email backend — Maddy + R2 drain + Cloudflare Email Worker (optional)

pocket-homeserver ships an **optional** self-hosted email backend that gives you a
real mailbox on your own domain WITHOUT exposing an SMTP port from the phone. It is
**off by default** — enable it with `ENABLE_EMAIL=true` in `.env`.

This page covers the inbound/outbound **pipeline** (the mail engine + the drain +
the Cloudflare Email Worker). A webmail UI to read the mailbox in a browser is a
separate optional component.

## Why this shape

A phone can't sanely run a public mail server: it has no static IP, sleeps, and
exposing port 25 from a residential/mobile line gets you on every blocklist. So the
pipeline never accepts SMTP on the phone at all:

```
sender ──▶ Cloudflare Email Routing (*@your-mail-domain)
             │
             ▼
        Email Worker  ──▶  R2: pending/<sha256>.eml   (+ returns SMTP 2xx accept)
        (your CF account)        │
                                 ▼
        phone (Termux) ── mail-drain.py PULLS R2 ──▶ injects into Maddy (loopback SMTP)
                                                       │
                                                       ▼
                                          Maddy imapsql store (loopback IMAP)
                                                       ▲
        outbound:  client ──▶ Maddy submission :loopback ──▶ Resend smarthost ──▶ internet
```

- **Inbound accept never depends on the phone.** Cloudflare's Worker stores the raw
  message in R2 and returns a 2xx the instant the bytes are durable. The phone pulls
  it later. A phone outage means mail waits in `pending/`, never a bounce.
- **No public listener on the phone.** Maddy binds loopback only (IMAP / inject /
  submission). The drain reaches into R2 over HTTPS; Caddy + the Cloudflare Tunnel
  front any webmail UI.
- **Outbound via a relay.** Maddy relays outbound through Resend's SMTP smarthost
  (:587 STARTTLS); Resend signs DKIM so DMARC aligns.

## Components

| File | What | Runs where |
|---|---|---|
| `scripts/email/worker/email-worker.js` | CF Email Worker: raw → sha256 → `R2.put(pending/<sha>)` → accept | Cloudflare edge (your account) |
| `scripts/email/worker/README.md` | how to deploy the Worker with `wrangler` | a dev box with wrangler |
| `scripts/email/maddy.conf.tmpl` | Maddy config template (rendered by the installer) | phone, in the Debian userland |
| `scripts/email/mail-drain.py` | R2 drain loop (stdlib SigV4 S3 client + sqlite ledger + flock + loopback-SMTP inject) | phone, Termux-native python3 |
| `scripts/email/r2-check.py` | bucket lister helper (verification) | phone / dev box |
| `scripts/steps/85-install-email.sh` | installs Maddy in-proot, renders config, provisions accounts, supervises maddy + drain | phone |

## Prerequisites you provision (on YOUR accounts)

These are external services you set up yourself; secrets go into `0600` files under
`${DATA_DIR}/secrets`, never into `.env` or any tracked file.

1. **A mail domain** whose DNS is on Cloudflare (e.g. `mail.${DOMAIN}`).
2. **Cloudflare R2**: a bucket for inbound mail + a bucket-scoped Object Read & Write
   token → fill `${DATA_DIR}/secrets/mail-r2.env`:
   ```sh
   R2_ACCOUNT_ID=...
   R2_ACCESS_KEY_ID=...
   R2_SECRET_ACCESS_KEY=...
   R2_BUCKET=pocket-mail-inbound
   ```
3. **Cloudflare Email Routing** for the mail domain, catch-all `*@your-mail-domain`
   → "Send to a Worker" → the deployed Email Worker (see
   `scripts/email/worker/README.md`).
4. **Resend** (or any SMTP relay) for OUTBOUND → fill
   `${DATA_DIR}/secrets/mail-relay.env`:
   ```sh
   RESEND_API_KEY=...    # the SMTP user is the literal "resend"
   ```

The installer GENERATES the rest (the inject credential, and the catch-all + admin
mailbox passwords) into `0600` files and reuses them on every re-run. The per-user
IMAP HMAC key used by the **optional** Matrix-SSO webmail is generated and owned by
the auth gateway (`scripts/steps/60`), not here — see [docs/WEBMAIL.md](WEBMAIL.md).

## Configuration (`.env`)

```sh
ENABLE_EMAIL=false                  # default OFF
MAIL_DOMAIN=mail.${DOMAIN}          # the mail domain (CF Email Routing target)
MAIL_HOSTNAME=mx.mail.${DOMAIN}     # Maddy EHLO/greeting hostname
MAIL_IMAP_PORT=9143                 # loopback IMAP (a webmail client reads this)
MAIL_INJECT_PORT=9125               # loopback inject (drain delivers here, AUTH)
MAIL_SUBMISSION_PORT=9587           # loopback submission → smarthost (outbound)
MAIL_POLL=180                       # drain poll interval (seconds)
MAIL_ADMIN_LOCALPART=admin          # role/admin mail funnels to <this>@MAIL_DOMAIN
```

The Maddy release pin lives in the install step:
`MADDY_VERSION` / `MADDY_ARCH` / `MADDY_URL` / `MADDY_SHA256`. The reference ran
**Maddy 0.9.5** in proot. You MUST set `MADDY_SHA256` to the real checksum of the
archive you download (the step ships a placeholder so `fetch_verified` fails closed
until you pin it).

## How inbound routing works

The Worker stores each message's original recipient in R2 metadata
(`x-amz-meta-to`). On each pass the drain:

1. lists `pending/`, dedupes by content sha against its SQLite ledger,
2. routes each message to `<recipient-localpart>@${MAIL_DOMAIN}` IF that localpart
   is a provisioned Maddy mailbox (it reads the live `maddy imap-acct list` each
   pass, unioned with an optional pre-seed file), else to the catch-all `inbox@`,
3. funnels role addresses (`postmaster@`, `abuse@`, `dmarc@`, `hostmaster@`,
   `webmaster@`, `security@`, `root@`) to the admin mailbox when it exists,
4. injects over the loopback inject endpoint (SMTP AUTH), then moves the R2 object
   to `processed/`.

The ledger-before-inject + content-addressed move make the whole pass crash-safe and
exactly-once.

## Enabling it

1. Provision the prerequisites above and fill the two `0600` secrets files.
2. Set `ENABLE_EMAIL=true` (and the mail vars) in `.env`.
3. Re-run the installer (it self-gates on the flag):
   ```sh
   ./pocket.sh        # menu → Install   (or: bash scripts/install.sh --force)
   ```
4. Deploy the Email Worker + wire the Email Routing catch-all (Worker README).
5. Verify: send a test mail to any address at your mail domain; it should appear in
   R2 `pending/`, then drain into Maddy. `scripts/email/r2-check.py` lists the
   bucket; `ONESHOT=1 python3 ${DATA_DIR}/mail/mail-drain.py` runs a single pass.

## Security notes

- Maddy binds **loopback only**; there is no public mail listener on the phone.
- The inject endpoint REQUIRES SMTP AUTH, closing the Android shared-loopback hole
  (any app with the INTERNET permission can reach a localhost port).
- The R2 token is **bucket-scoped, read/write only**; the Resend key is the only
  outbound credential. Both live in `0600` files and are exported into a child env —
  never on argv / `ps`.
- Per-user IMAP passwords are derived from a server-held HMAC key, so a webmail SSO
  front end can hand a user their own mailbox password without storing one.

## Operational notes

- Mail that arrives for a user before their mailbox is provisioned lands in the
  catch-all `inbox@` until they're provisioned.
- `pending/` has a bounded R2 lifecycle (e.g. 30 days) — the drain raises a backlog
  alert (optional `MAIL_ALERT_CMD`) well before that, so silent loss is visible.
- Back up the Maddy `imapsql.db` + `credentials.db` together with the drain ledger
  (a ledger newer than its DB snapshot would re-inject still-pending mail on
  restore). They live under `${DATA_DIR}/mail/maddy-state` and `${POCKET_STATE_DIR}`.
