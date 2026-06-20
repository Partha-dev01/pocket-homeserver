# Cloudflare Email Worker — inbound mail front door

`email-worker.js` is the Cloudflare-side half of the pocket-homeserver email
pipeline. It runs **on your own Cloudflare account** (NOT on the phone): when mail
arrives for your mail domain, Cloudflare Email Routing hands the raw message to
this Worker, which writes it to an R2 bucket and returns an SMTP `2xx` accept. The
phone then PULLS that mail out of R2 on its own schedule (`mail-drain.py`), so the
SMTP accept never depends on the phone being online.

```
sender ──▶ Cloudflare Email Routing (*@your-mail-domain)
             │
             ▼
        email-worker.js  ──▶  R2: pending/<sha256>.eml   (+ returns SMTP 2xx)
                                   │
                                   ▼
                          phone: mail-drain.py pulls, injects into Maddy,
                                 then moves the object to processed/
```

You deploy this Worker yourself with `wrangler`. Everything below happens in YOUR
Cloudflare dashboard / a dev box with `wrangler` installed — nothing here runs on
the phone.

## Prerequisites (all on your Cloudflare account)

1. Your mail domain's DNS is on Cloudflare (it can be a subdomain of your apex,
   e.g. `mail.example.com`).
2. **R2** is enabled. Create a bucket for inbound mail:
   ```sh
   wrangler r2 bucket create pocket-mail-inbound
   ```
   Then create an **R2 API token scoped to that bucket, Object Read & Write** — it
   yields the S3 access key id + secret the phone's drain uses. Keep those in the
   phone's 0600 secrets file (`mail-r2.env`); they are NEVER embedded here.
3. **Email Routing** is enabled for the mail domain (the dashboard adds the mail
   `MX` set automatically). You will point a catch-all rule at this Worker in the
   last step.
4. **Resend** (or any SMTP relay) for OUTBOUND — that is configured on the phone
   side (`maddy.conf.tmpl` + the `mail-relay.env` secret), not here.

## Configure `wrangler.toml`

Create a `wrangler.toml` next to `email-worker.js`. A minimal one:

```toml
name = "pocket-mail-inbound-worker"
main = "email-worker.js"
compatibility_date = "2026-01-01"

# R2 bucket binding — the Worker references this as env.MAILBUCKET.
# Create the bucket first:  wrangler r2 bucket create pocket-mail-inbound
[[r2_buckets]]
binding = "MAILBUCKET"
bucket_name = "pocket-mail-inbound"

# Optional low-latency wake-ping (advanced; leave commented for pure-pull):
# [vars]
# PING = "https://your-wake-endpoint.example/wake"
```

Set the R2 object lifecycle in the dashboard (or `wrangler r2 bucket lifecycle`):

| prefix        | rule                                                            |
|---------------|-----------------------------------------------------------------|
| `processed/`  | expire after ~1 day (already injected — just an audit trail)    |
| `pending/`    | expire after ~30 days (the one deliberate, bounded loss point)  |

## Deploy + bind to your mail domain

```sh
wrangler deploy
```

An Email Worker is connected to an address via **Email Routing**, not a wrangler
trigger. After deploying, in the Cloudflare dashboard:

```
Email Routing (your mail domain) -> Routing rules ->
  catch-all *@your-mail-domain -> Action "Send to a Worker" -> pocket-mail-inbound-worker
```

(Email Routing on a subdomain is free-plan supported.)

## Verify

Send a test mail to any address at your mail domain from an external account. A
`pending/<sha256>.eml` object should appear in the R2 bucket within seconds. On the
phone, `r2-check.py` lists the bucket (`pending/` / `processed/`), and once the
drain runs it injects the message into Maddy and moves the object to `processed/`.

## Why this shape

- **Accept never depends on the phone.** The 2xx is returned the moment R2 has the
  bytes durably. A phone outage just means mail waits in `pending/` until the drain
  catches up — it never bounces.
- **Content hash is the idempotency key.** Cloudflare may retry the Worker up to 3×
  in a session; the put-if-absent + the phone-side SQLite ledger guarantee each
  message is injected exactly once.
- **No MIME parsing at the edge.** The raw RFC822 bytes are stored verbatim, so the
  message your client sees is byte-identical to what the sender sent (bar one
  `Received` header Maddy adds on inject).
