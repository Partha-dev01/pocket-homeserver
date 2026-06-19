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
- **`ops/`** — operational scripts the panel drives: `restart.sh`, `status.sh`,
  `backup-db.sh` / `backup-all.sh` / `rotate-backups.sh`, and `panic-soft.sh` /
  `panic-hard.sh`.

## Library

- **`lib/common.sh`** — sourced by every script. Provides logging (`say/ok/warn/
  die`), `.env` loading with defaults, validation (`require_var`/`require_cmd`),
  idempotency markers (`run_once`/`mark_done`/`is_done`), and a process
  supervisor (`supervise`/`unsupervise`) with restart-safe PID identity checks.

## Layout (filling in incrementally)

```
install.sh          orchestrator (resumable; ../pocket.sh drives it)
start-stack.sh      bring the whole stack up / --restart
render-config.sh    .env -> config/rendered/
lib/common.sh       shared library
steps/              core install/bring-up steps (userland, cloudflared, Caddy,
                    Matrix, Element, auth gateway, admin)
apps/               one install script per optional app
ops/                operational scripts (restart, status, backups, panic)
gateway/            the optional Matrix-SSO auth gateway
```
