# Honeypot — scanner detection (optional, alert-only by default)

pocket-homeserver ships an **optional, alert-only** honeypot: a small native
Python watcher that tails the core Caddy access log, flags high-confidence
scanner probes (requests for `/.env`, `/.git`, `/wp-login.php`, `/phpmyadmin`,
shell-upload endpoints, …), and writes a JSONL ledger that the web admin panel
renders as a **Security** console.

It is **off by default**. Enable it with `ENABLE_HONEYPOT=true` in `.env`.

## What it is — and what it is not

- **No inbound listener, no new attack surface.** The watcher does not open a
  socket and does not change Caddy. It only *reads* the access log that Caddy
  already writes. Cloudflare's WAF / Bot Fight Mode filters most junk before it
  ever reaches your tunnel, so the ledger is usually quiet — that is normal.
- **Alert-only by default.** Out of the box the watcher does exactly one thing:
  append matched probes to the ledger. Matrix alerts and Cloudflare edge
  blocking are **both** opt-in (see below) and **both** off until you create the
  relevant `0600` files under `${DATA_DIR}/secrets`.
- **Native, not in the userland.** Like the admin panel, the watcher runs
  Termux-native because it tails the host-side Caddy log and may call the
  Cloudflare API / the loopback Matrix API. It is stdlib-only Python.
- **Defensive only.** Nothing the honeypot does ever sends traffic *to* a source
  IP. The strongest action it can take is to add an IP Access Rule on *your own*
  Cloudflare account edge — and only if you explicitly opt in.

## Enabling it

1. Set in `.env`:

   ```sh
   ENABLE_HONEYPOT=true
   ```

2. (Re-)run the installer. The honeypot step self-gates on the flag:

   ```sh
   ./pocket.sh        # menu → Install   (or: bash scripts/install.sh --force)
   ```

   The step `scripts/steps/77-install-honeypot.sh`:
   - seeds `${DATA_DIR}/secrets/honeypot.mode` = `alert` (`0600`) if absent,
   - seeds a `${DATA_DIR}/secrets/honeypot-safelist.txt` template (`0600`),
   - touches the ledger `${POCKET_LOG_DIR}/honeypot.log` (`0600`),
   - supervises the watcher (recorded in state so `start-stack.sh` re-supervises
     it on every bring-up, surviving a reboot).

3. Open the admin panel → **Security** (`/honeypot`). Hits appear there as the
   watcher records them. The console also exposes per-IP drill-down, passive
   enrichment (RDAP / reverse-DNS / offline geo / threat-intel deep-links), and
   an abuse-report draft generator.

## The ledger

The ledger is the source of truth and **always works** (the admin console reads
it directly):

```
${POCKET_LOG_DIR}/honeypot.log     # one JSON object per line (JSONL), chmod 600
```

Each line records the timestamp (UTC), client IP, host, request path, the matched
detection rule, the HTTP status Caddy returned, and any action taken.

## The safelist

`${DATA_DIR}/secrets/honeypot-safelist.txt` (`0600`) lists IPs/CIDRs the watcher
**never** alerts on or blocks. Loopback and all Cloudflare edge ranges are built
into the watcher already; use this file for your own egress / known-good
addresses — one IPv4/IPv6 address or CIDR per line, `#` comments allowed:

```
# my home/office egress
203.0.113.10
2001:db8:1234::/48
```

You can also add an IP to the safelist from the admin console (the **safelist**
action on a per-IP page), which appends an annotated line here.

## Optional: Matrix alerts

By default the watcher is **ledger-only**. To also post alerts to a Matrix room,
create the file `${DATA_DIR}/secrets/honeypot-alert.env` (`0600`) with:

```sh
HP_MATRIX_HS=http://127.0.0.1:8448          # your homeserver base URL (loopback is fine)
HP_MATRIX_TOKEN=syt_your_bot_access_token   # an access token for a bot/alert account
HP_MATRIX_ROOM=!yourRoomId:example.com      # the room to post alerts into
```

```sh
chmod 600 "$DATA_DIR/secrets/honeypot-alert.env"
```

Then restart the watcher (admin panel → Security → *restart watcher*, or
`bash scripts/ops/restart.sh honeypot-watcher`). The token is read from the
`0600` file inside the supervisor and is **never** placed on a process command
line. If the file or any of the three variables is absent, Matrix alerting is
silently skipped — the ledger still records everything.

Alerts are posted via the standard Matrix client-server API
(`PUT /_matrix/client/v3/rooms/{room}/send/m.room.message/{txn}`), and throttled
per source IP so a noisy scanner cannot flood the room.

## Optional: offline geo / ASN enrichment

By default ledger hits carry no geo/ASN data. You can enable **offline**
enrichment — country, ASN, and an advisory hosting/datacenter flag — by deploying
the free DB-IP *lite* datasets (CC-BY 4.0). It is computed entirely locally (no
live IP-intel lookups, nothing sent to the source), and it is **purely advisory**:
geo never affects detection, the safelist, or blocking.

Drop the two `*.csv.gz` files into `scripts/honeypot/geo/` (the datasets are not
shipped — they are large and regenerable) and restart the watcher. The download
URLs, expected filenames, the required CC-BY attribution, and a one-liner refresh
command are in [`scripts/honeypot/geo/README.md`](../scripts/honeypot/geo/README.md).
With no dataset present the watcher never imports the geo module and every lookup
is a no-op, so the ledger record is byte-identical to a geo-less run. Once a
dataset is in place, the **Security** console shows top countries / ASNs and a
hosting-ASN ratio, and per-IP pages show the network owner.

## Optional: Cloudflare edge blocking (triple-gated, off by default)

Blocking is the most powerful action, so it is **triple-gated** — all three must
be true before the watcher will challenge or block a source IP:

1. **Mode.** `${DATA_DIR}/secrets/honeypot.mode` contains `challenge` or `block`
   (the default, and the only value the installer writes, is `alert`).
2. **Opt-in marker.** The file `${DATA_DIR}/secrets/honeypot-allow-blocking`
   exists (any content). This means a tampered mode file *alone* can never enable
   mass-blocking — an attacker with write access to your secrets would *also*
   have to create this marker.
3. **Token-scope self-check.** The Cloudflare API token in
   `${DATA_DIR}/secrets/cf-honeypot.env` passes the watcher's over-scope
   tripwire: it must be scoped to **only** `Account → Firewall Access Rules →
   Edit` and nothing more. An over-privileged token is refused.

### Provisioning the Cloudflare credentials

Create `${DATA_DIR}/secrets/cf-honeypot.env` (`0600`):

```sh
CF_API_TOKEN=your_scoped_token
CF_ACCOUNT_ID=your_account_id
```

```sh
chmod 600 "$DATA_DIR/secrets/cf-honeypot.env"
```

### Scoping the token to ONLY Firewall Access Rules: Edit

In the Cloudflare dashboard:

1. **My Profile → API Tokens → Create Token → Create Custom Token.**
2. Under **Permissions**, add exactly **one** row:
   `Account` · `Account Firewall Access Rules` · `Edit`.
3. Under **Account Resources**, scope it to the single account you use.
4. Add nothing else — no Zone permissions, no DNS, no other account permissions.
   The watcher's self-check **refuses** a token that carries any extra scope.
5. Create the token, copy it into `cf-honeypot.env`, and put your account ID in
   the same file.

The over-scope self-check is deliberate defence-in-depth: even if the secrets
directory were compromised, a correctly-scoped token can do nothing beyond
adding/removing IP Access Rules, and a stolen *broad* token would be rejected by
the watcher rather than used.

### Turning blocking on

With `cf-honeypot.env` provisioned and the `honeypot-allow-blocking` marker
created, set the mode and restart the watcher:

```sh
printf 'challenge\n' > "$DATA_DIR/secrets/honeypot.mode"   # or: block
chmod 600 "$DATA_DIR/secrets/honeypot.mode"
touch "$DATA_DIR/secrets/honeypot-allow-blocking"
bash scripts/ops/restart.sh honeypot-watcher
```

- `challenge` adds an IP Access Rule in **managed_challenge** mode — real humans
  can still pass an interstitial, automated scanners fail. CGNAT-safe.
- `block` hard-refuses every request from the IP at the edge (heavier; a shared
  / CGNAT address would take collateral).

Both add exactly **one** rule per source IP, tagged `honeypot-auto` in its notes,
on *your own* account edge. To keep the edge ruleset from growing without bound,
the watcher ships a `--reap` mode that prunes aged `honeypot-auto` rules — but
pocket-homeserver does **not** schedule it for you. Run `python3
scripts/honeypot/honeypot-watcher.py --reap` periodically (e.g. from your own
cron / `termux-job-scheduler`), or just remove rules on demand with the console's
**unblock** action.

## Unblocking / undo

From the admin console, open the per-IP page and use:

- **unblock** — deletes every `honeypot-auto` IP Access Rule that targets that IP
  (challenge or block). Only rules the honeypot itself created are touched; your
  manual Cloudflare rules are never affected.
- **safelist** — appends the IP to `honeypot-safelist.txt` so it is never
  alerted on or auto-blocked again. (Note: safelisting does **not** remove an
  existing Cloudflare rule — run **unblock** as well if one is active.)

To turn blocking off entirely, set the mode back to alert-only and restart:

```sh
printf 'alert\n' > "$DATA_DIR/secrets/honeypot.mode"
rm -f "$DATA_DIR/secrets/honeypot-allow-blocking"
bash scripts/ops/restart.sh honeypot-watcher
```

Existing edge rules are not removed automatically — use the console's **unblock**
action (or the Cloudflare dashboard) to clear any you no longer want.

## Optional: the rate-jail (fail2ban-style, off by default)

The scanner rules above match **what** a request is (a probe for `/.env`,
`/wp-login.php`, …). The **rate-jail** is a complementary rule that watches **how a
single IP behaves over time**: it is an **auth-failure-burst** detector — the
fail2ban pattern. It is **off by default** and adds no listener; it is just extra
logic in the same watcher, reading the same Caddy log.

```sh
RATE_JAIL_MODE=off       # off | alert | enforce   (default off)
```

- **`off`** (default) — a strict no-op. The detector returns immediately; the
  watcher's behaviour is byte-identical to a build without it.
- **`alert`** — when an IP trips the threshold, append a `rate-jail` line to the
  ledger and (if Matrix alerts are configured) post a dedicated *"auth-failure
  burst"* alert. **Never blocks.**
- **`enforce`** — same as `alert`, **and** apply a Cloudflare **managed-challenge**
  via the *same* triple-gated `cf_block` path the scanner rules use. Because it
  reuses that path, `enforce` **safely degrades to alert-only** unless you have also
  opted into blocking (the `honeypot-allow-blocking` marker + a correctly-scoped
  token + `cf-honeypot.env`). So `enforce` alone never starts challenging — the
  blocking opt-in is still required.

### What trips it (low false-positive by design)

It counts **only auth-failure responses** — HTTP `401` / `403` / `429`
(`RATE_JAIL_STATUSES`) — from one IP within a sliding window. Normal browsing
(`2xx`/`3xx`) is ignored entirely; it **never jails on raw request volume**. When an
IP produces `RATE_JAIL_FAILS` such responses inside `RATE_JAIL_WINDOW` seconds, it
trips once per `RATE_JAIL_COOLDOWN` (so a sustained burst ledgers/alerts once, not on
every failing request). The safelist (loopback + Cloudflare edge + your own entries)
is honoured, and the per-IP tracking dict is **bounded** (`RATE_JAIL_IP_CAP`,
defaults to the scanner `IP_STATE_CAP`) with oldest-failure eviction, so a
high-cardinality scanner cannot grow it without bound.

```sh
RATE_JAIL_WINDOW=300        # sliding window, seconds
RATE_JAIL_FAILS=12          # auth-fails within the window → trip
RATE_JAIL_STATUSES=401,403,429
RATE_JAIL_IP_CAP=<IP_STATE_CAP>   # max tracked IPs (bounded)
RATE_JAIL_COOLDOWN=<ALERT_COALESCE>   # re-trip throttle, seconds
```

Set the mode in `.env` (the `setup.sh` wizard offers `alert` when you enable the
jailer) and restart the watcher. `rate-jail` hits show up in the **Security** console
and the ledger like any other hit (`hit_rule: "rate-jail"`, `mode: "rate:<mode>"`).

> **Log-coverage caveat.** The watcher tails the **core Caddy access log**, so the
> rate-jail only sees auth failures for services fronted by that Caddy edge. Failed
> logins on a backend that does its own logging elsewhere are not visible to it.

## Disabling the honeypot

Set `ENABLE_HONEYPOT=false` in `.env` and stop the watcher:

```sh
bash scripts/ops/restart.sh honeypot-watcher   # picks up nothing to start
# or stop it directly via the panel's Security console
```

The ledger, mode file, and safelist under `${DATA_DIR}/secrets` are left in place
so you can re-enable later without reconfiguring.
