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

### From the admin panel

With the panel enabled, the **Sites** page gives you the same pipeline without
a shell: drag a `.zip` onto the drop zone (name + admin password re-auth, the
same bar the app catalog uses), watch the deploy log stream live, then roll
back, share a QR of the live URL, or delete from the site's card. Panel
uploads accept **pre-built** zips only — `--build hugo|node` source deploys
stay CLI-only. See [ADMIN.md](ADMIN.md#sites-pocket-pages-section-optional).

> **Upload speed**: a panel upload travels over the Cloudflare Tunnel — fine
> for typical site sizes, but a near-cap (200 MB) upload can take minutes on a
> phone SIM. Off-tunnel paths are meaningfully faster: an `ssh -L 9000:127.0.0.1:9000`
> tunnel straight to the panel, or `scp` + the CLI deploy over local Wi-Fi.

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

## SPA mode (client-side routers)

`SITES_SPA_MODE=true` in `.env` makes **every** deployed site fall back to its
`/index.html` on unknown paths (`try_files {path} {path}/ /index.html`), so a
client-side router (React Router, Vue Router, …) survives hard refreshes and
deep links. It is a **global, toggle-time** setting — it edits the ONE wildcard
vhost, never a per-site config — and defaults to `false` (a bare `file_server`,
the right behavior for sites without a router). Apply a change by re-running
`bash scripts/apps/sites.sh` (re-renders + `caddy validate`s the vhost) and
restarting Caddy, or from the admin panel's Sites section.

The dotfile 403 guard is unaffected: an **existing** dotfile keeps its path
through `try_files` and still 403s; only paths that don't exist rewrite to the
SPA shell.

## Landing page sync

With the landing portal enabled (`ENABLE_LANDING=true`, see
[LANDING.md](LANDING.md)), every deploy and delete refreshes a "your sites"
card grid on the portal automatically — the pipeline calls
`scripts/landing/regen-landing.sh` as a best-effort hook after the registry
update (a landing hiccup never fails a deploy). No installer rerun needed.
Note the portal is public by default, and every deployed site is listed on it;
gate the portal behind the SSO gateway (see LANDING.md) if you don't want a
public directory.

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
- **Admin panel**: the Sites section (drag-drop deploys, live deploy log,
  rollback, QR share, guarded delete) covers day-to-day operation — see
  "From the admin panel" above; builds and bulk work stay on the CLI.
- **MCP**: with the MCP server enabled, an LLM agent can drive the same
  pipeline — list/deploy/poll/rollback/delete (`pocket_sites_list`,
  `pocket_site_deploy`, …). Artifacts are staged out-of-band (`scp` into
  `.staging/`), never sent over MCP — see
  [MCP.md — Deploying a site over MCP](MCP.md#deploying-a-site-over-mcp).
