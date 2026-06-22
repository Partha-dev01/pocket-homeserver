# Security Policy

## Reporting a vulnerability

**Please report security issues privately — do not open a public issue or PR.**

Use GitHub's private vulnerability reporting:
[**Report a vulnerability**](https://github.com/Partha-dev01/pocket-homeserver/security/advisories/new)
(repository **Security** tab → *Report a vulnerability*).

Include, as best you can:

- the affected component/version (or commit) and the relevant `ENABLE_*` flags,
- a description and the impact (what an attacker gains),
- steps to reproduce or a proof of concept,
- any suggested fix.

Please **redact secrets** from anything you attach — `.env` values, the Cloudflare
Tunnel token, registration/admin tokens, keys. This is a single-maintainer hobby
project, so responses are best-effort; you'll get an acknowledgement and, once a
fix ships, credit in the release notes if you'd like it.

## Supported versions

Pre-1.0, only the **latest release** receives security fixes. Always update to the
newest tag (see [docs/UPDATING.md](docs/UPDATING.md)).

| Version | Supported |
|--------|-----------|
| latest release (`0.x`) | ✅ |
| older releases | ❌ |

## Security model (in brief)

pocket-homeserver is designed to keep a phone-hosted stack defensible:

- **No public inbound.** Services bind **loopback** (`127.0.0.1`) inside the proot
  userland; the only path in is a Cloudflare Tunnel → Caddy. There are no
  `0.0.0.0` listeners by default.
- **Everything optional is OFF.** Every module is gated by an `ENABLE_*` flag,
  disabled by default; you only expose what you turn on.
- **Secrets stay out of git.** Config and secrets live in `.env` (mode `0600`),
  which is gitignored; they are never committed and never passed on a command line.
  `tools/leak-scan.sh` runs in CI as a **blocking gate** on every push/PR.
- **Verified supply chain.** Every fetched binary/archive is pinned to an exact
  `sha256` (`config/versions.env`) and verified fail-closed — a mismatch aborts
  the install rather than running an unknown binary.
- **Sensible auth.** Browser apps can sit behind Cloudflare Access and/or the
  optional Matrix-SSO gateway; API/token clients use their own native auth.

The full architecture and the threat model are in
[docs/SECURITY.md](docs/SECURITY.md) and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
