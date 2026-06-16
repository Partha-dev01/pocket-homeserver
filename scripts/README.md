# scripts/

Config-driven bring-up for pocket-homeserver. Every script reads `../.env`
(copy it from `../.env.example` first) and is idempotent — safe to re-run.

## Entrypoints

- **`install.sh`** — the orchestrator.
  - `./scripts/install.sh --check` validates your `.env` and prints the ordered
    plan without running anything.
  - `./scripts/install.sh` runs the plan. Optional-app steps run only when their
    `ENABLE_<APP>` flag is `true`.
- **`render-config.sh`** — renders `../config/*.tmpl` into `../config/rendered/`,
  substituting the values from `.env` (the rendered output is gitignored).

## Library

- **`lib/common.sh`** — sourced by every script. Provides logging (`say/ok/warn/
  die`), `.env` loading with defaults, validation (`require_var`/`require_cmd`),
  idempotency markers (`run_once`/`mark_done`/`is_done`), and a process
  supervisor (`supervise`/`unsupervise`) with restart-safe PID identity checks.

## Layout (filling in incrementally)

```
install.sh          orchestrator
render-config.sh    .env -> config/rendered/
lib/common.sh       shared library
steps/              core install/bring-up steps (userland, cloudflared, Caddy,
                    Matrix, Element, auth gateway, admin)
apps/               one install script per optional app
```
