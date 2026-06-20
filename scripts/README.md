# scripts/

Config-driven bring-up for pocket-homeserver. Every script reads `../.env`
(copy it from `../.env.example` first) and is idempotent — safe to re-run.

## Entrypoints

- **`../pocket.sh`** — the interactive control panel (TUI). The friendly front
  door; every menu item just runs one of the scripts below. Start here.
- **`install.sh`** — the orchestrator (resumable + idempotent).
  - `./scripts/install.sh` runs the plan. Each completed step is recorded under
    `${POCKET_STATE_DIR}` and skipped next time, so re-runs are fast and an
    interrupted install resumes. Optional-app steps run only when their
    `ENABLE_<APP>` flag is `true`.
  - `--status` shows what's installed and what's running; `--check` prints the
    ordered plan without running anything; `--force` redoes every step (use after
    changing `.env`); `--reset` clears the step markers.
- **`start-stack.sh`** — brings the whole stack up (or `--restart`s it): core
  services plus every installed app, re-supervised from the launch commands
  recorded at install time. Run by `install.sh` as its last step.
- **`render-config.sh`** — renders `../config/*.tmpl` into `../config/rendered/`,
  substituting the values from `.env` (the rendered output is gitignored).
- **`ops/`** — operational scripts the panel and `pocket.sh` drive:
  - service control — `restart.sh`, `status.sh`;
  - backups — `backup-db.sh`, `backup-all.sh`, `rotate-backups.sh`, and the
    optional scheduled `backup-daemon.sh` (gated on `ENABLE_BACKUP_DAEMON`);
  - recovery — `restore.sh` (dry-run by default);
  - credential rotation — `rotate-admin-password.sh`,
    `rotate-registration-token.sh`, `rotate-tunnel-token.sh`,
    `rotate-authgw-rs.sh`, `rotate-adminbot-token.sh`, and `rotate-all.sh`;
  - break-glass — `panic-soft.sh` (tunnel only) / `panic-hard.sh` (whole stack).

## Library

- **`lib/common.sh`** — sourced by every script. Provides logging (`say/ok/warn/
  die`), `.env` loading with defaults, validation (`require_var`/`require_cmd`),
  idempotency markers (`run_once`/`mark_done`/`is_done`), and a process
  supervisor (`supervise`/`unsupervise`) with restart-safe PID identity checks.

## Layout

```
install.sh          orchestrator (resumable; ../pocket.sh drives it)
start-stack.sh      bring the whole stack up / --restart
render-config.sh    .env -> config/rendered/
watchdog.sh         JobScheduler self-heal job (re-runs the bring-up)
lib/common.sh       shared library
steps/              numbered install/bring-up steps, run in order:
                      00 prereqs · 10 userland · 20 cloudflared · 30 Caddy ·
                      40 Matrix · 50 Element · 60 auth gateway · 70 admin ·
                      75 boot survival · 77 honeypot · 78 filters ·
                      79 bootstrap · 80 cloud bots · 81 exobot ·
                      82 stickers · 83 admin bot · 84 landing · 85 email ·
                      86 webmail · 87 MCP   (optional steps self-gate on ENABLE_*)
apps/               one install script per optional app (linkding, freshrss,
                    gatus, ittools, memos, pingvin, searxng, vikunja)
ops/                operational scripts (service control, backups, restore,
                    credential rotation, panic — see above)
gateway/            the optional Matrix-SSO auth gateway
honeypot/           the optional scanner-detection watcher (+ geo datasets dir)
filters/            the optional privacy / media loopback proxies
bootstrap/          the optional one-shot Matrix seeding
chatbot/            the optional cloud-LLM and on-phone (exobot) chat bots
sticker/            the optional sticker-picker backend + import bot
adminbot/           the optional operator-only Matrix ops bot
landing/            the optional apex landing portal
email/              the optional Maddy + R2-drain mail pipeline
mcp/                the optional Model Context Protocol server
```
