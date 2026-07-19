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

## Git-push-to-deploy (Forgejo webhooks)

With the bundled git forge installed ([FORGEJO.md](FORGEJO.md)) and
`ENABLE_SITES_WEBHOOKS=true`, a `git push` deploys a site end to end — no
zip, no panel click:

1. In the admin panel, open the site's card → **git-push-to-deploy →** and
   generate the webhook secret (shown once).
2. In Forgejo: your repo → Settings → Webhooks → Add Webhook → Forgejo, and
   paste the target URL + secret the panel shows (POST, `application/json`,
   push events).
3. Push to `SITES_WEBHOOK_BRANCH` (default `main`). The panel verifies the
   HMAC signature, archives the pushed commit from the bare repo with
   `git archive`, and hands it to the exact same deploy pipeline every other
   channel uses. Pushes to any other branch are skipped, not errors.

Notes:
- Delivery is **loopback-only** (Forgejo → the panel's local bind) — it never
  crosses the tunnel or Cloudflare Access. But do remember the pre-existing
  requirement the forge docs call out prominently: **`git push` itself over
  HTTPS needs the Cloudflare Access service-token exemption for
  `git.${DOMAIN}`** ([FORGEJO.md](FORGEJO.md)) — git clients can't follow a
  302-to-login. Webhooks make pushing a first-class deploy path, so that
  exemption is now load-bearing for Pocket Pages too.
- **Upgrading from a pre-M4 install:** Forgejo's own webhook SSRF guard
  (`[webhook] ALLOWED_HOST_LIST`) defaults to `external` and silently refuses
  loopback targets. Re-run `scripts/apps/forgejo.sh` once — it appends
  `ALLOWED_HOST_LIST = loopback` to an existing `app.ini` (an operator-set
  value is respected, never overridden) and restarts nothing by itself.
- The build tier used is whatever the site's registry records (`none` for a
  never-deployed site — push pre-built output, or deploy once with `--build
  hugo|node` first).
- Per-site cooldown (`SITES_WEBHOOK_COOLDOWN_S`) gives cheap back-pressure
  against a runaway loop; rotating the secret in the panel invalidates the
  one pasted into Forgejo.

## Deploy from your phone (share sheet + widget)

Two opt-in, on-device deploy paths — honest descriptions, since neither can
show "pocket-homeserver" in Android's own UI:

- **Share-sheet deploy** (`ENABLE_SITES_SHARE_DEPLOY=true`, then re-run the
  sites installer): share a `.zip` from any app and pick **"Termux"** in the
  share sheet (that label is the receiving app's and can't be changed without
  shipping a companion APK — out of scope). Termux saves the file to
  `~/downloads`, asks you to confirm the filename, then runs its global
  `~/bin/termux-file-editor` hook — which this feature installs: for a `.zip`
  it prompts for a site name (a popup with Termux:API installed, a terminal
  prompt without) and deploys; **every other file still opens in your editor**
  (`${EDITOR:-nano}`), preserving the hook's normal purpose. The installer
  never overwrites a `termux-file-editor` you wrote yourself — it warns and
  skips instead.
- **Widget deploy** (`ENABLE_SITES_WIDGET_DEPLOY=true`): installs
  `~/.shortcuts/pocket-deploy.sh` for the **Termux:Widget** companion app
  (F-Droid, same family as Termux:Boot). Tap the home-screen shortcut → type
  a site name → pick a `.zip` in the system file picker → it deploys. A
  two-step flow (get the file onto the device first), not literally one tap.

Both paths need Android's storage permission granted to Termux. Termux:API
(F-Droid app + the `termux-api` package) is **required for the widget** — its
file picker *is* `termux-storage-get`, and the shortcut exits with a clear
error without it — but optional for the share hook, where it only upgrades the
terminal site-name prompt to a popup and adds toast/notification feedback.
Both run the standard `site-deploy.sh` CLI path — same validation, same
atomic swap, same rollback.

## Forms

`ENABLE_SITES_FORMS=true` (then re-run the sites installer) gives every
deployed site working HTML forms with **zero client-side JavaScript**:

```html
<form method="POST" action="/__pocket-forms__/submit/contact">
  <input name="name">
  <textarea name="message"></textarea>
  <!-- honeypot: keep it hidden with your own CSS; bots fill it, humans don't -->
  <input name="_pocket_hp" style="display:none" tabindex="-1" autocomplete="off">
  <button>Send</button>
</form>
```

- `contact` in the action URL is the form's name (letters/digits/`._-`);
  the path prefix `/__pocket-forms__/` is **reserved** — a deployed file
  there is never served.
- Submissions land in a SQLite inbox in the admin panel (site card → **form
  submissions →**): body capped at `SITES_FORMS_MAX_BODY_KB`, field
  count/length capped, and rate-limited per (site, form, visitor-prefix).
- A filled honeypot marks the row spam (hidden from the default inbox view,
  never emailed) but the submitter sees a normal success page — no signal.
- **Email relay** (`ENABLE_SITES_FORMS_EMAIL=true`, needs the email module):
  non-spam submissions are relayed through the bundled Maddy to
  `SITES_FORMS_EMAIL_TO` (default: the admin mailbox). A relay failure never
  loses the submission — the row is stored first and shows `emailed=0`.
- **Privacy stance** (say this to your visitors if you're required to): the
  stored record is the field values the visitor typed, a user-agent string, a
  timestamp, and a **truncated** network prefix (/24 for IPv4, /48 for IPv6)
  — never the full address, which is also never logged. Rows are deleted
  automatically after `SITES_FORMS_RETENTION_DAYS` (default 180).

## Analytics

`ENABLE_SITES_ANALYTICS=true` (then re-run the sites installer) adds a JSON
access log to the shared sites vhost and a per-site **analytics** page in the
panel: request counts, status split, top paths, bytes served, and an
approximate unique-visitor count — parsed on demand from the log, cached a
few minutes, **no daemon, no cookies, no client-side JS, nothing per-visitor
stored** (unique counts come from a truncated-prefix set that lives only for
the length of one aggregation pass; query strings are never recorded at all).

One caveat, stated plainly: the log rotates by **size** (10 MiB × 5), not by
calendar — so "the last `SITES_ANALYTICS_RETENTION_DAYS` days" is an upper
bound. A busy site may hold less history than the window; a quiet one, more.
A calendar-stable daily rollup is on the roadmap.

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
