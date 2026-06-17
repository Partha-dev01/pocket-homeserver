# Contributing

Thanks for your interest in pocket-homeserver. It is an early, pre-release
project, so issues, reports, and ideas are especially valuable.

## Reporting issues

Open a GitHub issue with:

- what you ran (the command and which step / app),
- what you expected and what happened (paste the relevant log lines),
- your environment — phone model, Android version, Termux source (F-Droid), and
  the app or step involved.

A clean install on a brand-new phone hasn't been exhaustively shaken out yet, so
"the setup guide didn't match reality at step N" is a genuinely useful report.

## Working on the code

1. Clone the repo and copy the config: run `./setup.sh` (the wizard) or
   `cp .env.example .env` and edit it. `.env` is gitignored.
2. The scripts are plain `bash` and source [`scripts/lib/common.sh`](scripts/lib/common.sh)
   for logging, config, validation, and the process supervisor. Match the style
   of the script you're editing.
3. Keep everything **idempotent** (safe to re-run) and **loopback-bound** — no
   service should ever listen on anything but `127.0.0.1` / `${CADDY_BIND}`.
4. Downloads are **pinned and `sha256`-verified** fail-closed (see
   [`docs/SECURITY.md`](docs/SECURITY.md)); never add an unverified fetch.
5. `bash -n` your scripts and, for the admin panel, `python3 -m py_compile admin/app.py`.

## Before you push (required)

This repository is **public**, so it must never contain secrets or
deployment-specific data. A guard script enforces this:

```bash
./tools/leak-scan.sh            # scan all tracked files
./tools/leak-scan.sh --staged   # scan only what you're about to commit
```

Run it before every push and make sure it reports `clean`. Keep real
hostnames, tokens, keys, public IPs, and personal data out of commits — use the
placeholders from `.env.example` in examples and docs.

## Commit style

- Small, focused commits with a clear imperative subject line.
- Don't commit generated files, `.env`, backups, or build output (see
  [`.gitignore`](.gitignore)).

By contributing, you agree that your contributions are licensed under the
project's [MIT License](LICENSE).
