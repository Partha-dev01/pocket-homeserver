# SPEC-SITES-PIPELINE — Pocket Pages core: static-site hosting + deploy pipeline (`sites` module)

**Status: APPROVED 2026-07-17** (operator delegated the open questions; resolutions recorded in §14).
Milestone: M1 of the Pocket Pages program (ships as `v1.1.0-pre1`).
Related (later specs): SPEC-SITES-PANEL (admin UI), SPEC-LANDING-SYNC, SPEC-MCP-COMPLETION, SPEC-DIFFERENTIATORS.

---

## 1. Goal

Netlify-like static-site hosting ON the phone: upload an artifact (zip or prepared dir) → optional build →
**atomic all-or-nothing publish** → live at `https://<site>.<DOMAIN>` → immutable release history →
**instant pointer-swap rollback**. One pipeline, consumed by three frontends (admin panel M2, MCP tools M3,
webhooks M4). No Docker, no root, no new long-running process.

## 2. Non-goals (v1.1.0)

- Content-addressed incremental uploads (Netlify digest model) — v1.2 roadmap.
- Preview-then-promote deploy URLs — v1.2 roadmap.
- Per-site custom Caddy config (headers/redirects) — v1.2 (drop-in override mechanism).
- Serverless functions — explicitly deferred (riskiest; needs rlimit/seccomp design).
- Multi-tenant/user-owned sites: the operator owns all sites (single-operator model, same as the rest).

## 3. Architecture decisions

### AD-1 — ONE wildcard Caddy vhost; per-site deploys are pure filesystem operations
Instead of one Caddy drop-in per site (the proxy-routes model), the module installs a **single**
`/etc/caddy/apps/sites.caddy` with a wildcard site address and a **dynamic root derived from the host
label**:

```caddyfile
# ONE static block — never edited again after install
http://*.${DOMAIN}:${CADDY_PORT} {
	bind ${CADDY_BIND}
	root * ${SITES_ROOT_USERLAND}/{labels.<L>}/current
	@dot path /.*
	respond @dot 403
	header {
		X-Content-Type-Options nosniff
		Referrer-Policy strict-origin-when-cross-origin
		Cache-Control "public, max-age=300"
	}
	file_server
}
```

- `{labels.<L>}` = the site's subdomain label. Caddy labels are **0-indexed from the right**
  (`site.example.com` → labels.0=com, labels.1=example, labels.2=site), so the installer computes
  `L = <number of labels in ${DOMAIN}>` once at install time (example.com → 2; example.co.uk → 3).
- **Exact-hostname site blocks always outrank the wildcard** (verified against Caddy docs patterns —
  wildcard + exact blocks coexist; most-specific host wins), so `chat.`, `admin.`, `mcp.`, every existing
  app vhost is untouched. E2E asserts this with the pinned Caddy binary.
- Host labels cannot contain `/` or `.` (RFC host parsing; a label is by definition dot-free), so the
  dynamic `root` cannot be path-traversed via the Host header. The wildcard matches exactly ONE label.
- Unknown/undeployed subdomains fall into the wildcard and 404 (missing root dir) — asserted in E2E.

**Consequences (why this beats per-site drop-ins):**
- Deploy/rollback/delete = directory + symlink operations only. **No Caddy config change, no
  `caddy validate`, no reload, no restart, zero ingress blip, nothing to corrupt** per deploy.
- The only Caddy touch is the ONE-TIME module install (drop the wildcard vhost + validate + the standard
  "restart the stack when convenient" hint — identical UX to every other app install).
- The failure domain of a bad deploy shrinks to one site's directory tree.

### AD-2 — SITES_ROOT lives inside the userland rootfs, accessed natively from Termux
`SITES_ROOT_USERLAND=/var/www/sites` (path Caddy serves). The host-side view is
`${PD_BASE}/debian/var/www/sites` where `PD_BASE="${PREFIX}/var/lib/proot-distro/installed-rootfs"`
(exact pattern already used by `ops/backup-all.sh:33` and `ops/restore.sh:43`).

- Termux-native code (pipeline scripts, later the panel) does **plain file I/O on the host path** — no
  proot round-trip for file operations; proot is only needed to *execute* things in the userland
  (`caddy validate` at install; Node builds).
- The rootfs is on **ext4** (`/data`) → safe for JSON state, symlinks, hardlinks (exFAT SD would break all
  three — `rsync --link-dest`, `ln -sfn`, atomic `mv -T` all need ext4 semantics).
- **Backup coverage is automatic**: `ops/backup-all.sh` tars the entire rootfs, `/var/www/sites` included
  (same coverage class as Element/landing). GC retention (AD-5) keeps growth bounded; `docs/SITES.md` must
  note that site history adds to rootfs snapshot size.

### AD-3 — Build tiers (operator decision Q1: ship all three)
`build` mode is per-site, recorded in `meta.json`: `none` (default) | `hugo` | `node`.

| Tier | Mechanism | Guardrails |
|---|---|---|
| `none` | artifact is served as-is | zip-safety caps only |
| `hugo` | pinned Hugo binary (`config/versions.env`: `HUGO_VERSION` + `HUGO_SHA256`, arm64 tarball → `/opt/hugo/hugo` via `fetch_verified`), run **in the userland** against the extracted source; publishes `public/` | timebox `SITES_BUILD_TIMEOUT` (default 300s); niceness `nice -n 10` |
| `node` | userland `nodejs`+`npm` via apt (pingvin precedent, `apps/pingvin.sh:98`; node ≥ 20 check reused); `npm ci --no-audit --no-fund` + `npm run build`; publishes `SITES_NODE_PUBLISH_DIR` (default `dist`, fallbacks `build`, `out`, `public`) | **serialized global build lock** (`${POCKET_STATE_DIR}/site-build.lock`, `flock`-style noclobber — builds NEVER concurrent); RAM ceiling via `ulimit -v` (`SITES_BUILD_MAX_RAM_MB`, default 1024); timebox (default 900s); on kill → job FAILED with a clear reason; npm cache persisted in the userland for reuse |

Build tools install **lazily**: `sites.sh` installs nothing heavy; the first `hugo`/`node` deploy triggers
the tool install (logged in the deploy log). Keeps the module light for upload-only users.

### AD-4 — Atomic publish
1. Stage: extract/copy/build into `releases/<RELEASE_ID>.tmp/` (same filesystem).
2. Fsync-then-rename: `mv -T releases/<id>.tmp releases/<id>` (atomic on ext4).
3. Swap: `ln -sfn releases/<id> current.tmp && mv -T current.tmp current` — the classic two-step that makes
   the symlink swap a **single rename syscall**. Caddy resolves `current` per-request → zero-404 window.
4. Rollback = step 3 pointing at an older release. Nothing is rebuilt, nothing is copied.

### AD-5 — Retention/GC
Keep `SITES_KEEP_RELEASES` (default 5) most-recent releases per site; never GC the release `current` points
at. `rsync --link-dest=<prev-release>` hardlinks unchanged files between releases, so history is cheap.
GC runs at the end of every deploy + on demand (`site-gc.sh`).

### AD-6 — Job model (shared with panel/MCP)
Every deploy/rollback/delete allocates `JOB_ID` (`<UTC-ts>-<4hex>`); writes
`${POCKET_STATE_DIR}/site-job-<JOB_ID>.json`:

```json
{"job": "<id>", "kind": "deploy|rollback|delete", "site": "<name>",
 "state": "running|done|failed", "release": "<release-id-or-null>",
 "started": "<iso8601>", "ended": "<iso8601|null>", "error": "<string|null>"}
```

Per-job log: `${POCKET_LOG_DIR}/site-deploy-<JOB_ID>.log` (SSE-tailed by the panel in M2; `pocket_site_status`
polls the state file in M3). Job/state files GC'd after `SITES_JOB_RETENTION_DAYS` (default 7).

## 4. Filesystem layout

```
${PD_BASE}/debian/var/www/sites/            # = SITES_ROOT (host view; userland sees /var/www/sites)
├── .registry.json                          # site index (schema §5)
├── .staging/                               # server-allocated upload staging, GC'd with jobs
│   └── upload-<JOB_ID>.zip
└── <site>/
    ├── current -> releases/<RELEASE_ID>    # atomic pointer (relative symlink)
    ├── meta.json                           # {created, build, publish_dir, spa (v1: recorded, not enforced), quota_mb, notes}
    └── releases/
        ├── 20260717T1200Z-a1b2/            # immutable release trees (hardlink-deduped)
        └── 20260718T0900Z-c3d4/
```

## 5. Registry schema — `.registry.json`

```json
{"version": 1, "sites": {
  "<name>": {"created": "<iso8601>", "updated": "<iso8601>",
              "active_release": "<release-id>", "releases": ["<id>", "..."],
              "build": "none|hugo|node", "bytes": 12345, "url": "https://<name>.<DOMAIN>"}}}
```

Written atomically (tmp + `os.replace`/`mv -T`); the registry is derived state — `site-list.sh --rebuild`
reconstructs it from the directory tree (self-healing after restores).

## 6. Pipeline scripts — `scripts/sites/` (all Termux-native bash, `set -euo pipefail`, source `lib/common.sh`)

| Script | Contract |
|---|---|
| `site-deploy.sh <name> <staged-artifact> [--build none\|hugo\|node] [--job <id>]` | validate name (§7) → allocate release + job → safe-extract (§8) or copy dir → build tier (AD-3) → sanity (`index.html` present at publish root unless `--allow-no-index`) → atomic swap (AD-4) → registry update → landing-regen hook (no-op until M2 ships `regen-landing.sh`) → GC → job `done`. Exit 0 only if live. |
| `site-rollback.sh <name> [<release-id>]` | default = previous release; pure pointer swap + registry update + job record. |
| `site-list.sh [--json] [--rebuild]` | registry dump / rebuild-from-tree. |
| `site-delete.sh <name> [--yes]` | interactive confirm unless `--yes` (panel/MCP pass it after their own gates); removes the site tree + registry entry; wildcard vhost untouched (host now 404s). |
| `site-gc.sh [<name>]` | retention GC + stale staging/job cleanup. |

Rules: **the only user-derived argv input is `<name>`** (validated §7) and an optional release id
(validated `^[0-9TZ-]+-[0-9a-f]{4}$` + must exist in the registry). Staged artifact paths are always
server-allocated (panel/MCP write into `.staging/` themselves and pass the path they created;
`site-deploy.sh` additionally realpath-asserts the artifact is inside `.staging/` OR the operator ran it
by hand from a shell (tty check) with any path — CLI convenience without widening the panel/MCP surface).

## 7. Name validation + reservations

- Regex: `SUB_RE='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'` (reuse from `proxy-routes.sh:98`).
- Reserved (refuse to create): `CORE_SUBS` (proxy-routes.sh:86: chat admin files music books audiobooks
  read dav wiki vault links share rss notes tasks search tools status stickers webmail ai mcp git dns)
  **plus** `www mail mta smtp imap pop autoconfig autodiscover matrix sites api cdn ns1 ns2 preview` —
  factored into `scripts/sites/reserved-subs.sh` sourced by both this module and (follow-up) proxy-routes.
- Also refuse names already claimed by a BYO proxy route (check `/etc/caddy/apps/byo-<name>.caddy` —
  the filename `proxy-routes.sh:206` actually writes; `route-<name>.caddy` is additionally checked as a
  belt against a future rename) and vice-versa (proxy-routes gains the same check in a follow-up —
  noted in SPEC, small diff).

## 8. Zip/artifact safety (enforced in `site-deploy.sh`'s extractor — Python stdlib helper `scripts/sites/safe_extract.py`)

- Total compressed size ≤ `SITES_MAX_UPLOAD_MB` (default 200) — checked by the frontends too, re-checked here.
- Entries ≤ 20,000; per-file uncompressed ≤ 512 MB; total uncompressed ≤ 4× `SITES_MAX_UPLOAD_MB`
  (zip-bomb ratio cap, configurable `SITES_MAX_RATIO`).
- Every entry: reject absolute paths, `..` after normalization, symlink/hardlink entries, non-regular files;
  realpath of every extraction target must stay under the release dir (belt over Python's own guards —
  `zipfile` alone is NOT sufficient policy).
- Extraction streams to disk (no in-memory inflation).
- Unit-tested with traversal/symlink/bomb fixtures **in M1** (tests land with the pipeline, not later).

## 9. Env vars (`.env.example` additions)

```
ENABLE_SITES=false            # Pocket Pages static-site hosting -> <site>.${DOMAIN} (wildcard vhost)
SITES_MAX_UPLOAD_MB=200       # per-artifact cap (panel + extractor)
SITES_KEEP_RELEASES=5         # per-site release history retention
SITES_BUILD_TIMEOUT=900       # seconds; per-build hard timebox (hugo default 300 internally)
SITES_BUILD_MAX_RAM_MB=1024   # ulimit -v ceiling for node builds
```
(`SITES_JOB_RETENTION_DAYS=7`, `SITES_MAX_RATIO=4` exist as env-overridable internals, not in .env.example.)

## 10. Installer — `scripts/apps/sites.sh`

1. Standard preamble (`load_env`, `require_var DOMAIN DATA_DIR`, `require_cmd proot-distro`).
2. `mkdir -p` SITES_ROOT (+`.staging`) via the host path; seed empty `.registry.json`.
3. Compute label index `L` from `${DOMAIN}`; render + drop `/etc/caddy/apps/sites.caddy` (AD-1) via the
   standard proot heredoc; `caddy validate` fail-closed (landing pattern `84-install-landing.sh:173-183`).
4. Print closing notes: CF dashboard **either** one-time wildcard Public Hostname
   `*.${DOMAIN} → http://localhost:${CADDY_PORT}` (zero-step future sites; requires CF free wildcard —
   first-level only, which is exactly what we use) **or** per-site explicit hostnames; plus the standard
   `start-stack.sh --restart` hint. No supervise, no `.cmd`, no port (process-less — landing precedent).
5. Registrations: `install.sh` `app_order`/`app_step`; `admin/app.py` `ENABLE` + `APP_CATALOG` entries
   (full panel UI is M2 — M1 only registers the flag so the catalog can install the module);
   `docs/SITES.md`; `docs/APPS.md` row; `CHANGELOG.md` `### Added`; `config/versions.env` Hugo pin.

## 11. Security invariants (module-wide)

1. Caddy serves sites read-only; dotfiles 403; no directory listing (no `browse`).
2. No user-derived strings ever reach a shell unvalidated: name/release-id regex-validated; artifact paths
   server-allocated + realpath-contained; build commands are fixed strings (never from meta/artifact).
3. Node builds are the highest-risk surface (arbitrary `npm` lifecycle scripts run *as the userland user*):
   documented loudly in `docs/SITES.md` — same trust model as installing any app in the userland; mitigations
   = RAM/time caps + serialized lock; **the operator only deploys their own code** (single-operator model).
4. Wildcard vhost cannot shadow core apps (exact blocks win) and cannot traverse (single dot-free label).
5. Quotas everywhere a byte enters: upload cap, ratio cap, entry cap, release retention.
6. Everything auditable: job files + per-deploy logs; frontends additionally `log_audit` (M2/M3).

## 12. Test plan (lands WITH M1)

**Unit (`tests/`, pytest — first tests in the repo; CI gains job #5):**
safe_extract (traversal · symlink · bomb-ratio · entry-cap · absolute-path fixtures) · name validation +
reserved list · atomic swap helper (tmpdir: swap under concurrent reader, rollback correctness) · registry
read/update/rebuild · job-state lifecycle.

**E2E (arm64 qemu, 1.0-program harness):** install `ENABLE_SITES=true` → deploy fixture site (zip) →
assert 200 on `site1.<domain>` via loopback Host-header curl; assert exact-vhost precedence (`chat.` still
routes to Element/matrix vhost, NOT the wildcard); assert unknown subdomain → 404; redeploy v2 while
curl-looping (no non-200 during swap); rollback → v1 content; GC keeps N; zip-bomb fixture rejected;
`site-delete` → 404 + registry clean; Hugo-tier fixture build; node-tier fixture build under the lock
(skippable in constrained CI via flag, always run pre-release).

**Laptop smoke:** shellcheck all new scripts; `py_compile` safe_extract; `install.sh --check` with
`ENABLE_SITES=true`; wildcard-vhost + labels-placeholder behavior probed against the pinned Caddy binary
locally (validates AD-1 assumptions before qemu).

## 13. Out of scope here, handled by later specs

Panel upload endpoint/UI + SSE (SPEC-SITES-PANEL) · landing regen + re-theme (SPEC-LANDING-SYNC) ·
MCP tools/job polling (SPEC-MCP-COMPLETION) · webhook/share-sheet/forms/analytics (SPEC-DIFFERENTIATORS).

## 14. Open questions — RESOLVED 2026-07-17 (operator delegated; defaults accepted)

- **OQ-1**: `SITES_MAX_UPLOAD_MB=200` — **accepted** (generous cap; env-overridable).
- **OQ-2**: `SITES_KEEP_RELEASES=5` — **accepted**.
- **OQ-3**: reserved list as specified in §7 — **accepted** (deliberately does NOT reserve generic words
  like `blog`/`test` an operator may legitimately want as site names; overridable via a follow-up env knob
  if ever needed).
- **OQ-4**: SPA fallback recorded-not-enforced in pre1 — **accepted** (global `SITES_SPA_MODE` lands with
  the panel milestone; per-site override deferred to v1.2).
