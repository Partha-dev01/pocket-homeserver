<!-- Thanks for contributing! Keep PRs focused. Link any related issue. -->

## What & why


## Checklist
- [ ] `tools/leak-scan.sh` passes — no secrets, public IPs, or deployment-specific data
- [ ] Changed shell is `shellcheck --severity=error` clean; changed Python `py_compile`s
- [ ] Any new long-running service is gated by an `ENABLE_*` flag (**OFF by default**) and supervised via `lib/common.sh`
- [ ] Secrets come from `.env` / `setup.sh` (0600) — never committed, never passed on argv
- [ ] Services bind loopback (`127.0.0.1`) and are reached via a Caddy vhost; `caddy validate` stays fail-closed
- [ ] New component versions are pinned in `config/versions.env`; binary downloads are sha256-verified
- [ ] Docs updated (relevant `docs/*.md`) and a `CHANGELOG.md` `[Unreleased]` entry added
