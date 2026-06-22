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
4. Downloads are **pinned and `sha256`-verified** fail-closed; every version pin
   lives in one place — [`config/versions.env`](config/versions.env) — and is
   bumped safely with [`scripts/ops/update.sh`](scripts/ops/update.sh) (snapshot →
   verify → health-check → rollback; see [`docs/UPDATING.md`](docs/UPDATING.md)).
   Never add an unverified fetch.
5. `bash -n` your scripts (and `shellcheck` if you have it); for Python,
   `python3 -m py_compile <file>`. [`scripts/ops/doctor.sh`](scripts/ops/doctor.sh)
   runs a quick read-only health/preflight check.

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

## Continuous integration

Every push and pull request runs [`.github/workflows/ci.yml`](.github/workflows/ci.yml),
which must pass:

- **leak-scan** — `tools/leak-scan.sh` as a blocking secret/IP gate;
- **shellcheck** — `--severity=error` on all shell scripts;
- **python** — `py_compile` of every tracked `.py`;
- **install --check** — validates the install plan from a synthetic `.env`.

Run the equivalents locally before pushing so CI stays green.

## Versioning & releases

The project follows [Semantic Versioning](https://semver.org/) (`MAJOR.MINOR.PATCH`)
with a [Keep a Changelog](https://keepachangelog.com/) `CHANGELOG.md`. While we are
`0.x`, minor versions may include breaking changes — each is called out in the
changelog. Add user-facing changes under `## [Unreleased]` as you go.

Releases are cut from `main`: move `[Unreleased]` to the new version, tag
`vX.Y.Z`, and publish a GitHub release. `0.x` tags are prereleases; `1.0.0` will
be the first stable release.

## Commit style

- Small, focused commits with a clear imperative subject line.
- Don't commit generated files, `.env`, backups, or build output (see
  [`.gitignore`](.gitignore)).

By contributing, you agree that your contributions are licensed under the
project's [MIT License](LICENSE).
