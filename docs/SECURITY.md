# Security

The threat model pocket-homeserver is designed around, the layered defenses that
follow from it, and a short checklist for anyone deploying. This is reusable
guidance, not an audit of any one deployment.

## Threat model

The design assumes a small, invite-only server (chat plus personal web apps) run
by one operator for a handful of trusted users, reachable only through a
Cloudflare Tunnel. Federation is off. The phone has no inbound ports and no
public IP.

| Threat | Likelihood | Impact | Primary mitigation |
|---|---|---|---|
| Opportunistic scanner / botnet | High | Low | No inbound ports; Cloudflare WAF; registration is token-gated |
| Automated scraper / enumeration | Medium | Low | No federation = no cross-server enumeration; closed room directory |
| Compromised member device | Medium | Medium | Per-user rate limits; admin kick / token revoke |
| Malicious invited member | Low–Med | Medium | Rate limits, moderation, small trust set |
| Tunnel token leak | Low | High | Token kept secret + chmod 600; rotate on suspicion; Cloudflare 2FA |
| Server software RCE / 0-day | Very Low | High | Memory-safe server; update cadence; least-privilege userland (no root) |
| Carrier / network MITM | Low | High | Tunnel is mutually authenticated by design; TLS at the edge |
| Phone physical theft | Low | High | Device encryption + strong screen lock + remote wipe |

The two structural facts that shrink the attack surface the most: **no inbound
ports** (the phone only ever dials out), and **no federation** (the server talks
to no other Matrix server).

## Trust boundaries

```
 untrusted internet
        │
   Cloudflare edge        ← WAF, rate limiting, bot protection, Access (identity gate, default)
        │  mutually-authenticated tunnel
   cloudflared / Caddy    ← plain-HTTP loopback origin (tunnel terminates TLS); security headers
        │
   app login / optional SSO ← native app login by default; optional Matrix-SSO forward-auth gate
        │
   loopback services      ← "same host, same user" trust; nothing binds public
```

Everything past the tunnel is loopback. The trust between loopback services is
"same host, same user": an attacker with a shell on the phone already has
everything, so there is nothing to encrypt *between* local services. The
meaningful boundaries are the **edge**, the **auth gate**, and the **admin
panel**.

## Defense in depth

### Edge (Cloudflare)
- Proxy ("orange-cloud") the hostname; the phone's IP is never published.
- **Tunnel only** — no DNS A record to the origin. The single path in is the
  outbound tunnel the phone opened.
- Strict TLS end-to-end; HSTS with a long max-age.
- WAF managed rules; a rate-limit rule on the login endpoint to blunt brute
  force; bot-fight / browser-integrity checks on non-client paths.

### Matrix homeserver
- `allow_federation = false` — the single most important setting.
- `allow_registration = false`; account creation is gated by single-use,
  expiring invite tokens minted by the admin.
- Closed room directory (no anonymous enumeration).
- Server-side rate limits on login, registration, upload, and messages.
- Sensible upload size caps.

### Reverse proxy (Caddy)
- Binds loopback only; origin TLS is internal/self-signed (fine on loopback,
  since real TLS is terminated at the edge).
- Security headers: HSTS, `X-Content-Type-Options: nosniff`, `X-Frame-Options`,
  a strict `Referrer-Policy`, and the `Server` header removed.
- The **forward-auth gate** is the boundary for every private app. A subtle but
  critical detail: **client-supplied auth headers must be stripped before the
  gate**, and upstream header rewrites must happen *after* it — otherwise a
  client could forge identity headers, or a header strip could break authed
  requests. Always verify a gate change with both an authenticated and an
  unauthenticated probe.

### Host / Termux
- Every listener binds `127.0.0.1`. `netstat -tln` should show no `0.0.0.0`
  line from any service; if it does, a config change regressed the hardening.
- SSH (if enabled) is key-only, no password, no root login, loopback-bound.
- `cloudflared` is outbound-only by design.

### Server-side request forgery (SSRF)
Some apps fetch user-chosen URLs server-side (an RSS reader subscribing to a
feed; a metasearch image proxy). On the phone, "the intranet" those fetchers can
reach is **loopback** — where the sensitive services live. Mitigations:
- Disable server-side image/content proxying where the app offers the toggle.
- Keep every fetcher behind the auth gate, so only trusted members can drive it.
- Ensure **no sensitive loopback endpoint answers an unauthenticated request** —
  that removes the only response worth relaying. There is no cloud-metadata
  endpoint on a phone, which removes the classic SSRF target.
- A no-root phone cannot impose a network-namespace egress filter, so where an
  app exposes no egress control the residual risk is *accepted*, bounded by the
  small trusted-member set.

### Secrets and supply chain
- Secrets live in mode-`600` files, are kept out of git, and are never passed on
  the command line or written to logs.
- Because the repository is public, a [`tools/leak-scan.sh`](../tools/leak-scan.sh)
  guard scans every change for secrets, keys, public IPs, and deployment-specific
  strings before it is pushed.
- Backups can be encrypted at rest (e.g. with [`age`](https://github.com/FiloSottile/age)).
  **Store the decryption key off the device** — a backup you cannot decrypt is
  not a backup.
- Downloaded binaries are verified fail-closed — pinned versions + `sha256`
  checks (the [`verify_sha256` / `fetch_verified`](../scripts/lib/common.sh)
  helpers) — so a compromised mirror cannot inject a payload.

### Physical
- Strong screen lock; device encryption on (default on modern Android).
- Limit USB-debug authorizations to machines you control.
- Enable remote-locate / remote-wipe.

### Deception (optional)
An **optional, off-by-default honeypot** ships with the stack (`ENABLE_HONEYPOT`):
a native watcher that tails the Caddy access log, flags high-confidence scanner
probes (requests for `/.env`, `/.git`, `/wp-login.php`, …), and surfaces them in
the admin panel's Security console — turning scans into signal. It opens no new
listener and changes nothing at the edge by default; Matrix alerts and Cloudflare
edge blocking are each separately opt-in. See [HONEYPOT.md](HONEYPOT.md).

## What this design deliberately does not do

- **No federation** — avoids the largest attack surface and unwanted state/egress.
- **No open room directory** — no anonymous room enumeration.
- **No email-based password reset in the base design** — password resets go
  through the admin. The phone never exposes an inbound SMTP port. An **optional,
  off-by-default email backend** (`ENABLE_EMAIL`) does exist, but it deliberately
  accepts no SMTP on the device: inbound mail arrives via a pull-based Cloudflare
  Email Routing → R2 → drain pipeline into a loopback-only mailbox, and outbound
  goes through a relay. See [EMAIL.md](EMAIL.md).
- **No always-on voice/video relay (TURN)** in the base design.

## Operator checklist

If you do nothing else, do these:

1. **`allow_federation = false`.**
2. **`allow_registration = false`** plus token-gated invites.
3. **All listeners on `127.0.0.1`**, all external traffic via the tunnel.

Then:

- Set a strong, unique `ADMIN_PASSWORD`; never ship the default.
- Keep `CF_TUNNEL_TOKEN` secret; rotate it if you suspect exposure.
- Back up the **backup-encryption key off the device**.
- Use a strong screen lock and enable device encryption + remote wipe.
- Keep the server software and `cloudflared` reasonably current.
