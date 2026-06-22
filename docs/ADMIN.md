# Web admin panel

A small, phone-friendly control panel for the whole stack — health, device stats,
logs, service restarts, backups, the registration token, and a guarded danger
zone. It is a single Flask app ([admin/app.py](../admin/app.py)) installed by
[scripts/steps/70-install-admin.sh](../scripts/steps/70-install-admin.sh).

It is on by default (`ENABLE_ADMIN=true`); set it to `false` in `.env` to skip it.

## Where it runs (and why)

The panel runs **Termux-native** — NOT inside the proot Debian userland — because
its job is to orchestrate the host: it shells out to the scripts under `scripts/`
(service restarts via `proot-distro`, the backup / rotation / panic scripts),
reads the supervisor pidfiles under `${POCKET_STATE_DIR}`, and `pgrep`s the host
processes for health. None of that works from inside the userland. It binds
`127.0.0.1:${ADMINWEB_PORT}` (default `9000`) and Caddy (in the userland, which
shares the host network namespace) reverse-proxies `${ADMIN_HOST}` to it.

```
you ──HTTPS──> Cloudflare (Access policy) ──tunnel──> Caddy :CADDY_PORT
                                                         └─> 127.0.0.1:9000  (the panel)
```

## Protecting it

Two independent layers, both recommended:

1. **Cloudflare Access (edge).** Add a Zero Trust *self-hosted application* policy
   on `${ADMIN_HOST}` in the Cloudflare dashboard so only your identities can even
   reach the panel. (Not configured by the script — see [APP_AUTH.md](APP_AUTH.md).)
2. **The panel's own login.** A scrypt-hashed password (from `ADMIN_PASSWORD`),
   a signed session cookie with an idle timeout, CSRF on every POST, and a per-IP
   brute-force lockout. Optionally the panel **also** validates the Cloudflare
   Access JWT itself (set `CF_ACCESS_TEAM_DOMAIN` + `CF_ACCESS_MODE=enforce`).

A header-less request on loopback (e.g. an `ssh -L 9000:127.0.0.1:9000` tunnel)
bypasses Caddy/Cloudflare and lands directly on the panel's own login — your
break-glass path if the edge is misbehaving.

## What you can do

| Page | What it shows / does |
|---|---|
| **dashboard** (`/`) | live stat chips (uptime/load/RAM/battery), stack health, per-service quick-restart buttons |
| **health** (`/health`) | HTTP endpoint probes + process liveness, refreshed every 30 s |
| **stats** (`/stats`) | device / CPU / memory / thermal / network detail |
| **backups** (`/backups`) | list + delete snapshots; trigger a DB / full-rootfs backup; push encrypted backups off-device (when `ENABLE_OFFSITE_BACKUP`) |
| **tokens** (`/tokens`) | reveal (password-gated) the Matrix registration token |
| **logs** (`/logs`) | tail any service log, with a case-insensitive filter + line count |
| **metrics** (`/metrics`) | sparklines + a 24h health strip (when `ENABLE_METRICS`) — see [OBSERVABILITY.md](OBSERVABILITY.md) |
| **users** (`/users`) | list / create / reset-password / suspend / deactivate + invite tokens (when `ENABLE_USER_ADMIN`) — see [USERS.md](USERS.md) |
| **problems** (`/problems`) | appears when a service is crash-looping or down: per-service detail + restart + a *run doctor* button |
| **danger** (`/danger`) | rotations + panic kill-switches, behind a two-page typed confirmation |

### The action surface

Every clickable action maps to a fixed entry in an allow-list (`SCRIPTS_OK`) — no
user input ever reaches a shell. The backing scripts live in
[scripts/ops/](../scripts/ops/):

- **restarts** — `ops/restart.sh <service>` re-supervises a single service from the
  exact command the supervisor recorded at start time; `start-stack.sh --restart`
  cycles the core stack.
- **backups** — `ops/backup-db.sh`, `ops/backup-all.sh`, `ops/rotate-backups.sh`
  (see [BACKUPS.md](BACKUPS.md)).
- **danger** — `ops/rotate-registration-token.sh`, `ops/rotate-admin-password.sh`,
  `ops/panic-soft.sh`, `ops/panic-hard.sh`.

### The danger zone

Destructive actions require a **two-page confirmation**: an impact-review page,
then a final page that needs three independent inputs — a per-action typed phrase,
the literal word `yes`, and your admin password re-entered. Every attempt is
audit-logged (timestamp + IP + user-agent) to `${DATA_DIR}/logs/admin-audit.log`.

- **Soft panic** stops only the Cloudflare Tunnel (public access off; loopback
  still works) — fully reversible with `start-stack.sh`.
- **Hard panic** stops the whole stack *except the panel itself*, so you can
  recover from the loopback PWA.
- **Rotate admin password** mints a new panel password, shown once.
- **Rotate registration token** mints a new Matrix invite token and restarts the
  homeserver. (Rotating a *Matrix admin user's* password is a future addition.)

## Operations

- **Restart the panel:** `bash scripts/ops/restart.sh adminweb` (it runs detached —
  the running worker is the one being replaced).
- **Logs:** `${POCKET_LOG_DIR}/adminweb.log` (and `adminweb-async.log` for detached
  backups). The audit trail is `${DATA_DIR}/logs/admin-audit.log`.
- **Re-run the installer** any time (`bash scripts/steps/70-install-admin.sh`) — it
  is idempotent and preserves a password you rotated from the danger zone.

## Network throughput via Shizuku (optional)

Android (SELinux) denies the Termux app domain a few `/proc`/`/sys` files —
notably `/proc/net/dev`. So on most phones the panel's **network interfaces**
panel shows *“restricted — the OS blocks /proc/net/dev for this app.”* That is
expected and harmless; everything else (uptime, load, CPU, memory, thermals) is
read without it.

If you want live per-interface RX/TX and throughput, install
[Shizuku](https://shizuku.rikka.app/) and its `rish` shell-uid bridge at
`~/.shizuku/rish`. The panel then reads `/proc/net/dev` as shell uid (2000) and
labels the panel *“via Shizuku.”* This is **entirely optional and best-effort**:

- Without Shizuku (the default) the bridge is a no-op — nothing changes, no error.
- Shizuku's service **stops on every reboot** (a non-root limitation), so the
  network panel reverts to “restricted” until you re-enable Shizuku. The panel
  handles this gracefully (it never blocks on the bridge).
- Nothing else in the stack depends on it; it only enriches one read-only panel.

## Design invariants (don't "fix" these)

- **gunicorn runs a SINGLE worker, with NO `--preload`.** The brute-force lockout
  counters live in process memory and are persisted to disk; a second worker would
  diverge them, and `--preload` would make recycled workers revert to a stale
  startup snapshot of the counters. With one worker `--preload` saves nothing.
- **Binds `127.0.0.1` only.** Public reach is exclusively via the tunnel → Caddy.
- **Scripts are an allow-list**, run via fixed argv (no `shell=True`, no user input
  to a shell). Backup deletes validate the bucket + basename and enforce realpath
  containment.

## See also

- [APP_AUTH.md](APP_AUTH.md) — Cloudflare Access vs the optional Matrix-SSO gateway.
- [BACKUPS.md](BACKUPS.md) — the backup scripts the panel triggers, and restore.
- [SECURITY.md](SECURITY.md) — the wider threat model and operator checklist.
