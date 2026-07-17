# Pocket Pages — static-site hosting on the phone

Netlify-like static-site deploys, hosted entirely on the phone: upload a zip
(or point the CLI at a directory) → optional on-phone build → **atomic
publish** → live at `https://<site>.<your-domain>` → immutable release history
→ **instant rollback**. No Docker, no separate server process — the core Caddy
serves every site through one wildcard vhost.

Design spec: [specs/SPEC-SITES-PIPELINE.md](specs/SPEC-SITES-PIPELINE.md).

## Enable

```bash
# .env
ENABLE_SITES=true
# then
./scripts/install.sh
```

The installer creates `/var/www/sites` (inside the userland), seeds the site
registry, and drops **one** wildcard Caddy vhost (`*.${DOMAIN}`). After the
one-time Cloudflare step below, **deploys never touch Caddy, DNS, or the
dashboard again** — they are pure filesystem operations.

**One-time Cloudflare step** (Zero Trust dashboard) — either:
- **Wildcard (recommended)**: add a Public Hostname `*.<your-domain>` →
  `http://localhost:8443`. Every future site is live the moment you deploy it.
  Explicit hostnames (`chat.`, `admin.`, …) keep outranking the wildcard.
- **Per-site**: add `<site>.<your-domain>` → `http://localhost:8443` for each
  site you deploy.

Site hostnames are deliberately **first-level** (`mysite.example.com`, never
`mysite.sites.example.com`): Cloudflare's free Universal SSL only covers one
wildcard level.

## Deploy

```bash
# a pre-built site (dir with index.html at its root, or a zip of one):
scripts/sites/site-deploy.sh mysite /path/to/dist-or.zip

# with an on-phone build (toolchain installs lazily on first use):
scripts/sites/site-deploy.sh blog source.zip --build hugo
scripts/sites/site-deploy.sh app  source.zip --build node   # npm ci && npm run build
```

Every deploy creates an immutable `releases/<id>/` tree and flips the site's
`current` symlink in a **single atomic rename** — a visitor never sees a
half-updated site, and there is no downtime window.

```bash
scripts/sites/site-list.sh              # what's deployed
scripts/sites/site-rollback.sh mysite   # instant: point back at the previous release
scripts/sites/site-rollback.sh mysite <release-id>
scripts/sites/site-delete.sh  mysite    # asks you to type the site name to confirm
scripts/sites/site-gc.sh                # retention + staging + job-record cleanup (also runs after each deploy)
```

## Build tiers

| Tier | What runs | Guardrails |
|---|---|---|
| *(default)* pre-built | nothing — your artifact is served as-is | size/zip-safety caps |
| `--build hugo` | pinned, sha256-verified Hugo binary (plain build, no Sass) | timeboxed, niced |
| `--build node` | `npm ci && npm run build` in the userland (Node ≥ 20 via apt) | **one build at a time** (global lock), RAM ceiling (`SITES_BUILD_MAX_RAM_MB`), timebox (`SITES_BUILD_TIMEOUT`) |

⚠ **The Node tier runs your project's npm lifecycle scripts** with the
userland's privileges — the same trust model as installing any app into the
userland. Deploy only code you trust (on a single-operator server, that's your
own code). The RAM/time caps protect the phone's other services from a runaway
build, not you from malicious code.

## Safety & limits

- Uploads are capped (`SITES_MAX_UPLOAD_MB`, default 200) and zip extraction is
  hardened: path-traversal, symlink entries, absolute paths, entry-count and
  zip-bomb ratio caps are all rejected (unit-tested in `tests/`).
- Site names are DNS-label-validated and checked against a reserved list
  (core hostnames like `chat`, `admin`, `mcp`, `mail`, … can never be claimed).
- Release history is pruned to `SITES_KEEP_RELEASES` (default 5). Redeploying
  from a **directory** artifact hardlink-dedupes unchanged files against the
  previous release (`rsync --checksum --link-dest`), so history stays cheap;
  **zip** uploads extract fresh every time (no dedupe — each zip release costs
  its full size on disk).
- Dotfiles are never served; directory listings are off.

## Where things live / backups

Everything lives inside the userland rootfs (ext4):
`/var/www/sites/<site>/releases/…` + `current` + a small JSON registry. That
means deployed sites are **automatically inside `ops/backup-all.sh`'s rootfs
snapshot** — no extra backup wiring. Release history adds to snapshot size;
retention (above) keeps it bounded.

## Interactions worth knowing

- **Unknown subdomains**: with the wildcard hostname configured, a subdomain
  with no deployed site serves a plain 404 (missing release root). Harmless.
- **BYO proxy routes** (`ENABLE_PROXY_ROUTES`): a site name that collides with
  an existing BYO route is refused. (The reverse check lands in proxy-routes in
  a follow-up.)
- **Admin panel**: the Sites section (upload UI, deploy log streaming, rollback
  buttons, QR share) ships in the next prerelease; in this one the panel's app
  catalog can install the module, and the CLI above is the deploy surface.
- **MCP**: agentic deploy tools (`pocket_site_deploy` etc.) ship with the MCP
  completion milestone.
